# Changelog

## Unreleased

## 2.0.1 - 2026-09-02

- Bind automatic protected-resource callbacks to the named profile loaded from
  the helper's `otp_app` argument on `attesto_phoenix` 3.x, keeping multiple
  named profiles isolated. The helper does not select a profile from
  `conn.private`. The `attesto_phoenix` 2.14 compatibility path supports one
  globally configured profile; using it for multiple profiles can route
  persistent replay or revocation reads through that global profile's store.

## 2.0.0 - 2026-09-02

- Make `PhoenixParser` treat each configured path as a decoded segment prefix:
  the prefix, route-equivalent trailing or repeated slashes, and every child
  path bypass host body parsing before authentication. This includes ordinary
  routes below the configured prefix, so unrelated routes must not overlap it.
  Malformed, oversized, multipart, and otherwise unsupported child requests
  reach the authenticated MCP boundary without prior body parsing.
- Add a validated Plug `client_ip` callback for authenticated and
  failed-authentication rate-limit buckets. The default remains
  `conn.remote_ip` verbatim, including non-IP local-peer terms; explicit
  callback failures fail closed and emit neutral `client_ip/exception`
  telemetry.
- Require `session_clustered: true` servers to configure the same explicit,
  shared `cursor_secret` on every node; an omitted or shorter-than-16-byte
  secret now refuses startup instead of generating incompatible per-process
  cursor keys. Load-balanced multi-node deployments serving stateless
  `2026-07-28` requests must also configure the same explicit secret, even when
  `session_clustered` is false, if cursors may cross nodes. Pagination cursors
  now bind to deterministic visible catalog content rather than node-local
  mutation history, so peers on the same OTP major with the same final catalog,
  secret, and pagination context can continue them across nodes even when their
  registration histories differ. A mixed-OTP-major rolling upgrade may
  invalidate in-flight cursors, so clients should restart pagination when that
  boundary is crossed.
- Emit periodic session-cleanup start/stop telemetry with a bounded reaped
  count and neutral outcome. Custom session-store cleanup responses must be
  valid batches of at most 1,000 keys; oversized or malformed responses are
  rejected as unavailable rather than truncated. Cleanup duration covers the
  store cleanup call and its bounded return normalization, failure reporting,
  and namespace filtering, but excludes start telemetry, local stream closing,
  and clustered close broadcast.

## 1.1.0 - 2026-09-01

- Add `AttestoMCP.Server.Result.tool_from_context/2,3` so tool handlers and
  shared adapters inherit the supervised server's JSON budget and output
  canonicalization settings without repeating or overriding those options.
  The standalone result constructors and their secure defaults remain
  unchanged.

## 1.0.0 - 2026-09-01

- Establish the stable 1.0 host API while preserving the strict output and
  string-keyed argument defaults from 0.14.
- Add a bounded `principal_binding` callback so handlers can receive complete
  loaded principals while session ownership, subscription isolation, cursors,
  and accounting use a small stable identifier. Add a separate post-auth,
  pre-body Plug `authorize` gate for mount-wide policy with neutral 403
  denials.
- Let `AttestoMCP.Server.Phoenix.protected_resource_options/2` compose a
  post-load principal callback without replacing AttestoPhoenix JTI revocation
  checks or principal loading.
- Add explicit `:json` and `:jason` tool-output canonicalization modes for
  protocol-encoded structs and atom values, retaining bounded input, encoded,
  decoded, and final wire validation. Trusted exception reporters receive a
  value-free JSON Pointer diagnostic when canonicalization fails.
- Add opt-in schema-limited atom keys for tool arguments. Conversion happens
  only after input validation, uses existing atoms, and never creates atoms
  from schemas or client data.
- Add `AttestoMCP.Server.Test.call_tool/4` for focused host tests that exercise
  scopes, definition policy, schemas, handler execution, and complete wire
  results through normal dispatch.
- Support up to 32 exact MCP paths in `PhoenixParser` and document a complete
  multi-server Phoenix deployment with distinct durable-session namespaces.
- Add bounded, cursor-based active legacy session ID pages for operator
  tooling. Bundled ETS and Ecto stores expose IDs without loading records or
  principal bindings; Ecto uses deterministic bytewise ordering.
- Add a public migration guide for moving documented `anubis_mcp` component,
  response, context, scope, and schema APIs onto AttestoMCP registrations.

## 0.14.0 - 2026-09-01

