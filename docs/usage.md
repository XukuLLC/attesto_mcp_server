# Usage and deployment

## Phoenix installation

`attesto_mcp_server` owns the protected-resource protocol boundary. In a host
that also uses `attesto_phoenix`, the latter remains the authorization server:
it owns issuer, consent, token, refresh, revocation, and sender-constrained
credential behavior. The installer reuses both its validated core
`Attesto.Config` and its public protected-resource adapter for DPoP
replay/nonce, canonical-request, and mTLS certificate callbacks; it does not
duplicate or reconfigure those responsibilities. There is no hard dependency
from this package to `attesto_phoenix`.

With `attesto_phoenix` already declared directly by the host, run:

```sh
mix igniter.install attesto_mcp_server --base-url https://mcp.example.com
```

On this combined path the installer adds the compatible Req dependency and,
when the corresponding keys are absent, configures:

```elixir
config :my_app, AttestoPhoenix.Config,
  client_id_metadata: [enabled: true],
  native_apps: [loopback_include_localhost: true]
```

This supports clients that use an HTTPS Client ID Metadata Document and native
clients that register a portless `http://localhost/...` callback before binding
an ephemeral port. The default AttestoPhoenix fetcher retains its HTTPS,
DNS/IP, size, timeout, redirect, and cache validation. Deployments with a known
client set should add a narrow `:allowed_hosts` list. Existing configuration is
not replaced, and the installer does not enable dynamic registration or invent
client persistence.

This path supports direct public-Hex `attesto_phoenix` requirements that
overlap `>= 2.14.0 and < 3.0.0` and Req requirements that overlap
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
a starter registration test, and mounts these top-level router forwards in
order. The generated metadata wrapper keeps the two forwarded plug modules
distinct for Phoenix 1.7 compatibility. On the automatic AttestoPhoenix path,
the exact protected-resource options are resolved after the server, request
header budget, and HTTP method checks on every protected MCP request. Public
metadata requests resolve the same current options independently:

```elixir
Elixir.Phoenix.Router.forward(
  "/.well-known/oauth-protected-resource/mcp",
  Elixir.MyApp.MCP.MetadataPlug,
  server: Elixir.MyApp.MCP,
  path: "/mcp",
  auth: {Elixir.AttestoMCP.Server.Phoenix, :protected_resource_options, [:my_app]},
  resource: "/mcp",
  base_url: "https://mcp.example.com"
)

Elixir.Phoenix.Router.forward(
  "/mcp",
  Elixir.AttestoMCP.Server.Plug,
  server: Elixir.MyApp.MCP,
  path: "/mcp",
  auth: {Elixir.AttestoMCP.Server.Phoenix, :protected_resource_options, [:my_app]},
  resource: "/mcp",
  base_url: "https://mcp.example.com"
)
```

The explicit `--attesto-config` path instead keeps the static
`auth: [config: &Elixir.MyApp.MCP.attesto_config/0, resource: "/mcp",
base_url: "https://mcp.example.com"]` form. Such hosts remain responsible for
supplying every replay, nonce, canonical-request, and certificate callback
their sender-constraint policy needs.

Keep both forwards outside browser-session and CSRF pipelines. The metadata
route is intentionally public; the MCP route authenticates every protected
leg. If the endpoint parses JSON before the router, configure that parser's
body-length limit at least as strictly as the MCP Plug's `:max_body_bytes`;
host parsing necessarily occurs before MCP authentication. Run the task again
safely after an interrupted install: generated modules,
configuration, supervision, routes, and tests are idempotent. Use Igniter's
global `--dry-run` option to inspect the edits first. If the router cannot be
selected uniquely, pass `--router MyAppWeb.Router`; the task refuses ambiguous
router selection and prints an exact manual snippet if no router exists.

Additional options are `--mcp-path`, `--server-module`, `--router`, and
`--attesto-config`. Run the task inside the Phoenix child application rather
than at an umbrella root. The generated `server_status` tool is deliberately a
small starter; replace it with application-specific registrations and scopes.
`--mcp-path` must be a non-root ASCII path whose nonempty segments use only
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

## Bandit development server

The HTTP boundary is a normal Plug. A documented local launcher is:

