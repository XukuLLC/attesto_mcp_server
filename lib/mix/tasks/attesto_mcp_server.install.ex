defmodule Mix.Tasks.AttestoMcpServer.Install.Docs do
  @moduledoc false

  @external_resource Path.join([__DIR__, "attesto_mcp_server", "install", "igniter.exs"])
  @external_resource Path.join([__DIR__, "attesto_mcp_server", "install", "fallback.exs"])

  @spec short_doc() :: String.t()
  def short_doc, do: "Installs an Attesto-protected MCP server into a Phoenix host"

  @spec example() :: String.t()
  def example do
    "mix attesto_mcp_server.install --base-url https://mcp.example.com " <>
      "--attesto-config MyApp.Attesto.config/0"
  end

  @spec long_doc() :: String.t()
  def long_doc do
    """
    #{short_doc()}.

    The task creates an application-owned supervised MCP module and starter
    test, adds a protected MCP forward (and, by default, an RFC 9728 metadata
    forward) to a Phoenix router, and adds conservative server configuration.
    It is idempotent and does not invent credentials, authorization policy, or
    a public origin.

    When `attesto_phoenix` is already a direct dependency, the generated routes
    reuse its validated verifier, access-token revocation and principal policy,
    and sender-constraint callbacks. The installer does not enable Client ID
    Metadata Documents by default. Use `--enable-cimd` only after confirming
    that the host has suitable CIMD storage; the installer will then add the
    Req dependency used by the default metadata fetcher. Existing native
    localhost callback compatibility remains unchanged.
    Other hosts must supply a zero-arity callback with `--attesto-config`.

    ## Example

        #{example()}

    ## Options

      * `--base-url` - required canonical public origin. HTTPS is required
      * `--mcp-path` - MCP route path; defaults to `/mcp`
      * `--server-module` - supervised host module; defaults to `<App>.MCP`
      * `--router` - Phoenix router module; selected automatically when unique
      * `--attesto-config` - zero-arity callback such as
        `MyApp.Attesto.config/0`; unnecessary with `attesto_phoenix`
      * `--reuse-metadata-route` - reuse a statically proven exact
        AttestoPhoenix protected-resource metadata forward instead of adding
        the package-owned metadata forward
      * `--enable-cimd` - explicitly enable AttestoPhoenix Client ID Metadata
        Documents and add the default fetcher's Req dependency
      * `--session-store` - choose `auto` (the default), `ecto`, or `ets` for
        2025-era session-bound MCP state. Automatic mode uses Ecto when exactly
        one host Repo is statically confirmed to use PostgreSQL and supervised
        as an application child. With no Repo, or when the sole Repo cannot be
        statically confirmed as supervised PostgreSQL, automatic mode safely
        keeps the in-memory ETS store; use `ets` to opt out of durable sessions
        explicitly. Explicit `ecto` remains fail-closed unless PostgreSQL is
        statically proven
      * `--repo` - Ecto Repo module used by the durable session store when the
        host has more than one Repo, or when `ecto` is selected explicitly
      * `--schema-prefix` - optional PostgreSQL schema used by the durable
        session store and its migration
      * `--allow-http-loopback` - allow an explicit HTTP loopback origin for
        local development only

    Igniter's global `--dry-run`, `--yes`, and related options remain
    available. Umbrella roots are not supported; run the task inside the
    Phoenix child application. When the installer selects Ecto, it prints the
    exact `mix attesto_mcp_server.gen.migration` command; it never generates or
    runs that migration automatically.
    """
  end
end

implementation =
  %{true => "igniter.exs", false => "fallback.exs"}
  |> Map.fetch!(Code.ensure_loaded?(Igniter))

Code.require_file(Path.join([__DIR__, "attesto_mcp_server", "install", implementation]))