- Add an optional PostgreSQL-backed Ecto session store for the session-bound
  `2025-11-25` and `2025-06-18` revisions. Composite, collision-resistant
  server namespaces,
  row-locked updates, indexed expiry, and bounded cleanup let sessions survive
  application restarts and remain safe across nodes sharing one database.
- Make the Phoenix installer select durable session storage automatically when
  it finds exactly one statically confirmed, supervised PostgreSQL host Repo.
  It preserves existing custom choices, leaves Repo-free hosts on ETS, and
  falls back to ETS with an actionable notice when a sole Repo cannot be proven
  supervised or its adapter cannot be proven. It also resolves literal aliases
  in application and config source, refuses unsupported explicit or ambiguous
  Repo choices, and supports explicit `--session-store`, `--repo`, and
  `--schema-prefix` choices.
- Add `mix attesto_mcp_server.gen.migration` for the fixed
  `attesto_mcp_sessions` table. Generation is explicit and duplicate-safe;
  neither the installer nor the generator runs a database migration. Default
  paths follow the selected Repo's child application in umbrella projects.
- Keep Ecto optional so non-Ecto and stdio consumers retain the existing
  dependency footprint and in-memory default.
- Emit a neutral `[:attesto_mcp_server, :session_store, :failure]` event for
  each failed session-store call, keep adapter error details private, and
  preserve one `:session_store_unavailable` result through server, HTTP, and
  stdio boundaries.
- Bound Ecto query, transaction, and PostgreSQL row-lock waits below the server
  call budget. Record-bearing listings use small batches, counts use a SQL
  aggregate, and cleanup loads only bounded keys. Direct loads and
  record-bearing listings discard detected corrupt rows under lock with
  bounded telemetry so one unusable row cannot wedge later work.
- Keep session activity timestamps monotonic under concurrent refreshes and
  constrain session timeouts to `1..9_000_000_000_000_000_000` milliseconds.
  Malformed external session identifiers behave like absent sessions. Invalid
  stored record versions are discarded atomically, while rolling upgrades
  preserve higher integer record versions and bindings that a node cannot
  decode without creating atoms. Conditional corruption cleanup rechecks the
  current record under the adapter lock before deletion.
- Reject Ecto adapter operations that require their own row-locking transaction
  when called inside a caller-owned Repo transaction, before changing
  transaction-local timeouts, returning an explicit unsupported nesting error
  without poisoning the host transaction.
- In clustered mode, propagate explicit session deletion and periodic
  expired-row cleanup to peer processes with versioned, namespace-bound,
  size-limited control messages so every node closes its local streams without
  rebroadcast loops.
- Make session-store outages detected before response streaming return HTTP 503
  consistently across JSON-RPC POST, session-bound notification, GET, and
  DELETE paths. Configured HTTP method-scope checks and core method
  authorization precede outage disclosure. `Stdio.main/1` now stops the server
  it owns on exit and raises when its initial durable session cannot be stored.
- Make HexDocs open on the installer-first README so the Phoenix SaaS path is
  the package's default documentation entry point.

## 0.13.0 - 2026-08-31

- Require `attesto_mcp >= 1.3.0 and < 2.0.0`, adding compatibility with the
  Attesto 2.x authorization contracts.
- Accept direct public-Hex `attesto_phoenix` requirements from the supported
  2.14.1 floor through the 3.x line, retaining fail-closed intersection and
  dependency-source validation.
- Refresh path-based `Mix.install/2` examples so an existing install cache
  cannot retain dependency versions from an earlier server release.

## 0.12.2 - 2026-08-30

- Reject `2026-07-28` request metadata paired with missing, duplicate, or
  mismatched HTTP mirror headers before session-bound routing, preserving one
  neutral `body_header_mismatch` response across methods and stale session IDs.
- Add a runnable Livebook walkthrough for an authenticated local server,
  including discovery, initialization, tool listing, and a tool call.
- Add regression coverage proving late-bound named-server transport limits use
  the active server JSON budget, including absent-server startup and server
  restarts above the secure 2 MB default.
- Make the real Bandit disconnect and stdio interleaving regressions
  independent of peer-request and EOF-drain timing on loaded test hosts.
- Document the complete modern mirror-header contract and streamline the
  README around the batteries-included Phoenix path, client onboarding, and a
  concrete non-Phoenix dependency setup.

## 0.12.1 - 2026-08-30

