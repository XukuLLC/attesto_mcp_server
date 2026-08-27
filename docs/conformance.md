# Frozen conformance fixture

`examples/conformance_server.exs` is the package-owned authenticated Bandit
fixture used by the frozen official server runner and exact official client
smoke gates. It mints a short-lived credential only inside the development/test
fixture; the production authentication boundary is unchanged.

See the root [`CONFORMANCE.md`](../CONFORMANCE.md) for the exact runner version,
commit, archive digest, commands, observed scored and not-scored results,
expected-failure status, client versions, and non-certification statement.

The frozen runner has no scored `2025-06-18` requirement set. Compatibility
for that revision is therefore covered by package-owned HTTP, stdio, lifecycle,
revision-filtering, and configuration regressions rather than being presented
as an official conformance result.
