# Changelog

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
