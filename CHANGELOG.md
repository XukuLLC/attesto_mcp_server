# Changelog

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
