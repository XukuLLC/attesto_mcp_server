# Acceptance traceability

This ledger uses the exact requirement and test identifiers from the clean-room
baseline. `PASS` means the named observable evidence was run locally and is
complete for that row. `PARTIAL` means only a subset was observed. `NOT RUN`
means no evidence is claimed. `BASELINE DEVIATION` identifies an intentional
release addition that is separately specified and tested below. Full official conformance remains external
evidence; independent SDK smoke evidence is recorded only where explicitly
listed and is not treated as complete interoperability.

## Requirements

| ID | Baseline requirement | Status | Evidence |
| --- | --- | --- | --- |
| R01 | Package identity and license: publish as `:attesto_mcp_server`, license original code Apache-2.0, include `LICENSE`, metadata, source URL, changelog, security policy, and attribution/source ledger | PASS | public repository and hosted 0.8.0/0.9.0/0.10.0/0.10.1/0.10.2/0.10.3/0.10.4 releases, `mix.exs`, `LICENSE`, `CHANGELOG.md`, `SECURITY.md`, and package metadata |
| R02 | Dependencies and HTTP boundary: require compatible Attesto/AttestoMCP and Plug; use a normal Plug entry point; no production Bandit/web-server dependency; Bandit only in development/test/example scope | PASS | direct requirement `attesto_mcp ~> 1.2.1`, `mix.exs`, production dependency tree, auth tests, server-neutral Plug tests, and Bandit adapter tests |
| R03 | Complete server surface: public registration/handler contracts for tools, resources, templates, prompts, completion, notifications, MRTR and optional per-era tasks, with stdio and Streamable HTTP adapters and deterministic duplicate rejection | PARTIAL | API, registry, MRTR, subscription, stdio, and adapter tests; Tasks are deliberately unadvertised |
| R04 | Decode UTF-8 JSON-RPC 2.0 only; accept string or integer non-null IDs; reject batches; distinguish requests, notifications, responses, and malformed objects; validate selected dated schemas while preserving allowed extensions; default to JSON Schema 2020-12; never fetch network refs | PARTIAL | `lib/attesto_mcp_server/json_rpc.ex`, `lib/attesto_mcp_server/schema.ex`, parsed-body bounds, recoverable/detached binary-ID regressions, schema tests, and the pinned fixture's scored schema scenarios; broad message corpus remains partial |
| R05 | Support exactly 2026-07-28 and 2025-11-25 by default, selecting modern per request metadata and legacy from initialize without sharing negotiated state | BASELINE DEVIATION (C01) | Both baseline eras remain supported and pass their original evidence; C01 deliberately adds `2025-06-18` to the default set |
| R06 | Require modern protocolVersion/clientCapabilities metadata; implement discover; return exact unsupported-version/capability errors; include resultType and server identity metadata on modern successes | PASS | P0/P4/P10-P13 regressions plus pinned 2026 scored runner |
| R07 | Legacy lifecycle: initialize is first non-ping interaction, negotiate 2025-11-25, return server info/capabilities/instructions, wait for initialized before server traffic, and restrict negotiated capabilities | PARTIAL | 2025-11-25 core/Plug/stdio tests, detached-owner cancellation, newest-live same-session stream routing, stale teardown, and `test/p10_p13_regression_test.exs`; full stream matrix remains partial |
| R08 | Modern Streamable HTTP: one request/notification per POST, JSON/SSE Accept coverage, request-scoped SSE and empty 202 for notifications; modern GET/DELETE 405 and no sessions/resumption | PASS | modern Plug/Bandit tests, stream fixture, and pinned 2026 scored runner |
| R09 | Legacy Streamable HTTP: dated POST/GET, optional secure session IDs, 400/404 lifecycle, DELETE, multiple streams without duplicate delivery, and only advertised resumption | PARTIAL | legacy Plug/Bandit tests plus deterministic same-session isolation and stale-teardown regressions; resumption is not advertised |
| R10 | HTTP mirror headers: case-insensitive protocol/method/name/parameter declarations, exact Base64 sentinel, body/header equality, and official `x-mcp-header` constraints | PASS | `plug_auth_test.exs`, `p4_regression_test.exs`, and frozen HTTP scenarios |
| R11 | Stdio: one compact UTF-8 JSON-RPC message per stdout line, logs on stderr, interleaved IDs, modern cancellation, prompt EOF, and legacy server requests only after capability negotiation | PARTIAL | `stdio_test.exs`, 2025-06-18 initialize/list/call regression, cold-start/live-pipe tests including malformed/oversized frame recovery, and `Stdio.main/1` adapter-option isolation regression; broad client scripts remain partial |
| R12 | Fixed auth pipeline: every protected HTTP leg enters the approved Attesto boundary before dispatch/body work, with canonical assigns; stdio uses launcher/environment credentials | PASS | released `attesto_mcp` 1.2.1; direct public `ProtectResource.prepare/1`, `authenticate/2`, and `authorize/3` calls; boundary ordering, request-time AttestoPhoenix adapter resolution, canonical resolver-assign refusal, real-token audience binding, Phoenix-style parsed-body integration, and stdio tests; no older fallback |
| R13 | Resource metadata and audience: RFC 9728 metadata, authorization server, bearer header, resource_metadata challenges, and one pinned canonical resource/audience | PARTIAL | metadata and auth tests; deployment proxy matrix remains partial |
| R14 | Token and sender constraints: Authorization on every leg, no query/body tokens by default, issuer/audience/time/purpose/principal/scopes and DPoP/mTLS binding through Attesto | PARTIAL | `p3_auth_acceptance_test.exs` plus a live resolved-adapter DPoP success/replay regression in `plug_auth_resolver_test.exs`; full deployment matrix remains partial |
| R15 | Authorization policy: documented method scopes, operation plus configured subscription/task scopes, 401/403 challenges, and reauthorization for every handle/delivery | PARTIAL | subscription and auth tests; full sender/deployment matrix remains partial |
| R16 | Isolation and supervision: separately cancellable supervised work, correlated IDs, configurable global/principal limits, and handler crash isolation | PARTIAL | core, runtime, P5, atomic admission/ownership, nil-ID concurrency, detached-owner, same-session isolation, and exact-once terminal telemetry tests; broad stress remains partial |
| R17 | State boundaries: independently routable modern handles and principal/session-bound bounded legacy state | PARTIAL | cursor/request-state tests; clustered two-replica evidence not run |
| R18 | Cancellation and timeout: per-method soft/absolute limits, owner-only stream close/cancel, no post-cancel output, and prompt cleanup | PARTIAL | core, stdio, real Bandit disconnect, detached legacy cancellation, owner detachment, and exact-once counter/telemetry cleanup tests; full disconnect matrix remains partial |
| R19 | Error taxonomy: dated JSON-RPC/HTTP separation, reserved 2026 codes, modern 400/404/405 rules, and legacy dated resource errors | PARTIAL | P0/P7 tests, correlated non-object metadata errors with transport recovery, and pinned scored runner; broad malformed/error corpus remains partial |
| R20 | Tool execution errors: protocol errors for unknown/malformed calls, `isError` business results, and declared output-schema validation | PARTIAL | primitive matrix and core tests; full handler corpus remains partial |
| R21 | Server primitives: all tools/resources/templates/prompts/completion methods, dated content variants, pagination, completion cap, validation, and auth filtering | PARTIAL | P2A primitive tests and pinned diagnostic fixture/scenarios; full local matrix remains partial |
| R22 | Streaming/progress: JSON or SSE by need, valid final response, no-buffering header, keepalive, bounded queues, monotonic active-token progress, and cancellation stop | PARTIAL | Bandit and subscription tests; broad queue/flood matrix remains partial |
| R23 | MRTR: allowed methods, capability-filtered input requests, unique keys, new retry IDs, typed response validation, bound integrity state, expiry and single use | PARTIAL | `p1a_mrtr_test.exs`, core tests, and `test/p10_p13_regression_test.exs` |
| R24 | Subscriptions: explicit filters, first acknowledgment, owner request IDs/meta, concurrent isolation, close/cancel targeting, authorization recheck, and suppression | PARTIAL | state/HTTP subscription tests, 128-URI/4,096-byte legacy and modern bounds, retained-binary detachment, collision-free server ID allocation, malformed-event survival, no-touch rejection, and `test/p10_p13_regression_test.exs` |
| R25 | Legacy Tasks: disabled unless durable store/limits are configured; when enabled, advertise only negotiated dated task capabilities and implement full lifecycle | NOT ADVERTISED | Legacy Tasks are hard-disabled and unadvertised |
| R26 | Modern Tasks: disabled unless durable store/limits are configured; when enabled, only tools/call task results, auth-checked lifecycle, headers, notifications, TTL and MRTR separation | NOT ADVERTISED | Modern Tasks are hard-disabled and unadvertised |
| R27 | Deterministic lists/pagination: stable auth-visible order, opaque integrity/auth-bound cursors, fixed limits, and invalid/expired/cross-context rejection | PARTIAL | cache/cursor tests including catalog-bound cursor rejection; cluster and full mutation matrix remain partial |
| R28 | Cache semantics: nonnegative TTL/cache scope, no MRTR caching, private auth-varying defaults, safe public proof, stable page scopes, and invalidation notifications | PARTIAL | cache and subscription tests plus atom cache-scope normalization and facade pagination/cache-option coverage; broad cross-connection matrix remains partial |
| R29 | Security/resource controls: bounded inputs/output/schema/queues, rate limits, URI/origin safety, safe logs/telemetry, secure randomness, and fail-closed callbacks/config | PARTIAL | schema/resource, telemetry, P5, exact public-notification validation, direct Origin enforcement, four-way HTTP header-budget rejection, deferred resolver failure containment and portable-MFA validation, and bounded subscription tests; broad fuzz/stress remains partial |
| R30 | Observability/release gates: safe lifecycle telemetry, documented deployment/configuration/examples, and formatter/warnings/static/local/official gates | PARTIAL | lifecycle start/system-time and exact-once terminal telemetry tests; authenticated pinned runner for 0.10.0 (2026: 50 selected, 37 scored passed, raw 161/30; 2025: 33 selected, 30 scored passed, raw 80/0); exact TS 2.0.0/Python 2.1.1 clients pass both eras; 0.10.1 through 0.10.4 local and hosted release gates pass; the 0.10.5 local aggregate gate passes 325 checks at 81.85% coverage with zero-error/zero-skip Dialyzer, package build, and advisory audit; 9 not-scored Tasks failures and broad fuzz remain open |