```elixir
Mix.install([{:attesto_mcp_server, path: "."}, {:bandit, "~> 1.6"}], verbose: false)
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
replay/nonce plus mTLS DER callbacks when used by the deployment. The metadata
endpoint is public; protected POST/GET/DELETE traffic is not.

For advanced runtime integration, `:auth` may be an external zero-arity
function or an MFA whose arguments are portable compile-time literals. The
resolver must return a keyword list. Keep `:resource`/`:resource_audience` or
`:base_url`/`:origin` pinned in the Plug's top-level options; runtime results
cannot replace the mounted resource path or the boundary's canonical assign
keys, and cannot enable non-header bearer-token locations. Resolution is
deferred until an applicable request and failures return a generic 500
response.

The package requires `attesto_mcp ~> 1.2.1` and calls the public
`ProtectResource.prepare/1`, `authenticate/2`, and `authorize/3` contract
directly. There is no sibling-path or pre-1.2 authentication fallback.

Per-delivery subscription reauthorization requires an executable `%Attesto.Config{}`
through `auth: [config: ...]`. An `issuer:` without a verifier configuration is
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
on the owning response stream. Legacy sessions start with a conservative
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
the principal, tenant, scopes, visible catalog revision, page size, and
negotiated era.

Resource templates use bounded reverse matching for one RFC 6570 expression:
named path variables (`{id}`), reserved path variables (`{+path}`), prefix
modifiers (`{id:3}`), and query variables (`{?q,limit}` or `{?keys*}`) are
supported. Query values are strictly percent-decoded, bounded, and reject
ambiguous duplicates or decoded traversal. Unsupported multi-expression or
operator layouts are rejected at registration rather than accepted with
nonfunctional matching. A matching `resources/read` handler receives both the
requested `uri` and a `params` map of captured variables. Completion handlers
should register an explicit `ref` matching the prompt or resource-template
reference; only that handler is invoked, and returned string values preserve
the handler's relevance order, are de-duplicated, and are capped at 100 with
truthful `total`/`hasMore` metadata.

Callback inputs are deliberately explicit and primitive-specific:

```elixir
# Tool
handler: fn %{"left" => left, "right" => right}, _context ->
  {:ok, %{"total" => left + right}}
end

# Prompt whose definition declares "topic" as required
handler: fn %{name: "review", arguments: %{"topic" => topic}}, _context ->
  {:ok,
   [%{"role" => "user", "content" => %{"type" => "text", "text" => topic}}]}
end

# Resource or resource template
handler: fn %{uri: uri, params: template_params}, _context ->
  {:ok, [%{"uri" => uri, "text" => inspect(template_params)}]}
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

Tool output content, prompt messages, and resource contents are checked before
they reach the wire. Supported content includes text, Base64 image/audio,
resource links, embedded resources, and structured tool output. Malformed
handler output is converted to a safe protocol failure or `isError` tool
result; business and upstream failures remain ordinary MCP error results.

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
defaults; absent or empty entries retain the fail-closed HTTP defaults. For
`completion/complete`, one explicit method entry governs both prompt and
resource references; without it, each reference uses its category read scope.
Legacy resource subscriptions per session and modern resource filters per
subscription have fixed defensive bounds of 128 unique URIs and 4,096 bytes
per URI. Repeating an existing legacy subscription is idempotent,
unsubscribing releases its entry, and modern filters preserve the first
occurrence of each URI. Invalid or over-limit legacy changes do not refresh
the session idle deadline.

`rate_limits` is an optional map of bounded token buckets for `calls`,
`completion`, `subscriptions`, and `auth_failures`; each entry is
`%{burst: positive_integer, window_ms: positive_integer}`. Defaults are
600/60s, 300/60s, 100/60s, and 120/60s respectively. A category can be set to
`false` only when the host explicitly accepts unlimited traffic for that
category; malformed settings fail closed. Rejections use HTTP 429 and
JSON-RPC `-32029`, and are isolated by principal plus remote address.

Plug-only streaming selection is explicit and validated at
`AttestoMCP.Server.Plug.init/1`:
`stream_tools: ["tool_name"]` enables request-scoped SSE for those tool calls,
while `stream_all_tools: true` enables it for every tool call. Names must be
unique strings and the all-tools flag must be boolean; malformed values fail
at startup rather than during a request. These options are intended for hosts
whose tools produce progress or server notifications. Subscriptions and calls
with a caller progress token remain streaming regardless of this selection.

