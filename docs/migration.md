# Migration runbook

This guide maps an existing MCP catalog and deployment onto
`AttestoMCP.Server`. It focuses on choices that affect compatibility,
authorization, and rollout safety. The [usage guide](usage.md) contains the
complete option reference.

## 1. Inventory the catalog

Represent each primitive as one registration tuple:

```elixir
registrations = [
  {:tool, "sum", tool_definition},
  {:resource, "urn:guide:index", static_resource_definition},
  {:template, "urn:guide:item/{id}", resource_template_definition},
  {:prompt, "review", prompt_definition},
  {:completion, "review", completion_definition}
]
```

The supported tuple types are `:tool`, `:resource`, `:template`, `:prompt`, and
`:completion`. Identities, definitions, handlers, schemas, URI templates, and
scope declarations are validated before registration. A batch contains at most
1,000 entries.

Prefer startup registration when the entire catalog is known during boot:

```elixir
children = [
  {AttestoMCP.Server,
   name: MyApp.MCP,
   registrations: registrations}
]
```

`start_link/1` returns only after the whole batch has been validated and
installed. `AttestoMCP.Server.API.register_all/2` provides the same atomic
validation for additions after startup. A duplicate or invalid entry rejects
the whole batch, leaves the previous catalog revision unchanged, and emits no
invalidation.

For a generated catalog, `AttestoMCP.Server.API.replace_catalog/2` atomically
makes one validated batch the complete catalog. Omitted definitions are
removed. An identical batch is a no-op; a changed batch advances the revision
once and emits one list-changed notification for each affected advertised
catalog category. Resources and templates share one category; completion-only
changes emit none. Keep the application's generated or persisted catalog as
the source of truth.

## 2. Adapt handler inputs and results

Handler input depends on the primitive:

| Primitive | Handler input |
| --- | --- |
| Tool | JSON arguments map |
| Prompt | `%{name: name, arguments: arguments}` |
| Resource or template | `%{uri: uri, params: template_params}` |
| Completion | `%{ref: ref, argument: argument, value: value, context: context}` |

The declared envelope fields use atom keys. Nested client-supplied MCP values
retain JSON string keys. Resource multi-round retries also add their
string-keyed response entries at the top level of the resource envelope.

Handlers may be arity-one functions, arity-two functions, or supported MFA
callbacks. The second function argument is the authenticated request context.
Use `{:ok, value}` for success and
`{:error, AttestoMCP.Server.Result.error(message, code)}` only for an error
deliberately approved for client disclosure. Modern tool, prompt, and resource
handlers may return `{:input_required, requests}` when multi-round input is
needed.

Use the public constructors for standard output:

```elixir
alias AttestoMCP.Server.{Content, Result}

tool_result =
  Result.tool(Content.text("saved"),
    structured_content: %{"id" => "item-7"}
  )

resource_result =
  Result.resource(
    Content.resource_text("urn:item:7", "contents", mime_type: "text/plain")
  )

prompt_messages = [
  Content.prompt_message(:user, Content.text("Review item 7"))
]
```

`Content` also constructs image, audio, resource-link, embedded-resource, and
blob content. Constructors emit canonical string-key maps and reject invalid,
unknown, or duplicate options. Image, audio, and blob arguments are already
encoded wire values and must be canonical padded Base64. Valid raw maps remain
supported when an extension member is needed.

## 3. Separate static resources from templates

Register a static resource when the client URI must equal one fixed URI.
Register a `:template` when the server needs to extract bounded variables from
the requested URI. The supported RFC 6570 subset includes named and reserved
path variables, prefix modifiers, and query variables in one expression. An
unsupported or ambiguous template is rejected during registration.

A static and a matching template may coexist. Exact static lookup wins; the
first matching template in deterministic identity order handles the remaining
URI. A template handler receives the original URI and its decoded `params`.
Keep completion registrations tied to an explicit prompt or resource-template
reference so only the intended completion handler can run.