## Release additions beyond the baseline

| ID | Additional compatibility requirement | Status | Evidence |
| --- | --- | --- | --- |
| C01 | Add negotiated `2025-06-18` compatibility without weakening preferred `2026-07-28` or baseline `2025-11-25` behavior | PASS | exact initialize echo; immutable HTTP/stdio session binding; revision-specific field filtering; positive `2025-11-25` controls; authenticated HTTP POST/GET/DELETE and stdio regressions |
| I01 | Provide an optional installer without adding Phoenix, an authorization server, or a web server to the runtime dependency graph | PASS | conditional Igniter task, dynamic `AttestoMCP.Server.Phoenix` helper, package metadata, optional-dependency-absent compile, and dependency inventory |
| I02 | Generate a supervised application-owned server, conservative config, and a starter registration test | PASS | in-memory host fixture assertions; exact generated ownership/auth-source recognition; rooted generated module references; and `scripts/check_installer_compat.sh` disk-backed host compile/test |
| I03 | Mount public RFC 9728 metadata before protected MCP at a pinned HTTPS origin and outside browser-session/CSRF pipelines | PASS | route-order assertions; forward arities 2–4; fully qualified generated and qualified/scoped existing routes; source-order chained/grouped aliases; dedicated-file lexical provenance; nested/aliased/dynamic/plug-reuse collision refusal; canonical ASCII raw-path enforcement; Phoenix 1.7 generated-MFA router compilation with deferred escape-safe Plug state; and usage documentation |
| I04 | Be safe to rerun and support both an existing `attesto_phoenix` host and an explicit Attesto callback | PASS | zero-diff in-memory and disk-backed second runs; literal dependency-catalog preflight, stable range intersection, and unsafe-option refusal; managed-source compile-hook/macro/nested-module fail-closed regressions; exact legacy and interrupted mixed-route migration with custom registration preservation, near-match refusal, and nested quoted-code preservation; automatic/callback fixture cases; real `attesto_phoenix` config derivation; and the exact Igniter 0.6.0 compatibility gate in `scripts/check_installer_compat.sh` |
| I05 | Configure a detected authorization-server host for URL client metadata and native loopback clients without weakening explicit host policy or changing callback-only installations | PASS | absent-key CIMD/localhost defaults; compatible Req insertion with dependency preflight; existing-policy preservation; callback-path negative assertions; exact post-primary `AttestoPhoenix.Router` integration with opaque-use negative controls; AttestoPhoenix 2.14 core configuration plus public protected-resource adapter derivation; rooted generated references; and actual Phoenix 1.8.13 `mix phx.new` combined-installer compatibility in `scripts/check_installer_compat.sh` |

