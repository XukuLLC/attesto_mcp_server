#!/usr/bin/env sh
# Each compatibility host runs in a subshell, so exported values are intentionally scoped.
# shellcheck disable=SC2030,SC2031
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH='' cd -- "$script_dir/.." && pwd)
temp_root=${TMPDIR:-/tmp}
host_dir=$(mktemp -d "$temp_root/attesto-mcp-installer-host.XXXXXX")
phoenix_host_dir=$(mktemp -d "$temp_root/attesto-mcp-installer-phoenix-host.XXXXXX")
phoenix_floor_host_dir=$(mktemp -d "$temp_root/attesto-mcp-installer-phoenix-floor-host.XXXXXX")
phoenix_three_host_dir=$(mktemp -d "$temp_root/attesto-mcp-installer-phoenix-three-host.XXXXXX")
phoenix_postgres_floor_host_dir=$(mktemp -d "$temp_root/attesto-mcp-installer-phoenix-postgres-floor-host.XXXXXX")
outside_config_dir=$(mktemp -d "$temp_root/attesto-mcp-installer-outside-config.XXXXXX")
absent_dir=$(mktemp -d "$temp_root/attesto-mcp-installer-absent.XXXXXX")
generated_root=$(mktemp -d "$temp_root/attesto-mcp-installer-generated.XXXXXX")
generated_host_dir="$generated_root/installer_host"

cleanup() {
  rm -rf -- "$host_dir" "$phoenix_host_dir" "$phoenix_floor_host_dir" "$phoenix_three_host_dir" "$phoenix_postgres_floor_host_dir" "$outside_config_dir" "$absent_dir" "$generated_root"
}

trap cleanup EXIT HUP INT TERM

cp -R "$repo_dir/fixtures/installer_host/." "$host_dir"
cp -R "$repo_dir/fixtures/installer_host/." "$phoenix_host_dir"
cp "$repo_dir/fixtures/installer_phoenix_host/mix.exs" "$phoenix_host_dir/mix.exs"
cp "$repo_dir/fixtures/installer_phoenix_host/router.ex" "$phoenix_host_dir/lib/installer_host_web/router.ex"
cp "$repo_dir/fixtures/installer_phoenix_host/parsed_body_probe.ex" "$phoenix_host_dir/lib/installer_host_web/parsed_body_probe.ex"
cp -R "$repo_dir/fixtures/installer_host/." "$phoenix_floor_host_dir"
cp "$repo_dir/fixtures/installer_phoenix_host/mix.exs" "$phoenix_floor_host_dir/mix.exs"
cp "$repo_dir/fixtures/installer_phoenix_host/router.ex" "$phoenix_floor_host_dir/lib/installer_host_web/router.ex"
cp "$repo_dir/fixtures/installer_phoenix_host/parsed_body_probe.ex" "$phoenix_floor_host_dir/lib/installer_host_web/parsed_body_probe.ex"
cp -R "$repo_dir/fixtures/installer_host/." "$phoenix_three_host_dir"
cp "$repo_dir/fixtures/installer_phoenix_host/mix.exs" "$phoenix_three_host_dir/mix.exs"
cp "$repo_dir/fixtures/installer_phoenix_host/router.ex" "$phoenix_three_host_dir/lib/installer_host_web/router.ex"
cp "$repo_dir/fixtures/installer_phoenix_host/parsed_body_probe.ex" "$phoenix_three_host_dir/lib/installer_host_web/parsed_body_probe.ex"
cp -R "$repo_dir/fixtures/installer_phoenix_postgres_host/." "$phoenix_postgres_floor_host_dir"
mkdir -p \
  "$phoenix_postgres_floor_host_dir/lib/installer_host_web" \
  "$phoenix_postgres_floor_host_dir/config"
cp "$repo_dir/fixtures/installer_phoenix_host/router.ex" "$phoenix_postgres_floor_host_dir/lib/installer_host_web/router.ex"
cp "$repo_dir/fixtures/installer_phoenix_host/parsed_body_probe.ex" "$phoenix_postgres_floor_host_dir/lib/installer_host_web/parsed_body_probe.ex"

digest_tree() {
  {
    find config lib test -type f -print
    printf '%s\n' mix.exs
  } |
    LC_ALL=C sort |
    while IFS= read -r file; do
      if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file"
      else
        shasum -a 256 "$file"
      fi
    done |
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum
    else
      shasum -a 256
    fi
}