- Support bounded resource URI templates containing up to 16 separated simple
  or reserved path expressions and 32 globally unique variables. Reverse
  matching remains deterministic, rejects adjacent ambiguous expressions,
  encoded separators for simple variables, traversal, and oversized captures,
  and is shared by direct, batch, startup, and replacement registration paths.
- Bound URI-template work across the complete candidate scan for one resource
  lookup. Budget exhaustion is distinct from a non-match, fails closed for
  selected resource dispatch and notification scopes, and a local resource
  notification reuses one scope resolution for modern and legacy delivery.
- Limit the complete primitive catalog to 1,000 definitions across all types.
  Atomic batches and replacements, repeated additions, startup, and registry
  recovery enforce the same total without mutating the catalog or revision on
  rejection.
- Add the server-wide `max_json_bytes` budget. The secure default remains
  2,000,000 bytes; hosts may explicitly raise it to a finite maximum of
  64,000,000 bytes. The selected budget now governs JSON Schema instances,
  handler-result normalization, final result validation, JSON-RPC encoding,
  Streamable HTTP, and stdio. Transport limits may not exceed their supervised
  server's budget. Registered definition and schema data use that same budget
  during startup, dynamic registration, catalog replacement, and restoration.
- Cap omitted HTTP transport limits by the selected JSON budget, including
  budgets below the 2,000,000-byte nominal body default. Explicit limits above
  the selected budget still fail during initialization.
- Make invalid low-level JSON-RPC `max_bytes` options fail closed for decoding
  and ID recovery instead of relying on Erlang term ordering.
- Document the stdio adapter's 512-byte minimum frame limit alongside its
  server-budget ceiling.
- Clarify that `Schema.max_instance_bytes/0` denotes the secure default rather
  than the configurable ceiling, and that `nil` and `true` schemas remain
  subject to the active JSON budget.
- Allow the public content and result constructors to opt into the same larger
  finite budget with `max_json_bytes`, while retaining the 2,000,000-byte
  default and all structural and canonical-Base64 checks.

## 0.12.0 - 2026-08-29

- Add bounded `alternative_scope_sets` to primitive definitions. The primary
  `required_scopes` clause and each alternative remain all-of requirements,
  while any complete clause can authorize the definition consistently across
  catalogs, selected lookups, resource templates, subscriptions, and both
  protocol eras.
- Add typed, strict `AttestoMCP.Server.Content` constructors and complete tool
  and resource constructors in `AttestoMCP.Server.Result`. They emit canonical
  string-key maps and enforce the same content, URI, JSON, and padded-Base64
  rules as handler-output validation; handwritten maps remain supported.
- Revalidate every finalized success result after adding protocol, cache, and
  server-identity fields. Oversized completion values and aggregate catalog or
  handler results now fail closed with bounded protocol errors in both eras.
- Align handler-output validation with the MCP content contracts. Embedded
  resources now require one text or blob resource-content entry rather than a
  nested `contents` array. Present optional string, map, list, and size members
  must now have their declared types, so explicit null text/blob siblings,
  null MIME/description/metadata members, malformed link titles, negative link
  sizes, and invalid link/resource icons or annotations are rejected. Use the
  public content constructors when migrating affected handlers.
- Document that JSON Schema defaults are annotations, and add the bounded,
  explicitly invoked `AttestoMCP.Server.Schema.apply_property_defaults/2`
  helper for direct property defaults without changing dispatch behavior.
- Add atomic `replace_catalog/2` for bounded generated catalogs. Failed and
  no-op replacements leave the catalog revision unchanged; successful changes
  emit one list-changed notification for each affected advertised catalog
  category. Resources and templates share one category; completion-only
  changes emit none.
- Make the 2,000,000-byte schema-instance ceiling explicit across server,
  Streamable HTTP, and stdio configuration. Oversized `max_body_bytes` or
  `max_message_bytes` settings now fail during initialization, while the
  message limit continues to govern JSON-RPC decoding.
- Validate `scope_map` through one shared bounded policy: only supported MCP
  request methods are accepted, and scope lists must be unique, valid,
  length-bounded, and aggregate-byte-bounded in both server and Plug options.
- Allow resolver-backed `:auth` to supply a strictly validated canonical
  resource or base origin after runtime configuration loads. The resolved URL
  must agree with the mounted path and any static pin, and the same identifier
  drives RFC 9728 metadata and audience verification.
- Require static and resolved `:base_url`/`:origin` values to be bare HTTP
  origins without application paths. A static path-bearing value now fails
  during Plug initialization, and a resolver-returned value fails closed when
  the resolver is evaluated, instead of producing protected-resource metadata
  that disagrees with the served route.