## 4. Migrate schemas without implicit coercion

Tool input schemas and optional output schemas use the package's bounded local
JSON Schema 2020-12/draft-07 subset. Remote references are never fetched.
Validate representative schemas during the migration rather than waiting for
the first client request:

```elixir
:ok = AttestoMCP.Server.Schema.validate_schema(tool_schema)
```

JSON Schema `default` is an annotation. `Schema.validate/2` and normal server
dispatch validate the original value and never insert defaults. If a handler
explicitly wants defaults on optional direct properties, it may call:

```elixir
{:ok, arguments} =
  AttestoMCP.Server.Schema.apply_property_defaults(arguments, tool_schema)
```

The helper applies at most 500 defaults, preserves every present value, and
validates the completed object. It follows only literal `properties`, recursing
into existing objects or an object supplied by an explicit property default.
It does not infer values through references, combinators, conditionals, array
items, or pattern properties. Because the registered input schema is validated
before the handler runs, a missing required property still fails before the
handler can apply a default.

## 5. Translate authorization explicitly

Keep the layers distinct:

1. The HTTP boundary authenticates the token and sender constraint before
   reading the request body.
2. The effective transport `scope_map` or secure method default authorizes the
   MCP operation.
3. An opt-in HTTP `scope_policy` filters visible definitions or authorizes the
   selected tool/resource through the prepared Attesto boundary.
4. The definition's local scope clauses are checked.
5. Its `authorize` callback runs once after a scope clause succeeds.
6. Only then may the handler run or multi-round retry state be consumed.

Use `required_scopes` for the primary all-of clause. When a broader grant or a
different combination should also permit the definition, use bounded
alternatives:

```elixir
required_scopes: ["documents.read"],
alternative_scope_sets: [
  ["documents.admin"],
  ["workspace.read", "documents.execute"]
]
```

Any one complete clause permits access; partial clauses do not. Alternatives
require a non-empty primary clause. At most seven alternatives, 128 total
scope memberships, 8,192 aggregate scope bytes, and 256 bytes per scope are
accepted. The catalog, direct lookups, templates, subscriptions, and both
protocol eras agree on these clauses. Keep RFC 9728 `scopes_supported`
explicitly aligned with grants the authorization server issues; alternatives
do not rewrite the metadata document.

Use `authorize` for a host business rule that needs the authenticated context,
not to reproduce token verification or scope algebra. A literal `true` permits
the definition. Any other return, raise, throw, or exit denies it. Denied
definitions are omitted from catalogs and direct lookups return the same
neutral result as an unknown identity.

## 6. Preserve authenticate-before-body ordering

Mount the protected MCP Plug outside browser-session and CSRF pipelines. If a
Phoenix endpoint runs `Plug.Parsers` before routing, that parser would otherwise
consume the request body before MCP authentication. The installer can add an
exact-path `AttestoMCP.Server.PhoenixParser` bypass only when it can prove a
direct standard parser declaration. It refuses custom or ambiguous parser
setups without editing them.

For a manual integration, bypass the MCP path and its route-equivalent trailing
slashes before any host parser, or enforce an equally strict authenticated body
reader yourself. Keep every upstream body limit at least as strict as the MCP
Plug's `max_body_bytes`.

`max_body_bytes` limits the HTTP body; `max_message_bytes` limits JSON-RPC
decoding and the complete stdio frame. Neither may exceed
`AttestoMCP.Server.Schema.max_instance_bytes/0`, currently 2,000,000 bytes.
The HTTP defaults are 2,000,000 body bytes and 1,000,000 message bytes.

## 7. Choose one metadata owner

The protected-resource metadata endpoint is public; the MCP endpoint remains
protected. Normally the installer adds distinct metadata and MCP forwards. If
an existing AttestoPhoenix router already publishes exactly one matching
protected-resource metadata route, install with `--reuse-metadata-route`. The
installer preserves that route and adds only the MCP forward. Ambiguous,
dynamic, or mismatched routes are refused.

