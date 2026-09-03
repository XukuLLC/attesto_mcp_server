# Usage and deployment

For a checklist that maps an existing catalog and deployment onto this
package, start with the [migration runbook](migration.md).

## Phoenix installation

`attesto_mcp_server` owns the protected-resource protocol boundary. In a host
that also uses `attesto_phoenix`, the latter remains the authorization server:
it owns issuer, consent, token, refresh, revocation, and sender-constrained
credential behavior. The installer reuses both its validated core
`Attesto.Config` and its public protected-resource adapter for DPoP
replay/nonce, canonical-request, and mTLS certificate callbacks. The resulting
MCP boundary also applies the host's access-token JTI revocation check and
principal loader before reading the request body; it does not duplicate or
reconfigure those responsibilities. There is no hard dependency from this
package to `attesto_phoenix`.

Use `attesto_phoenix` 3.x when one Phoenix host serves multiple named profiles.
It binds each automatic protected-resource callback to the named profile
loaded from the `otp_app` passed to the helper, keeping those profiles
isolated. It does not select a profile from `conn.private`. The 2.14
compatibility path supports one globally configured profile; using it for
multiple profiles can route persistent replay or revocation reads through that
global profile's store.

These bindings cover the DPoP, mTLS, URL, revocation, and principal callbacks
listed above. Token signature verification uses the keystore carried by the
derived `Attesto.Config`; each named profile must therefore configure a
keystore that is safe to invoke without Phoenix request-local configuration.

On this automatic path, every authenticated token subject must resolve through
the host's `load_principal` callback. A revoked JTI, an unresolved subject, or
a callback failure denies the request with a neutral invalid-token response.
Handlers receive that complete loaded value as `context.principal` and
`context.attesto_mcp_principal`.

By default, the loaded principal also remains the identity used for ownership,
session and subscription isolation, cursors, and rate/concurrency accounting.
For a loaded struct or any value with fields that can differ between loads,
configure the Plug's `principal_binding` callback. It receives the loaded
principal and returns the stable identity term directly:

```elixir
forward "/mcp", AttestoMCP.Server.Plug,
  server: MyApp.MCP,
  path: "/mcp",
  auth: {AttestoMCP.Server.Phoenix, :protected_resource_options, [:my_app]},
  principal_binding: {MyApp.MCPIdentity, :binding},
  resource: "/mcp",
  base_url: "https://mcp.example.com"

defmodule MyApp.MCPIdentity do
  def binding(%MyApp.Accounts.User{id: id}), do: {:user, id}
end
```

Anonymous one-argument functions and `{module, function, prefix_arguments}`
MFAs are also supported. The return is not an `{:ok, value}` wrapper: it is the
binding itself. It must be non-nil, portable, and at most 64 KiB in its encoded
form. Prefer a small opaque identifier without profile data or other PII.
Invalid returns and callback failures stop the request with a generic internal
error before a POST body is read. The derived value is available to handlers as
`context.principal_binding`; the complete principal is not replaced.

The durable record format remains version 1 and retains its existing
`"principal"` field, which stores the binding. Existing 0.14 records therefore
need no database migration and continue to decode. With `principal_binding`
omitted, their comparison behavior is unchanged. Enabling a new binding on a
mount fails closed for an existing row unless that row's stored principal is
equal to the newly derived binding. Drain those session-bound clients or allow
their sessions to expire and reconnect when changing this policy; modern
session-free clients are unaffected.

With `attesto_phoenix` already declared directly by the host, run:

```sh
mix igniter.install attesto_mcp_server --base-url https://mcp.example.com
```

When exactly one host Ecto Repo is statically confirmed to use PostgreSQL and
to be supervised as a literal application child, the installer wires the
bundled session store and orders the MCP child after that Repo. Run the exact
generator command printed in the installer notice, followed by the host's
normal migration command:

```sh
mix attesto_mcp_server.gen.migration --repo MyApp.Repo
mix ecto.migrate
```

The installer and generator only write source; neither changes the database.
With no Repo, the in-memory ETS default remains in use. With multiple Repos, the
installer refuses to choose until `--repo MyApp.Repo` is supplied. Use
`--session-store ets` to retain in-memory sessions deliberately, or
`--schema-prefix my_schema` with Ecto for a validated PostgreSQL schema. If the
sole Repo is not statically confirmed as a supervised PostgreSQL application
child, automatic selection keeps the in-memory ETS default, adds a notice, and
emits no Ecto session configuration or migration guidance. Explicit
`--session-store ecto` and/or `--repo MyApp.Repo` choices remain fail-closed
until PostgreSQL is statically proven.

Static discovery reads regular `.exs` files below `config/` without following
symlinks. Conflicting environment-specific Repo or session-store declarations
are treated as ambiguous; make the selection consistent or pass an explicit
supported choice rather than relying on file order.

Whether or not CIMD is enabled, the installer sets
`native_apps.loopback_include_localhost` to `true` only when that key is absent.
This lets a registered portless `http://localhost/...` native-app callback use
the ephemeral port chosen by the client. An application's existing `true` or
`false` choice remains authoritative.

On this combined path the installer does not enable Client ID Metadata Documents
(CIMD) by default. This avoids silently selecting AttestoPhoenix's default
Ecto-backed CIMD cache when an established host has not run the required
`attesto_client_id_metadata` migration. If the host has verified its CIMD
storage, opt in explicitly:

```sh
mix igniter.install attesto_mcp_server \
  --base-url https://mcp.example.com \
  --enable-cimd
```

The explicit opt-in adds the compatible Req dependency and, when the
corresponding CIMD key is absent, enables it. Together, the relevant defaults
are:

```elixir
config :my_app, AttestoPhoenix.Config,
  client_id_metadata: [enabled: true],
  native_apps: [loopback_include_localhost: true]
```

The CIMD setting supports clients that use an HTTPS Client ID Metadata
Document. The default AttestoPhoenix fetcher retains its HTTPS, DNS/IP, size,
timeout, redirect, and cache validation. Deployments with a known client set
should add a narrow `:allowed_hosts` list. Existing configuration is not
replaced, and the installer does not enable dynamic registration or invent
client persistence. Existing cache, repo, table-prefix, allowlist, and disabled
settings remain authoritative; a custom cache module does not require an Ecto
table. Review the generated notice and host migration status before enabling
CIMD.

This path supports direct public-Hex `attesto_phoenix` requirements that
overlap `>= 2.14.1 and < 4.0.0` and Req requirements that overlap
`>= 0.6.1 and < 1.0.0`. Existing stable requirements are narrowed to their
intersection, which must contain at least one stable release; pre-release-only
matches are intentionally rejected. The task accepts only the public packages
with safe runtime options; an ambiguous dependency catalog or a dynamic,
duplicate, incompatible, restricted, custom-source, or unsupported declaration
makes installation stop before any edit. The explicit-callback path below
remains dependency-neutral.

For an Attesto host without `attesto_phoenix`, name a zero-arity callback that
returns the verifier configuration:

```sh
mix igniter.install attesto_mcp_server \
  --base-url https://mcp.example.com \
  --attesto-config MyApp.Attesto.config/0
```

If the dependency is already present, the package task can be called directly:

```sh
mix attesto_mcp_server.install \
  --base-url https://mcp.example.com \
  --attesto-config MyApp.Attesto.config/0
```

The task requires a canonical public origin rather than inferring one from a
request. HTTPS is mandatory except for an explicitly enabled loopback origin:

```sh
mix attesto_mcp_server.install \
  --base-url http://127.0.0.1:4000 \
  --allow-http-loopback \
  --attesto-config MyApp.Attesto.config/0
```

It creates an application-owned `<App>.MCP` process, adds it to the application
supervisor, adds conservative `server_options` in `config/config.exs`, creates
a starter registration test, and mounts two top-level router forwards in this
order. The generated forwards contain `server`, `path`, `auth`, `resource`, and
`base_url`. A host that issues `workspace.mcp` can then add the
`scopes_supported` and `default_scopes` lines shown below. The generated
metadata wrapper keeps the two forwarded plug modules distinct for Phoenix 1.7
compatibility. On the automatic AttestoPhoenix path, the exact
protected-resource options are resolved after the server, request header
budget, and HTTP method checks on every protected MCP request. Public metadata
requests resolve the same current options independently:

