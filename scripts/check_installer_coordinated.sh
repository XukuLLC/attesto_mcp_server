#!/usr/bin/env sh
set -eu

if [ "${ATTESTO_MCP_PATH:-}" != "1" ] && [ "${ATTESTO_MCP_PATH:-}" != "true" ]; then
  echo "set ATTESTO_MCP_PATH=1 to run the coordinated source lane" >&2
  exit 64
fi

attesto_ref=${ATTESTO_REF:-}
phoenix_ref=${ATTESTO_PHOENIX_REF:-}
mcp_ref=${ATTESTO_MCP_REF:-}

for ref in "$attesto_ref" "$phoenix_ref" "$mcp_ref"; do
  if ! printf '%s' "$ref" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "coordinated source refs must be supplied as full lowercase 40-character commit SHAs" >&2
    exit 64
  fi
done

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH='' cd -- "$script_dir/.." && pwd)

# Never fall back to an arbitrary sibling directory in a release lane. The
# caller must name all three checkouts explicitly so a missing source cannot be
# silently replaced by an unrelated local checkout.
mcp_source_dir=${ATTESTO_MCP_SOURCE_PATH:-}
attesto_source_dir=${ATTESTO_SOURCE_PATH:-}
phoenix_source_dir=${ATTESTO_PHOENIX_SOURCE_PATH:-}

for source_dir in "$mcp_source_dir" "$attesto_source_dir" "$phoenix_source_dir"; do
  test -n "$source_dir" || {
    echo "coordinated source paths must be supplied explicitly" >&2
    exit 64
  }
done

for source_dir in "$mcp_source_dir" "$attesto_source_dir" "$phoenix_source_dir"; do
  test -d "$source_dir" || {
    echo "coordinated source checkout is missing" >&2
    exit 64
  }

  test -e "$source_dir/.git" || {
    echo "coordinated dependency must be a source checkout" >&2
    exit 64
  }

  test "$(git -C "$source_dir" rev-parse --is-inside-work-tree 2>/dev/null)" = true || {
    echo "coordinated dependency checkout is not a readable Git work tree" >&2
    exit 64
  }
done

verify_checkout_ref() {
  source_dir=$1
  expected_ref=$2

  actual_ref=$(git -C "$source_dir" rev-parse HEAD 2>/dev/null) || {
    echo "coordinated dependency checkout has no readable HEAD: $source_dir" >&2
    exit 64
  }

  if [ "$actual_ref" != "$expected_ref" ]; then
    echo "coordinated dependency checkout does not match its expected commit: $source_dir" >&2
    exit 64
  fi
}

verify_checkout_ref "$attesto_source_dir" "$attesto_ref"
verify_checkout_ref "$phoenix_source_dir" "$phoenix_ref"
verify_checkout_ref "$mcp_source_dir" "$mcp_ref"

temp_root=${TMPDIR:-/tmp}
host_dir=$(mktemp -d "$temp_root/attesto-mcp-coordinated-host.XXXXXX")

cleanup() {
  rm -rf -- "$host_dir"
}

trap cleanup EXIT HUP INT TERM
cp -R "$repo_dir/fixtures/installer_host/." "$host_dir"

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
  export ATTESTO_MCP_PATH=1
  export ATTESTO_MCP_SOURCE_PATH="$mcp_source_dir"
  export ATTESTO_SOURCE_PATH="$attesto_source_dir"
  export ATTESTO_PHOENIX_SOURCE_PATH="$phoenix_source_dir"
  export ATTESTO_MCP_SERVER_PATH="$repo_dir"
  INSTALLER_HOST_SIGNING_PEM=$(openssl genpkey -algorithm ED25519 2>/dev/null)
  export INSTALLER_HOST_SIGNING_PEM

  # The automatic Phoenix installer intentionally accepts only literal public
  # Hex requirements. This source-linked lane therefore installs through the
  # explicit callback path, then executes that callback through the real
  # AttestoPhoenix 3 bridge below. The published-dependency compatibility lane
  # separately exercises the complete automatic path against released packages.

  elixir -e '
    path = "mix.exs"
    source = File.read!(path)
    marker = ~S|      {:attesto_mcp_server, path: System.fetch_env!("ATTESTO_MCP_SERVER_PATH")},