## Local black-box matrix

| ID | Status | Evidence |
| --- | --- | --- |
| T01 | PASS | API tests and `examples/consumer` compile/run |
| T02 | PARTIAL | `test/conformance_fixture_test.exs`, `examples/conformance_server.exs`, `scripts/run_conformance_fixture.sh`, and the 0.10.4 hosted official-interop lane in run 33190111361 |
| T03 | PARTIAL | primitive matrix |
| T04 | PARTIAL | JSON-RPC and P4 tests |
| T05 | PASS | core discovery test and pinned 2026 fixture |
| T06 | PASS | P0 version test |
| T07 | PASS | P0/P4 metadata and capability tests |
| T08 | PASS | Plug auth/header tests |
| T09 | PARTIAL | Plug and stdio tests |
| T10 | PARTIAL | Bandit streaming test plus official progress/stream fixture scenarios; complete local matrix remains partial |
| T11 | PASS | modern method/session-header tests |
| T12 | PARTIAL | legacy lifecycle tests |
| T13 | PARTIAL | legacy session matrix |
| T14 | NOT ADVERTISED | Legacy resumption is not advertised |
| T15 | PARTIAL | stdio and cold-start tests, including adapter-option isolation from owned server startup |
| T16 | PASS | metadata/auth tests |
| T17 | PASS | Attesto context test |
| T18 | PARTIAL | token failure matrix |
| T19 | PASS | scope and subscription tests |
| T20 | PASS | DPoP tests, including request-time AttestoPhoenix adapter options and replay rejection |
| T21 | PASS | mTLS tests plus protected-resource adapter callback derivation |
| T22 | PARTIAL | runtime/core concurrency tests |
| T23 | PARTIAL | cancellation tests |
| T24 | PARTIAL | error taxonomy tests |
| T25 | PARTIAL | tool/content tests and official fixture diagnostics; full local matrix remains partial |
| T26 | PARTIAL | resource tests, `test/p15_uri_template_test.exs`, and official fixture resource diagnostics; static/template edge matrix remains partial |
| T27 | PARTIAL | prompt/completion tests and `test/p10_p13_regression_test.exs` |
| T28 | PARTIAL | bounded schema tests and pinned 2026 JSON-Schema scenarios; broad hostile matrix remains partial |
| T29 | PARTIAL | progress/telemetry tests |
| T30 | PASS | MRTR protocol tests and `test/p10_p13_regression_test.exs` |
| T31 | PARTIAL | MRTR binding tests |
| T32 | PASS | subscription acknowledgment/filter tests and `test/p10_p13_regression_test.exs` |
| T33 | PARTIAL | subscription auth/close tests |
| T34 | NOT ADVERTISED | Legacy Tasks disabled |
| T35 | NOT ADVERTISED | Legacy Tasks disabled |
| T36 | NOT ADVERTISED | Modern Tasks disabled |
| T37 | NOT ADVERTISED | Modern Tasks disabled |
| T38 | NOT ADVERTISED | Modern Tasks disabled |
| T39 | PARTIAL | cache/cursor tests plus atom cache-scope normalization and facade pagination/cache-option coverage |
| T40 | PARTIAL | local telemetry/hostile cases, pinned scored suites, and exact TS 2.0.0/Python 2.1.1 authenticated smoke gates in both eras; broad fuzz and the not-scored optional Tasks extension remain outside the passing surface |

