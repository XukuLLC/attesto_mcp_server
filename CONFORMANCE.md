# Conformance evidence

This is reproducible test evidence for `attesto_mcp_server` 1.0.0, not a
certification, endorsement, or claim of support for every optional MCP
extension.

## Tested candidate

- source fingerprint:
  `ea84e03ed57d74e12fab61a82559b433d5858a9768a68b73dd736592be14e567`
- official runner: `@modelcontextprotocol/conformance` `0.2.0-alpha.11`
- runner commit: `74edef34d674f563537be8c6587cebaa58e830ca`
- runner archive SHA-256:
  `28d22ae3a4541a9a68c208e6a5653486bfacd97df45cf63cd8f0f7f9d5938293`
- expected-failure files or exemptions: none

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
| `2026-07-28` | 50 | 37/37 passed | 4 passed, 9 failed | 161 passed, 30 failed | exit 0 |
| `2025-11-25` | 33 | 30/30 passed | 3 passed, 0 failed | 80 passed, 0 failed | exit 0 |

The 30 raw failures belong to nine Tasks-extension scenarios that the runner
marks not scored. Tasks are disabled and are not advertised by this release.
The unscored JSON Schema and HTTP-header scenarios passed.

To reproduce the runner setup:

```sh
RUNNER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mcp-conformance.XXXXXX")"
ARCHIVE="$RUNNER_DIR.tar.gz"
curl -fsSL \
  "https://github.com/modelcontextprotocol/conformance/archive/74edef34d674f563537be8c6587cebaa58e830ca.tar.gz" \
  -o "$ARCHIVE"
printf '%s  %s\n' \
  28d22ae3a4541a9a68c208e6a5653486bfacd97df45cf63cd8f0f7f9d5938293 \
  "$ARCHIVE" | sha256sum -c -
mkdir -p "$RUNNER_DIR"
tar -xzf "$ARCHIVE" -C "$RUNNER_DIR" --strip-components=1
npx --yes npm@12.0.2 ci --prefix "$RUNNER_DIR"
npx --yes npm@12.0.2 run build --prefix "$RUNNER_DIR"
scripts/run_conformance_fixture.sh "$RUNNER_DIR" 2026-07-28
scripts/run_conformance_fixture.sh "$RUNNER_DIR" 2025-11-25
```

## Official client SDKs

The package fixture also negotiated each scored revision, listed tools, called
`test_simple_text`, validated the response, and closed the connection with the
exact released SDK versions below.

| Client | `2025-11-25` | `2026-07-28` |
| --- | --- | --- |
| `@modelcontextprotocol/client@2.0.0` | passed | passed |
| `mcp==2.1.1` | passed | passed |

The entrypoints are `scripts/client_smoke_ts.mjs`,
`scripts/client_smoke_python.py`, and `scripts/run_client_smoke_fixture.sh`.
They validate authenticated protocol interoperability, not OAuth discovery or
token acquisition.

## Package gates

- The default lane passed 628 checks: one doctest and 627 tests, with the 39
  database-gated tests skipped. Coverage for this default lane was 80.09%.
  A separate non-coverage PostgreSQL lane then passed all 39 durable Ecto
  session-store tests.
- Dialyzer completed with zero errors and zero skips.
- Package construction and the Hex advisory audit passed.
- The installer matrix passed with AttestoMCP 1.3.0 across Attesto 1.15.0 and
  2.0.0, AttestoPhoenix 2.14.1, 2.14.2, and 3.0.0, and a generated Phoenix
  1.8.13 host.

The frozen runner does not score `2025-06-18`. Package-owned HTTP, stdio,
lifecycle, revision-filtering, and configuration regressions cover that
revision without presenting an official runner score for it.
