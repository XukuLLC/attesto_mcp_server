#!/usr/bin/env sh
# Each compatibility host runs in a subshell, so exported values are intentionally scoped.
# shellcheck disable=SC2030,SC2031
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH='' cd -- "$script_dir/.." && pwd)
temp_root=${TMPDIR:-/tmp}
host_dir=$(mktemp -d "$temp_root/attesto-mcp-installer-host.XXXXXX")
phoenix_host_dir=$(mktemp -d "$temp_root/attesto-mcp-installer-phoenix-host.XXXXXX")
absent_dir=$(mktemp -d "$temp_root/attesto-mcp-installer-absent.XXXXXX")
generated_root=$(mktemp -d "$temp_root/attesto-mcp-installer-generated.XXXXXX")
generated_host_dir="$generated_root/installer_host"

cleanup() {
  rm -rf -- "$host_dir" "$phoenix_host_dir" "$absent_dir" "$generated_root"
}

trap cleanup EXIT HUP INT TERM

cp -R "$repo_dir/fixtures/installer_host/." "$host_dir"
cp -R "$repo_dir/fixtures/installer_host/." "$phoenix_host_dir"
cp "$repo_dir/fixtures/installer_phoenix_host/mix.exs" "$phoenix_host_dir/mix.exs"

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
    --yes

  test -f lib/installer_host/mcp.ex
  grep -Fq 'children = [InstallerHost.MCP]' lib/installer_host/application.ex
  grep -Fq ':protected_resource_options' lib/installer_host_web/router.ex

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
             is_function(protected[:htu], 1) do
      raise("real attesto_phoenix integration omitted protected-resource callbacks")
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
    --yes

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
  mix attesto_mcp_server.install --base-url https://mcp.example.com --yes
  mix deps.get

  grep -Fq 'plug AttestoPhoenix.Plug.PutConfig' lib/installer_host_web/router.ex
  grep -Fq 'Elixir.Phoenix.Router.forward("/mcp", Elixir.AttestoMCP.Server.Plug' lib/installer_host_web/router.ex
  grep -Fq ':protected_resource_options' lib/installer_host_web/router.ex
  grep -Fq 'client_id_metadata: [enabled: true]' config/config.exs
  grep -Fq 'native_apps: [loopback_include_localhost: true]' config/config.exs
  grep -Fq '{:req, ">= 0.6.1 and < 1.0.0"}' mix.exs

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
             is_function(protected[:htu], 1) do
      raise("generated Phoenix host omitted protected-resource callbacks")
    end

    unless AttestoPhoenix.Config.client_id_metadata_enabled?(config) do
      raise("generated Phoenix host did not enable URL client metadata")
    end

    unless AttestoPhoenix.Config.native_app_loopback_matching(config) ==
             :exact_allow_loopback_port_including_localhost do
      raise("generated Phoenix host did not enable localhost callback compatibility")
    end
  '

  mix attesto_phoenix.install --yes
  mix attesto_mcp_server.install --base-url https://mcp.example.com --yes

  second_digest=$(digest_tree)
  test "$first_digest" = "$second_digest"
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