- Add a migration runbook for registrations, handler contracts, schema
  behavior, authorization ordering, Phoenix wiring, session continuity, and
  safe result construction.
- Bind clustered resource-notification delivery to a versioned, bounded
  publisher scope snapshot and the recipient's current definition scopes.
  Legacy cluster resource envelopes without publisher scopes fail closed, so
  catalog drift during deployment cannot weaken modern or legacy delivery
  authorization. Per-publish authorization callbacks now suppress both modern
  and legacy delivery consistently.
- Clarify the distinct modern and legacy subscription scope rules, including
  additive `subscriptions/listen` and per-notification requirements.
- Add explicit `2025-06-18` HTTP, stdio, initialization, and revision-filtering
  regressions, and make live stdio tests wait for owned child processes before
  removing isolated build directories.

## 0.11.1 - 2026-08-29

- Document the existing per-definition `authorize` contract, including callback
  forms, host context, evaluation order, neutral denial behavior, and the
  subscription boundary; test function and MFA callbacks on both allow and
  deny paths.
- Refuse non-isolated or uninspectable Phoenix endpoint sources before editing,
  distinguish those failures from safe installer warnings, and make metadata
  route reuse diagnostics specific without relaxing preflight.
- Clarify host-owned custom-scope configuration and pin parser bypass behavior
  for route-equivalent repeated trailing slashes.

## 0.11.0 - 2026-08-28

- Add per-mount RFC 9728 `scopes_supported` configuration. Custom-scope
  deployments no longer have to advertise the package's generic scopes and
  cause clients to request grants the authorization server does not issue.
- Add isolated host context builders, bounded server-wide telemetry dimensions,
  exact primitive identity on handler spans, host exception reporting, and a
  handler-task initialization callback with function and MFA forms.
- Add explicit bounded client-safe handler failures with
  `AttestoMCP.Server.Result.error/2`; arbitrary failure terms and exceptions
  remain private.
- Add host-wide `default_scopes` with explicit method-map precedence and
  additive subscription delivery scopes.
- Add atomic bounded `register_all/2`, startup `:registrations`, coalesced
  catalog invalidations, exact registry recovery, and stable named child specs.
- Add a durable legacy-session adapter contract, versioned bounded records,
  fail-closed store monitoring, and an in-memory default adapter with bounded
  fair cleanup, including immediate cleanup bookkeeping removal on explicit
  deletion. Optional clustered session mode uses one explicit shared store and
  namespace and fans notifications out to live peers; process-backed streams
  reconnect after failover, and transient store reads do not mislabel live
  streams as expired.
- Add opt-in HTTP definition-scope policies for filtered tools/resource
  catalogs and selected tool/resource calls. Selected definitions are bound
  before MRTR retry-state consumption and authorized through the prepared
  Attesto boundary; hidden and denied definitions remain neutral, while the
  existing generic scope defaults and subscription generic-plus-definition
  reauthorization remain unchanged.
- Make AttestoPhoenix Client ID Metadata Documents an explicit installer opt-in;
  existing cache, repository, prefix, allowlist, and disabled settings remain
  authoritative, and Req is required only for that opt-in.
- Reuse only one statically proven published
  `attesto_routes(protected_resource_paths: [path])` metadata route for the
  selected MCP path, preserving it byte-for-byte and adding only MCP wiring.
- Preflight Phoenix endpoint parser provenance and add a literal static-route
  bypass, including route-equivalent trailing slashes, only for a direct
  standard `Plug.Parsers` declaration; custom or ambiguous body readers receive
  an actionable refusal.
- Require header-only bearer presentation for both static and resolved auth,
  require successful tools with `outputSchema` to return conforming structured
  content even under permissive schemas, reject ungrantable definition scopes,
  redact private server options from crash status, and ignore unrelated calls,
  casts, and mailbox messages without terminating the server.

## 0.10.6 - 2026-08-28

- Apply the automatic AttestoPhoenix access-token JTI revocation check and
  principal loader when authenticating each MCP request or stream, before
  request-body reads, returning a neutral invalid-token response when either
  rejects.
- Treat configured and canonical authentication assigns as boundary-owned:
  clear them before verification, repopulate them only from verified results,
  and reject non-atom, nil, boolean, duplicate, or cross-owned assign-key
  configurations at Plug initialization. Verifier exceptions also retain the
  cleared boundary.