```elixir
Elixir.Phoenix.Router.forward(
  "/.well-known/oauth-protected-resource/mcp",
  Elixir.MyApp.MCP.MetadataPlug,
  server: Elixir.MyApp.MCP,
  path: "/mcp",
  scopes_supported: ["workspace.mcp"],
  auth: {Elixir.AttestoMCP.Server.Phoenix, :protected_resource_options, [:my_app]},
  resource: "/mcp",
  base_url: "https://mcp.example.com"
)

Elixir.Phoenix.Router.forward(
  "/mcp",
  Elixir.AttestoMCP.Server.Plug,
  server: Elixir.MyApp.MCP,
  path: "/mcp",
  scopes_supported: ["workspace.mcp"],
  default_scopes: ["workspace.mcp"],
  auth: {Elixir.AttestoMCP.Server.Phoenix, :protected_resource_options, [:my_app]},
  resource: "/mcp",
  base_url: "https://mcp.example.com"
)
```

`protected_resource_options/2` can transform or reject the loaded principal
without replacing the automatic revocation and `load_principal` path. Its
`:principal` callback runs only after both steps succeed and receives the
loaded principal, verified claims, and sender information. It must return
`{:ok, non_nil_principal}` or `{:error, reason}`:

```elixir
auth:
  {AttestoMCP.Server.Phoenix, :protected_resource_options,
   [
     :my_app,
     [principal: {MyApp.MCPPrincipal, :finalize}]
   ]}

defmodule MyApp.MCPPrincipal do
  def finalize(loaded_principal, claims, _sender) do
    {:ok,
     %{
       account: loaded_principal,
       client_id: claims["client_id"]
     }}
  end
end
```

The function and MFA forms are strict three-argument callbacks; an MFA with
prefix arguments receives those first. A malformed return or exception denies
authentication. Use the Plug-level `authorize` option below for mount access
policy that should produce a neutral 403 rather than an invalid-token response.

The explicit `--attesto-config` path instead keeps the static
`auth: [config: &Elixir.MyApp.MCP.attesto_config/0, resource: "/mcp",
base_url: "https://mcp.example.com"]` form. Such hosts remain responsible for
supplying every replay, nonce, canonical-request, and certificate callback
their sender-constraint policy needs, plus any application-specific
`:principal` callback that performs principal availability or access-token
revocation checks.

The generated metadata wrapper and MCP forward may both receive
`scopes_supported: ["..."]`; use the grants that the authorization server can
actually issue for that resource. A reused `attesto_routes` metadata endpoint
remains owned by AttestoPhoenix, so configure its protected-resource metadata
there. `default_scopes: ["..."]` separately replaces generic MCP operation
defaults unless a non-empty method entry in `scope_map` takes precedence.

Keep both forwards outside browser-session and CSRF pipelines. The metadata
route is intentionally public; the MCP route authenticates every protected
leg. The installer inspects the selected Phoenix endpoint. For a direct,
standard `Plug.Parsers` declaration it wraps that parser with
`AttestoMCP.Server.PhoenixParser`, which bypasses body parsing for the configured
decoded path prefix, its route-equivalent trailing and repeated slashes, and
every deeper child path, while leaving metadata, browser, JSON, and form routes
outside that prefix unchanged. This is a path-prefix safety boundary, not
proof of router ownership: ordinary routes below the configured prefix also
bypass body parsing, so do not overlap the prefix with unrelated routes.
Custom or ambiguous parser setups make the installer stop before editing any
project file and report the required remediation. Fix
the ambiguity or wire the parser and routes manually before deployment, then
rerun the installer if appropriate. When the endpoint cannot be inferred from
the selected router, or its source cannot be found, the installer warns and
continues without an endpoint edit; the host must then verify the parser
pipeline manually. A statically proven simple endpoint with no direct parser
also produces an informational warning and continues, leaving bounded body
decoding to the MCP Plug; that case needs no immediate endpoint edit. Any
host-owned parser added or discovered later must skip the configured decoded
MCP path prefix and every deeper child path, and use a body-length limit at
least as strict as the MCP Plug's `:max_body_bytes`, because host parsing
otherwise occurs before MCP authentication. Do not place unrelated routes below
that prefix. Run the task again safely after an interrupted install:
generated modules, configuration, supervision, routes, and tests are
idempotent. Use Igniter's
global `--dry-run` option to inspect the edits first. If the router cannot be
selected uniquely, pass `--router MyAppWeb.Router`; the task refuses ambiguous
router selection and prints an exact manual snippet if no router exists.

Additional options are `--mcp-path`, `--server-module`, `--router`,
`--attesto-config`, `--enable-cimd`, `--reuse-metadata-route`,
`--session-store`, `--repo`, and `--schema-prefix`. Run the task inside the Phoenix child application rather
than at an umbrella root. The generated `server_status` tool is deliberately a
small starter; replace it with application-specific registrations and scopes.
When `--reuse-metadata-route` is selected, the task requires exactly one
supported zero-option `use AttestoPhoenix.Router` followed by the literal
`attesto_routes(protected_resource_paths: ["/mcp"])` invocation (with the
selected path substituted). It preserves that invocation and inserts only the
MCP forward immediately after it. It does not infer paths from dynamic,
parameterized, glob, scoped, ambiguous, duplicate, or mismatched routes; if
exact equivalence cannot be proven, it stops before editing and prints the
exact manual MCP forward required. `--mcp-path` must be a non-root ASCII path whose nonempty segments use only
URI-unreserved letters, digits, `.`, `_`, `~`, and `-`. The same canonical
path grammar is enforced by the runtime Plug so an encoded client path cannot
silently differ from the configured resource. The generated MCP module owns a
dedicated source file; move unrelated modules or file-level compiler directives
elsewhere before rerunning the installer. A selected Phoenix router must
likewise be the only top-level module in its file so inherited aliases and
imports cannot redirect its routing DSL. Installation also stops when an
existing exact, parameterized, glob, resource, or forwarded route could overlap
either generated mount; resolve the conflict or mount the two forwards manually
at an intentional precedence point.

### Three named MCP servers in one Phoenix host

The installer owns one generated mount. A host with several MCP resources can
wire them manually. Give every server a distinct registered name and session
namespace. The bundled Ecto adapter then keeps all sessions in the same
`attesto_mcp_sessions` table while its `{namespace, session_id}` key prevents a
session issued at one mount from being accepted at another:

```elixir
defmodule MyApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MyApp.Repo,
      mcp_child(MyApp.MCP.Catalog, "mcp-catalog", MyApp.MCP.Catalog.registrations()),
      mcp_child(MyApp.MCP.Operations, "mcp-operations", MyApp.MCP.Operations.registrations()),
      mcp_child(MyApp.MCP.Preview, "mcp-preview", MyApp.MCP.Preview.registrations())
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
  end

  defp mcp_child(name, namespace, registrations) do
    {:ok, store} =
      AttestoMCP.Server.SessionStore.Ecto.new(
        repo: MyApp.Repo,
        namespace: namespace
      )

    {AttestoMCP.Server,
     name: name,
     registrations: registrations,
     session_store: {AttestoMCP.Server.SessionStore.Ecto, store},
     session_namespace: namespace}
  end
end
```

Replace the endpoint's ordinary `Plug.Parsers` declaration with the wrapper,
retaining the host's parser options. One wrapper accepts up to 32 unique static
MCP paths. It matches each decoded configured path as a segment prefix and
bypasses the prefix, trailing/repeated-slash equivalents, and every deeper child
path; parent paths and sibling segment prefixes still run the host parser.
Because this is a prefix-based body-parsing boundary, ordinary routes below a
configured prefix also bypass parsing and must not overlap it:

```elixir
plug AttestoMCP.Server.PhoenixParser,
  mcp_path: ["/mcp/catalog", "/mcp/operations", "/mcp/preview"],
  parsers: [:urlencoded, :multipart, :json],
  pass: ["*/*"],
  json_decoder: Phoenix.json_library()
```

