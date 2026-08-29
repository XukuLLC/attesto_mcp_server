# Security policy

HTTP traffic enters the approved `AttestoMCP.Plug.ProtectResource` boundary
before body decoding and protocol dispatch; its prepared dynamic authorization
API receives route-derived scopes. Configure a
pinned resource origin behind TLS-terminating proxies,
an Attesto issuer, sender constraints, replay/nonce checks, and least-privilege
scopes. Do not put credentials, proofs, request state, or private content in
logs or telemetry. Hosts using definition-scoped grants may explicitly set the
Plug `scope_policy` for the supported catalog and selected tool/resource
methods. Selected definitions are resolved before retry-state consumption and
authorized through the prepared boundary; denied and unknown definitions have
the same neutral protocol result. Omit this option to retain generic method
scopes, and never overlap it with `scope_map` (including an empty entry).
Subscriptions retain generic opening scopes and reauthorize generic plus
matched definition scopes at delivery. If a Phoenix endpoint parses bodies
before the router, install the exact-path parser bypass or enforce an equally
strict parser limit before relying on the Plug's authenticate-before-decode
guarantee. Definitions with empty required scopes are authenticated-only only
under explicit definition policy; defaults and empty map entries retain generic
scope checks. Report security issues privately to the maintainers.

Set `scopes_supported` per MCP mount when the authorization server issues
custom grants. Advertising generic package scopes for a custom-scope resource
can make discovery-driven clients request an unusable grant. When
AttestoPhoenix owns a reused metadata route, its protected-resource
configuration is authoritative.

An HTTP `context_builder` receives the authenticated connection and may return
application data for handlers. The returned map is available only at
`context.host_context`; it cannot replace authenticated identity, grants, or
Attesto assigns. A non-map return or callback failure stops dispatch and emits
only a generic client response. Use `AttestoMCP.Server.Result.error/2` only for
bounded failure text and codes intentionally safe to disclose.

External legacy-session adapters are part of the security boundary. They must
implement atomic update and expiry callbacks, preserve unknown record fields,
keep `{namespace, session_id}` as data rather than atoms, and enforce access
controls appropriate to their backend. Cluster mode requires a shared adapter
and explicit namespace. Stream processes are node-local and must reconnect
after failover; never treat a session identifier as authorization.
