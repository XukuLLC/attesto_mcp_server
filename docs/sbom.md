# Production dependency inventory (0.14.0)

This release evidence was observed locally on 2026-09-01 for 0.14.0 after
resolving the published Hex packages with `mix deps.get` and checking the graph
with `mix deps.tree --only prod`. This library does not maintain or ship a
project lockfile, so consumers resolve the declared version ranges.

| Component | Resolved version | License policy | Production path |
|---|---:|---|---|
| attesto_mcp | 1.3.0 | MIT | direct |
| attesto | 2.0.0 | MIT | attesto_mcp |
| jose | 1.11.12 | MIT | attesto_mcp; attesto |
| plug | 1.20.3 | Apache-2.0 | direct; attesto_mcp; attesto |
| jason | 1.4.5 | Apache-2.0 | direct |
| telemetry | 1.4.2 | Apache-2.0 | direct; attesto; plug |
| mime | 2.0.7 | Apache-2.0 | plug |
| plug_crypto | 2.2.0 | Apache-2.0 | plug |

All listed base-runtime components are MIT or Apache-2.0 compatible. Bandit,
Phoenix, ExDoc, and Dialyzer are development/test-only. Package tests and the
fresh generated host use Phoenix 1.8.13; reusable compatibility hosts also
exercise Phoenix 1.7.24 where required. Pinned `phx_new` 1.8.13 supplies the
fresh host. None is a runtime dependency. The base consumer runtime contains
no web server, and this package does not start an HTTP client, OAuth
authorization-server endpoint, or token-issuer endpoint. CI asserts the
web-server invariant against the production dependency tree.

Igniter is a declared optional, non-runtime MIT-licensed installer dependency
(`~> 0.6`; 0.8.3 in the observed development resolution). The project-level
production tree displays its optional tooling graph, including Req, Finch, and
Mint; those are not part of the base consumer runtime and no Igniter or HTTP
client module is used by the server or protected-resource boundary. A consumer
does not pull this optional graph unless the host independently enables
Igniter. `attesto_phoenix` is detected only when the host already declares it;
it is not a root dependency of this package. The installer does not enable CIMD
or add Req by default; with explicit `--enable-cimd`, the host receives a direct
compatible Req dependency because the enabled default CIMD fetcher needs an
HTTP client at runtime. The reusable and generated-host compatibility checks
accepted public-Hex `attesto_phoenix` requirements overlapping
`>= 2.14.1 and < 4.0.0` and Req requirements overlapping
`>= 0.6.1 and < 1.0.0`; the exact floor check resolved `attesto_phoenix`
2.14.1, the current 2.x check resolved 2.14.2, the 3.x check resolved 3.0.0,
and the enabled CIMD path resolved Req 0.7.4. The 2.x hosts resolved Attesto
1.15.0, while the 3.x host resolved Attesto 2.0.0. Automatic routes call the
public AttestoPhoenix protected-resource APIs at request time so replay, nonce,
canonical-request, certificate, access-token revocation, and principal-loading
policies remain host-owned. The explicit-callback installer path does not add
either dependency.

Ecto is a declared optional Apache-2.0-licensed dependency (`~> 3.10`; 3.14.2
in the observed development resolution) used only when a host selects the
bundled PostgreSQL session store. Its optional graph adds the Apache-2.0-
licensed Decimal 3.1.1 package and reuses Jason and Telemetry. SQL execution
and the PostgreSQL driver remain supplied by the host's existing Repo; this
package uses `ecto_sql` and Postgrex only in tests. The dependency-neutral
consumer lane verifies that neither Ecto nor the Ecto session adapter is
loaded when the host does not declare Ecto.

The declared package floor is Elixir 1.18 with OTP 27. `elixir --version`
reported Elixir 1.18.3/OTP 27.3 for the local floor gate and Elixir 1.20.3/OTP
29.0.5 for the local current gate. CI independently declares strict lanes for
Elixir 1.18.3/OTP 27.3 and Elixir 1.20.4/OTP 29.0.5. License and version claims
above are tied to this resolution date and must be regenerated when dependency
constraints change.
