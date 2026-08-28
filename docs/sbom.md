# Production dependency inventory

Observed locally on 2026-08-28 from `mix.exs` with `mix deps.get` and checked with
`mix deps.tree --only prod`. This library does not maintain or ship a project
lockfile; the exact observed resolution is recorded below and must be refreshed
when constraints or publication inputs change.

| Component | Resolved version | License policy | Production path |
|---|---:|---|---|
| attesto_mcp | 1.2.2 | MIT | direct |
| attesto | 1.15.0 | MIT | attesto_mcp |
| jose | 1.11.12 | MIT | attesto |
| plug | 1.20.3 | Apache-2.0 | direct; attesto_mcp |
| jason | 1.4.5 | Apache-2.0 | direct |
| telemetry | 1.4.2 | Apache-2.0 | direct; attesto, plug |
| mime | 2.0.7 | Apache-2.0 | plug |
| plug_crypto | 2.2.0 | Apache-2.0 | plug |

All listed base-runtime components are MIT or Apache-2.0 compatible. Bandit,
Phoenix, ExDoc, and Dialyzer are development/test-only. Phoenix 1.7.24 is used
to compile the reusable generated router, and pinned `phx_new` 1.8.13 supplies
the fresh combined-installer host; neither is a runtime dependency. The base
runtime graph contains no web server, HTTP client, OAuth authorization server,
or token issuer. CI asserts the web-server invariant against the production
dependency tree.

Igniter is a declared optional, non-runtime MIT-licensed installer dependency
(`~> 0.6`; 0.8.3 in the observed development resolution). The project-level
production tree displays its optional tooling graph, including Req, Finch, and
Mint; those are not part of the base consumer runtime and no Igniter or HTTP
client module is used by the server or protected-resource boundary. A consumer
does not pull this optional graph unless the host independently enables
Igniter. `attesto_phoenix` is detected only when the host already declares it;
it is not a root dependency of this package. On that installer path the host
receives a direct compatible Req dependency because the enabled default CIMD
fetcher needs an HTTP client at runtime. The reusable and generated-host
compatibility checks accept public-Hex `attesto_phoenix` requirements
overlapping `>= 2.14.0 and < 3.0.0` and Req requirements overlapping
`>= 0.6.1 and < 1.0.0`; the generated host resolved `attesto_phoenix` 2.14.1
and Req 0.7.4. The explicit-callback installer path does not add either
dependency.

The declared package floor is Elixir 1.18 with OTP 27. `elixir --version`
reported Elixir 1.18.3/OTP 27.3 for the local floor gate and Elixir 1.20.3/OTP
29.0.5 for the local current gate. CI independently declares strict lanes for
Elixir 1.18.3/OTP 27.3 and Elixir 1.20.3/OTP 29.0.5. License and version claims
above are tied to this resolution date and must be regenerated when dependency
constraints change.