Configure `scopes_supported` on whichever component owns the metadata route.
For resolver-backed `:auth`, the callback may supply an absolute canonical
`:resource`/`:resource_audience` or `:base_url`/`:origin` after runtime
configuration loads. Its path and origin must agree exactly with the mount and
any static pin. The same resolved identifier is used for metadata and audience
verification. Resolver failures fail closed. Static pins remain supported;
`allow_dynamic_origin` is for explicitly local development only.

`base_url` and `origin` must be bare HTTP origins, such as
`https://mcp.example.com`, with no application path. Move the MCP path into the
Plug `:path` option. Version 0.12 rejects static path-bearing origin values
during Plug initialization and fails closed on resolver-returned values when a
request evaluates the resolver. Such values can make the advertised metadata
URL disagree with the route the host actually serves.

## 8. Plan session continuity separately from token continuity

OAuth tokens and MCP transport sessions have different lifecycles. This package
does not issue access or refresh tokens. A package upgrade does not inherently
require reauthentication: compatible existing tokens remain usable while the
issuer, client registration, canonical resource/audience, accepted scopes,
signing configuration, and revocation state remain compatible.

Modern `2026-07-28` requests are session-free. Legacy `2025-11-25` and
`2025-06-18` clients negotiate a server session. The default legacy store is
in-memory, so a server restart or deploy removes those sessions and clients
must initialize again. It does not invalidate their OAuth credentials.

When legacy sessions must survive a rolling deploy, implement
`AttestoMCP.Server.SessionStore`, configure a stable `session_namespace`, and
use the same durable backend on every eligible node. Enable
`session_clustered: true` only with that shared store. Streams are still
node-local and reconnect after node loss; cross-node delivery is asynchronous
and does not promise replay or exactly-once delivery during a partition.

## 9. Preserve neutral failures and canonical resource content

Do not expose arbitrary exception terms or upstream error bodies. Unexpected
handler failures become generic protocol errors. Use `Result.error/2` only for
bounded business text and a code that is safe for an untrusted client. A tool
receives an `isError` result; prompt and resource failures use a JSON-RPC
application error. Authentication and definition denials retain their neutral
responses so clients cannot distinguish a hidden definition from an unknown
one.

Each resource-content entry has a safe `uri` and exactly one of `text` or
canonical padded-Base64 `blob`; `mimeType` is optional. Prefer
`Content.resource_text/3` and `Content.resource_blob/3`, then wrap the entry in
`Result.resource/2` or `Content.embedded_resource/2` as appropriate. Keep
credentials, proofs, private diagnostics, and secrets out of content,
annotations, `_meta`, logs, and Telemetry.

Version 0.12 applies these content contracts strictly to handwritten handler
results. An embedded resource's `resource` member is one resource-content entry,
not a map containing a nested `contents` array. Do not include an explicit
`"blob" => nil` beside text or `"text" => nil` beside a blob. Omit optional
members instead of encoding them as null: when present, titles, descriptions,
and MIME types must be strings; `_meta` and `annotations` must be maps; `icons`
must be a valid list; and resource-link `size` must be a non-negative integer.
Replace affected handwritten values with `Content.embedded_resource/2`,
`Content.resource_text/3`, `Content.resource_blob/3`, or
`Content.resource_link/3` so invalid output is rejected at construction time.

## Rollout checklist

- Validate the complete registration batch before deployment.
- Exercise every handler with its primitive-specific input envelope.
- Test the primary and every alternative scope clause, plus partial-clause
  denial.
- Confirm `scopes_supported`, token audience, Plug path, and public origin use
  the same canonical resource.
- Verify authentication runs before every component that can read the MCP body.
- Decide whether legacy sessions may reset or require a durable store.
- Test one modern client flow and every legacy protocol revision kept enabled.
- Replace the catalog atomically, and verify removals, resource/template
  coalescing, and no list-changed notification for completion-only changes.
- Confirm client-visible failures and binary resource content use the public
  constructors.
