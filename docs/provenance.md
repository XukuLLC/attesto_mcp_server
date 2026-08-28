# Provenance and approved sources

Implementation source and package-owned tests were derived only from the
approved sources below. Independent risk review supplied neutral protocol
scenarios only; no third-party implementation code or tests entered the
clean-room workspace.

| Source | Revision/license | Requirement use |
| --- | --- | --- |
| [MCP 2026-07-28 specification](https://modelcontextprotocol.io/specification/2026-07-28) and [pinned repository](https://github.com/modelcontextprotocol/modelcontextprotocol/tree/57ac4a2ec742e0cb7622d899b0f5d3bcf769fd69) | `57ac4a2ec742e0cb7622d899b0f5d3bcf769fd69`; new code and specification contributions Apache-2.0, unrelicensed earlier contributions MIT, non-specification documentation CC-BY-4.0 | R04-R06, R08, R10-R11, R16-R24, R27-R30 |
| [MCP 2025-11-25 specification](https://modelcontextprotocol.io/specification/2025-11-25) | same pinned repository revision and license transition: Apache-2.0/MIT for code and specifications, CC-BY-4.0 for non-specification documentation | R04-R05, R07, R09, R11, R16-R22, R25 |
| [MCP 2025-06-18 specification](https://modelcontextprotocol.io/specification/2025-06-18) | same pinned repository revision and license transition: Apache-2.0/MIT for code and specifications, CC-BY-4.0 for non-specification documentation | C01; compatibility evidence for R04-R05, R07, R09, R11, R16-R22 |
| [Final SEP-2663 Tasks extension](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/57ac4a2ec742e0cb7622d899b0f5d3bcf769fd69/docs/seps/2663-tasks-extension.mdx) | same pinned revision; final extension; Apache-2.0 specification contribution under the repository transition notice | R26 |
| [MCP conformance requirements](https://github.com/modelcontextprotocol/conformance/tree/74edef34d674f563537be8c6587cebaa58e830ca) | Runner `0.2.0-alpha.11`; commit `74edef34d674f563537be8c6587cebaa58e830ca`; archive SHA-256 `28d22ae3a4541a9a68c208e6a5653486bfacd97df45cf63cd8f0f7f9d5938293`; new contributions Apache-2.0, unrelicensed earlier contributions MIT | `examples/conformance_server.exs`, `scripts/run_conformance_fixture.sh`, frozen `server` scenarios for R04/R06/R08/R10/R19/R21-R24/R30; scored suites run for both eras without expected-failure baselines |
| Attesto public generated API docs listed in the governing baseline | Attesto git `5fc1b687f78fe869d0a77bfa766433fb1a8c23e9`, package `v1.15.0`; MIT | R12-R15 |
| AttestoMCP public generated API docs and released package | Hex package `attesto_mcp` `v1.2.1`; MIT | Public `ProtectResource.prepare/1`, `authenticate/2`, and `authorize/3`; R02, R12-R15 |
| [AttestoPhoenix public generated API docs](https://hexdocs.pm/attesto_phoenix/AttestoPhoenix.Config.html) and [accepted-floor `v2.14.0` tag](https://github.com/XukuLLC/attesto_phoenix/tree/v2.14.0) | Host-provided optional package; API floor `v2.14.0`, fresh fixture resolution `v2.14.2`; MIT | Public from-OTP-app validation, core-config and protected-resource adapter derivation, CIMD, native-loopback, router integration, and combined-installer compatibility gates; I01/I04-I05 |
| [Igniter documentation](https://hexdocs.pm/igniter/readme.html) and released package | Optional `~> 0.6`; development resolution `v0.8.3`, compatibility fixture `v0.6.0`; MIT | Idempotent Phoenix host installer and in-memory/real-project installation tests; I01-I05 |
| [Phoenix Router public API](https://hexdocs.pm/phoenix/Phoenix.Router.html), Phoenix, and `phx_new` | Router floor fixture `v1.7.24`; pinned project generator `v1.8.13`; MIT | Compile-time verification of distinct forwards plus actual generated Phoenix-host combined-installer gate; I03-I05 |
| [Official TypeScript MCP SDK](https://github.com/modelcontextprotocol/typescript-sdk) | npm artifact `@modelcontextprotocol/client@2.0.0`; MIT; immutable package version | Package `Client` and Streamable HTTP transport; authenticated negotiation/list/call smoke gate in pinned modern `2026-07-28` and explicit legacy modes; R30/T40 |
| [Official Python MCP SDK](https://github.com/modelcontextprotocol/python-sdk) | PyPI artifact `mcp==2.1.1`; MIT; immutable package version | High-level `Client` and Streamable HTTP transport; authenticated negotiation/list/call smoke gate in pinned modern `2026-07-28` and legacy modes; R30/T40 |

Official Elixir/OTP, Plug, Jason, Telemetry, ExUnit, and Mix APIs provide the
runtime primitives. Bandit is a development/test/example dependency only.
