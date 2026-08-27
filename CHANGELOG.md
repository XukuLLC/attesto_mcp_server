# Changelog

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