## Compatibility and robustness ledger

| ID | Baseline definition | Status | Evidence |
| --- | --- | --- | --- |
| G01 | Progress has a live caller route and truthful delivery outcome | PARTIAL | core progress test; delivery acknowledgement remains limited |
| G02 | Every identified request, including unknown methods, terminates correlated | PARTIAL | core/Plug/stdio tests and real Bandit disconnect coverage; every-transport unknown-method matrix remains incomplete |
| G03 | Legacy later legs obey negotiated version headers | PASS | legacy Plug tests |
| G04 | Selected initialization revision governs later behavior | PARTIAL | legacy lifecycle tests |
| G05 | SSE survives split points and legal line endings | PARTIAL | split-point parser harness and real server stream tests; exhaustive byte-split server-output coverage remains open |
| G06 | Supervised sibling restart is ownership-safe under active work | PARTIAL | runtime restart tests; full stress not run |
| G07 | Replicated legacy sessions have one authoritative route | NOT RUN | Replication is not advertised |
| G08 | Standing streams deliver incrementally | PASS | legacy and modern Bandit tests |
| G09 | Server-originated traffic is owner isolated | PASS | subscription/legacy stream tests |
| G10 | Decode categories and recoverable IDs remain private | PARTIAL | JSON-RPC/P4 tests; full secret-marker fuzz not run |
| G11 | Every applicable legacy HTTP leg reauthenticates | PASS | legacy Plug/Bandit tests |
| G12 | Initialization/recovery rejection is correlated and encodable | PASS | legacy rejection tests |
| G13 | Initialized/request race does not cause avoidable failure | PASS | 100-schedule legacy race |
| G14 | Invalid session identifiers remain bounded | PARTIAL | bounded lookup tests; full flood not run |
| G15 | Every POST negotiates JSON and event-stream media | PASS | strict parser regressions plus modern request/notification and legacy initialize/request/notification HTTP tests |