installed_http_smoke() {
  mix run -e '
    defmodule InstallerHost.InstallerSmokeKeystore do
      @behaviour Attesto.Keystore

      @impl Attesto.Keystore
      def signing_pem, do: System.fetch_env!("INSTALLER_HOST_SIGNING_PEM")

      @impl Attesto.Keystore
      def verification_pems, do: [signing_pem()]
    end

    current = Application.fetch_env!(:installer_host, AttestoPhoenix.Config)

    current =
      current
      |> Keyword.put(:keystore, InstallerHost.InstallerSmokeKeystore)
      |> Keyword.put(:audience, "https://mcp.example.com/mcp")
      |> Keyword.put(:principal_kinds, fn ->
        [Attesto.PrincipalKind.new("installer_test", "installer_test_")]
      end)
      |> Keyword.put(:load_principal, fn subject -> {:ok, %{id: subject}} end)

    Application.put_env(:installer_host, AttestoPhoenix.Config, current)

    endpoint = &InstallerHostWeb.Endpoint.call(&1, InstallerHostWeb.Endpoint.init([]))

    metadata =
      Plug.Test.conn(:get, "/.well-known/oauth-protected-resource/mcp")
      |> endpoint.()

    unless metadata.status == 200 and byte_size(metadata.resp_body) > 0 do
      raise("protected-resource metadata route was not public and successful")
    end

    unauthenticated = fn body ->
      Plug.Test.conn(:post, "/mcp", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> endpoint.()
    end

    malformed = unauthenticated.("{")

    unless malformed.status in [401, 403] do
      raise("malformed unauthenticated MCP body reached the handler before authorization")
    end

    oversized = unauthenticated.(String.duplicate("x", 1_100_000))

    unless oversized.status in [401, 403] do
      raise("oversized unauthenticated MCP body reached the handler before authorization")
    end

    unrelated_json =
      Plug.Test.conn(:post, "/unrelated-json", ~s({"ok":true}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> endpoint.()

    unless unrelated_json.body_params == %{"ok" => true} do
      raise("unrelated JSON request was not parsed by the endpoint")
    end

    unrelated_form =
      Plug.Test.conn(:post, "/unrelated-form", "alpha=beta")
      |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
      |> endpoint.()

    unless unrelated_form.body_params == %{"alpha" => "beta"} do
      raise("unrelated form request was not parsed by the endpoint")
    end

    protected = AttestoMCP.Server.Phoenix.protected_resource_options(:installer_host)

    principal = %{
      kind: "installer_test",
      sub: "installer_test_installer",
      scopes: [AttestoMCP.Scopes.tools_read()],
      claims: %{"client_id" => "installer"}
    }

    {:ok, minted} = Attesto.Token.mint(protected[:config], principal)

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list",
        "params" => %{
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }
        }
      })

    conn =
      Plug.Test.conn(:post, "/mcp", body)
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> minted.access_token)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")
      |> Plug.Conn.put_req_header("mcp-protocol-version", "2026-07-28")
      |> Plug.Conn.put_req_header("mcp-method", "tools/list")
      |> endpoint.()

    unless conn.status == 200 and Jason.decode!(conn.resp_body)["result"]["tools"] != [] do
      raise("installed AttestoPhoenix MCP route rejected authenticated traffic")
    end
  '
}

(
  cd "$host_dir"
  export ATTESTO_MCP_SERVER_PATH="$repo_dir"

  mix deps.get
  mix attesto_mcp_server.install \
    --base-url https://mcp.example.com \
    --attesto-config InstallerHost.Attesto.config/0 \
    --router InstallerHostWeb.Router \
    --yes

  test -f lib/installer_host/mcp.ex
  grep -Fq 'children = [InstallerHost.MCP]' lib/installer_host/application.ex

  first_digest=$(digest_tree)

  mix format --check-formatted
  mix compile --warnings-as-errors
  mix test

  mix attesto_mcp_server.install \
    --base-url https://mcp.example.com \
    --attesto-config InstallerHost.Attesto.config/0 \
    --router InstallerHostWeb.Router \
    --yes

  second_digest=$(digest_tree)
  test "$first_digest" = "$second_digest"
)