Publish one path-specific protected-resource metadata document and one
protected forward per server. `root: false` avoids assigning the ambiguous
unsuffixed metadata document to any of the three resources:

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router
  use AttestoMCP.Router

  scope "/" do
    attesto_mcp_protected_resource_metadata "/mcp/catalog",
      scopes: ["catalog.mcp"],
      base_url: "https://mcp.example.com",
      root: false

    attesto_mcp_protected_resource_metadata "/mcp/operations",
      scopes: ["operations.mcp"],
      base_url: "https://mcp.example.com",
      root: false

    attesto_mcp_protected_resource_metadata "/mcp/preview",
      scopes: ["preview.mcp"],
      base_url: "https://mcp.example.com",
      root: false
  end

  forward "/mcp/catalog", AttestoMCP.Server.Plug,
    server: MyApp.MCP.Catalog,
    path: "/mcp/catalog",
    scopes_supported: ["catalog.mcp"],
    default_scopes: ["catalog.mcp"],
    auth: {AttestoMCP.Server.Phoenix, :protected_resource_options, [:my_app]},
    resource: "/mcp/catalog",
    base_url: "https://mcp.example.com"

  forward "/mcp/operations", AttestoMCP.Server.Plug,
    server: MyApp.MCP.Operations,
    path: "/mcp/operations",
    scopes_supported: ["operations.mcp"],
    default_scopes: ["operations.mcp"],
    auth: {AttestoMCP.Server.Phoenix, :protected_resource_options, [:my_app]},
    resource: "/mcp/operations",
    base_url: "https://mcp.example.com"

  forward "/mcp/preview", AttestoMCP.Server.Plug,
    server: MyApp.MCP.Preview,
    path: "/mcp/preview",
    scopes_supported: ["preview.mcp"],
    default_scopes: ["preview.mcp"],
    auth: {AttestoMCP.Server.Phoenix, :protected_resource_options, [:my_app]},
    resource: "/mcp/preview",
    base_url: "https://mcp.example.com"
end
```

Keep these routes outside browser-session and CSRF pipelines. Each metadata
path, Plug `:path`, protected resource, public origin, advertised scopes, and
server registration must agree for that mount.

## Bandit development server

The HTTP boundary is a normal Plug. A documented local launcher is:

```elixir
Mix.install(
  [{:attesto_mcp_server, path: "."}, {:bandit, "~> 1.6"}],
  force: true,
  verbose: false
)
{:ok, server} = AttestoMCP.Server.start_link(name: :bandit_example)
plug = {AttestoMCP.Server.Plug, server: server, path: "/mcp", auth: [config: my_attesto_config, base_url: "http://127.0.0.1:4000"]}
Bandit.start_link(plug: plug, scheme: :http, ip: {127, 0, 0, 1}, port: 4000)
```

For an executable credential-free launcher, use `elixir examples/bandit.exs`.
It starts Bandit with an empty static keystore and therefore answers 401 until
the host supplies a token; it contains no hidden application module or secret.

### Frozen conformance fixture

The package includes an authenticated, package-owned Bandit fixture under
`test/conformance_fixture_test.exs`. It registers representative tools,
resources, a URI template, prompts, and completion, then exercises real TCP
HTTP tool listing, tool calling, and prompt retrieval with an Attesto test
token. Run the fixture independently for each frozen requirements set:

```sh
MCP_REQUIREMENTS=2026-07-28 MIX_ENV=test mix test test/conformance_fixture_test.exs --seed 0
MCP_REQUIREMENTS=2025-11-25 MIX_ENV=test mix test test/conformance_fixture_test.exs --seed 0
```

These are authenticated fixture preflights, not a substitute for the pinned
official conformance runner. They do not count disabled Tasks scenarios and do
not claim full conformance.

Use TLS at the deployment edge, pin `base_url`/`origin` when a reverse proxy
terminates TLS, and configure trusted proxy normalization before the Plug.

## Attesto and resource metadata

The `auth` options enter the approved `AttestoMCP.Plug.ProtectResource` boundary
before body decoding on every protected POST/GET/DELETE leg. Its prepared
dynamic authorization step receives the route/filter scope union after bounded
POST decoding; Attesto owns token, DPoP, mTLS, RFC 9728 challenges, and scope
algebra. Configure an
issuer/resource verifier, `resource: "/mcp"` (or a canonical resource
identifier), `resource_metadata_url` only when explicitly pinned, and DPoP
replay/nonce plus mTLS DER callbacks when used by the deployment. Hosts using
the explicit callback path can also provide a `:principal` callback for
principal availability and access-token revocation policy. The metadata
endpoint is public; protected POST/GET/DELETE traffic is not.

Static `:auth` options may select distinct, non-nil, non-boolean atom keys for
`:claims_key`, `:context_key`, `:principal_key`, `:scopes_key`, and
`:sender_key`, provided a custom key does not reuse a different package-owned
canonical key. These configured slots and their canonical aliases belong to
the authentication boundary: it clears them before verification and
repopulates them only from the verified result. Do not use those assign names
for unrelated upstream state.

For advanced runtime integration, `:auth` may be an external zero-arity
function or an MFA whose arguments are portable compile-time literals. The
resolver must return a keyword list. It may supply the canonical absolute
`:resource`/`:resource_audience` or `:base_url`/`:origin` after runtime
configuration has loaded. The value is validated on every applicable request:
its path must exactly match the mounted Plug path, paired resource and origin
values must agree, and only an `http` or `https` URL without user information,
query, or fragment is accepted. The same resolved identifier drives RFC 9728
metadata and token-audience verification. A static top-level pin remains
supported and cannot conflict with a resolver result. Runtime results cannot
replace the mounted resource path or canonical assign keys, and cannot enable
non-header bearer-token locations. Resolution failure produces a generic 500
response. `allow_dynamic_origin` remains only for explicitly local development;
do not derive a production audience from an untrusted request Host header.

The package requires `attesto_mcp >= 1.3.0 and < 2.0.0` and calls the public
`ProtectResource.prepare/1`, `authenticate/2`, and `authorize/3` contract
directly. There is no automatic fallback to an older authentication boundary.

Per-delivery subscription reauthorization requires an executable
`%Attesto.Config{}` through `auth: [config: ...]`. It re-verifies the captured
access token's validity, audience, sender binding, applicable scopes, and any
matched resource definition scopes before modern or session-bound
subscription-notification delivery.
Comparisons with the opening token actor, principal binding, and tenant preserve
the authenticated stream's ownership snapshot; they do not re-run host policy.
Host revocation, principal, and mount-authorization callbacks run when the
stream is authenticated, not inside shared publish processes; a later
host-policy change applies on the next request or reconnect. An `issuer:`
without a verifier configuration is
metadata-only: it may serve RFC 9728 metadata, but protected traffic fails
closed until the host supplies an executable Attesto configuration.

### Handler notifications and logging

The handler context contains `notify/1` for bounded server-originated
notifications. It returns `:ok` only when the request's response sink accepted
the notification, or `{:error, reason}` when the sink is unavailable, the event
is unsupported, the event is over the request queue limit, or policy filters it.
The event must be a JSON-safe JSON-RPC notification with no `id`, `result`, or
`error`; request methods such as `sampling/createMessage` are available only
through the capability-gated `client_request/2` callback. `context.progress/3`
is the corresponding progress helper and reports delivery failure rather than
claiming success without a sink.

An HTTP handler has a notification sink only when its request uses an SSE
response. Configure `stream_tools` or `stream_all_tools`, or supply a progress
token for a request that emits progress. A JSON response has no side channel,
so `notify/1` returns `{:error, :unsupported}` there. For modern
`notifications/message`, the server must also be started with
`capabilities: %{"logging" => %{}}` and the request must include a recognized
`_meta["io.modelcontextprotocol/logLevel"]`; otherwise logging is deliberately
suppressed.

Modern requests may include `_meta["io.modelcontextprotocol/logLevel"]` with a
recognized syslog severity. `notifications/message` is suppressed when that
metadata is absent and is delivered only at or above the requested threshold
on the owning response stream. Sessions for earlier revisions start with a conservative
no-log policy and `logging/setLevel` changes that threshold for that session
only. Logging notifications contain a recognized level, optional bounded
logger, and bounded JSON data; arbitrary protocol envelopes, secrets, and
client requests are rejected.

## Registration

Register tools, resources, URI templates, prompts, and completions before
serving traffic. Identity collisions return `{:error, {:duplicate, type,
identity}}`. Registration rejects unsafe names/URIs/templates, malformed
handlers, unsupported JSON Schema dialects/remote references, and schemas
outside the bounded local 2020-12/draft-07 subset. Anchors, local dynamic
references, tuple items, unevaluated items, and content annotations are
validated without network fetches. Registry output is stable
by identity and pagination cursors are opaque, signed, expiring, and bound to
the principal, tenant, scopes, visible catalog content, page size, and
negotiated era.

Resource templates use bounded reverse matching for an RFC 6570 subset. A
template may contain up to 16 separated named or reserved path expressions and
32 globally unique variables, including prefix modifiers such as `{id:3}`.
Adjacent path expressions remain rejected because their capture boundary is
ambiguous. A single query expression supports `{?q,limit}` and `{?keys*}`.
Values are strictly percent-decoded and bounded; simple variables reject raw or
encoded path separators, and every variable rejects traversal. Unsupported or
ambiguous operator layouts are rejected at registration rather than accepted
with nonfunctional matching. A matching `resources/read` handler receives both the
requested `uri` and a `params` map of captured variables. Completion handlers
should register an explicit `ref` matching the prompt or resource-template
reference; only that handler is invoked, and returned string values preserve
the handler's relevance order, are de-duplicated, and are capped at 100 with
truthful `total`/`hasMore` metadata.

Callback inputs are deliberately explicit and primitive-specific:

```elixir
alias AttestoMCP.Server.{Content, Result}

