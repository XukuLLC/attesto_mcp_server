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
- `0.10.2` patch-candidate source fingerprint:
  `791e7308119c10261a579896efdb5a2b43c1c8dea944d5426cb3ab681c7a46a5`
- `0.10.3` patch-candidate source fingerprint:
  `c39c0cd59444d08ed1d356d836b05490caf13ec9bc0c511a43523fc98a7878c4`
- `0.10.4` patch-candidate source fingerprint:
  `4e40ffedc43508c726dccf9d67008dec9768fc304b830bb845c9806a349a70bb`
- `0.11.0` release-candidate source fingerprint:
  `0538b3fe409f75b58c03cfb3901b940d849303300c93c71c1f4f2db2b456e4d7`
- `0.11.0` 2026 runner completed at: `2026-08-29T06:57:30Z`
- `0.11.0` 2025 runner completed at: `2026-08-29T06:57:32Z`
- 2026 runner completed at: `2026-08-27T10:04:29Z`
- 2025 runner completed at: `2026-08-27T10:04:31Z`
- TypeScript SDK smoke gates completed at: `2026-08-27T10:04:34Z`
- Python SDK smoke gates completed at: `2026-08-27T10:04:36Z`
- `0.10.1` hosted official-interop job completed at: `2026-08-27T15:40:48Z`
  in [run 33089002514](https://github.com/XukuLLC/attesto_mcp_server/actions/runs/33089002514)
- `0.10.2` hosted official-interop job completed at: `2026-08-27T17:55:41Z`
  in [run 33100777065](https://github.com/XukuLLC/attesto_mcp_server/actions/runs/33100777065)
- `0.10.3` hosted official-interop job completed at: `2026-08-28T14:30:51Z`
  in [run 33180401361](https://github.com/XukuLLC/attesto_mcp_server/actions/runs/33180401361)
- `0.10.4` hosted official-interop job completed at: `2026-08-28T16:29:34Z`
  in [run 33190111361](https://github.com/XukuLLC/attesto_mcp_server/actions/runs/33190111361)

The runner was built and invoked with the following commands. `RUNNER_DIR` and
`ARCHIVE` identify caller-owned locations outside the package so the record
does not embed a workstation path.

Each fingerprint covers the tracked `mix.exs`, `config`, `lib`, `examples`,
`scripts`, `test`, and reusable installer `fixtures` files in lexical order.
The table below was rerun against the exact `0.10.0` release candidate after
the Phoenix installer work; it is not inherited from the `0.9.0` run. The
`0.10.1` patch candidate adds regressions for request bodies decoded or passed
through by a host parser; its official runner and exact SDK client smokes were
repeated successfully by the hosted release gate linked above.
The `0.10.2` patch candidate clarifies primitive callback inputs and removes a
hard-coded default server version. Its hosted release gate passed all four jobs
at `2026-08-27T17:59:31Z` against implementation commit
`81a1f7cfa5c6fbf291c8c6cf155faabdf4048545`.
The `0.10.3` patch candidate hardens optional-installer dependency, route,
callback, and generated-module ownership preflight; normalizes atom cache-scope
options; keeps stdio adapter controls out of owned server startup; and exercises
combined installers in a fresh Phoenix 1.8.13 host against released
`attesto_mcp` 1.2.2 and `attesto_phoenix` 2.14.1. It also hardens completion
scope enforcement, metadata handling, notification publication, retained
request identifiers, and bounded legacy/modern resource subscriptions. Its
local aggregate gate passed 312 checks (one doctest plus 311 tests), 81.54%
coverage, zero-error/zero-skip Dialyzer, package construction, and the Hex
advisory audit. Hosted run 33180401361 passed all four jobs at
`2026-08-28T14:35:44Z` against implementation commit
`d6492bb8184702859bb0160343fd92de647fbdf8`.
The `0.10.4` patch candidate preserves Attesto's scheme-correct OAuth
challenges and error details for invalid DPoP proofs, sender-bound tokens
presented as Bearer, nonce requests, and insufficient scopes; keeps anonymous
discovery challenges error-free; and pins challenge metadata to the configured
canonical resource origin. Its hosted aggregate gate passed 312 checks (one
doctest plus 311 tests), 81.59% coverage, zero-error/zero-skip Dialyzer,
package construction, and the Hex advisory audit. Hosted run 33190111361
passed all four jobs at `2026-08-28T16:34:28Z` against implementation commit
`e7d19a02ad9b73ccdd19b9b7a583590bfa5fcf56`.
The `0.11.0` release candidate adds host callbacks, explicit client-visible
application errors, durable legacy-session storage, clustered publication,
subscription reauthorization, trusted telemetry metadata, and a conservative
Phoenix installer path. Its local aggregate gate passed 400 checks (one
doctest plus 399 tests), 82.21% coverage, zero-error/zero-skip Dialyzer,
package construction, and the Hex advisory audit. The full installer matrix
also passed against released dependencies, the pinned `attesto_phoenix` floor,
a freshly generated Phoenix 1.8.13 host, installer reruns, authenticated MCP
traffic, and the no-Igniter fallback. The frozen official runner was repeated
at the candidate fingerprint above with the same scored and raw totals shown
in the table.

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
recorded completion time. The package fixture wrapper inserts its own bearer
token into each client transport. These gates therefore validate authenticated
server protocol interoperability, not SDK OAuth discovery or token acquisition.

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
