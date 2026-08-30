# Security policy

HTTP traffic enters the approved `AttestoMCP.Plug.ProtectResource` boundary
before body decoding and protocol dispatch; its prepared dynamic authorization
API receives route-derived scopes. Configure a trusted static or
runtime-resolved resource origin behind TLS-terminating proxies,
an Attesto issuer, sender constraints, replay/nonce checks, and least-privilege
scopes. Do not put credentials, proofs, request state, or private content in
logs or telemetry. Hosts using definition-scoped grants may explicitly set the
Plug `scope_policy` for the supported catalog and selected tool/resource
methods. Selected definitions are resolved before retry-state consumption and
authorized through the prepared boundary; denied and unknown definitions have
the same neutral protocol result. Omit this option to retain generic method
scopes, and never overlap it with `scope_map` (including an empty entry).
Modern subscriptions use configured `default_scopes` instead of generic
category scopes when no non-empty `scope_map["subscriptions/listen"]` entry
exists. A non-empty method entry is additive to generic category scopes, and
`subscription_scopes` are always additive. Modern delivery rechecks that
opening union plus notification requirements; resource updates also require the
generic resource scope and any matched definition scopes. Legacy
subscription-notification delivery reauthorizes catalog events with their
generic category scope; resource-update notifications also require any matched
definition scopes. If a Phoenix endpoint parses bodies before the router,
install the exact-path parser bypass or enforce an equally strict parser limit
before relying on the Plug's authenticate-before-decode guarantee.
Definitions with empty required scopes are authenticated-only only under
explicit definition policy; defaults and empty map entries retain generic scope
checks. Report security issues privately to the maintainers.

`alternative_scope_sets` is an OR of complete all-of clauses, not a list of
independent scopes. Keep each alternative least-privilege and review broader
administrative clauses deliberately. The server applies the same bounded
clauses to catalogs, selected lookups, templates, subscriptions, and both
protocol eras, then runs a definition's `authorize` callback once after one
clause succeeds. Alternatives never weaken token validation, sender binding,
revocation, principal loading, or request reauthentication.

Set `scopes_supported` per MCP mount when the authorization server issues
custom grants. Advertising generic package scopes for a custom-scope resource
can make discovery-driven clients request an unusable grant. When
AttestoPhoenix owns a reused metadata route, its protected-resource
configuration is authoritative.

A resolver-backed `:auth` may provide its absolute canonical resource or base
origin at runtime. Treat that callback and its configuration source as part of
the security boundary. The server requires exact agreement with the mounted
path and any static resource/origin value, and uses the same resolved identifier
for metadata and audience verification. Do not use `allow_dynamic_origin` in
production or derive an audience from an untrusted Host header.

HTTP `max_body_bytes` and `max_message_bytes`, and stdio
`max_message_bytes`, cannot exceed the 2,000,000-byte schema-instance ceiling.
The message limit still governs JSON-RPC decoding. Keep an upstream parser's
limit at least as strict as the MCP Plug and preserve the
authenticate-before-body-read ordering.

Every successful result is bounded again after protocol, cache, and server
identity fields are added. This final check applies to modern and legacy
responses, including aggregate catalog pages and completion values; a result
that no longer fits is replaced with a bounded internal protocol error.

An HTTP `context_builder` receives the authenticated connection and may return
application data for handlers. The returned map is available only at
`context.host_context`; it cannot replace authenticated identity, grants, or
Attesto assigns. A non-map return or callback failure stops dispatch and emits
only a generic client response. Use `AttestoMCP.Server.Result.error/2` only for
bounded failure text and codes intentionally safe to disclose.

Content and result constructors validate protocol data; they do not decide
whether data is safe to disclose. Keep secrets and untrusted diagnostic detail
out of text, resources, annotations, and `_meta`. Binary constructors accept an
already encoded canonical padded-Base64 value, so hosts remain responsible for
content classification and media-type policy. JSON Schema defaults are never
inserted by dispatch. The opt-in property-default helper is bounded and
revalidates its result, but defaults remain host-authored input and must not
carry authority or bypass authorization checks.

External legacy-session adapters are part of the security boundary. They must
implement atomic update and expiry callbacks, preserve unknown record fields,
keep `{namespace, session_id}` as data rather than atoms, and enforce access
controls appropriate to their backend. Cluster mode requires a shared adapter
and explicit namespace. In 0.12.0, peer catalog drift cannot reduce
publisher-required scopes; drain mixed old/new clusters rather than rely on
them for resource notifications. Stream processes are node-local and must
reconnect after failover; never treat a session identifier as authorization.

`replace_catalog/2` atomically swaps the in-memory definition catalog, but the
host remains responsible for the trusted source of those definitions. Validate
that a generated replacement contains every intended authorization clause and
handler before applying it; omitted definitions are removed. Failed and no-op
replacements do not advance the revision or emit catalog invalidations.
