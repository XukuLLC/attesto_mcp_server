# attesto_mcp_server

Add an authenticated MCP endpoint to an Elixir or Phoenix SaaS application.
`attesto_mcp_server` combines the MCP server, Streamable HTTP transport, tool
catalog, request validation, and [Attesto](https://hex.pm/packages/attesto)
authorization in one Apache-2.0 package.

For a Phoenix application already using
[`attesto_phoenix`](https://hex.pm/packages/attesto_phoenix), the
batteries-included setup is one Igniter command. It reuses the application's
existing issuer, token verification, revocation, principal loading, DPoP, and
mTLS policy; it does not create a second authentication system.

Want to exercise the full request path before changing an application? The
[runnable Livebook walkthrough](https://github.com/XukuLLC/attesto_mcp_server/blob/main/examples/attesto_mcp_server.livemd)
creates an ephemeral local issuer, starts Bandit, registers a tool, and makes
authenticated MCP requests against it.

## Install in a Phoenix application

Run this inside the Phoenix child application—not an umbrella root—with
Igniter available and `attesto_phoenix` declared directly from Hex at a
version compatible with `>= 2.14.1 and < 4.0.0`:

```sh
mix igniter.install attesto_mcp_server --base-url https://mcp.example.com
```

`--base-url` is the externally reachable HTTPS origin, without `/mcp`; the
installer mounts the MCP path itself.

The installer:

- creates and supervises an application-owned `<App>.MCP` server;
- uses the application's single, statically confirmed and supervised
  PostgreSQL Ecto Repo for durable session-bound client sessions, while
  Repo-free applications retain the in-memory ETS default;
- mounts the protected `/mcp` endpoint and its public OAuth resource metadata;
- connects the endpoint to the live `attesto_phoenix` configuration;
- preserves token revocation, principal loading, DPoP replay/nonce, canonical
  request, and mTLS certificate checks;
- installs the parser bypass when it can prove a direct standard parser,
  refuses custom or ambiguous parser setups before editing, and reports the
  narrower cases that still need manual verification; and
- adds a starter `server_status` tool and registration test.

Review every installer notice, including any migration command and exact manual
verification emitted when endpoint source is unavailable. When the installer
selects the bundled Ecto store, run the command it prints and then migrate:

```sh
mix attesto_mcp_server.gen.migration --repo MyApp.Repo
mix ecto.migrate
```

The installer does not run either command. After a successful install, run the
generated starter test before editing the sample:

```sh
mix test
```

Then replace the starter registration in `<App>.MCP` with application tools
and update the generated registration test to assert those tools. The generated
module uses the stable host-facing API:

```elixir
alias AttestoMCP.Server.API

def register(server) do
  API.register_all(server, [
    {:tool, "customer_lookup",
     %{
       description: "Look up a customer by ID",
       input_schema: %{
         "type" => "object",
         "properties" => %{
           "id" => %{"type" => "string", "minLength" => 1}
         },
         "required" => ["id"],
         "additionalProperties" => false
       },
       handler: fn %{"id" => id}, context ->
         customer = MyApp.Customers.fetch!(context.principal, id)
         {:ok, %{"id" => customer.id, "name" => customer.name}}
       end
     }}
  ])
end
```

Run the updated tests and start the application normally:

```sh
mix test
mix phx.server
```

For focused tool tests, `AttestoMCP.Server.Test.call_tool/4` runs input-schema,
scope, policy, handler, output-schema, and wire-result checks without setting up
an HTTP token. Keep separate Plug tests for the authentication boundary.

MCP clients connect to `https://mcp.example.com/mcp` and authorize against the
same Attesto authorization server as the rest of the application.

### Connect a client

First make the client known to the application's Attesto authorization server:
pre-register a known client in the host's client store, or enable Client ID
Metadata Documents (CIMD) when the client identifies itself with an HTTPS
metadata URL. See AttestoPhoenix's
[CIMD guidance](https://hexdocs.pm/attesto_phoenix/readme.html#url-client-metadata-for-native-clients).
Then point the client at the `/mcp` URL.

The generated endpoint uses secure generic MCP scope defaults:
`mcp:tools:read`, `mcp:tools:call`,
`mcp:resources:read`, and `mcp:prompts:read`. Make sure the authorization
server grants those scopes, or set the mount's `scopes_supported` and
`default_scopes` to scopes the application already issues.

With package-generated routes, add `scopes_supported` to both the generated
metadata forward and MCP forward, and add `default_scopes` to the MCP forward.
With `--reuse-metadata-route`, AttestoPhoenix owns the public metadata, so
configure its advertised scopes there and the enforcement defaults on the MCP
forward.

Some clients identify themselves with an HTTPS Client ID Metadata Document. If
the application already supports CIMD, its configuration is reused. Otherwise,
run the `attesto_client_id_metadata` migration when using the default Ecto
cache, or prepare the selected custom cache, then rerun the same installer
command with `--enable-cimd`. Preserve its other flags, including
`--reuse-metadata-route` when used. The installer does not silently enable
dynamic client registration or invent client persistence. See
[Phoenix installation](docs/usage.md#phoenix-installation) for those host-owned
authorization-server choices.

## What application code owns

The package handles protocol negotiation, authenticated transport, catalog
discovery, request validation, bounded execution, result validation, sessions,
subscriptions, and neutral authorization failures. Application code supplies
the useful part: registered tools, resources, prompts, completion handlers, and
business-policy callbacks.

Registrations can be installed atomically at startup or through `register_all/2`.
The public API supports:

- tools with JSON Schema inputs and optional output schemas;
- static resources and bounded multi-expression URI templates;
- prompts and completions;
- catalog replacement for generated or reloaded catalogs; and
- notifications and subscriptions across the supported MCP revisions.

Handler inputs are specific to each primitive. An arity-2 handler receives the
decoded input followed by an authenticated context containing the principal,
tenant, scopes, claims, sender constraints, request metadata, and optional
application context. One-arity and MFA handlers are also supported. See the
[registration and handler contract](docs/usage.md#registration) for every input
form. Tool arguments remain string-keyed unless the server explicitly selects
`tool_argument_keys: :atoms`; that mode converts only schema-declared keys whose
atoms already exist and never creates atoms from client input.

## Handler results

Handlers can return simple strings or valid string-key maps. Public `Content`
and `Result` constructors are available for text, structured tool results,
resources, prompts, images, audio, and canonical Base64 blobs. They catch
malformed output before it reaches a client; raw maps remain supported for
extensions. See [registration and handler results](docs/usage.md#registration).

Structured output remains strict by default. A server may explicitly select
`output_canonicalization: :json` or `:jason` to stringify atom values and pass
structs through the corresponding encoder protocol under the normal bounded
output checks. Pairing `output_canonicalization: :jason` with
`tool_argument_keys: :atoms` is the direct migration setting for applications
whose existing handlers already use Jason-derived structs and atom-keyed tool
arguments.

JSON Schema `default` values are annotations and are not inserted during normal
dispatch. Applications that intentionally need bounded direct-property defaults
can call `AttestoMCP.Server.Schema.apply_property_defaults/2`.

For a business failure that is safe to disclose, return
`{:error, AttestoMCP.Server.Result.error(message, code)}`. Other errors and
exceptions remain generic at the protocol boundary.

## Scopes and application policy

`scopes_supported` is the public scope list MCP clients request for a mount.
`default_scopes` is the scope set enforced for protected operations without an
explicit method override. Keep both aligned with grants the application's
Attesto authorization server can issue.

Definitions can add narrow `required_scopes`, bounded alternative scope sets,
and an `authorize` callback for business rules that are not grants. These rules
apply consistently to catalog visibility and direct invocation.

Only literal `true` from `authorize` permits access; failures deny access
without disclosing whether the definition exists. An optional HTTP
`context_builder` can add application data under `context.host_context` without
replacing the authenticated identity or claims.

For loaded principal structs, set the HTTP Plug's `principal_binding` callback
to a small stable identifier. Handlers continue to receive the complete value
as `context.principal`, while sessions, subscriptions, cursors, and accounting
use `context.principal_binding`. A separate Plug-level `authorize` callback can
gate the complete mount once per authenticated HTTP leg and returns a neutral
403 on denial. See [principal loading and mount authorization](docs/usage.md#phoenix-installation).

Applications needing definition-scoped HTTP authorization can enable the
bounded `scope_policy` modes documented in
[definition authorization](docs/usage.md#per-definition-authorization).
Omitting that option retains the secure method-level defaults.

## Installer options

The automatic path above is intended for most Phoenix SaaS applications. These
options cover less common installations:

### Choose session storage

The default `--session-store auto` behavior is deliberately simple:

- one discovered, statically confirmed and supervised PostgreSQL Ecto Repo
  selects the bundled store and prints the exact migration command;
- no Repo keeps the in-memory ETS store; and
- multiple Repos stop installation before editing until `--repo MyApp.Repo`
  selects one.

If the sole Repo is not statically confirmed as a supervised PostgreSQL
application child, automatic selection keeps the in-memory ETS store and
prints a notice; no Ecto session configuration or migration guidance is added.
Explicit `--session-store ecto` and/or `--repo MyApp.Repo` choices remain
fail-closed until PostgreSQL is statically proven. Use `--session-store ets` to
make the in-memory choice explicit.

Use `--schema-prefix my_schema` with the selected Repo when the application
keeps these rows outside PostgreSQL's default schema. To keep sessions in
memory even when a Repo exists, opt out explicitly:

```sh
mix igniter.install attesto_mcp_server \
  --base-url https://mcp.example.com \
  --session-store ets
```

The Ecto store keeps negotiated `2025-11-25` and `2025-06-18` sessions across
application restarts. The `2026-07-28` transport is session-free. Live streams
reconnect after process loss; persisted session state does not promise event
replay. Distributed Erlang deployments that need cross-node notification
fanout can additionally enable `session_clustered: true`. Treat the session
table as authorization-sensitive data and use a least-privilege PostgreSQL
role; the [durable-session guidance](docs/usage.md#atomic-startup-telemetry-and-durable-sessions)
covers database timeouts, capacity, and cutover requirements.

### Enable Client ID Metadata Documents

The installer leaves CIMD disabled unless explicitly requested, because the
default `attesto_phoenix` cache may require the
`attesto_client_id_metadata` migration. After verifying that storage, run:

```sh
mix igniter.install attesto_mcp_server \
  --base-url https://mcp.example.com \
  --enable-cimd
```

Existing cache, repository, table-prefix, allowlist, native-app, and disabled
settings remain authoritative.

### Reuse an existing metadata route

If the router already exposes matching `attesto_phoenix` protected-resource
metadata for `/mcp`, retain it and add only the MCP endpoint with:

```sh
mix igniter.install attesto_mcp_server \
  --base-url https://mcp.example.com \
  --reuse-metadata-route
```

Ambiguous or mismatched routes are left unchanged and reported with manual
remediation.

### Use a loopback origin for local development

HTTP remains disabled for deployed origins. For local development, explicitly
allow a loopback origin:

```sh
mix igniter.install attesto_mcp_server \
  --base-url http://127.0.0.1:4000 \
  --allow-http-loopback
```

Connect local clients to `http://127.0.0.1:4000/mcp`; an unauthenticated probe
should reach the boundary and return 401 rather than 404.

When the AttestoPhoenix native-app callback setting is absent, the installer
also enables `localhost` callback matching so a registered portless callback
can use a client's ephemeral local port. It preserves any existing `true` or
`false` choice.

### Use Attesto without attesto_phoenix

An application with its own Attesto configuration callback can still use the
installer:

```sh
mix igniter.install attesto_mcp_server \
  --base-url https://mcp.example.com \
  --attesto-config MyApp.Attesto.config/0
```

The task validates dependency, router, route, and parser ownership before
editing. It refuses ambiguous or custom parser arrangements instead of
guessing. All installer options and recovery steps are in
[Phoenix installation](docs/usage.md#phoenix-installation).

## Other hosts and transports

Non-Phoenix Plug hosts can add the package directly:

```elixir
def deps do
  [{:attesto_mcp_server, "~> 1.0"}]
end
```

Supervise `AttestoMCP.Server`, register definitions through
`AttestoMCP.Server.API`, and mount `AttestoMCP.Server.Plug` directly. The
[`examples/bandit.exs`](examples/bandit.exs) program demonstrates direct server
startup, registration, and the protected Plug; the [usage guide](docs/usage.md)
documents the transport and authentication options. Router and supervision
wiring remain specific to the host. It also includes a
[three-server Phoenix example](docs/usage.md#three-named-mcp-servers-in-one-phoenix-host)
for applications with multiple MCP mounts.

The production library depends on Plug rather than a particular HTTP server.
Bandit is the documented development/test adapter. The loopback example returns
401 until given a valid credential. The stdio adapter is available through
`AttestoMCP.Server.Stdio.run/2` and [`examples/stdio.exs`](examples/stdio.exs).

## Operations and limits

Secure defaults bound JSON values, outputs, queues, concurrency, and execution
time. Applications with larger tool inputs or Base64 resources can raise the
finite `max_json_bytes` budget together with the relevant `max_body_bytes` and
`max_message_bytes` transport ceilings. Result constructors may also need an
explicit higher limit for oversized content. Atomic catalogs, the bundled
PostgreSQL session store, custom session-store adapters, clustered routing,
cache policy, telemetry, and
exception reporting are documented in the [usage guide](docs/usage.md).

Operator code can page active session-bound client IDs with
`AttestoMCP.Server.API.active_session_ids/2` without loading session records,
principals, or tenants. The session-free `2026-07-28` transport has no server
session IDs to list.

The server prefers MCP `2026-07-28` and also negotiates `2025-11-25` and
`2025-06-18`. The latest recorded runner and SDK evidence covers 1.0.0 in
[`CONFORMANCE.md`](CONFORMANCE.md).

At this package's protected HTTP boundary, clients sending a `2026-07-28` POST
must include the required version, method, and selected-definition mirror
headers. Missing, duplicate, or mismatched mirrors return a neutral HTTP 400.
See [modern HTTP mirror headers](docs/usage.md#modern-http-mirror-headers) for
the complete contract and request examples. The earlier session-bound MCP
revisions use their negotiated session rules instead.

## Package boundaries

[`attesto_mcp`](https://hex.pm/packages/attesto_mcp) supplies the protected
resource boundary used before body decoding. In the batteries-included Phoenix
path, `attesto_phoenix` remains the OAuth authorization server and token issuer;
`attesto_mcp_server` supplies the MCP protocol server and transports. The
installer connects them using the host application's validated runtime
configuration.

## More documentation

- [Usage and deployment](docs/usage.md)
- [Migration runbook](docs/migration.md)
- [Security policy](SECURITY.md)
- [Conformance evidence](CONFORMANCE.md)
