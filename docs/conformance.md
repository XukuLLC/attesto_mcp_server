# Frozen conformance fixture

`examples/conformance_server.exs` is the package-owned authenticated Bandit
fixture used by the frozen official server runner and exact official client
smoke gates. It mints a short-lived credential only inside the development/test
fixture; the production authentication boundary is unchanged.

See the root [`CONFORMANCE.md`](../CONFORMANCE.md) for the exact runner version,
commit, archive digest, commands, observed scored and not-scored results,
expected-failure status, client versions, and non-certification statement.

The root record covers the fingerprinted 2.3.0 release candidate.

`fixtures/oauth_host` separately exercises OAuth discovery, authorization code
and PKCE, client token acquisition, ID-token verification, and authenticated MCP
requests through the coordinated Attesto packages. Run it with
`scripts/run_oauth_fixture.sh`. Its in-process test transport does not establish
external TLS or an official authorization-server score.

The separate `scripts/run_authorization_conformance_fixture.sh` starts a local
HTTPS test host and runs the frozen source runner's unscored DPoP
authorization-server scenario. Its subprocess trusts only the generated
temporary certificate; the evidence records real discovery, PKCE, nonce retry,
and access-token binding checks.

The pinned official JSON Schema corpus is exercised by
`scripts/run_json_schema_suite.exs` with `formats: false`. Its exclusion manifest
records unavailable external references and dialects; format assertion policy
has separate package regressions.

The frozen runner has no scored `2025-06-18` requirement set. Compatibility
for that revision is therefore covered by package-owned HTTP, stdio, lifecycle,
revision-filtering, and configuration regressions rather than being presented
as an official conformance result.
