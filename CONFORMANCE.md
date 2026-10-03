# Conformance evidence

This is reproducible test evidence for `attesto_mcp_server` 2.3.0. It does not
establish certification, endorsement, or support for every optional MCP extension.

## Tested candidate

- source fingerprint:
  `f187f0e0cbbdcc6726ec90efdb33c795c21d8eba97b7e217480377a662a0ae97`
- official runner source: package version `0.2.0-alpha.12`, including PR #396
- runner commit: `c37eec888e1c6ff140af79987a40008548b7cc5f`
- runner archive SHA-256:
  `a890632d5d8c2576652cfd1fdccb11b2595a2e635e3a335c14e1a224b175548b`
- MCP expected-failure files or exemptions: none

This source pin is distinct from the published npm alpha.12 artifact, whose
`gitHead` is `f44482ba17df816d3176962a11cdf36aec9bda00`. The pinned source
contains the authorization-server DPoP scenario added by
[PR #396](https://github.com/modelcontextprotocol/conformance/pull/396).
Authorization-server scenarios have no official scored requirements; the server
scores below do not include authorization-server tests. The separate DPoP
authorization-server scenario passed all three checks as recorded below.

The fingerprint covers the tracked `mix.exs`, `config`, `lib`, `examples`,
`scripts`, `test`, and `fixtures` files:

```sh
git ls-files -z mix.exs config lib examples scripts test fixtures |
  xargs -0 shasum -a 256 |
  shasum -a 256
```

## Official server runner

| Requirements | Selected | Scored | Not scored | Raw assertions | Result |
| --- | ---: | --- | --- | --- | --- |
| `2026-07-28` | 50 | 37/37 passed | 4 passed, 9 failed | 162 passed, 30 failed | exit 0 |
| `2025-11-25` | 33 | 30/30 passed | 3 passed, 0 failed | 80 passed, 0 failed | exit 0 |

The 30 raw failures belong to nine Tasks-extension scenarios that are unscored
under `--requirements 2026-07-28`. Tasks are disabled and are not advertised.
This exclusion is specific to that requirements set. The unscored JSON Schema
and HTTP-header scenarios passed. No Tasks failure was ignored in the legacy run.

Two modern SHOULD checks emit warnings because the frozen runner sends
`inputResponses` on the first call without obtaining or echoing request state.
This implementation requires bound state for retries. Package regressions
cover valid retries that ignore unknown keys and request missing answers again,
preserving earlier validated answers and the original expiry.

To reproduce the runner setup:

```sh
RUNNER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mcp-conformance.XXXXXX")"
ARCHIVE="$RUNNER_DIR.tar.gz"
curl -fsSL \
  "https://github.com/modelcontextprotocol/conformance/archive/c37eec888e1c6ff140af79987a40008548b7cc5f.tar.gz" \
  -o "$ARCHIVE"
printf '%s  %s\n' \
  a890632d5d8c2576652cfd1fdccb11b2595a2e635e3a335c14e1a224b175548b \
  "$ARCHIVE" | sha256sum -c -
mkdir -p "$RUNNER_DIR"
tar -xzf "$ARCHIVE" -C "$RUNNER_DIR" --strip-components=1
(
  cd "$RUNNER_DIR"
  npx --yes npm@12.0.2 ci
  npx --yes npm@12.0.2 run build
)
scripts/run_conformance_fixture.sh "$RUNNER_DIR" 2026-07-28
scripts/run_conformance_fixture.sh "$RUNNER_DIR" 2025-11-25
```

## Official client SDKs

The authenticated fixture negotiated each scored revision, listed tools, called
`test_simple_text`, validated the response, and closed the connection using
these exact released SDK versions:

| Client | `2025-11-25` | `2026-07-28` |
| --- | --- | --- |
| `@modelcontextprotocol/client@2.0.0` | passed | passed |
| `mcp==2.1.1` | passed | passed |

The entrypoints are `scripts/client_smoke_ts.mjs`,
`scripts/client_smoke_python.py`, and `scripts/run_client_smoke_fixture.sh`.
This fixture internally mints a token and therefore covers authenticated protocol
interoperability without establishing OAuth token acquisition.

## Coordinated OAuth fixture

`fixtures/oauth_host` uses source-linked Attesto, AttestoClient,
AttestoPhoenix, AttestoMCP, and AttestoMCP.Server. Its five tests exercise
discovery, authorization code and PKCE, token acquisition through the real
client, ID-token verification, and authenticated MCP requests across both
scored revisions. Negative cases include wrong resources, PKCE, code replay,
DPoP key binding, nonce retry, proof replay, `ath`, HTTP method, and target URI.

Run `scripts/run_oauth_fixture.sh` with sibling family checkouts, or set
`ATTESTO_SOURCE_PATH`, `ATTESTO_CLIENT_SOURCE_PATH`,
`ATTESTO_PHOENIX_SOURCE_PATH`, and `ATTESTO_MCP_SOURCE_PATH` explicitly.
The in-process Req transport preserves the client discovery checks but does
not establish external TLS or an official authorization-server score.

## Official authorization-server DPoP scenario

The pinned source runner's `authorization --scenario dpop` passed three checks
with zero failures, warnings, or skips: asymmetric algorithm metadata, exclusion
of `none`/HMAC algorithms, and actual `token_type: DPoP`/JWT `cnf.jkt` binding.
The request trace includes discovery, PKCE authorization, a `use_dpop_nonce`
challenge, and a successful token exchange using a fresh proof with that nonce.
These are unscored checks and do not alter either MCP server score.

```sh
scripts/run_authorization_conformance_fixture.sh \
  "$RUNNER_DIR/dist/index.js" /path/to/empty-evidence-directory
```

The fixture starts a test-only HTTPS listener and trusts its temporary
certificate only in the runner subprocess. It cleans up the certificate, key,
and settings afterward. Its fixed-client policy does not advertise CIMD, so
this DPoP scenario does not establish the separate CIMD metadata check.

## JSON Schema corpus


The pinned official JSON Schema Test Suite commit is
`5b0ee1613e45fcc2bddac00e07c19cd49b00d8a8`. Across 46 required draft2020-12
files, the adapter passes 1,252 cases, with 49 explicit exclusions and zero
mismatches or exceptions. The exclusions cover external references and
unavailable dialects; they are recorded in
`test/support/json_schema_suite_exclusions.json`. The runner rejects stale
exclusions so newly supported cases cannot silently remain omitted.

```sh
mix run scripts/run_json_schema_suite.exs /path/to/JSON-Schema-Test-Suite
```

The corpus selects `formats: false` annotation semantics. Direct validation
and server tool input/output retain format assertions by default in 2.x.
Internal elicitation URLs and form responses always assert their formats.

## Package gates

- All 736 checks passed, including the PostgreSQL-backed session and URL
  elicitation store tests.
- Dialyzer completed with zero errors and zero skips.
- Package construction, source/package hygiene, formatting, documentation,
  and the Hex advisory audit passed.
- The coordinated OAuth fixture passed all five tests.
- The complete PostgreSQL lane also passed on the declared Elixir 1.18.3/OTP
  27.3 floor, with 736 checks and zero failures.

The frozen runner does not score `2025-06-18`. Package-owned HTTP, stdio,
lifecycle, revision-filtering, and configuration regressions cover that
revision without presenting an official runner score for it.