## Observed gate

The current direct dependency constraint is `attesto_mcp ~> 1.2.1`. The fresh
local and public-package installer-host resolutions are released 1.2.2 within
that constraint.
The current-runtime Elixir 1.20.3/OTP 29.0.5 `mix test.all` gate for the 0.10.5
candidate passed 325 total checks (one doctest plus 324 tests), 81.85% coverage
at randomized seed 746440, zero-error/zero-skip Dialyzer, package unpack, and
Hex advisory audit. Its disk-backed installer gate also passed callback-only,
AttestoPhoenix 2.14.2, Phoenix 1.7.24 and 1.8.13, Igniter 0.6.0, idempotence,
and optional-dependency-absent hosts.
Full-suite order-randomized runs for the 0.10.0 candidate passed at seeds 1,
424242, and 99991; the 0.10.3 candidate independently passed full-suite runs at
seeds 424242 and 99991. The 0.10.2 hosted Elixir 1.18.3/OTP 27.3 floor passed its
244-check gate with 79.84% coverage, zero-error/zero-skip Dialyzer, package
unpack, and Hex advisory audit. Hosted verification is recorded below for
0.10.0 through 0.10.4.

The pinned runner `0.2.0-alpha.11` at commit
`74edef34d674f563537be8c6587cebaa58e830ca` selected
50 scenarios for 2026-07-28 (37 scored passed; raw 161 passed/30 failed, with
9 failing Tasks and both pending header scenarios passing) and 33 scenarios for
2025-11-25 (30 scored passed; raw 80 passed/0 failed in the candidate run).
No expected-failure baseline was used. Exact
TypeScript 2.0.0 and Python 2.1.1 clients passed authenticated list/call gates
in both eras. The 0.10.2 hosted source also passed formatting, documentation,
package, version-floor, optional-installer, and disk-backed host checks. The
0.10.3 candidate locally passed its 312-check aggregate gate and a
combined-installer run in a fresh Phoenix 1.8.13 application using the public
Hex dependency graph. Hosted
[run 33180401361](https://github.com/XukuLLC/attesto_mcp_server/actions/runs/33180401361)
passed all four jobs at `2026-08-28T14:35:44Z` against implementation commit
`d6492bb8184702859bb0160343fd92de647fbdf8`. The 0.10.4 patch preserves
scheme-correct OAuth challenges and error details for DPoP failures, nonce
requests, and insufficient scopes while keeping anonymous discovery
error-free and challenge metadata bound to the configured canonical resource.
Hosted
[run 33190111361](https://github.com/XukuLLC/attesto_mcp_server/actions/runs/33190111361)
passed all four jobs at `2026-08-28T16:34:28Z` against implementation commit
`e7d19a02ad9b73ccdd19b9b7a583590bfa5fcf56`; its aggregate gate passed 312
checks at 81.59% coverage with zero-error/zero-skip Dialyzer. The 0.10.1 patch
adds Phoenix-style parser-pipeline and pass-through parser regressions while
preserving encoded message-size and nesting bounds. Its independent read-only
review returned GO
at `2026-08-27T15:38:47Z`. Hosted
[run 33089002514](https://github.com/XukuLLC/attesto_mcp_server/actions/runs/33089002514)
passed all four jobs at `2026-08-27T15:45:09Z` against implementation commit
`33eb0e86ed9ca39ec90c73e70b5794d6d0659500`. The 0.10.2 patch clarifies
primitive callback inputs and derives its default server version from OTP
application metadata. Its local release gate passes, and an independent
read-only rereview returned GO at `2026-08-27T17:53:41Z`; hosted verification is
recorded by
[run 33100777065](https://github.com/XukuLLC/attesto_mcp_server/actions/runs/33100777065),
which passed all four jobs at `2026-08-27T17:59:31Z` against implementation
commit `81a1f7cfa5c6fbf291c8c6cf155faabdf4048545`. An independent read-only 0.10.0
release review returned GO at
`2026-08-27T10:23:42Z`. Hosted
[run 33062882020](https://github.com/XukuLLC/attesto_mcp_server/actions/runs/33062882020)
passed all four jobs at `2026-08-27T10:29:43Z` against implementation commit
`1944311232d82d776e958b8eae2a914e27e6e078`. For historical comparison, the
0.9.0 review returned GO at
`2026-08-27T07:36:25Z`, and hosted CI
[run 33050469173](https://github.com/XukuLLC/attesto_mcp_server/actions/runs/33050469173)
passed all three jobs at `2026-08-27T07:41:23Z` against implementation commit
`18bd7af2c1cca325b4011a8b8f13ad8fcf8452ab`; neither historical result is
claimed for 0.10.0.