# Tool
handler: fn %{"left" => left, "right" => right}, context ->
  total = left + right

  {:ok,
   Result.tool_from_context(Content.text("total: #{total}"), context,
     structured_content: %{"total" => total}
   )}
end

# Prompt whose definition declares "topic" as required
handler: fn %{name: "review", arguments: %{"topic" => topic}}, _context ->
  {:ok, [Content.prompt_message(:user, Content.text(topic))]}
end

# Resource or resource template
handler: fn %{uri: uri, params: template_params}, _context ->
  {:ok,
   Result.resource(
     Content.resource_text(uri, inspect(template_params), mime_type: "text/plain")
   )}
end

# Completion
handler: fn %{value: value}, _context ->
  {:ok, [value]}
end
```

Declared outer envelope fields use atom keys. A resource MRTR retry also
places its string-keyed input-response entries at the envelope's top level.
Nested MCP arguments, references, and completion context retain their JSON
string keys. For optional prompt arguments, read the nested map with `Map.get/2`
instead of requiring the key in the callback head. An arity-2 callback's second
argument is the authenticated request context; a completion input's `:context`
is the separate client-supplied completion context. Arity-1 and MFA handler
forms are also accepted.

Tool handlers receive string-keyed arguments by default. Applications porting
handlers that already use atom keys may opt in at server startup:

```elixir
server_options = [
  tool_argument_keys: :atoms,
  output_canonicalization: :jason
]
```

`:atoms` is applied only after the original string-keyed input has passed its
registered JSON Schema. It converts literal keys found under `properties` only
when the corresponding atom already exists in the VM; no call creates an atom.
Undeclared keys and declared names without an existing atom remain strings.
The conversion follows nested literal `properties`, array `items`, and
`prefixItems`. Keys available only through references, combinators, or
conditional branches remain strings so ambiguous schema paths never broaden
the conversion. The default `tool_argument_keys: :strings` preserves the wire
map exactly.

Tool output content, prompt messages, and resource contents are checked before
they reach the wire. Supported content includes text, Base64 image/audio,
resource links, embedded resources, and structured tool output. Malformed
handler output is converted to a safe protocol failure or `isError` tool
result; business and upstream failures remain ordinary MCP error results.
`AttestoMCP.Server.Content` constructs individual content and prompt values;
`AttestoMCP.Server.Result.tool/1,2` and `resource/1,2` construct complete
results. Inside an arity-2 tool handler, prefer
`AttestoMCP.Server.Result.tool_from_context/2,3`. It inherits the supervised
server's JSON budget and output canonicalization settings, so shared adapters
do not have to repeat those options. Its inherited settings cannot be
overridden through that constructor; use standalone `Result.tool/2` for a
deliberate per-result override. The constructors emit canonical string-key
maps, apply the same bounded validation as the wire path, and reject unknown or
duplicate options. Image, audio, and blob arguments must already be canonical
padded Base64. Valid handwritten maps remain supported for extensions.

The server rechecks the complete result after adding `resultType`, cache
metadata, and server identity. A constructor value at the standalone ceiling
can therefore be refused when server-owned fields would make the final result
too large. Results for session-bound revisions receive the same final aggregate check.

Structured tool output is strict by default: non-boolean atom values and
structs are rejected, while atom map keys continue to canonicalize to strings.
`output_canonicalization: :json` opts into `JSON.Encoder`; `:jason` opts into
`Jason.Encoder`. In either mode, non-boolean atom values become strings and a
struct is encoded only through the selected protocol, decoded back to ordinary
JSON values, and then checked normally. Encoder input, encoded iodata, decoded
nodes, depth, and final JSON bytes all remain bounded by the server's configured
limits. Derive encoders with an explicit `:only` field list when a struct can
contain private application data.

Raw handler values automatically use the server setting. When constructing a
complete tool result inside the handler, use its context so the constructor
applies the same setting and byte budget:

```elixir
Result.tool_from_context(Content.text("loaded"), context,
  structured_content: record
)
```

`Result.tool/1,2` retain their standalone `:strict` and 2,000,000-byte defaults
for code that has no handler context.

If canonicalization fails, the client still receives only a generic failure. A
configured trusted `exception_reporter` additionally receives a bounded,
value-free diagnostic identifying the first JSON Pointer path and rejection
category, with safe value and encoder categories where applicable. When a
public result constructor detects the failure inside the handler, its
`ArgumentError` message carries the same bounded path and category. The
rejected value is never included in either report or Telemetry metadata.

`AttestoMCP.Server.Schema.validate/2` treats JSON Schema `default` as an
annotation and never changes the original request. A handler may explicitly
call `Schema.apply_property_defaults/2` for optional direct properties:

```elixir
schema = %{
  "type" => "object",
  "properties" => %{
    "format" => %{"type" => "string", "default" => "summary"}
  }
}

handler: fn arguments, context ->
  with {:ok, arguments} <- AttestoMCP.Server.Schema.apply_property_defaults(arguments, schema) do
    {:ok,
     AttestoMCP.Server.Result.tool_from_context(
       AttestoMCP.Server.Content.text(arguments["format"]),
       context
     )}
  end
end
```

The helper applies at most 500 defaults, never replaces a present value, and
validates the completed object. It follows only literal `properties`, recursing
into existing objects or an object supplied by an explicit property default;
it does not infer values through references, combinators, conditionals, array
items, or pattern properties. Dispatch never invokes it automatically, and a
required property must pass the registered input schema before the handler can
run.

For deliberately client-visible business failures, return:

```elixir
{:error, AttestoMCP.Server.Result.error("account is read-only", "account_read_only")}
```

The message and optional code are length-bounded and validated as UTF-8. Tool
calls receive an `isError` result, with a supplied code at
`_meta["io.attesto/errorCode"]` so it cannot violate a declared output
schema. Prompt and resource calls receive a JSON-RPC application error with
HTTP 200. Arbitrary terms, oversized strings, callback failures, and exceptions
remain generic.

HTTP hosts may derive application context after authentication:

```elixir
context_builder: fn conn ->
  %{request_id: Plug.Conn.get_req_header(conn, "x-request-id") |> List.first()}
end
```

The map is exposed only as `context.host_context`. Returning anything else or
raising prevents handler invocation.

### Mount authorization

Use the HTTP Plug's `authorize` option for one business-policy gate covering an
entire mount:

```elixir
forward "/mcp/admin", AttestoMCP.Server.Plug,
  server: MyApp.AdminMCP,
  path: "/mcp/admin",
  auth: {AttestoMCP.Server.Phoenix, :protected_resource_options, [:my_app]},
  principal_binding: {MyApp.MCPIdentity, :binding},
  authorize: {MyApp.MCPPolicy, :admin_mount?},
  resource: "/mcp/admin",
  base_url: "https://mcp.example.com"

defmodule MyApp.MCPPolicy do
  def admin_mount?(context), do: context.principal.role == :admin
end
```

The callback accepts a one-argument function, `{module, function}`, or
`{module, function, prefix_arguments}`; prefix arguments precede the context.
It receives the authenticated base context, including the complete principal,
stable principal binding, tenant, scopes, claims, sender information, and
`host_context` when a `context_builder` is configured. Only literal `true`
permits access. Every other return and every raise, throw, or exit produces the
same plain 403 response without a `WWW-Authenticate` challenge or policy
details.

This gate runs once on each authenticated POST, GET, and DELETE leg, before a
POST body is read and before protocol dispatch. Invalid credentials still stop
at authentication and never invoke it. Because the request body has not been
classified yet, the callback does not receive an MCP method or its arguments;
use `scope_map`, `scope_policy`, and per-definition authorization for those
decisions. When both `context_builder` and mount authorization are configured,
the built context is cached and reused for dispatch, so each callback runs only
once. Metadata discovery is public and does not run the mount policy.

For streams and subscriptions, this policy governs the authenticated opening
leg. Delivery reauthorization continues to check the captured binding, tenant,
sender, and scopes; a later business-policy change takes effect on the next
request or reconnect.

### Focused tool tests

Use `AttestoMCP.Server.Test.call_tool/4` for a per-tool test that still goes
through protocol dispatch. It checks the server's operation scopes, the
tool's scope clauses and `authorize` callback, its input schema, the handler,
its output schema, and final wire-output validation. The return value is the
complete JSON-RPC response map, so success and neutral denial/error results can
be asserted without constructing an internal request:

```elixir
response =
  AttestoMCP.Server.Test.call_tool(
    MyApp.MCP,
    "get_item",
    %{"id" => "item-7"},
    request_id: "get-item-test",
    principal: %{id: "user-7"},
    scopes: ["items.read"],
    host_context: %{account_id: "acct-1"}
  )