(
  cd "$phoenix_host_dir"
  export ATTESTO_MCP_SERVER_PATH="$repo_dir"
  INSTALLER_HOST_SIGNING_PEM=$(openssl genpkey -algorithm ED25519 2>/dev/null)
  export INSTALLER_HOST_SIGNING_PEM

  mix deps.get
  mix attesto_mcp_server.install \
    --base-url https://mcp.example.com \
    --enable-cimd \
    --reuse-metadata-route \
    --yes

  test -f lib/installer_host/mcp.ex
  grep -Fq 'children = [InstallerHost.MCP]' lib/installer_host/application.ex
  grep -Fq 'attesto_routes(protected_resource_paths: ["/mcp"])' lib/installer_host_web/router.ex
  test "$(grep -F -c 'attesto_routes(protected_resource_paths: ["/mcp"])' lib/installer_host_web/router.ex)" -eq 1
  test "$(grep -F -c 'Elixir.Phoenix.Router.forward("/mcp"' lib/installer_host_web/router.ex)" -eq 1
  if grep -Fq 'oauth-protected-resource' lib/installer_host_web/router.ex; then
    echo "reused Phoenix metadata route was duplicated" >&2
    exit 1
  fi

  first_digest=$(digest_tree)

  mix format --check-formatted
  mix compile --warnings-as-errors
  mix test
  mix run -e '
    host_config = AttestoPhoenix.Config.from_otp_app(:installer_host)

    unless match?(%Attesto.Config{}, InstallerHost.MCP.attesto_config()) do
      raise("real attesto_phoenix integration did not derive Attesto.Config")
    end

    protected = AttestoMCP.Server.Phoenix.protected_resource_options(:installer_host)

    unless match?(%Attesto.Config{}, protected[:config]) and
             is_function(protected[:replay_check], 2) and
             is_function(protected[:htu], 1) and
             is_function(protected[:principal], 2) do
      raise("real attesto_phoenix integration omitted protected-resource callbacks")
    end

    unless protected[:principal].(
             %{"sub" => "svc_installer", "client_id" => "installer"},
             %{binding: :bearer}
           ) == {:ok, %{id: "svc_installer"}} do
      raise("real attesto_phoenix principal callback was not executable")
    end

    unless AttestoPhoenix.Config.client_id_metadata_enabled?(host_config) do
      raise("MCP installer did not enable URL client metadata")
    end

    unless AttestoPhoenix.Config.native_app_loopback_matching(host_config) ==
             :exact_allow_loopback_port_including_localhost do
      raise("MCP installer did not enable ephemeral localhost callback ports")
    end

    unless Code.ensure_loaded?(Req) do
      raise("default URL client metadata fetcher dependency is unavailable")
    end
  '

  mix attesto_mcp_server.install \
    --base-url https://mcp.example.com \
    --reuse-metadata-route \
    --yes

  second_digest=$(digest_tree)
  test "$first_digest" = "$second_digest"
)

(
  cd "$phoenix_floor_host_dir"
  export ATTESTO_MCP_SERVER_PATH="$repo_dir"
  INSTALLER_HOST_SIGNING_PEM=$(openssl genpkey -algorithm ED25519 2>/dev/null)
  export INSTALLER_HOST_SIGNING_PEM

  elixir -e '
    path = "mix.exs"
    source = File.read!(path)
    marker = ~s({:attesto_phoenix, "~> 2.14"})

    unless length(:binary.matches(source, marker)) == 1 do
      raise("attesto_phoenix floor dependency marker was not unique")
    end

    File.write!(path, String.replace(source, marker, ~s({:attesto_phoenix, "== 2.14.1"})))
  '

  mix deps.get
  mix attesto_mcp_server.install --base-url https://mcp.example.com --enable-cimd --reuse-metadata-route --yes
  grep -Fq 'attesto_routes(protected_resource_paths: ["/mcp"])' lib/installer_host_web/router.ex
  test "$(grep -F -c 'attesto_routes(protected_resource_paths: ["/mcp"])' lib/installer_host_web/router.ex)" -eq 1
  test "$(grep -F -c 'Elixir.Phoenix.Router.forward("/mcp"' lib/installer_host_web/router.ex)" -eq 1
  mix format --check-formatted
  mix compile --warnings-as-errors
  mix run -e '
    protected = AttestoMCP.Server.Phoenix.protected_resource_options(:installer_host)

    unless to_string(Application.spec(:attesto_phoenix, :vsn)) == "2.14.1" do
      raise("attesto_phoenix floor lane did not resolve exactly 2.14.1")
    end

    unless match?(%Attesto.Config{}, protected[:config]) and
             is_function(protected[:principal], 2) and
             protected[:principal].(
               %{"sub" => "svc_installer", "client_id" => "installer"},
               %{binding: :bearer}
             ) == {:ok, %{id: "svc_installer"}} do
      raise("attesto_phoenix 2.14.1 protected-resource integration failed")
    end
  '

)

