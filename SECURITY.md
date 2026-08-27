# Security policy

HTTP traffic enters the approved `AttestoMCP.Plug.ProtectResource` boundary
before body decoding and protocol dispatch; its prepared dynamic authorization
API receives route-derived scopes. Configure a
pinned resource origin behind TLS-terminating proxies,
an Attesto issuer, sender constraints, replay/nonce checks, and least-privilege
scopes. Do not put credentials, proofs, request state, or private content in
logs or telemetry. Report security issues privately to the maintainers.