assert %{
         "id" => "get-item-test",
         "result" => %{
           "resultType" => "complete",
           "structuredContent" => %{"id" => "item-7"}
         }
       } = response
```

The helper JSON-encodes and decodes its request before dispatch, matching a
client's nested string keys before any configured tool-argument key policy.
It defaults to protocol revision `2026-07-28`, principal `"test-principal"`,
and no scopes; `:protocol_version`, `:client_capabilities`, and `:timeout` are
available for focused variants.

The principal, tenant, scopes, and host context options stand in for a request
that has already authenticated. This helper does not exercise token, DPoP,
mTLS, HTTP header, parser-order, or mount-policy checks. Keep Plug-level tests
for that boundary.

### Per-definition authorization

Every tool, resource, resource template, prompt, and completion definition may
include an `authorize` callback. It accepts any of these forms:

```elixir
authorize: fn context -> context.principal == "operator" end
authorize: {MyApp.MCPPolicy, :allowed?}
authorize: {MyApp.MCPPolicy, :allowed?, [:reports]}
```

The callback receives the authenticated base context from which the handler
context is built. Handlers additionally receive `primitive_type` and
`primitive_identity`; `authorize` does not, so encode definition-specific input
in the MFA prefix arguments when a shared policy module needs it. For the MFA
forms, the base context is appended after those prefix arguments. On HTTP, it
includes the package-owned principal, tenant, scopes, claims, and sender data;
when `context_builder` is configured, its result is available as
`context.host_context` too.

This callback controls all catalog results (`tools/list`, `resources/list`,
`resources/templates/list`, and `prompts/list`) and all definition lookups
(`tools/call`, `resources/read`, `prompts/get`, and
`completion/complete`). A literal `true` permits the definition. `false`, any
other return value, or a raise, throw, or exit denies it. Catalog methods omit
a denied definition. Lookup methods return the same method-specific unknown
result as an unregistered definition, including across modern and session-bound
protocol revisions, and never invoke its handler. Callback failures are
intentionally converted to denial and are not sent to `exception_reporter`.

For HTTP, authentication and the effective transport scope check occur before
protocol dispatch. Definition `required_scopes` are then checked before
`authorize`; if those scopes are missing, the callback is not invoked. For the
five methods explicitly mapped by an opt-in `scope_policy`, that policy also
has to permit the definition and runs before the local `required_scopes` and
`authorize` checks. Use `required_scopes` and `scope_policy` for grantable
Attesto scopes. Use `authorize` for host business rules that need the
authenticated context or `context.host_context`. When they are combined, every
applicable check must permit access.

`alternative_scope_sets` adds bounded alternatives to the primary all-of
`required_scopes` clause. Any one complete clause permits the definition; a
partial clause never does. For example:

```elixir
required_scopes: ["documents.read"],
alternative_scope_sets: [
  ["documents.admin"],
  ["workspace.read", "documents.execute"]
]
```

The primary clause must be non-empty when alternatives are present. Each
alternative is non-empty and duplicate-free, and clauses that differ only by
member order are duplicates. Registration accepts at most seven alternatives,
128 total scope memberships across all clauses, 8,192 aggregate scope bytes,
and 256 bytes per scope. Catalog filtering, selected lookups, templates,
subscription scope snapshots, and both protocol eras use the same clauses.
`authorize` is called once only after a clause succeeds. RFC 9728
`scopes_supported` remains host-configured, so advertise the meaningful narrow
scope clients should normally request rather than automatically exposing every
alternative.

Subscriptions are outside this callback contract. Establishment does not
consult a resource definition's `authorize`, and subscription-notification
delivery reauthorization checks the captured identity, sender binding,
applicable scopes, and any matched resource definition scopes rather than
re-running host business policy. Apply changed host policy on the next request
or reconnect, and do not rely on `authorize` to suppress subscription updates.

### Limits and scope policy

`max_concurrency`, `per_principal_concurrency`, `request_timeout`,
`max_request_timeout`, `max_queue`, `stream_keepalive_ms`, and
`stream_queue_size` are the bounded server limits. `subscription_queue_size`
may override `max_queue` for modern subscriptions; otherwise all stream and
subscription queues use `max_queue`. A Plug option overrides the corresponding
server option for that adapter. The server `scope_map` is the default policy;
an explicit Plug `scope_map` replaces it for HTTP, and the effective map is
used both by the prepared AttestoMCP authorization boundary and by protocol dispatch.
There is no second implicit scope source. Non-empty entries override method
defaults; absent or empty entries use `default_scopes` when configured and
otherwise retain the fail-closed HTTP defaults. For
`completion/complete`, one explicit method entry governs both prompt and
resource references; without it, each reference uses its category read scope.
The map accepts only the request methods implemented by this release:
`server/discover`, `initialize`, `ping`, `logging/setLevel`, `tools/list`,
`tools/call`, `resources/list`, `resources/templates/list`, `resources/read`,
`resources/subscribe`, `resources/unsubscribe`, `prompts/list`, `prompts/get`,
`completion/complete`, and `subscriptions/listen`. Notification names, task
methods, atom keys, and arbitrary extension methods are rejected. Each method
has at most 128 unique scopes, each scope is at most 256 bytes, and per-method
and aggregate byte limits are enforced during initialization.

`max_json_bytes` bounds JSON Schema instances, handler-result normalization,
final response validation, and JSON-RPC encoding. It defaults to 2,000,000
bytes and accepts explicit finite values from 512 through 64,000,000 bytes.
The minimum leaves room for a bounded protocol error.
`max_body_bytes` bounds the HTTP body and `max_message_bytes` bounds JSON-RPC
decoding (and the complete stdio frame). HTTP limits must be positive; the
stdio frame limit must be at least 512 bytes. None may exceed the supervised
server's `max_json_bytes` value. The nominal HTTP defaults
remain 2,000,000 body bytes and 1,000,000 message bytes; omitted values are
automatically capped by a smaller selected JSON budget. Explicit transport
limits above that budget fail before body reading. Configure all three together
when opting into a larger payload. The stdio adapter defaults to the smaller of
64,000 bytes and the supervised server's JSON budget unless
`max_message_bytes` is supplied explicitly.

`Result.tool_from_context/2,3` inherits the selected budget for the complete
tool-result envelope. Individual `Content` constructors validate before that
envelope is built, and `Result.resource/1,2` remains a standalone constructor;
pass `max_json_bytes: selected_budget` to either when the value itself exceeds
the secure 2,000,000-byte constructor default.

For hosts that issue definition scopes instead of generic method grants, add an
explicit Plug-only `scope_policy`:

```elixir
scope_policy: %{
  "tools/list" => :visible_definitions,
  "tools/call" => :selected_definition,
  "resources/list" => :visible_definitions,
  "resources/templates/list" => :visible_definitions,
  "resources/read" => :selected_definition
}
```

Visible-definition methods filter catalogs through each definition's required
scopes and authorization callback. Selected-definition methods resolve the
requested tool, exact static resource, or first matching URI template before
authorizing that definition through the prepared Attesto boundary; denial is
the normal neutral unknown result and cannot invoke a handler or consume an
MRTR retry state. The policy is opt-in and only supports the five methods
shown. Omitted policy retains generic method scopes, empty `scope_map` entries
retain their documented defaults, and a policy method cannot overlap
`scope_map` even with an empty list. An explicit Plug `scope_map` replaces the
server map; the effective map is checked again at request time for named or
restarted servers. A definition with `required_scopes: []` is authenticated-only
only on an explicitly policy-mapped method; defaults and empty-map methods keep
requiring their generic scope.

Subscriptions are deliberately outside this policy map. Modern
`subscriptions/listen` opening uses configured `default_scopes` instead of
generic category scopes when no non-empty method entry exists. A non-empty
`scope_map["subscriptions/listen"]` entry is additive to the generic category
scopes, and `subscription_scopes` are always additive. Modern delivery
reauthorizes the captured principal and tenant with that opening union plus its
notification requirements; resource updates also require the generic resource
scope and any matched definition scopes. Session-bound subscription-notification
delivery reauthorizes catalog events with their generic category scope;
resource-update notifications also require any matched definition scopes.
Resource subscriptions for session-bound revisions and modern resource filters per
subscription have fixed defensive bounds of 128 unique URIs and 4,096 bytes
per URI. Repeating an existing session-bound subscription is idempotent,
unsubscribing releases its entry, and modern filters preserve the first
occurrence of each URI. Invalid or over-limit session-bound changes do not refresh
the session idle deadline.

`rate_limits` is an optional map of bounded token buckets for `calls`,
`completion`, `subscriptions`, and `auth_failures`; each entry is
`%{burst: positive_integer, window_ms: positive_integer}`. Defaults are
600/60s, 300/60s, 100/60s, and 120/60s respectively. A category can be set to
`false` only when the host explicitly accepts unlimited traffic for that
category; malformed settings fail closed. Rejections use HTTP 429 and
JSON-RPC `-32029`, and are isolated by principal plus client address. If
`client_ip` is omitted, the Plug uses `conn.remote_ip` verbatim, including a
non-IP local-peer term. An explicit `client_ip` callback, configured as a
one-argument function or MFA, must return a trusted canonical IPv4 or IPv6
tuple derived from the proxy-aware connection. The callback is used for both
authenticated and failed-authentication buckets; invalid returns or callback
failures fail closed and emit neutral `client_ip/exception` telemetry. Do not
trust a raw client-supplied
`X-Forwarded-For` entry; use only connection state normalized by a correctly
configured trusted-proxy component.

### Atomic startup, telemetry, and durable sessions

The complete catalog is limited to 1,000 definitions across all primitive
types. `AttestoMCP.Server.register_all/2` validates at most 1,000 additions and
refuses any batch or repeated registration that would take the catalog above
that total; rejection leaves both the catalog and its revision unchanged. A
successful batch emits one catalog invalidation per affected category, while a
failed batch emits none. Supply the same tuples in the server's
`:registrations` option to make the complete catalog available before
`start_link/1` returns. Registry recovery enforces the same total. Named server
child specs use the registered name as the supervision ID, allowing multiple
independently named servers under one supervisor.

URI-template resolution also has one finite work allowance for the complete
candidate scan. Exhaustion is not treated as a missing or unscoped resource:
resource reads return a bounded internal `resource_match_limit` error and
resource-notification publication returns
`{:error, :template_match_budget_exhausted}` without delivery. Exact static
resources bypass template matching.

`AttestoMCP.Server.replace_catalog/2` validates one complete catalog of at most
1,000 tuples and then atomically replaces every primitive category, so
definitions omitted from the batch are removed. A failed replacement leaves
the prior definitions, revision, and notifications untouched. An identical
replacement is a no-op. A changed replacement advances the catalog revision
once and emits one list-changed notification for each affected advertised
catalog category. Resources and templates share one category; completion-only
changes emit none. Keep the host's generated or persisted catalog as the source
of truth; this API does not introduce a second catalog store.

`telemetry_metadata` is a map of at most 16 bounded scalar dimensions. Reserved
protocol keys cannot be replaced. Handler spans include the registered
primitive type and exact identity; unknown wire methods are reported as
`:unknown`. `handler_task_init` runs in the request worker before the handler,
and `exception_reporter` receives a trusted exception report without copying
private details into protocol responses or Telemetry. Function, `{Module,
:function}`, and `{Module, :function, prefix_args}` callback forms are
supported.

The default session store is package-owned in-memory state. The Phoenix
installer selects the bundled PostgreSQL adapter only when exactly one Repo is
statically confirmed as both supervised and PostgreSQL-backed. Manual
configuration may use the same stateless data handle in application config:

```elixir
store = %{
  repo: MyApp.Repo,
  namespace: "primary-mcp",
  schema_prefix: nil
}