(
  cd "$phoenix_three_host_dir"
  export ATTESTO_MCP_SERVER_PATH="$repo_dir"
  INSTALLER_HOST_SIGNING_PEM=$(openssl genpkey -algorithm ED25519 2>/dev/null)
  export INSTALLER_HOST_SIGNING_PEM

  elixir -e '
    path = "mix.exs"
    source = File.read!(path)
    marker = ~s({:attesto_phoenix, "~> 2.14"})

    unless length(:binary.matches(source, marker)) == 1 do
      raise("attesto_phoenix 3.x dependency marker was not unique")
    end

    File.write!(path, String.replace(source, marker, ~s({:attesto_phoenix, "~> 3.0"})))
  '

  mix deps.get
  mix attesto_mcp_server.install --base-url https://mcp.example.com --enable-cimd --reuse-metadata-route --yes
  grep -Fq 'attesto_routes(protected_resource_paths: ["/mcp"])' lib/installer_host_web/router.ex
  test "$(grep -F -c 'attesto_routes(protected_resource_paths: ["/mcp"])' lib/installer_host_web/router.ex)" -eq 1
  test "$(grep -F -c 'Elixir.Phoenix.Router.forward("/mcp"' lib/installer_host_web/router.ex)" -eq 1
  if grep -Fq 'oauth-protected-resource' lib/installer_host_web/router.ex; then
    echo "reused Phoenix 3 metadata route was duplicated" >&2
    exit 1
  fi

  first_digest=$(digest_tree)
  mix format --check-formatted
  mix compile --warnings-as-errors
  mix test
  mix run -e '
    version = Application.spec(:attesto_phoenix, :vsn) |> to_string()
    protected = AttestoMCP.Server.Phoenix.protected_resource_options(:installer_host)

    unless Version.match?(version, ">= 3.0.0 and < 4.0.0") do
      raise("attesto_phoenix 3.x lane resolved an unsupported version")
    end

    unless match?(%Attesto.Config{}, protected[:config]) and
             is_function(protected[:replay_check], 2) and
             is_function(protected[:htu], 1) and
             is_function(protected[:principal], 2) and
             protected[:principal].(
               %{"sub" => "svc_installer", "client_id" => "installer"},
               %{binding: :bearer}
             ) == {:ok, %{id: "svc_installer"}} do
      raise("attesto_phoenix 3.x protected-resource integration failed")
    end
  '

  mix attesto_mcp_server.install --base-url https://mcp.example.com --enable-cimd --reuse-metadata-route --yes
  second_digest=$(digest_tree)
  test "$first_digest" = "$second_digest"
)

mix phx.new "$generated_host_dir" \
  --app installer_host \
  --module InstallerHost \
  --database sqlite3 \
  --no-assets \
  --no-dashboard \
  --no-gettext \
  --no-html \
  --no-mailer \
  --no-install \
  --no-version-check \
  --no-agents-md