- Emit a payload-free `[:attesto_mcp_server, :auth, :policy_failure]` telemetry
  event when the automatic Phoenix revocation check returns an invalid result
  or its revocation/principal callback or the HTTP verifier raises, throws, or
  exits.
- Fix modern and legacy DPoP- and mTLS-bound subscription delivery with loaded
  opaque principals, including static auth configurations that use custom
  assign keys. Delivery re-verifies the captured token and sender binding
  without running host policy callbacks in shared publish processes; later
  revocation or principal-policy changes take effect on the next request or
  stream reconnect.
- Require the oldest published compatible AttestoPhoenix release, 2.14.1,
  when the installer reuses its protected-resource policy.

## 0.10.5 - 2026-08-28

- Carry the host's current AttestoPhoenix protected-resource adapter options
  into generated MCP routes, including DPoP replay/nonce, canonical-request,
  and mTLS certificate callbacks, instead of retaining only the core verifier.
- Resolve automatic AttestoPhoenix authentication at request time while
  keeping the canonical resource and public origin statically pinned. Resolver
  failures fail closed; on protected MCP requests, unavailable servers,
  oversized headers, and unsupported methods are rejected before runtime
  configuration is requested.
- Add a constrained runtime auth resolver contract for external zero-arity
  callbacks and portable-literal MFA values. Generated routes remain safe for
  Phoenix compile-time Plug initialization and cannot replace package-owned
  assigns or advertise unsupported bearer-token locations.
- Migrate only exact legacy installer-owned AttestoPhoenix forwards, including
  interrupted mixed old/new installations, while preserving application tool
  registrations, refusing near matches, and leaving nested quoted examples
  untouched.

## 0.10.4 - 2026-08-28

- Preserve Attesto's scheme-correct OAuth challenges and error details for
  invalid DPoP proofs, sender-bound tokens presented as Bearer, nonce requests,
  and insufficient scopes instead of replacing them with a generic Bearer
  response.
- Keep anonymous discovery challenges error-free, pin challenge metadata to the
  configured canonical resource origin, and cover header and host-owned
  credential paths with DPoP regressions.

## 0.10.3 - 2026-08-28

- Configure detected `attesto_phoenix` hosts for URL client metadata and native
  loopback clients by enabling Client ID Metadata Documents and ephemeral
  `localhost` callback ports without replacing existing host choices.
- Add the compatible Req dependency required by the default secure CIMD
  fetcher only on the `attesto_phoenix` installer path; explicit Attesto
  callback installations remain dependency-neutral.
- Harden dependency preflight to inspect only literal catalogs, intersect
  stable Hex requirements with the supported `attesto_phoenix` and Req ranges,
  and stop without edits on dynamic, duplicate, incompatible, restricted,
  custom-source, or otherwise unsafe declarations.
- Harden route and ownership recognition across forward arities 2–4, qualified
  and effective scoped calls, source-ordered/chained/grouped aliases, dynamic
  plug refusal, Phoenix-router identity, exact generated callbacks, fully
  qualified generated routes, and rooted generated module references.
- Fail closed on executable managed-module attributes, compile hooks, custom
  macro enablement, enclosing-file compiler directives, unsafe nested modules,
  and non-canonical endpoint paths; installer and runtime paths now use only
  slash-separated ASCII URI-unreserved segments.
- Preserve compatibility with the exact zero-option `AttestoPhoenix.Router`
  integration emitted after a trusted primary Phoenix router use while keeping
  every other secondary router macro source opaque and requiring router modules
  to own their source file for lexical provenance.
- Normalize atom cache-scope options, expose pagination and cache controls
  through the stable facade type, and keep stdio-only controls out of owned
  server startup.
- Exercise the combined installers in both the reusable fixture and an actual
  Phoenix 1.8.13 `mix phx.new` application, including config construction,
  generated routes, warnings-as-errors compilation, starter tests,
  authorization-installer reruns, and a zero-diff second MCP installation.
- Harden subscription ownership and cleanup, contain non-exception Plug
  failures, serialize first-use cursor secrets, and exercise prompt retrieval
  through both dated HTTP fixture paths.
- Enforce prompt and resource completion scopes at the authenticated HTTP
  boundary, including one explicit method override for both reference types.
- Preserve evaluated array-item annotations when JSON Schema references are
  reached through applicators, avoiding false rejection by `unevaluatedItems`.
