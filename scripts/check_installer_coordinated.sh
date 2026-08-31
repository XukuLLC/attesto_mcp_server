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
  # Hex requirements. This pre-release lane therefore installs through the
  # explicit callback path, then executes that callback through the real
  # AttestoPhoenix 3 bridge below. Installer unit tests cover the automatic
  # Phoenix rewrite; the published-dependency compatibility lane exercises the
  # complete automatic path once coordinated releases exist on Hex.

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

  mix attesto_mcp_server.install \
    --base-url https://mcp.example.com \
    --attesto-config InstallerHost.PhoenixAuth.config/0 \
    --yes

  second_digest=$(digest_tree)
  test "$first_digest" = "$second_digest"
)

printf '%s\n' "coordinated source installer checks passed"