(
  cd "$generated_host_dir"
  export ATTESTO_MCP_SERVER_PATH="$repo_dir"
  INSTALLER_HOST_SIGNING_PEM=$(openssl genpkey -algorithm ED25519 2>/dev/null)
  export INSTALLER_HOST_SIGNING_PEM

  elixir -e '
    mix_file = "mix.exs"
    marker = "  defp deps do\n    [\n"
    source = File.read!(mix_file)

    unless length(:binary.matches(source, marker)) == 1 do
      raise("generated Phoenix dependency list marker was not unique")
    end

    dependencies = """
          {:attesto_mcp_server, path: System.fetch_env!("ATTESTO_MCP_SERVER_PATH")},
          {:attesto_phoenix, "~> 2.14"},
          {:igniter, "== 0.6.0", override: true},
    """

    File.write!(mix_file, String.replace(source, marker, marker <> dependencies, global: false))
  '

  mix deps.get
  mix attesto_phoenix.install --yes
  cp "$repo_dir/fixtures/installer_phoenix_host/router.ex" lib/installer_host_web/router.ex
  cp "$repo_dir/fixtures/installer_phoenix_host/parsed_body_probe.ex" lib/installer_host_web/parsed_body_probe.ex
  mix attesto_mcp_server.install --base-url https://mcp.example.com --enable-cimd --reuse-metadata-route --yes
  mix deps.get

  grep -Fq 'AttestoPhoenix.Plug.PutConfig' lib/installer_host_web/router.ex
  grep -Fq 'Elixir.Phoenix.Router.forward("/mcp", Elixir.AttestoMCP.Server.Plug' lib/installer_host_web/router.ex
  grep -Fq 'attesto_routes(protected_resource_paths: ["/mcp"])' lib/installer_host_web/router.ex
  test "$(grep -F -c 'attesto_routes(protected_resource_paths: ["/mcp"])' lib/installer_host_web/router.ex)" -eq 1
  test "$(grep -F -c 'Elixir.Phoenix.Router.forward("/mcp"' lib/installer_host_web/router.ex)" -eq 1
  grep -Fq 'AttestoMCP.Server.PhoenixParser' lib/installer_host_web/endpoint.ex
  grep -Fq 'client_id_metadata: [enabled: true]' config/config.exs
  grep -Fq 'native_apps: [loopback_include_localhost: true]' config/config.exs
  grep -Fq '{:req, ">= 0.6.1 and < 1.0.0"}' mix.exs

  if grep -R -Fq 'AttestoMCP.Server.SessionStore.Ecto' config lib; then
    echo "SQLite host unexpectedly selected the durable Ecto session store" >&2
    exit 1
  fi

  if grep -R -Fq 'session_store:' config; then
    echo "SQLite host unexpectedly received session-store configuration" >&2
    exit 1
  fi

  if find priv -type f -name '*attesto_mcp_sessions*' -print -quit | grep -q .; then
    echo "SQLite host unexpectedly received a durable-session migration" >&2
    exit 1
  fi

  first_digest=$(digest_tree)

  mix format --check-formatted
  mix compile --warnings-as-errors
  mix test
  mix run -e '
    defmodule InstallerHost.InstallerTestKeystore do
      @behaviour Attesto.Keystore

      @impl Attesto.Keystore
      def signing_pem, do: System.fetch_env!("INSTALLER_HOST_SIGNING_PEM")

      @impl Attesto.Keystore
      def verification_pems, do: [signing_pem()]
    end

    current = Application.fetch_env!(:installer_host, AttestoPhoenix.Config)

    principal_kinds = fn ->
      [Attesto.PrincipalKind.new("installer_test", "installer_test_")]
    end

    current =
      current
      |> Keyword.put(:keystore, InstallerHost.InstallerTestKeystore)
      |> Keyword.put(:principal_kinds, principal_kinds)
      |> Keyword.put(:load_principal, fn subject -> {:ok, %{id: subject}} end)

    Application.put_env(
      :installer_host,
      AttestoPhoenix.Config,
      current
    )

    config = AttestoPhoenix.Config.from_otp_app(:installer_host)

    unless match?(%Attesto.Config{}, InstallerHost.MCP.attesto_config()) do
      raise("generated Phoenix host did not derive Attesto.Config")
    end

    protected = AttestoMCP.Server.Phoenix.protected_resource_options(:installer_host)

    unless match?(%Attesto.Config{}, protected[:config]) and
             is_function(protected[:replay_check], 2) and
             is_function(protected[:htu], 1) and
             is_function(protected[:principal], 2) do
      raise("generated Phoenix host omitted protected-resource callbacks")
    end

    unless protected[:principal].(
             %{"sub" => "installer_test_1", "client_id" => "installer"},
             %{binding: :bearer}
           ) == {:ok, %{id: "installer_test_1"}} do
      raise("generated Phoenix host principal callback was not executable")
    end

    unless AttestoPhoenix.Config.client_id_metadata_enabled?(config) do
      raise("generated Phoenix host did not enable URL client metadata")
    end

    unless AttestoPhoenix.Config.native_app_loopback_matching(config) ==
             :exact_allow_loopback_port_including_localhost do
      raise("generated Phoenix host did not enable localhost callback compatibility")
    end
  '

  installed_http_smoke

  mix attesto_mcp_server.install --base-url https://mcp.example.com --enable-cimd --reuse-metadata-route --yes

  second_digest=$(digest_tree)
  test "$first_digest" = "$second_digest"
)

