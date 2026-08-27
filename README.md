# attesto_mcp_server

`attesto_mcp_server` is an Apache-2.0, Attesto-native MCP server for Elixir.
It provides one protocol core with preferred MCP `2026-07-28` behavior and
negotiated `2025-11-25`/`2025-06-18` compatibility, a protected
Plug-compatible Streamable HTTP boundary, and a line-oriented stdio adapter.

Protected HTTP traffic enters the approved
`AttestoMCP.Plug.ProtectResource` boundary before body decoding and protocol
dispatch, with route-derived scopes applied through its prepared dynamic
authorization API. The required `attesto_mcp ~> 1.2.1` dependency provides
`ProtectResource.prepare/1`, `authenticate/2`, and `authorize/3`; no older
authentication fallback is included. Configure the canonical resource
path/origin, Attesto verifier, replay and certificate callbacks, and
least-privilege scopes in the host application. The package does not contain an
OAuth authorization server or token issuer.

## Quick start

```elixir
{:ok, server} = AttestoMCP.Server.start_link(name: :demo)

:ok = AttestoMCP.Server.register_tool(server, "hello", %{
  description: "Say hello",
  input_schema: %{"type" => "object"},
  handler: fn %{"name" => name}, _auth -> {:ok, "Hello #{name}!"} end
})

plug AttestoMCP.Server.Plug,
  server: server,
  path: "/mcp",
  auth: [
    config: &MyApp.Attesto.config/0,
    resource: "/mcp",
    base_url: "https://mcp.example.com"
  ]
```

`AttestoMCP.Server.API` is the stable documented facade for these startup,
registration, dispatch, session, subscription, and cancellation calls; the
lower-level `AttestoMCP.Server` module remains available for transport hosts.

### Phoenix installer

Phoenix hosts can install the same boundary with the optional Igniter task:

```sh
mix igniter.install attesto_mcp_server --base-url https://mcp.example.com
```

When the host already depends on `attesto_phoenix`, the generated application
module derives its verifier configuration from that package's validated OTP
configuration. Otherwise, provide an application-owned callback:

```sh
mix igniter.install attesto_mcp_server \
  --base-url https://mcp.example.com \
  --attesto-config MyApp.Attesto.config/0
```

The idempotent installer adds a supervised MCP module, conservative runtime
configuration, a starter registration test, and distinct top-level forwards
for `/mcp` and its public RFC 9728 metadata URL. The metadata forward uses a
generated application-owned wrapper, preserving compatibility with Phoenix
1.7's one-forward-per-plug rule. It never creates an issuer, credentials,
consent policy, or token storage. See
[Phoenix installation](docs/usage.md#phoenix-installation) for options and the
division of responsibilities between the packages.

Bandit is the documented development/test adapter, while the production
library depends only on Plug. For a local loopback example, see
`examples/bandit.exs`; it uses a credential-free verifier configuration and
returns 401 until a host supplies a token. For stdio interop, run
`elixir examples/stdio.exs` or call `AttestoMCP.Server.Stdio.run/2`.

The package-owned authenticated frozen-conformance fixture and its exact
observed results are documented in [`CONFORMANCE.md`](CONFORMANCE.md). It is a development/test
fixture only; its generated Attesto credential is never part of the library
or production configuration.

## Scope defaults

Tools listing uses `AttestoMCP.Scopes.tools_read/0`; tool execution uses
`tools_call/0`; resources and prompt/completion reads use their corresponding
`AttestoMCP.Scopes` helpers. Every HTTP request is reauthenticated and handles
or session IDs are never authorities by themselves.

## Operational notes

Pin the public origin behind a trusted proxy, use TLS in deployment, and keep
credentials/proofs/private content out of logs and Telemetry. Configure the
documented `max_queue`, `stream_keepalive_ms`, `stream_queue_size`, and
concurrency/timeout limits; Plug options override server defaults for that
adapter, while its effective `scope_map` is the single HTTP policy source.
Optional task profiles are disabled for this release; their
incomplete in-memory implementation cannot be enabled. A future durable
host-store contract is required before either profile can be advertised.

See [docs/usage.md](docs/usage.md), [docs/provenance.md](docs/provenance.md),
[docs/traceability.md](docs/traceability.md), and `SECURITY.md`.
