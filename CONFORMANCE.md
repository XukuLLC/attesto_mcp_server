# Conformance evidence

This file records reproducible evidence, not certification. The project does
not claim an MCP SDK tier, certification, endorsement, or complete coverage of
optional extensions.

## Frozen official server runner

The official `modelcontextprotocol/conformance` runner was frozen at:

- runner package: `@modelcontextprotocol/conformance` `0.2.0-alpha.11`
- commit: `74edef34d674f563537be8c6587cebaa58e830ca`
- commit archive SHA-256:
  `28d22ae3a4541a9a68c208e6a5653486bfacd97df45cf63cd8f0f7f9d5938293`
- evidence release: `0.10.0`
- evidence source fingerprint:
  `35b985a6d0ffdc7ab7a0dd75983c69ae89d35000620a6f70079a711a586c6e32`
- `0.10.1` patch-candidate source fingerprint:
  `442e5e16946eb90149bef41acc0461f18f7d4fdd682dd40b226c3a9814d29543`
- 2026 runner completed at: `2026-08-27T10:04:29Z`
- 2025 runner completed at: `2026-08-27T10:04:31Z`
- TypeScript SDK smoke gates completed at: `2026-08-27T10:04:34Z`
- Python SDK smoke gates completed at: `2026-08-27T10:04:36Z`

The runner was built and invoked with the following commands. `RUNNER_DIR` and
`ARCHIVE` identify caller-owned locations outside the package so the record
does not embed a workstation path.

Each fingerprint covers the tracked `mix.exs`, `config`, `lib`, `examples`,
`scripts`, `test`, and reusable installer `fixtures` files in lexical order.
The table below was rerun against the exact `0.10.0` release candidate after
the Phoenix installer work; it is not inherited from the `0.9.0` run. The
`0.10.1` patch candidate adds a local regression for request bodies decoded by
a host parser; its official runner is repeated by the hosted release gate.

```sh
git ls-files -z mix.exs config lib examples scripts test fixtures |
  xargs -0 shasum -a 256 |
  shasum -a 256
```

```sh
curl -fsSL \
  "https://github.com/modelcontextprotocol/conformance/archive/74edef34d674f563537be8c6587cebaa58e830ca.tar.gz" \
  -o "$ARCHIVE"
printf '%s  %s\n' \
  28d22ae3a4541a9a68c208e6a5653486bfacd97df45cf63cd8f0f7f9d5938293 \
  "$ARCHIVE" | sha256sum -c -
mkdir -p "$RUNNER_DIR"
tar -xzf "$ARCHIVE" -C "$RUNNER_DIR" --strip-components=1
npx --yes npm@11.6.1 ci --prefix "$RUNNER_DIR"
npx --yes npm@11.6.1 run build --prefix "$RUNNER_DIR"
scripts/run_conformance_fixture.sh "$RUNNER_DIR" 2026-07-28
scripts/run_conformance_fixture.sh "$RUNNER_DIR" 2025-11-25
```

No expected-failure file, flag, baseline, or exemption was supplied.

| Frozen requirements | Selected | Scored | Not scored | Raw assertions | Command result |
| --- | ---: | --- | --- | --- | --- |
| `2026-07-28` | 50 | 37/37 passed | 4 passed, 9 failed | 161 passed, 30 failed | exit 0 |
| `2025-11-25` | 33 | 30/30 passed | 3 passed, 0 failed | 80 passed, 0 failed | exit 0 |

All 30 raw failures in the 2026 run belong to nine not-scored Tasks-extension
scenarios. Tasks are hard-disabled and are not advertised by this release. The
not-scored JSON Schema and HTTP header scenarios passed. The 2025 not-scored
session lifecycle, JSON Schema, and SSE polling scenarios passed.

The following is historical `0.8.0` development context, not evidence for the
candidate rerun. Compatibility review found two intermittent legacy stream races. An early full
run routed a server-originated sampling request to a stale same-session stream;
that led to deterministic newest-live-stream routing. A later full rerun began
sampling and elicitation before the new connection's owned standing stream was
registered, producing 78 passed and 2 failed raw assertions even though both
scenarios passed in isolation. That led to a bounded stream-readiness wait and
a regression test. Ten consecutive complete 2025-11-25 runs in that historical
campaign then produced 80 passed and 0 failed assertions. The candidate table
is based on a separate rerun. Neither failed historical run was hidden or
converted to an expected failure.

## Official client SDK smoke gates

The package-owned authenticated fixture was also exercised with exact released
official clients. Each gate negotiated the named era, listed tools, called
`test_simple_text`, validated its text response, and closed the connection.
These four gates were rerun against the fingerprinted `0.10.0` candidate at the
recorded completion time.

| Client artifact | `2025-11-25` | `2026-07-28` |
| --- | --- | --- |
| `@modelcontextprotocol/client@2.0.0` | passed | passed |
| `mcp==2.1.1` | passed | passed |

The reproducible entrypoints are `scripts/client_smoke_ts.mjs`,
`scripts/client_smoke_python.py`, and `scripts/run_client_smoke_fixture.sh`.
The SDK packages and their build/download caches are installed outside the
package; they are not runtime dependencies or package contents.

## 2025-06-18 compatibility evidence

The frozen runner above does not score a `2025-06-18` requirement set, so this
project does not attach those conformance totals to that revision. Package
regressions instead exercise exact initialize version echo, initialized
lifecycle enforcement, tool listing/calling over stdio, and authenticated HTTP
session/header binding for `2025-06-18`. Product-client interoperability is
reported separately from official conformance evidence.
