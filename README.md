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
path/origin, Attesto verifier, principal policy, replay and certificate
callbacks, and least-privilege scopes in the host application. The package does
not contain an OAuth authorization server or token issuer.

## Quick start

```elixir
{:ok, server} = AttestoMCP.Server.start_link(name: :demo)

:ok = AttestoMCP.Server.register_tool(server, "hello", %{
  description: "Say hello",
  input_schema: %{
    "type" => "object",
    "properties" => %{
      "name" => %{"type" => "string", "minLength" => 1}
    },
    "required" => ["name"],
    "additionalProperties" => false
  },
  handler: fn %{"name" => name}, _auth -> {:ok, "Hello #{name}!"} end
})

plug AttestoMCP.Server.Plug,
  server: server,
  path: "/mcp",
  scopes_supported: ["workspace.mcp"],
  default_scopes: ["workspace.mcp"],
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

Public constructors catch malformed handler output at its source while keeping
raw string-key maps available for extensions:

```elixir
alias AttestoMCP.Server.{Content, Result}

{:ok,
 Result.tool(Content.text("saved"),
   structured_content: %{"id" => "document-7"}
 )}

{:ok,
 Result.resource(
   Content.resource_text("urn:document:7", "contents", mime_type: "text/plain")
 )}

{:ok, [Content.prompt_message(:user, Content.text("Review document 7"))]}
```

Image, audio, and resource-blob constructors take an already encoded canonical
padded-Base64 string. Constructors emit canonical string-key maps and reject
unknown or duplicate options. Server validation still accepts valid raw maps.

JSON Schema `default` is an annotation: normal validation and dispatch do not
insert it. A handler that explicitly wants defaults on optional direct
properties can opt in with
`AttestoMCP.Server.Schema.apply_property_defaults/2`. The bounded helper never
overwrites a present value, validates the completed object, and does not infer
defaults through references, combinators, conditionals, array items, or pattern
properties. Required properties must still pass normal request validation
before the handler runs.

`scopes_supported` controls the public RFC 9728 document for that mount, while
`default_scopes` controls protected operations without a non-empty
method-specific `scope_map` entry. Keep the two aligned with grants actually
issued by the Attesto authorization server. If an AttestoPhoenix router owns
the metadata route via `--reuse-metadata-route`, configure its protected
resource metadata there; the MCP Plug cannot alter a route it does not serve.
A resolver-backed `:auth` may instead supply the canonical absolute resource or
base origin after runtime configuration loads. Its path and origin must agree
with the Plug mount and any static pin; the same resolved identifier drives
metadata and audience verification. `allow_dynamic_origin` remains explicitly
development-only.

An optional `context_builder` function or MFA receives the authenticated
`Plug.Conn` and contributes a map under `context.host_context`; it cannot
replace the package-owned principal, scopes, claims, sender, or tenant fields.
Return `{:error, AttestoMCP.Server.Result.error(message, code)}` for bounded
business failures that are safe for a client. Other failure values and
exceptions remain generic at the protocol boundary.

### Phoenix installer

Phoenix hosts can install the same boundary with the optional Igniter task:

```sh
mix igniter.install attesto_mcp_server --base-url https://mcp.example.com
```

When the host already depends on `attesto_phoenix`, the generated routes derive
the verifier and protected-resource callbacks from that package's validated
OTP configuration on each applicable request. This carries access-token JTI
revocation, principal loading, DPoP replay/nonce, canonical-request, and mTLS
certificate policy into the MCP boundary without freezing callback closures at
router compile time. The installer preserves its native `localhost` callback
compatibility default, but the installer does not enable Client ID Metadata
Documents (CIMD) by default, so an established host cannot accidentally select
an Ecto-backed cache before running its `attesto_client_id_metadata` migration. Pass
`--enable-cimd` only after verifying that storage; this adds the Req dependency
used by the default fetcher. Existing host values win, including cache, repo,
table-prefix, allowlist, and disabled settings.

Automatic AttestoPhoenix integration requires every authenticated token
subject to resolve through the host's `load_principal` callback. A revoked JTI,
an unresolved subject, or a callback failure denies the MCP request with a
neutral invalid-token response. Return a principal term whose equality is
stable for the same identity: the server uses it for request ownership,
session and subscription isolation, and rate/concurrency accounting.

This path supports direct public-Hex `attesto_phoenix` requirements that
overlap `>= 2.14.1 and < 3.0.0` and Req requirements that overlap
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
for `/mcp` and its public RFC 9728 metadata URL. Use
`--reuse-metadata-route` to retain exactly one statically proven
`use AttestoPhoenix.Router` plus
`attesto_routes(protected_resource_paths: ["/mcp"])` metadata route and
generate only the MCP forward; ambiguous or mismatched
routes stop before editing with the manual wiring required. Otherwise the
metadata forward uses a generated application-owned wrapper, preserving
compatibility with Phoenix 1.7's one-forward-per-plug rule. A direct standard
Phoenix endpoint parser is wrapped to bypass `/mcp` and route-equivalent
trailing slashes before authentication; custom or ambiguous parser setups make
the installer stop before any edit and report the required remediation while
retaining host ownership. If the endpoint cannot be inferred or its source is
unavailable, installation proceeds with a warning and leaves manual pipeline
verification to the host. A proven simple endpoint with no parser produces an
informational warning but needs no endpoint edit. It never creates an issuer, credentials,
consent policy, token storage, or dynamic-registration policy. See
[Phoenix installation](docs/usage.md#phoenix-installation) for options and the
division of responsibilities between the packages.

Custom `--mcp-path` values must be non-root ASCII paths made from
slash-separated URI-unreserved segments (`A-Z`, `a-z`, digits, `.`, `_`, `~`,
and `-`). The task stops before editing when dependency, router, route, or
installer ownership cannot be established conservatively.

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

### Explicit definition-scoped HTTP policy

Hosts that issue fine-grained definition scopes can opt into per-method policy
without changing the secure defaults:

```elixir
scope_policy: %{
  "tools/list" => :visible_definitions,
  "tools/call" => :selected_definition,
  "resources/list" => :visible_definitions,
  "resources/templates/list" => :visible_definitions,
  "resources/read" => :selected_definition
}
```

The visible mode filters catalogs with each definition's `required_scopes` and
`authorize` callback. The selected mode binds the requested tool, static
resource, or URI template, then checks its scopes through the prepared Attesto
boundary before retry-state consumption or handler invocation. Hidden and
denied definitions use the same neutral unknown result. This option is
explicitly opt-in; omitted policy preserves the generic method scopes, and an
empty `scope_map` entry still restores that default. A policy method may not
also appear in `scope_map`, including with an empty entry; an explicit Plug
`scope_map` replaces the server map, and the effective map is revalidated at
request time for named or restarted servers.
Definitions with `required_scopes: []` are authenticated-only only on methods
explicitly mapped to this policy; default and empty-map methods still require
their generic scope.

A definition can declare bounded alternative all-of clauses without moving
scope logic into its business-policy callback:

```elixir
required_scopes: ["documents.read"],
alternative_scope_sets: [
  ["documents.admin"],
  ["workspace.read", "documents.execute"]
]
```

The primary `required_scopes` clause or any complete alternative permits the
definition. The primary clause must be non-empty when alternatives are used;
each clause is non-empty and duplicate-free, and clauses must be distinct
regardless of member order. At most seven alternatives, 128 total scope
memberships, and 8,192 aggregate scope bytes are accepted. Catalog filtering,
selected lookups, resource templates, subscription scope snapshots, and both
protocol eras use the same clauses. `authorize` runs once only after one clause
succeeds. Alternatives do not rewrite RFC 9728 metadata: continue to advertise
the meaningful scopes clients should request with `scopes_supported`.

Modern `subscriptions/listen` opening uses configured `default_scopes` instead
of generic category scopes when no non-empty method entry exists. A non-empty
`scope_map["subscriptions/listen"]` entry is additive to the generic category
scopes, and `subscription_scopes` are always additive. Each modern delivery
reauthorizes the captured principal and tenant with that opening union plus its
notification requirements; resource updates also require the generic resource
scope and any matched definition scopes. Legacy subscription-notification
delivery reauthorizes catalog events with their generic category scope;
resource-update notifications also require any matched definition scopes.
`subscriptions/listen` is intentionally not a definition-policy method.

## Operational notes

Pin the public origin behind a trusted proxy, use TLS in deployment, and keep
credentials/proofs/private content out of logs and Telemetry. Configure the
documented `max_queue`, `stream_keepalive_ms`, `stream_queue_size`, and
concurrency/timeout limits. HTTP `max_body_bytes` and `max_message_bytes`, and
stdio `max_message_bytes`, cannot exceed the 2,000,000-byte schema-instance
ceiling; the message limit still governs JSON-RPC decoding. Successful results
are checked again after the server adds protocol metadata, so aggregate pages
or handler values that exceed the ceiling fail closed. `page_size` bounds
catalog pages; `cache_ttl_ms`,
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

Use `register_all/2` or the startup `:registrations` option when a catalog must
appear atomically. A failed batch changes neither the registry nor its catalog
revision and emits no invalidation. One successful batch emits at most one
invalidation per affected catalog.

`replace_catalog/2` validates the same bounded registration tuples, then
atomically makes that batch the complete catalog, including removals. Failure
leaves the old catalog and revision intact. An identical replacement is a
no-op; a changed replacement advances the revision once and emits one
list-changed notification for each affected advertised catalog category.
Resources and templates share one category; completion-only changes emit none.

Legacy sessions use the private in-memory store by default. A durable host may
provide `session_store: {Adapter, handle}` and an explicit
`session_namespace`; the adapter implements
`AttestoMCP.Server.SessionStore`. Set `session_clustered: true` only with a
shared adapter and explicit namespace. Cluster peers then load the same session
records and fan modern, legacy, and catalog notifications to the node holding
each live stream. Live PIDs and sockets are never persisted, so clients reopen
streams after node loss; session identity, negotiated revision, capabilities,
subscriptions, and logging level survive. Store loss stops the server instead
of silently falling back to local memory when the configured store handle is a
monitored process; other adapters fail closed when an operation cannot reach
their backend. Use a globally unique `session_namespace` when unrelated
deployments share the same store or Erlang cluster. Cross-node notification
delivery is asynchronous and does not provide replay or exactly-once delivery
across a network partition. In 0.12.0, peer catalog drift cannot reduce
publisher-required scopes; drain mixed old/new clusters rather than rely on
them for resource notifications.

`telemetry_metadata` adds at most 16 bounded scalar host dimensions to emitted
events without permitting reserved-key replacement. `handler_task_init` runs
inside each request worker before its handler; `exception_reporter` receives
trusted exception details while wire responses and Telemetry remain scrubbed.
All three options accept documented function/MFA forms where applicable.

Plug options override server defaults for that adapter, while its effective
`scope_map` is the single HTTP policy source.
Optional task profiles are disabled for this release; their
incomplete implementation cannot be enabled.

See the [migration runbook](docs/migration.md), [usage guide](docs/usage.md),
and [security policy](SECURITY.md).