(
  cd "$phoenix_postgres_floor_host_dir"
  export ATTESTO_MCP_SERVER_PATH="$repo_dir"
  INSTALLER_HOST_SIGNING_PEM=$(openssl genpkey -algorithm ED25519 2>/dev/null)
  export INSTALLER_HOST_SIGNING_PEM

  export OUTSIDE_CONFIG_DIR="$outside_config_dir"
  elixir -e '
    outside = System.fetch_env!("OUTSIDE_CONFIG_DIR")
    File.write!(Path.join(outside, "linked.exs"), """
    import Config

    config :installer_host, InstallerHost.MCP,
      server_options: [session_store: {Outside.Store, :handle}]
    """)
    File.ln_s!(Path.join(outside, "linked.exs"), "config/linked.exs")
  '

  mix deps.get
  mix attesto_mcp_server.install --base-url https://mcp.example.com --reuse-metadata-route --yes

  grep -Fq 'AttestoMCP.Server.SessionStore.Ecto' config/config.exs
  grep -Fq 'repo: InstallerHost.Repo' config/config.exs
  grep -Fq 'children = [InstallerHost.Repo, InstallerHost.MCP]' lib/installer_host/application.ex

  migration_path="priv/repo/migrations"
  mix attesto_mcp_server.gen.migration --repo InstallerHost.Repo
  migration_file=$(find "$migration_path" -type f -name '*_create_attesto_mcp_sessions.exs' -print -quit)
  test -n "$migration_file"
  grep -Fq 'create table(:attesto_mcp_sessions, primary_key: false, prefix: prefix)' "$migration_file"
  grep -Fq 'add(:namespace, :string, size: 256, primary_key: true, null: false)' "$migration_file"
  grep -Fq 'add(:session_id, :string, size: 256, primary_key: true, null: false)' "$migration_file"
  grep -Fq 'add(:record, :map, null: false)' "$migration_file"
  grep -Fq 'add(:expires_at_ms, :bigint, null: false)' "$migration_file"
  grep -Fq 'index(:attesto_mcp_sessions, [:namespace, :expires_at_ms, :session_id]' "$migration_file"
  if command -v sha256sum >/dev/null 2>&1; then
    migration_digest=$(sha256sum "$migration_file")
  else
    migration_digest=$(shasum -a 256 "$migration_file")
  fi

  mix attesto_mcp_server.install --base-url https://mcp.example.com --reuse-metadata-route --yes
  test "$(find "$migration_path" -type f -name '*_create_attesto_mcp_sessions.exs' | wc -l | tr -d ' ')" -eq 1
  if command -v sha256sum >/dev/null 2>&1; then
    test "$migration_digest" = "$(sha256sum "$migration_file")"
  else
    test "$migration_digest" = "$(shasum -a 256 "$migration_file")"
  fi
)

(
  cd "$absent_dir"
  export ATTESTO_MCP_SERVER_PATH="$repo_dir"
  export MIX_INSTALL_DIR="$absent_dir/mix-install"

  elixir -e '
    Mix.install(
      [{:attesto_mcp_server, path: System.fetch_env!("ATTESTO_MCP_SERVER_PATH")}],
      verbose: false
    )

    if Code.ensure_loaded?(Igniter), do: raise("Igniter unexpectedly loaded")

    unless Code.ensure_loaded?(Mix.Tasks.AttestoMcpServer.Install) do
      raise("fallback installer task was not compiled")
    end

    try do
      Mix.Tasks.AttestoMcpServer.Install.run([])
      raise("fallback installer task unexpectedly succeeded")
    rescue
      error in Mix.Error ->
        message = Exception.message(error)

        unless String.contains?(message, "only: [:dev, :test], runtime: false") do
          raise("fallback guidance did not describe a host development dependency")
        end
    end
  '
)

printf '%s\n' "installer compatibility checks passed"