### HTTP mirror declarations

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
require the union of the configured subscription scope(s) and the category
scopes: `tools_read`, `prompts_read`, and/or `resources_read`; the same union is
checked again before each delivery.

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
Legacy `2025-11-25` and `2025-06-18` start with `initialize`, then
`notifications/initialized`, and may use an expiring principal-bound
`Mcp-Session-Id`. The server echoes and retains the exact accepted revision;
modern requests never use a legacy session.

Legacy GET is a standing incremental SSE stream with bounded keepalive and
session-owner delivery. DELETE closes the authenticated session and its
streams. This release does not advertise cross-process replication or
Last-Event-ID resumption; a Last-Event-ID GET is rejected rather than replayed.
Legacy initialization advertises the server's `resources.subscribe` capability;
clients do not need to self-declare that server capability. After
`notifications/initialized`, negotiated `sampling`, `elicitation`, and `roots`
client capabilities permit corresponding server-originated requests on the
SSE/stdio route, with typed JSON-RPC responses correlated to the waiting
handler. During HTTP connection startup, a server-originated request waits for
the session's owned standing stream for at most one second or the configured
client-request timeout, whichever is shorter; it then fails closed as not
ready.

Hosts may provide `initialize_callback: fn context, params -> :ok end` to
reject legacy initialization before negotiated state is committed. Callback
exceptions and arbitrary rejection terms are converted to a generic correlated
JSON-RPC internal error; no callback reason is sent to clients, and the Plug
endpoint remains available for later requests.

### Task profiles

The optional modern and legacy task profiles are disabled in this release. No
task capability is advertised, modern `tasks/*` methods return
method-not-found, legacy task opt-in is ignored, and the supervised task
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
* `auth/refusal`, `protocol/error`, `cancellation/request`,
  `cancellation/stop`, and `progress/emit` or `progress/reject`.
* `mrtr/round`, `subscription/open`, `subscription/close`,
  `subscription/suppressed`, and `subscription/backpressure`.
* `cache/choice`, `cache/invalidation`, `session/open`, `session/close`, and
  `supervision/restart`.

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
`2025-06-18` legacy initialize/initialized flows on stdin, writes only compact
JSON-RPC messages to stdout, and exits on EOF. Its default bounded frame limit
is 64,000 bytes; larger limits must be explicit. A host may instead call
`AttestoMCP.Server.Stdio.run/2` with its own supervised server and context.
`AttestoMCP.Server.Stdio.main/1` accepts the adapter-only identity, input,
server-request, and EOF controls too; it removes those controls before starting
the owned server so core unknown-option validation stays strict.

## Protocol version compatibility

Only three frozen versions are accepted: `2026-07-28` for modern discovery and
per-request metadata, plus `2025-11-25` and `2025-06-18` for the negotiated
legacy lifecycle.

Hosts may narrow that set with the server `protocol_versions` option. It must
be a non-empty subset of those revisions. A legacy HTTP session is bound to the
revision selected by `initialize`. Clients must send that revision in the
`Mcp-Protocol-Version` header on later POST, GET, and DELETE requests. For
backward compatibility, the server uses its authenticated session binding when
the header is absent; an invalid or changed value fails closed.

Modern discovery reports every revision the server supports. A client choosing
`2026-07-28` continues with per-request metadata. A client choosing either
legacy revision must open the dated `initialize`/`notifications/initialized`
flow; a modern metadata envelope cannot carry a legacy revision.

Revision-specific output is filtered before it reaches the client.
`2025-06-18` catalogs and resource content omit the later `icons` field. That
revision cannot send an explicit elicitation `mode` or sampling
`tools`/`toolChoice` fields; form elicitation remains available by omitting
`mode`. A server-side attempt to use one of those later fields returns
`{:error, :unsupported}`.

For legacy requests, handler context exposes the session's exact negotiated
revision as `context.protocol_version`. This is `2025-11-25` or `2025-06-18`,
not a generic legacy marker, so handlers can make revision-aware decisions
without re-reading transport headers.