server_options = [
  session_store: {AttestoMCP.Server.SessionStore.Ecto, store},
  session_namespace: "primary-mcp"
]
```

`AttestoMCP.Server.SessionStore.Ecto.new/1` validates and returns the same
handle when called from application startup code after the Repo module is
available. Do not call it while evaluating `config.exs`, before host modules
have been compiled.

Generate and apply `attesto_mcp_sessions` before starting the server:

```sh
mix attesto_mcp_server.gen.migration --repo MyApp.Repo
mix ecto.migrate
```

The adapter supports PostgreSQL and uses row locks for atomic updates. Its
required namespace is bound into the store handle, so key operations and
indexed listing/cleanup cannot cross server namespaces. Several named MCP
servers can therefore share one table without sharing sessions. It stores the
complete versioned record as JSONB, preserves unknown JSON-native fields with
binary object keys, validates indexed expiry mirrors before use, and uses those
mirrors for bounded listing and cleanup. Record-bearing listings return the
first eight active rows ordered by expiry and session ID; they are bounded
snapshots rather than a pagination API, and concurrent row locks may cause
`list_active` to omit otherwise active rows. Session counts use a separate SQL
aggregate. Cleanup trusts the indexed expiry column, selects only keys, and
claims at most 1,000 rows, so periodic passes drain larger backlogs without
loading their record payloads. Direct loads and record-bearing listings verify
the complete record against its expiry mirrors. Malformed rows detected there
fail closed and are removed under a row lock so one row cannot block later
work.

For operator tooling, `AttestoMCP.Server.active_session_ids/2` returns bounded,
cursor-based pages of active session IDs without loading or returning principals,
tenants, or session records:

```elixir
{:ok, %{session_ids: ids, next_cursor: cursor}} =
  AttestoMCP.Server.active_session_ids(MyApp.MCP, limit: 100)

next_page =
  if cursor do
    AttestoMCP.Server.active_session_ids(MyApp.MCP, cursor: cursor, limit: 100)
  end
