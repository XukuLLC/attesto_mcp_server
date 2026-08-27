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
- observation date: `2026-08-26`

The runner was built and invoked with the following commands. `RUNNER_DIR` and
`ARCHIVE` identify caller-owned locations outside the package so the record
does not embed a workstation path.

```sh
curl -fsSL \
  "https://github.com/modelcontextprotocol/conformance/archive/74edef34d674f563537be8c6587cebaa58e830ca.tar.gz" \
  -o "$ARCHIVE"
printf '%s  %s\n' \
  28d22ae3a4541a9a68c208e6a5653486bfacd97df45cf63cd8f0f7f9d5938293 \
  "$ARCHIVE" | sha256sum -c -
mkdir -p "$RUNNER_DIR"
tar -xzf "$ARCHIVE" -C "$RUNNER_DIR" --strip-components=1
npm ci --prefix "$RUNNER_DIR"
npm run build --prefix "$RUNNER_DIR"
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

Compatibility review found two intermittent legacy stream races. An early full
run routed a server-originated sampling request to a stale same-session stream;
that led to deterministic newest-live-stream routing. A later full rerun began
sampling and elicitation before the new connection's owned standing stream was
registered, producing 78 passed and 2 failed raw assertions even though both
scenarios passed in isolation. That led to a bounded stream-readiness wait and
a regression test. Ten consecutive complete 2025-11-25 runs then produced the
passing 80/0 result above. Neither failed run was hidden or converted to an
expected failure.

## Official client SDK smoke gates

The package-owned authenticated fixture was also exercised with exact released
official clients. Each gate negotiated the named era, listed tools, called
`test_simple_text`, validated its text response, and closed the connection.

| Client artifact | `2025-11-25` | `2026-07-28` |
| --- | --- | --- |
| `@modelcontextprotocol/client@2.0.0` | passed | passed |
| `mcp==2.1.1` | passed | passed |

The reproducible entrypoints are `scripts/client_smoke_ts.mjs`,
`scripts/client_smoke_python.py`, and `scripts/run_client_smoke_fixture.sh`.
The SDK packages and their build/download caches are installed outside the
package; they are not runtime dependencies or package contents.