- Reject non-object request `_meta` values as correlated protocol errors while
  keeping both stdio and HTTP transports available for later requests.
- Bound each legacy session and each modern resource filter to 128 unique
  resource URIs at 4,096 bytes per URI, detach retained URI slices from request
  bodies, and canonicalize duplicates without extra entries.
- Route every supported resource-update alias through the same legacy URI
  filter and avoid extending idle lifetime for rejected subscription changes.
- Reject malformed public notification fields before modern or legacy fanout,
  and suppress malformed direct subscription events without terminating the
  registry or preventing a later valid delivery.
- Detach accepted binary JSON-RPC and modern subscription IDs from larger
  decoded request buffers before retaining them.
- Refuse installer edits when existing static, parameterized, glob, resource,
  or forwarded routes overlap either generated mount; reject required macro
  calls whose router effects cannot be proven and accept callback punctuation
  only as a terminal Elixir identifier suffix.
- Bind pagination cursors to their catalog method and skip explicit
  owner-local subscription IDs when allocating server-generated identifiers.
- Add direct regressions for HTTP Origin enforcement and header budgets, plus
  a live stdio pipe recovery check spanning malformed, oversized, and valid
  consecutive frames.

## 0.10.2 - 2026-08-27

- Document the distinct tool, prompt, resource, and completion callback inputs,
  including prompt and resource envelopes, their declared atom-keyed fields,
  and resource MRTR retry entries.
- Add copyable prompt callback guidance after a live-client interoperability
  exercise exposed the ambiguity in the earlier generic callback wording.
- Derive the default advertised server version from package application
  metadata so patch releases cannot retain a stale hard-coded version.

## 0.10.1 - 2026-08-27

- Accept JSON request bodies already decoded by a Phoenix or Plug parser while
  retaining message-size, nesting, JSON-RPC validation, and recoverable-ID
  checks.
- Add Phoenix-style parser-pipeline and pass-through parser regressions using a
  current legacy-initialize client request.

## 0.10.0 - 2026-08-27

- Add an optional, idempotent Igniter installer for Phoenix hosts.
- Scaffold a supervised MCP module, protected `/mcp` and RFC 9728 metadata
  routes, runtime configuration, and starter tests without inventing secrets or
  application authorization policy.
- Detect `attesto_phoenix` hosts and reuse their validated Attesto configuration
  while keeping authorization-server concerns out of this package.
- Use a generated application-owned metadata wrapper so Phoenix 1.7 can mount
  metadata and protocol routes as distinct forwarded plug modules.
- Refuse unsafe origins, ambiguous router/module collisions, and partial edits;
  compare existing routes across nested scopes and aliases, refuse dynamic
  forwards and Phoenix 1.7 plug reuse, and preserve a zero-diff second run
  across the supported Igniter range.

## 0.9.0 - 2026-08-26

- Accept and exactly echo MCP `2025-06-18` during legacy initialization while
  retaining `2025-11-25` and preferred `2026-07-28` behavior.
- Preserve the negotiated legacy revision in HTTP session state and enforce it
  on later protocol-version headers.
- Add stdio initialize/list/call coverage and authenticated HTTP lifecycle
  regression coverage for `2025-06-18`.
- Isolate the live stdio regression's installation cache so stale build state
  cannot contaminate protocol stdout startup.
- Use the negotiated session revision when a legacy HTTP client omits the
  protocol-version header, while rejecting invalid or changed header values.
- Gate catalog/content icons, explicit elicitation modes, and sampling tool
  selection to revisions that define those fields.
- Reject an initialize protocol-version header when its revision was disabled
  by the host's `protocol_versions` configuration.
- Expose the exact negotiated legacy revision as `context.protocol_version` to
  request handlers.

## 0.8.0

Initial Apache-2.0 release of the Attesto-native dual-era MCP server.

- Require released `attesto_mcp ~> 1.2` and use its public prepared resource
  protection contract without sibling-path or older-auth fallbacks.
- Preserve unknown JSON-RPC extensions and add precise recursive message types.
- Isolate same-session legacy streams, prefer the newest live stream for
  server-originated client requests, wait briefly for an owned stream during
  connection startup, and make stale teardown ownership-safe.
- Make cancellation, detached-owner cleanup, nil-ID work, correlation, and
  request terminal telemetry exact-once under races.
- Add frozen official conformance evidence and exact TypeScript 2.0.0 and
  Python 2.1.1 client smoke gates for both supported eras.