|

    unless length(:binary.matches(source, marker)) == 1 do
      raise("coordinated server dependency marker was not unique")
    end

    replacement =
      [
        ~S|      {:attesto, path: System.fetch_env!("ATTESTO_SOURCE_PATH"), override: true},|,
        ~S|      {:attesto_phoenix, path: System.fetch_env!("ATTESTO_PHOENIX_SOURCE_PATH"), override: true},|,
        ~S|      {:attesto_mcp, path: System.fetch_env!("ATTESTO_MCP_SOURCE_PATH"), override: true},|,
        ~S|      {:attesto_mcp_server, path: System.fetch_env!("ATTESTO_MCP_SERVER_PATH")},|
      ]
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    File.write!(path, String.replace(source, marker, replacement, global: false))
  '

  elixir -e '
    File.write!("lib/installer_host/phoenix_auth.ex", """
    defmodule InstallerHost.PhoenixAuth do
      @moduledoc false

      def config, do: AttestoMCP.Server.Phoenix.attesto_config(:installer_host)
    end
    """)
  '

  elixir -e '
    source = """
    defmodule InstallerHost.NamedProfileProbe do
      @moduledoc false

      def load_principal(subject, profile) do
        report(profile, :principal)

        if subject == "svc_denied_" <> profile do
          {:error, :profile_denied}
        else
          {:ok, %{id: subject, profile: profile}}
        end
      end

      def replay_check(key, _ttl, profile) do
        report(profile, :replay)

        if key == "named-replay-failure", do: {:error, :replay}, else: :ok
      end

      def htu(_conn, profile) do
        report(profile, :htu)
        "https://" <> profile <> ".example/mcp"
      end

      def cert_der(_conn, profile) do
        report(profile, :cert_der)
        nil
      end

      defp report(profile, kind) do
        owner = Process.get(:installer_host_named_config_probe_owner)
        config = AttestoPhoenix.Config.request_config()
        send(owner, {:named_config_callback, profile, kind, config})
      end
    end

    defmodule InstallerHost.NamedNonceStore do
      @moduledoc false

      def issue(config, _ttl) do
        report(config, :nonce_issue)
        "named-nonce"
      end

      def valid?(config, nonce) do
        report(config, :nonce_check)
        nonce == "named-nonce"
      end

      defp report(config, kind) do
        owner = Process.get(:installer_host_named_config_probe_owner)
        send(owner, {:named_config_callback, profile(config), kind, AttestoPhoenix.Config.request_config()})
      end

      defp profile(config) do
        config.issuer |> URI.parse() |> Map.fetch!(:host) |> String.split(".") |> hd()
      end
    end

    defmodule InstallerHost.NamedProfileRepo do
      @moduledoc false

      def start_link do
        Agent.start_link(fn -> %{replay: MapSet.new(), revoked: false, calls: []} end, name: __MODULE__)
      end

      def reset(profile, revoked) do
        Agent.update(__MODULE__, fn _ -> %{replay: MapSet.new(), revoked: revoked, calls: [{:profile, profile}]} end)
      end

      def insert(profile, changeset, opts) do
        record_call(profile, :insert, opts)
        jti = Ecto.Changeset.get_field(changeset, :jti)

        Agent.get_and_update(__MODULE__, fn state ->
          if jti == "named-replay-failure" or MapSet.member?(state.replay, jti) do
            {{:error, Ecto.Changeset.add_error(changeset, :jti, "has already been taken")}, state}
          else
            {{:ok, changeset}, %{state | replay: MapSet.put(state.replay, jti)}}
          end
        end)
      end

      def exists?(profile, _query, opts) do
        record_call(profile, :exists, opts)
        Agent.get(__MODULE__, & &1.revoked)
      end

      def one(_profile, _query, _opts), do: nil
      def update_all(_profile, _query, _updates, _opts), do: {0, []}
      def delete_all(_profile, _query, _opts), do: {0, nil}

      def calls do
        Agent.get(__MODULE__, &Enum.reverse(&1.calls))
      end

      defp record_call(profile, kind, opts) do
        if owner = Process.get(:installer_host_named_config_probe_owner) do
          send(owner, {:named_repo_call, profile, kind, Keyword.get(opts, :prefix)})
        end

        Agent.update(__MODULE__, fn state ->
          %{state | calls: [{profile, kind, Keyword.get(opts, :prefix)} | state.calls]}
        end)
      end
    end

    defmodule InstallerHost.AlphaRepo do
      @moduledoc false
      def insert(changeset, opts), do: InstallerHost.NamedProfileRepo.insert(:alpha, changeset, opts)
      def exists?(query, opts), do: InstallerHost.NamedProfileRepo.exists?(:alpha, query, opts)
      def one(query, opts), do: InstallerHost.NamedProfileRepo.one(:alpha, query, opts)
      def update_all(query, updates, opts), do: InstallerHost.NamedProfileRepo.update_all(:alpha, query, updates, opts)
      def delete_all(query, opts), do: InstallerHost.NamedProfileRepo.delete_all(:alpha, query, opts)
    end

    defmodule InstallerHost.BetaRepo do
      @moduledoc false
      def insert(changeset, opts), do: InstallerHost.NamedProfileRepo.insert(:beta, changeset, opts)
      def exists?(query, opts), do: InstallerHost.NamedProfileRepo.exists?(:beta, query, opts)
      def one(query, opts), do: InstallerHost.NamedProfileRepo.one(:beta, query, opts)
      def update_all(query, updates, opts), do: InstallerHost.NamedProfileRepo.update_all(:beta, query, updates, opts)
      def delete_all(query, opts), do: InstallerHost.NamedProfileRepo.delete_all(:beta, query, opts)
    end

    defmodule InstallerHost.NamedAuth do
      @moduledoc false
      def alpha, do: AttestoMCP.Server.Phoenix.protected_resource_options(:installer_host_alpha)
      def beta, do: AttestoMCP.Server.Phoenix.protected_resource_options(:installer_host_beta)
    end

    """

    formatted = Code.format_string!(source) |> IO.iodata_to_binary() |> Kernel.<>("\n")
    File.write!("lib/installer_host/named_profile_probe.ex", formatted)
  '

  mix deps.get
  mix run --no-start -e '
    expected = [
      {:attesto, ">= 2.0.0 and < 3.0.0"},
      {:attesto_mcp, ">= 1.3.0 and < 2.0.0"},
      {:attesto_phoenix, ">= 3.0.0 and < 4.0.0"}
    ]

    for {app, requirement} <- expected do
      version = Application.spec(app, :vsn) |> to_string()

      unless Version.match?(version, requirement) do
        raise("coordinated dependency version check failed")
      end
    end
  '

  mix attesto_mcp_server.install \
    --base-url https://mcp.example.com \
    --attesto-config InstallerHost.PhoenixAuth.config/0 \
    --yes

  test "$(grep -F -c 'Elixir.Phoenix.Router.forward("/mcp"' lib/installer_host_web/router.ex)" -eq 1
  grep -Fq 'oauth-protected-resource' lib/installer_host_web/router.ex
  grep -Fq 'InstallerHost.PhoenixAuth.config()' lib/installer_host/mcp.ex

  first_digest=$(digest_tree)
  mix format --check-formatted
  mix compile --warnings-as-errors
  mix test
  mix run -e '
    protected = AttestoMCP.Server.Phoenix.protected_resource_options(:installer_host)

    unless match?(%Attesto.Config{}, InstallerHost.PhoenixAuth.config()) and
             match?(%Attesto.Config{}, protected[:config]) and
             is_function(protected[:replay_check], 2) and
             is_function(protected[:htu], 1) and
             is_function(protected[:principal], 2) and
             protected[:principal].(
               %{"sub" => "svc_installer", "client_id" => "installer"},
               %{binding: :bearer}
             ) == {:ok, %{id: "svc_installer"}} do
      raise("coordinated protected-resource integration failed")
    end
  '

  mix run -e '
    profiles = [
      {:installer_host_alpha, "alpha", "https://alpha.example", "https://alpha.example/mcp"},
      {:installer_host_beta, "beta", "https://beta.example", "https://beta.example/mcp"}
    ]

    base = Application.fetch_env!(:installer_host, AttestoPhoenix.Config)
    owner = self()
    Process.put(:installer_host_named_config_probe_owner, owner)
    {:ok, _repo_probe} = InstallerHost.NamedProfileRepo.start_link()

    for {otp_app, profile, issuer, audience} <- profiles do
      config =
        base
        |> Keyword.put(:issuer, issuer)
        |> Keyword.put(:audience, audience)
        |> Keyword.put(:repo, if(profile == "alpha", do: InstallerHost.AlphaRepo, else: InstallerHost.BetaRepo))
        |> Keyword.put(:schema_prefix, profile)
        |> Keyword.put(:load_principal, {InstallerHost.NamedProfileProbe, :load_principal, [profile]})
        |> Keyword.put(:replay_check, {AttestoPhoenix.Store.EctoReplayCheck, :check_and_record})
        |> Keyword.put(:htu, {InstallerHost.NamedProfileProbe, :htu, [profile]})
        |> Keyword.put(:nonce_store, InstallerHost.NamedNonceStore)
        |> Keyword.put(:dpop_nonce_required, true)
        |> Keyword.put(:mtls_enabled, true)
        |> Keyword.put(:trusted_proxies, ["127.0.0.1/32"])
        |> Keyword.put(:cert_der, {InstallerHost.NamedProfileProbe, :cert_der, [profile]})
        |> Keyword.put(:code_store, AttestoPhoenix.Store.EctoCodeStore)

      Application.put_env(otp_app, AttestoPhoenix.Config, config)
    end

    await_callback = fn profile, kind, expected_config ->
      receive do
        {:named_config_callback, ^profile, ^kind, observed} ->
          unless match?(%AttestoPhoenix.Config{}, observed) and
                   observed.issuer == expected_config.issuer and
                   observed.audience == expected_config.audience do
            raise("named protected-resource callback observed the wrong request config")
          end
      after
        1_000 ->
          messages = Process.info(self(), :messages) |> elem(1)
          raise("named protected-resource callback did not observe #{profile}/#{kind} request config: #{inspect(messages)}")
      end
    end

    await_repo_call = fn profile, kind, expected_prefix ->
      receive do
        {:named_repo_call, ^profile, ^kind, ^expected_prefix} -> :ok
      after
        1_000 -> raise("named Ecto store did not use its profile repository and schema")
      end
    end

    alpha_config = AttestoPhoenix.Config.from_otp_app(:installer_host_alpha)
    beta_config = AttestoPhoenix.Config.from_otp_app(:installer_host_beta)

    AttestoPhoenix.Config.with_request_config(alpha_config, fn ->
      unless AttestoPhoenix.Config.request_config() == alpha_config do
        raise("Phoenix request config was not installed")
      end

      AttestoPhoenix.Config.with_request_config(beta_config, fn ->
        unless AttestoPhoenix.Config.request_config() == beta_config do
          raise("nested Phoenix request config was not installed")
        end
      end)

      unless AttestoPhoenix.Config.request_config() == alpha_config do
        raise("nested Phoenix request config was not restored")
      end
    end)

    if AttestoPhoenix.Config.request_config() != nil do
      raise("Phoenix request config leaked after nested restoration")
    end

    {:ok, alpha_server} = AttestoMCP.Server.start_link(name: InstallerHost.NamedAlphaServer)
    {:ok, beta_server} = AttestoMCP.Server.start_link(name: InstallerHost.NamedBetaServer)

    :ok =
      AttestoMCP.Server.register_tool(alpha_server, "alpha-tool", %{
        description: "alpha",
        input_schema: %{"type" => "object"},
        handler: fn _params, _context -> {:ok, %{"profile" => "alpha"}} end
      })

    :ok =
      AttestoMCP.Server.register_tool(beta_server, "beta-tool", %{
        description: "beta",
        input_schema: %{"type" => "object"},
        handler: fn _params, _context -> {:ok, %{"profile" => "beta"}} end
      })

    alpha_plug =
      AttestoMCP.Server.Plug.init(
        server: alpha_server,
        path: "/mcp",
        origin: "https://alpha.example",
        auth: {InstallerHost.NamedAuth, :alpha}
      )

    beta_plug =
      AttestoMCP.Server.Plug.init(
        server: beta_server,
        path: "/mcp",
        origin: "https://beta.example",
        auth: {InstallerHost.NamedAuth, :beta}
      )

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

    request = fn plug, host, token ->
      Plug.Test.conn(:post, "/mcp", body)
      |> then(&%Plug.Conn{&1 | host: host})
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", "application/json, text/event-stream")
      |> Plug.Conn.put_req_header("mcp-protocol-version", "2026-07-28")
      |> Plug.Conn.put_req_header("mcp-method", "tools/list")
      |> AttestoMCP.Server.Plug.call(plug)
    end

    mint = fn otp_app, subject ->
      config = AttestoMCP.Server.Phoenix.protected_resource_options(otp_app)[:config]

      {:ok, token} =
        Attesto.Token.mint(config, %{
          kind: "service",
          sub: subject,
          scopes: [AttestoMCP.Scopes.tools_read()],
          claims: %{"client_id" => "named-http-test"}
        })

      token.access_token
    end

    InstallerHost.NamedProfileRepo.reset(:alpha, false)
    alpha_token = mint.(:installer_host_alpha, "svc_alpha")
    alpha_response = request.(alpha_plug, "alpha.example", alpha_token)

    unless alpha_response.status == 200 and
             "alpha-tool" in Enum.map(Jason.decode!(alpha_response.resp_body)["result"]["tools"], & &1["name"]) do
      raise("authenticated alpha HTTP request did not use the alpha definition: #{alpha_response.status} #{inspect(alpha_response.resp_body)}")
    end

    await_repo_call.(:alpha, :exists, "alpha")
    await_callback.("alpha", :cert_der, alpha_config)
    await_callback.("alpha", :principal, alpha_config)

    beta_token = mint.(:installer_host_beta, "svc_beta")
    cross_profile = request.(alpha_plug, "alpha.example", beta_token)

    unless cross_profile.status == 401 do
      raise("a beta token was accepted by the alpha HTTP definition")
    end

    await_callback.("alpha", :cert_der, alpha_config)

    InstallerHost.NamedProfileRepo.reset(:beta, false)
    beta_response = request.(beta_plug, "beta.example", beta_token)

    unless beta_response.status == 200 and
             "beta-tool" in Enum.map(Jason.decode!(beta_response.resp_body)["result"]["tools"], & &1["name"]) do
      raise("authenticated beta HTTP request did not use the beta definition")
    end

    await_repo_call.(:beta, :exists, "beta")
    await_callback.("beta", :cert_der, beta_config)
    await_callback.("beta", :principal, beta_config)

    denied_token = mint.(:installer_host_alpha, "svc_denied_alpha")
    denied_response = request.(alpha_plug, "alpha.example", denied_token)

    unless denied_response.status == 401 do
      raise("profile-specific principal rejection did not fail closed")
    end

    await_repo_call.(:alpha, :exists, "alpha")
    await_callback.("alpha", :cert_der, alpha_config)
    await_callback.("alpha", :principal, alpha_config)

    for {otp_app, profile, issuer, audience} <- profiles do
      phoenix_config = AttestoPhoenix.Config.from_otp_app(otp_app)
      InstallerHost.NamedProfileRepo.reset(String.to_atom(profile), false)
      protected = AttestoMCP.Server.Phoenix.protected_resource_options(otp_app)

      unless phoenix_config.issuer == issuer and phoenix_config.audience == audience and
               match?(%Attesto.Config{}, protected[:config]) and
               is_function(protected[:replay_check], 2) and
               is_function(protected[:nonce_check], 1) and
               is_function(protected[:nonce_issue], 0) and
               is_function(protected[:cert_der], 1) and
               is_function(protected[:htu], 1) and
               is_function(protected[:principal], 2) do
        raise("named protected-resource options were incomplete")
      end

      unless protected[:replay_check].("named-replay", 60) == :ok do
        raise("named replay callback returned an unexpected result")
      end

      await_repo_call.(String.to_atom(profile), :insert, profile)

      unless protected[:replay_check].("named-replay", 60) == {:error, :replay} do
        raise("named Ecto replay callback did not reject a repeated JTI")
      end

      await_repo_call.(String.to_atom(profile), :insert, profile)

      unless protected[:replay_check].("named-replay-failure", 60) == {:error, :replay} do
        raise("named replay failure behavior was not preserved")
      end

      await_repo_call.(String.to_atom(profile), :insert, profile)

      unless protected[:nonce_issue].() == "named-nonce" do
        raise("named nonce-issue callback returned an unexpected result")
      end

      await_callback.(profile, :nonce_issue, phoenix_config)

      unless protected[:nonce_check].("named-nonce") == :ok do
        raise("named nonce-check callback returned an unexpected result")
      end

      await_callback.(profile, :nonce_check, phoenix_config)

      unless protected[:nonce_check].("invalid-nonce") == {:error, :use_dpop_nonce} do
        raise("named nonce-check failure behavior was not preserved")
      end

      await_callback.(profile, :nonce_check, phoenix_config)

      cert_conn =
        Plug.Test.conn(:get, "/mcp")
        |> Plug.Test.put_peer_data(%{address: {127, 0, 0, 1}})

      unless protected[:cert_der].(cert_conn) == nil do
        raise("named certificate callback returned an unexpected result")
      end

      await_callback.(profile, :cert_der, phoenix_config)

      unless protected[:htu].(Plug.Test.conn(:get, "/mcp")) ==
               "https://" <> profile <> ".example/mcp" do
        raise("named URL callback returned an unexpected result")
      end

      await_callback.(profile, :htu, phoenix_config)

      unless protected[:principal].(
               %{"jti" => "named-token", "sub" => "named-subject"},
               %{binding: :bearer}
             ) == {:ok, %{id: "named-subject", profile: profile}} do
        raise("named principal callback returned an unexpected result")
      end

      await_repo_call.(String.to_atom(profile), :exists, profile)
      await_callback.(profile, :principal, phoenix_config)
    end
  '

  mix attesto_mcp_server.install \
    --base-url https://mcp.example.com \
    --attesto-config InstallerHost.PhoenixAuth.config/0 \
    --yes

  second_digest=$(digest_tree)
  test "$first_digest" = "$second_digest"
)

printf '%s\n' "coordinated source installer checks passed"