```

The default page is 100 IDs and the maximum is 1,000. Pass the returned
`next_cursor` unchanged to continue; a `nil` cursor means the page is complete.
IDs are ordered lexicographically and are scoped to the server's configured
`session_namespace`. This is an operator visibility API, not a session-loading
or administration API: use the normal authenticated session operations when a
specific session must be inspected or closed. The method applies to the
session-bound revisions; the 2026 stateless transport has no server-side
session IDs to list.

Custom session-store adapters may implement the optional `list_active_keys/4`
callback from `AttestoMCP.Server.SessionStore` to support this view. It must
return only `{namespace, session_id}` keys and a cursor, never record payloads
or principal bindings. Adapters that do not implement it return
`{:error, :unsupported}`; malformed pages and adapter failures are converted to
the neutral `:session_store_unavailable` result.

Session expiry uses wall-clock timestamps while refreshes preserve monotonic
activity. Clock skew between nodes can therefore extend a session's effective
TTL; synchronize clocks across every node using the durable store.

Database operations fail closed. The adapter limits PostgreSQL row-lock waits
to one second, individual query calls to 1.5 seconds, and transactions to three
seconds so a stalled database returns a neutral store-unavailable result before
the server's call budget. Size the Repo pool for ordinary application demand
plus concurrent MCP requests, and monitor checkout pressure and
`session_store/failure` events. The host Repo must supply `ecto_sql` and
Postgrex; this package keeps only Ecto itself as an optional dependency so
ETS-only consumers do not inherit a SQL stack.

Adapter operations that require their own row-locking transaction must run
outside caller-owned `Repo.transaction/2` blocks. Those operations reject
nested use before opening another transaction or changing transaction-local
timeouts, returning `{:error, :nested_transaction_unsupported}`. Let the MCP
server own its short session-store transaction rather than wrapping it in an
application transaction.

The table contains serialized authenticated principal and tenant bindings.
Treat it as part of the authorization trust boundary: grant the application
role only the required table/schema privileges, prevent unrelated writers, and
apply normal encrypted-backup and database audit controls. Before moving a
custom store to Ecto, confirm every persisted record is JSON-native and every
map key is a UTF-8 string; atom-keyed or otherwise BEAM-specific records are
rejected rather than coerced.

Principal and tenant bindings may contain existing atoms. Safe restoration
never creates atoms from persisted data, so every node that must use an
atom-bearing binding needs those atoms loaded already. A node where an atom is
absent treats the binding as unavailable and leaves the durable record intact;
use binary or string identities when nodes do not share the same loaded atom
set.

Hosts needing another backend can implement
`AttestoMCP.Server.SessionStore` and configure:

```elixir
session_store: {MyApp.MCPSessions, store_handle},
session_namespace: "primary-mcp"
```

Records are bounded versioned maps produced by
`AttestoMCP.Server.Session.to_record/1`; adapters preserve unknown fields and
perform update/TTL/cleanup atomically. Principal and tenant bindings are opaque
BEAM terms with defensive limits: pids, ports, references, functions, bindings
deeper than 32 levels, bindings with more than 10,000 nodes, and encoded
bindings larger than 64 KiB are rejected. The server stops if a monitored store
process is lost; adapters with non-process handles fail closed when an operation
cannot reach their backend.

For multiple Erlang nodes, add `session_clustered: true` with a genuinely
shared adapter, explicit namespace, and one shared `cursor_secret` on every
server. The cursor secret must be a binary of at least 16 bytes; 32 bytes is
recommended. Startup rejects clustered session servers that omit it or use a
short value instead of silently generating a per-process secret. A
load-balanced multi-node deployment serving the session-free `2026-07-28`
transport must also configure the same explicit cursor secret on every node,
even when `session_clustered` is false, if cursors may cross nodes. Cursors bind
to final visible catalog content rather than node-local mutation history, so
peers may reach identical content through different registration histories when
the catalog and pagination context agree. Deterministic continuation assumes
all nodes use the same OTP major. Mixed-major rolling upgrades may invalidate
in-flight cursors, so clients should restart pagination across that boundary.
Requests
on any peer can load the same session, publishes fan out asynchronously once to
each live peer, and explicit session deletion or periodic expired-row cleanup
closes matching local streams on every reachable peer.

Peer catalog drift cannot reduce publisher-required scopes; drain mixed
old/new clusters rather than rely on them for resource notifications. Use a
globally unique namespace when unrelated deployments share the store or Erlang
cluster. Streams remain local processes and reopen after failover; event replay
and exactly-once delivery across a network partition are not promised.
Session-bound notification delivery reloads each live stream's session and rechecks
its authorization before enqueueing an event. Store latency and signature
verification cost are therefore part of the session-bound fanout path; size durable
backends for the expected number of concurrent session-bound streams.

Plug-only streaming selection is explicit and validated at
`AttestoMCP.Server.Plug.init/1`:
`stream_tools: ["tool_name"]` enables request-scoped SSE for those tool calls,
while `stream_all_tools: true` enables it for every tool call. Names must be
unique strings and the all-tools flag must be boolean; malformed values fail
at startup rather than during a request. These options are intended for hosts
whose tools produce progress or server notifications. Subscriptions and calls
with a caller progress token remain streaming regardless of this selection.

### Modern HTTP mirror headers

The session-free `2026-07-28` transport mirrors routing fields into bounded
HTTP headers and requires them to agree with the decoded JSON-RPC request.
Header names are case-insensitive, but each required header must occur exactly
once.

| Header | `2026-07-28` | `2025-11-25` and `2025-06-18` |
| --- | --- | --- |
| `Mcp-Protocol-Version` | Required on every POST and equal to `params._meta["io.modelcontextprotocol/protocolVersion"]`. | During initialization it may be omitted; when present, it must be an enabled session-bound revision. After negotiation the protocol requires it on POST, GET, and DELETE, and it must match the session revision. The server accepts omission only for backward compatibility. |
| `Mcp-Method` | Required on every POST and equal to the JSON-RPC `method`. | Not required. |
| `Mcp-Name` | Required for the selected values listed below and equal to the corresponding body value. | Not required by the mirror contract. |

`Mcp-Name` carries:

- `params.name` for `tools/call` and `prompts/get`;
- `params.uri` for `resources/read`; and
- `params.taskId` for `tasks/get`, `tasks/update`, and `tasks/cancel`. Tasks are
  hard-disabled in this release, but malformed task mirrors are still rejected
  before the method-not-found response.

Other methods omit `Mcp-Name`, including catalog-list methods,
`completion/complete`, and `subscriptions/listen`. Literal ASCII values can be
sent directly. A value needing a header-safe representation can use the strict
`=?base64?...?=` sentinel described under tool argument mirrors below.

A missing, duplicate, or mismatched required mirror returns HTTP 400 and the
same neutral JSON-RPC error; the response does not identify which mirror
failed:

~~~json
{
  "jsonrpc": "2.0",
  "id": 7,
  "error": {
    "code": -32020,
    "message": "Invalid MCP metadata or header",
    "data": {"reason": "body_header_mismatch"}
  }
}
~~~

The following complete `tools/call` request selects the `customer_lookup`
tool. Replace the URL and bearer token with values issued for the deployed
Attesto resource:

~~~sh
curl https://mcp.example.com/mcp \
  --request POST \
  --header "Authorization: Bearer $ACCESS_TOKEN" \
  --header "Content-Type: application/json" \
  --header "Accept: application/json, text/event-stream" \
  --header "Mcp-Protocol-Version: 2026-07-28" \
  --header "Mcp-Method: tools/call" \
  --header "Mcp-Name: customer_lookup" \
  --data '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {
      "name": "customer_lookup",
      "arguments": {"id": "cus_123"},
      "_meta": {
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities": {}
      }
    }
  }'
~~~

For `resources/read`, `Mcp-Name` mirrors the complete `params.uri` value:

~~~sh
curl https://mcp.example.com/mcp \
  --request POST \
  --header "Authorization: Bearer $ACCESS_TOKEN" \
  --header "Content-Type: application/json" \
  --header "Accept: application/json, text/event-stream" \
  --header "Mcp-Protocol-Version: 2026-07-28" \
  --header "Mcp-Method: resources/read" \
  --header "Mcp-Name: urn:customer:cus_123" \
  --data '{
    "jsonrpc": "2.0",
    "id": 2,
    "method": "resources/read",
    "params": {
      "uri": "urn:customer:cus_123",
      "_meta": {
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities": {}
      }
    }
  }'
~~~

### Tool argument mirror declarations

Modern tools/call mirror headers are declared by the registered tool's
input_schema property, never by request metadata. A property can require a
parameter header with the x-mcp-header annotation:

~~~elixir
input_schema: %{
  "type" => "object",
  "properties" => %{
    "account" => %{
      "type" => "string",
      "x-mcp-header" => "account"
    }
  }
}
~~~

The `x-mcp-header` value is a nonempty RFC 9110 `tchar` suffix; the server
constructs `Mcp-Param-{suffix}`. It is valid only on statically reachable
string, integer, or boolean properties. If the property is absent or null,
the client omits its header; otherwise exactly one header is required and its
decoded value must equal the nested `params.arguments` value. The normative
Base64 sentinel is `=?base64?SGVsbG8=?=`: padding and alphabet are strict, and
values missing either prefix or suffix are compared literally. Mixed-case
header names and RFC 9110 optional whitespace are handled safely. `Mcp-Name`
mirrors the tool name, while task methods mirror `params.taskId`.

### Modern subscriptions and interactive requests

`subscriptions/listen` accepts a non-empty `notifications` object containing
the category flags `toolsListChanged`, `promptsListChanged`,
`resourcesListChanged`, and/or a `resourceSubscriptions` URI list. The listen
request ID is the subscription ID. The stream begins with
`notifications/subscriptions/acknowledged`; each later notification keeps its
actual MCP method and carries the ID under
`params._meta["io.modelcontextprotocol/subscriptionId"]`. Delivery is bounded,
filtered, and reauthorized for the subscription owner. Protected HTTP opens
require configured `default_scopes` plus additive `subscription_scopes` when no
non-empty method entry exists. Without host defaults, the requested generic
category scopes are used instead. A non-empty
`scope_map["subscriptions/listen"]` entry requires the requested generic
category scopes plus the method entry and `subscription_scopes`. Modern
delivery rechecks that opening union plus its notification requirements;
resource updates also require `resources_read` and any matched definition
scopes.

Modern tool, resource, and prompt handlers may return `{:input_required,
requests}` where `requests` is a map of unique server keys to real
`elicitation/create`, `sampling/createMessage`, or `roots/list` request
objects. The server emits a map of server-assigned `input_N` keys and an integrity-protected requestState;
retry with a new JSON-RPC ID and matching typed `inputResponses`: elicitation
responses use `action` (and accepted `content`), sampling responses use
`role`, `content`, `model`, and `stopReason`, and roots responses use a
`roots` array.

## Era separation

The JSON-RPC decoder rejects batches, invalid UTF-8, fractional/null IDs,
oversized or over-deep messages, and malformed response objects. Duplicate
JSON member names are outside this package's accepted protocol contract; the
decoder delegates their handling to Jason and does not promise an ordering
policy. Producers must not send duplicates; hosts requiring rejection should
reject those bytes before dispatch.

Modern requests carry `_meta.io.modelcontextprotocol/protocolVersion` and
`clientCapabilities` per request and use POST-only request-scoped responses.
`_meta` must be a JSON object when present; non-object values return a
correlated protocol error without terminating the transport.
Host-published catalog notifications accept only `type` and optional object
`_meta`; resource-update notifications additionally require a valid `uri`.
Unknown fields and malformed metadata are rejected before either delivery
path.
The earlier, session-bound `2025-11-25` and `2025-06-18` revisions start with
`initialize`, then `notifications/initialized`, and may use an expiring principal-bound
`Mcp-Session-Id`. The server echoes and retains the exact accepted revision;
modern requests never use one of these sessions.

Session-bound GET is a standing incremental SSE stream with bounded keepalive and
session-owner delivery. DELETE closes the authenticated session and its
streams. Clustered mode coordinates live peers but does not replicate stream
processes or event history. Last-Event-ID resumption is not supported; a
Last-Event-ID GET is rejected rather than replayed.

Session-bound initialization advertises the server's `resources.subscribe` capability;
clients do not need to self-declare that server capability. After
`notifications/initialized`, negotiated `sampling`, `elicitation`, and `roots`
client capabilities permit corresponding server-originated requests on the
SSE/stdio route, with typed JSON-RPC responses correlated to the waiting
handler. During HTTP connection startup, a server-originated request waits for
the session's owned standing stream for at most one second or the configured
client-request timeout, whichever is shorter; it then fails closed as not
ready.

Hosts may provide `initialize_callback: fn context, params -> :ok end` to
reject session-bound initialization before negotiated state is committed. Callback
exceptions and arbitrary rejection terms are converted to a generic correlated
JSON-RPC internal error; no callback reason is sent to clients, and the Plug
endpoint remains available for later requests.

### Task profiles

The optional modern and session-bound task profiles are disabled in this release. No
task capability is advertised, modern `tasks/*` methods return
method-not-found, the `legacy_tasks` opt-in is ignored, and the supervised task
boundary fails closed. The `modern_tasks` and `legacy_tasks` options cannot
enable the incomplete in-memory implementation; a future release must provide
a durable store contract before advertising either profile.

## Telemetry

Events use the `[:attesto_mcp_server, ...]` prefix. Metadata is filtered to
protocol version, method, transport, status, duration, outcome, and opaque
correlation values. Request/auth/handler/stream/progress/subscription/task and
protocol error events are safe to attach to an application reporter. The
stable event contract is:

* `http_request` and `stdio`: `start`, `stop`, and `exception`.
* `request`, `handler`, and `stream`: `start`, `stop`, `exception`, with
  `timeout`, `open`, `close`, and `backpressure` where applicable.
* `auth/refusal`, `auth/policy_failure`, `protocol/error`, `cancellation/request`,
  `cancellation/stop`, and `progress/emit` or `progress/reject`.
* `principal_binding/exception` and `context_builder/exception`.
* `mrtr/round`, `subscription/open`, `subscription/close`,
  `subscription/suppressed`, and `subscription/backpressure`.
* `cache/choice`, `cache/invalidation`, `session/open`, `session/close`,
  `session_store/failure`, `session_store/cleanup/start`,
  `session_store/cleanup/stop`, `client_ip/exception`, and
  `supervision/restart`.

`auth/policy_failure` can report the `:mount_policy` category. A failed
`principal_binding` callback emits `principal_binding/exception`, and a failed
`context_builder` callback emits `context_builder/exception`; both remain
value-free and use the configured `exception_reporter` when applicable.

`auth/policy_failure` identifies the failing boundary only through a safe
`principal_policy`, `mount_policy`, or `verifier` category and an atom failure
kind; it never includes the callback reason, token claims, or principal.

`session_store/failure` identifies the failed operation only through its bounded
`source` atom. The outcome is `unavailable`, or `corrupt_discarded` when the
bundled Ecto adapter removes a structurally corrupt persisted row so later
bounded passes can continue. Adapter reasons, session identifiers, records, and
exception text are never included.

Each periodic expiry pass emits `session_store/cleanup/start` and
`session_store/cleanup/stop`. The stop measurement contains a non-negative
`duration` for the store cleanup call and its bounded return normalization,
failure reporting, and namespace filtering; it excludes start telemetry, local
stream closing, and a clustered close broadcast. It also reports the bounded
number of sessions reaped for this server's namespace in `count` (at most
1,000); metadata reports `outcome: :success` or `outcome: :unavailable`. A
custom adapter response over 1,000 keys, or an otherwise malformed response, is
rejected as unavailable without truncating or processing any returned keys.
Adapters must batch larger backlogs across later passes. A failed pass still emits
`session_store/failure`, and the cleanup implementation adds no keys, records,
principals, tenants, or adapter error details. Explicitly configured trusted
`telemetry_metadata` remains attached to these events.

Credential, proof, request-state, baggage, private content, and arbitrary
callback values are removed before Telemetry emission.

### W3C trace context

Request `_meta` may carry `traceparent`, `tracestate`, and `baggage`. The core
syntax-validates `traceparent`; `tracestate` and `baggage` are bounded opaque
forwarding values. Each field is limited to 4096 bytes and accepted values are
passed to handlers as `context.trace_context`. Baggage is available to the
handler only; it is never included in logs or Telemetry.

## Stdio interop

`elixir examples/stdio.exs` launches the line-delimited adapter with no
credentials embedded. During cold installation it temporarily assigns Mix's
group leader to standard error (and also uses `Mix.Shell.Quiet` with
`verbose: false`), then restores the protocol stdout before starting the
adapter. Compilation and dependency diagnostics therefore stay off stdout;
stdout
contains protocol frames only. The preferred modern 2026 flow uses discovery and
per-request `_meta` protocol-version/capability metadata; it does not send an
`initialize` request. The adapter also accepts the `2025-11-25` and
`2025-06-18` session-bound initialize/initialized flows on stdin, writes only compact
JSON-RPC messages to stdout, and exits on EOF. Its default bounded frame limit
is 64,000 bytes; larger limits must be explicit. A host may instead call
`AttestoMCP.Server.Stdio.run/2` with its own supervised server and context.
`AttestoMCP.Server.Stdio.main/1` accepts the adapter-only identity, input,
server-request, and EOF controls too; it removes those controls before starting
the owned server so core unknown-option validation stays strict. `run/2` returns
one of these startup error tuples: `{:error, :session_store_unavailable}`,
`{:error, :nonportable_binding}`, `{:error, :binding_too_large}`, or
`{:error, :record_too_large}`. `main/1` stops its owned server after the
adapter exits and raises for a startup failure so an executable wrapper cannot
silently report a successful exit.

## Protocol version compatibility

Only three frozen versions are accepted: `2026-07-28` for modern discovery and
per-request metadata, plus `2025-11-25` and `2025-06-18` for the negotiated,
session-bound lifecycle.

Hosts may narrow that set with the server `protocol_versions` option. It must
be a non-empty subset of those revisions. An HTTP session is bound to the
revision selected by `initialize`. Clients must send that revision in the
`Mcp-Protocol-Version` header on later POST, GET, and DELETE requests. For
backward compatibility, the server uses its authenticated session binding when
the header is absent; an invalid or changed value fails closed.

Modern discovery reports every revision the server supports. A client choosing
`2026-07-28` continues with per-request metadata. A client choosing either
earlier revision must open the dated `initialize`/`notifications/initialized`
flow; a modern metadata envelope cannot carry a session-bound revision.

Revision-specific output is filtered before it reaches the client.
`2025-06-18` catalogs and resource content omit the later `icons` field. That
revision cannot send an explicit elicitation `mode` or sampling
`tools`/`toolChoice` fields; form elicitation remains available by omitting
`mode`. A server-side attempt to use one of those later fields returns
`{:error, :unsupported}`.

For session-bound requests, handler context exposes the session's exact negotiated
revision as `context.protocol_version`. This is `2025-11-25` or `2025-06-18`,
not a generic marker, so handlers can make revision-aware decisions
without re-reading transport headers.
