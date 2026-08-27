# Production dependency inventory

Resolved 2026-08-26 from `mix.exs` with `mix deps.get` and checked with
`mix deps.tree --only prod`. This library does not maintain or ship a project
lockfile; the exact observed resolution is recorded below and must be refreshed
when constraints or publication inputs change.

| Component | Resolved version | License policy | Production path |
|---|---:|---|---|
| attesto_mcp | 1.2.0 | MIT | direct |
| attesto | 1.15.0 | MIT | attesto_mcp |
| jose | 1.11.12 | MIT | attesto |
| plug | 1.20.3 | Apache-2.0 | direct; attesto_mcp |
| jason | 1.4.5 | Apache-2.0 | direct |
| telemetry | 1.4.2 | Apache-2.0 | direct; attesto, plug |
| mime | 2.0.7 | Apache-2.0 | plug |
| plug_crypto | 2.2.0 | Apache-2.0 | plug |

All listed production components are MIT or Apache-2.0 compatible. Bandit,
ExDoc, and Dialyzer are development/test-only. The production graph contains
no web server, HTTP client, OAuth authorization server, or token issuer.
CI asserts this invariant by failing if a production dependency tree contains
a web-server package name.

The declared package floor is Elixir 1.18 with OTP 27. The local floor gate ran
Elixir 1.18.3 on OTP 27.3; the local current gate ran Elixir 1.20.2 on OTP 28
(the Elixir executable was compiled with OTP 29). CI has strict lanes for
Elixir 1.18.3/OTP 27.3 and Elixir 1.20.3/OTP 29.0.5. License and version claims
above are tied to this resolution date and must be regenerated when dependency
constraints change.
