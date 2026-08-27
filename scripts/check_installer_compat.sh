#!/usr/bin/env sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
temp_root=${TMPDIR:-/tmp}
host_dir=$(mktemp -d "$temp_root/attesto-mcp-installer-host.XXXXXX")
phoenix_host_dir=$(mktemp -d "$temp_root/attesto-mcp-installer-phoenix-host.XXXXXX")
absent_dir=$(mktemp -d "$temp_root/attesto-mcp-installer-absent.XXXXXX")

cleanup() {
  rm -rf -- "$host_dir" "$phoenix_host_dir" "$absent_dir"
}

trap cleanup EXIT HUP INT TERM

cp -R "$repo_dir/fixtures/installer_host/." "$host_dir"
cp -R "$repo_dir/fixtures/installer_host/." "$phoenix_host_dir"
cp "$repo_dir/fixtures/installer_phoenix_host/mix.exs" "$phoenix_host_dir/mix.exs"

digest_tree() {
  find config lib test -type f -print |
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

  first_digest=$(digest_tree)

  mix format --check-formatted
  mix compile --warnings-as-errors
  mix test
  mix run -e '
    unless match?(%Attesto.Config{}, InstallerHost.MCP.attesto_config()) do
      raise("real attesto_phoenix integration did not derive Attesto.Config")
    end
  '

  mix attesto_mcp_server.install \
    --base-url https://mcp.example.com \
    --yes

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
