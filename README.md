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

Handler inputs are primitive-specific. Tools receive their JSON arguments map;
prompts receive `%{name: name, arguments: arguments}`; resources receive
`%{uri: uri, params: template_params}`; and completions receive
`%{ref: ref, argument: argument, value: value, context: completion_context}`.
Declared envelope fields use atom keys while nested MCP values keep their JSON
string keys; resource MRTR retries additionally carry string-keyed response
entries at the top level. An arity-2 handler's second argument is the
authenticated request context; arity-1 and MFA forms are also supported.

### Phoenix installer

Phoenix hosts can install the same boundary with the optional Igniter task:

```sh
mix igniter.install attesto_mcp_server --base-url https://mcp.example.com
```

When the host already depends on `attesto_phoenix`, the generated routes derive
the verifier and protected-resource callbacks from that package's validated
OTP configuration on each applicable request. This carries the host's DPoP
replay/nonce, canonical-request, and mTLS certificate policy into the MCP
boundary without freezing callback closures at router compile time. The
installer also enables secure URL client metadata and ephemeral `localhost`
callback ports for native desktop/CLI clients, adding the Req dependency used
by the default fetcher. Existing host values win, so an application can keep a
narrower metadata-host allowlist or stricter loopback policy.

This path supports direct public-Hex `attesto_phoenix` requirements that
overlap `>= 2.14.0 and < 3.0.0` and Req requirements that overlap
`>= 0.6.1 and < 1.0.0`; existing stable requirements are narrowed to their
intersection. That intersection must contain at least one stable release;
pre-release-only matches are intentionally rejected. If the dependency catalog
or either required declaration cannot be validated safely, installation stops
before editing. The explicit-callback path does not modify dependencies. Hosts
without `attesto_phoenix` provide an application-owned callback instead:

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
consent policy, token storage, or dynamic-registration policy. See
[Phoenix installation](docs/usage.md#phoenix-installation) for options and the
division of responsibilities between the packages.

Custom `--mcp-path` values must be non-root ASCII paths made from
slash-separated URI-unreserved segments (`A-Z`, `a-z`, digits, `.`, `_`, `~`,
and `-`). The task stops before editing when dependency, router, route, or
installer-owned module provenance cannot be established conservatively.

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
`AttestoMCP.Scopes` helpers. A non-empty `scope_map["completion/complete"]`
entry replaces the category default for both prompt and resource references;
an absent or empty entry cannot disable those defaults. Every HTTP request is
reauthenticated and handles or session IDs are never authorities by themselves.

## Operational notes

Pin the public origin behind a trusted proxy, use TLS in deployment, and keep
credentials/proofs/private content out of logs and Telemetry. Configure the
documented `max_queue`, `stream_keepalive_ms`, `stream_queue_size`, and
concurrency/timeout limits. `page_size` bounds catalog pages; `cache_ttl_ms`,
`cache_scope`, and `allow_public_cache` control cache metadata, with public
caching requiring both explicit opt-in and an authorization-independent result.
Request `_meta` values must be JSON objects when present; malformed values
produce request-local protocol errors without taking down either transport.
Published catalog notifications accept only `type` and optional object
`_meta`; resource-update notifications additionally require `uri`. Unknown
fields or malformed metadata are rejected before modern or legacy fanout.
Legacy resource subscriptions per session and modern resource filters per
subscription are fixed at 128 unique URIs and 4,096 bytes per URI; duplicates
do not consume another entry.
Plug options override server defaults for that adapter, while its effective
`scope_map` is the single HTTP policy source.
Optional task profiles are disabled for this release; their
incomplete in-memory implementation cannot be enabled. A future durable
host-store contract is required before either profile can be advertised.

See [docs/usage.md](docs/usage.md), [docs/provenance.md](docs/provenance.md),
[docs/traceability.md](docs/traceability.md), and `SECURITY.md`.
