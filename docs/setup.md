# Set up an MCP server

This guide starts with one working tool, then adds a transport, authentication,
application policy, and deployment settings. Use the
[Livebook](../examples/attesto_mcp_server.livemd) to execute the local HTTP path
from beginning to end. Use the [usage reference](usage.md) when you need a
complete option contract or a more specialized deployment.
Download the `.livemd` file and open it in Livebook with a dedicated runtime;
run its cells in order, including cleanup.

You need Elixir 1.18 or later and a compatible Erlang/OTP installation. Initial
dependency installation needs access to Hex. The HTTP examples use Bandit;
the library itself uses Plug and does not require a particular HTTP adapter.

## Choose your starting point

| Situation | Follow this path |
| --- | --- |
| Learn the API without changing an application | Run the Livebook, or start with the working tool below. |
| Add a remote endpoint to an existing Phoenix application using AttestoPhoenix | Start with [the Phoenix installer](#install-in-an-existing-phoenix-application), then connect a client. |
| A desktop client will launch a local process | Use [stdio](#use-stdio-for-a-local-client); the launcher supplies trusted identity. |
| Serve HTTP from another Plug application | Follow [explicit HTTP wiring](#use-another-plug-host) and supply an executable Attesto verifier. |
| Upgrade an existing MCP server | Read the [migration guide](migration.md) before changing configuration. |

For HTTP, the host's OAuth authorization server registers clients, authenticates
users, grants scopes, and issues tokens. `attesto_mcp_server` verifies protected
requests and implements MCP; it does not create that authorization service.
The Livebook supplies a temporary key and mints a local token so you can exercise
the boundary without setting up a login flow.

## Get one tool working

In an existing Elixir project, add the dependency and fetch it:

```elixir
{:attesto_mcp_server, "~> 2.4"}
```

```sh
mix deps.get
iex -S mix
```

In IEx, start a server with one tool installed atomically:

```elixir
alias AttestoMCP.Server.{API, Test}

{:ok, server} =
  API.start_link(
    registrations: [
      {:tool, "echo",
       %{
         description: "Return a message",
         input_schema: %{
           "type" => "object",
           "properties" => %{"message" => %{"type" => "string"}},
           "required" => ["message"],
           "additionalProperties" => false
         },
         handler: fn arguments, _context -> {:ok, arguments} end
       }}
    ]
  )

response = Test.call_tool(server, "echo", %{"message" => "hello"})
%{"result" => %{"structuredContent" => %{"message" => "hello"}}} = response

%{"error" => _} = Test.call_tool(server, "echo", %{"message" => 123})
```

You now have a registered tool whose valid input produces a structured result
and whose invalid input is rejected before the handler runs. `Test` dispatches
through the server's schema, policy, handler, and result checks. It supplies a
test identity and does not authenticate an HTTP token or perform transport
negotiation. Stop this temporary server with `GenServer.stop(server)` when done.

In an application, supervise the server and install registrations at startup
so a restarted process restores its catalog. Use `API.register_all/2` when
definitions are assembled in an application-owned registration module. The
[startup reference](usage.md#atomic-startup-telemetry-and-durable-sessions)
covers both forms and catalog replacement.

## Add a transport

### Install in an existing Phoenix application

The shortest deployed HTTP path assumes a working Phoenix application with
AttestoPhoenix already issuing tokens. Run inside the Phoenix child application,
with Igniter available and a direct Hex dependency on `attesto_phoenix`
compatible with `>= 2.14.1 and < 4.0.0`.

If the Igniter task is not available, add it to the host's development
dependencies and run `mix deps.get` first:

```elixir
{:igniter, "~> 0.8.4", only: [:dev, :test], runtime: false}
```

If the host does not issue tokens yet, follow the
[AttestoPhoenix setup](https://hexdocs.pm/attesto_phoenix/readme.html) before
connecting remote clients. With these prerequisites ready, install the server:

```sh
mix igniter.install attesto_mcp_server --base-url https://mcp.example.com
```

The base URL is the public origin without `/mcp`. The installer adds a
supervised application-owned server, a `server_status` tool and its test,
the protected `/mcp` forward, and public resource metadata. It reuses the
authorization server's live verification, principal, revocation, DPoP, and
mTLS configuration. Review its notices, including parser-order checks.

If it selects the bundled PostgreSQL session store, run the migration commands
it prints. The installer does not run migrations for you:

```sh
mix attesto_mcp_server.gen.migration --repo MyApp.Repo
mix ecto.migrate
```

Then run the generated test and start the application:

```sh
mix test
mix phx.server
```

For loopback development, use
`--base-url http://127.0.0.1:4000 --allow-http-loopback`. Production origins
use HTTPS. Applications with multiple named authorization profiles should
use AttestoPhoenix 3.x. See the
[Phoenix reference](usage.md#phoenix-installation) for prerequisites, manual
wiring, CIMD, metadata reuse, and installer recovery.

### Use another Plug host

Supply these pieces through the host application's supervision and routing:

| Piece | Responsibility |
| --- | --- |
| `AttestoMCP.Server` and registrations | Supervise the server and restore its catalog at startup. |
| `AttestoMCP.Server.Plug` | Mount `/mcp` with an executable Attesto configuration and a pinned public resource identifier. |
| OAuth protected-resource metadata | Publish the canonical resource, authorization server, and supported scopes for client discovery. |
| HTTP adapter and proxy configuration | Serve the Plug, normalize trusted proxy information, and preserve authentication before body parsing. |

Start from the Livebook for a complete authenticated Bandit example. The
[Bandit reference](usage.md#bandit-development-server) explains direct wiring;
[`examples/bandit.exs`](https://github.com/XukuLLC/attesto_mcp_server/blob/v2.4.0/examples/bandit.exs) is a credential-free boundary
example that returns 401 until configured with a valid key and credential.
Setting an issuer URL alone does not supply a token verifier. See
[Attesto and resource metadata](usage.md#attesto-and-resource-metadata) for
canonical audience, runtime configuration, revocation, and sender constraints.

### Use stdio for a local client

From a checkout of this repository, the runnable example starts an `echo` tool
and reads newline-delimited JSON-RPC from stdin. This single request exercises
the modern protocol without an HTTP token or an initialization handshake:

```sh
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"hello":"world"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}' \
  | elixir examples/stdio.exs
```

Expect a JSON-RPC result containing `structuredContent: {"hello":"world"}`.
The launcher routes install diagnostics to stderr so stdout carries protocol
messages. For an MCP client that launches processes, configure `elixir` as the
command and the absolute path to `examples/stdio.exs` as its argument.

For your own application, run `AttestoMCP.Server.Stdio.run/2` against its
registered server and supply a trusted `context`. This context represents the
local launcher's identity and permissions; it is not populated from an OAuth
bearer token. The [stdio reference](usage.md#stdio-interop) covers supervision,
framing, limits, and session-bound client compatibility.

## Connect an HTTP client

First make the client known to your authorization server. Pre-register it in
the host's client store, or enable CIMD when it identifies itself with an HTTPS
Client ID Metadata Document. Give it an appropriate grant and consent policy.
Dynamic client registration is a separate host decision. Point the MCP client
at the public `/mcp` URL; its OAuth support discovers the authorization server
and obtains a token for that resource.

Issue a resource-specific token whose `aud` matches the exact canonical MCP
resource URL. An existing token for another application API is not sufficient.
If this is a new resource, include it in the authorization server's issuance
policy. In AttestoPhoenix, that policy can include:

```elixir
resource_indicators: [allowed_resources: ["https://mcp.example.com/mcp"]]
```

Merge this entry with the host's existing allowed resources or per-client
policy. The client's OAuth requests select this resource through the `resource`
parameter. See [AttestoPhoenix resource indicators](https://hexdocs.pm/attesto_phoenix/readme.html#resource-indicators-rfc-8707)
for issuance configuration; keep MCP audience verification pinned to its own
resource.

The default HTTP method policies need these scopes:

| Operation | Default scope |
| --- | --- |
| List tools | `mcp:tools:read` |
| Call tools | `mcp:tools:call` |
| List or read resources | `mcp:resources:read` |
| List or retrieve prompts | `mcp:prompts:read` |

Ensure the authorization server can grant them and the resource metadata
advertises them. Alternatively, configure the mount's `scopes_supported` and
`default_scopes` to use your application's scopes. With generated routes,
set `scopes_supported` on both metadata and MCP forwards, and `default_scopes`
on the MCP forward. With a reused metadata route, its authorization-server
owner advertises the scopes. See [scopes and application policy](../README.md#scopes-and-application-policy).

### Verify the boundary and first request

Check public discovery and a protected endpoint without a token:

```sh
curl --include https://mcp.example.com/.well-known/oauth-protected-resource/mcp
curl --include https://mcp.example.com/mcp
```

The metadata route should return the configured resource description. The
unauthenticated MCP request should return 401 with an OAuth challenge. A 404
usually means the route is not mounted at that path.

After your authorization server issues a token for
`https://mcp.example.com/mcp` with `mcp:tools:read`, use it as `ACCESS_TOKEN`
to make a complete modern request. This example assumes an unbound bearer
token. A DPoP-bound token needs the DPoP authorization scheme and a valid proof;
an mTLS-bound token needs its matching client certificate. Use the client's
OAuth implementation to provide the sender constraints your host requires.

```sh
curl --include https://mcp.example.com/mcp \
  --request POST \
  --header "Authorization: Bearer $ACCESS_TOKEN" \
  --header "Content-Type: application/json" \
  --header "Accept: application/json, text/event-stream" \
  --header "Mcp-Protocol-Version: 2026-07-28" \
  --header "Mcp-Method: tools/list" \
  --data '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}'
```

A successful body lists the installed tools. Calling one also needs
`mcp:tools:call`, `Mcp-Method: tools/call`, and `Mcp-Name` equal to its name;
use the [complete call example](usage.md#modern-http-mirror-headers).
Check the JSON-RPC `error` member and a tool result's `isError`, as well as
HTTP status. Tool execution failures can use HTTP 200.

Modern `2026-07-28` requests carry protocol metadata on every request and do
not require `initialize` or a session ID. Clients selecting `2025-11-25` or
`2025-06-18` use initialization and the negotiated session rules instead.
Let the client SDK manage those differences. See
[protocol compatibility](usage.md#protocol-version-compatibility).

| Symptom | Check |
| --- | --- |
| 401 | Token expiry, issuer, resource audience, loaded principal, revocation, and any required DPoP or mTLS binding. |
| 403 | Granted method scopes and the host's mount policy. |
| 400 on a modern POST | Matching version/method/name headers and body metadata, without duplicate headers. |
| Tool absent or invocation denied | Definition scopes and its application authorization callback. |
| JSON-RPC input error | The registered schema and string-keyed arguments. |

## Replace the sample with application features

Tools should validate inputs and use the authenticated `context` to enforce
business policy. Register definition-level `required_scopes` or `authorize`
callbacks where appropriate; passing the HTTP method scope does not establish
permission to read a particular record. Use a stable `principal_binding` when
the host loads mutable principal structures. See
[definition authorization](usage.md#per-definition-authorization) and
[Phoenix principal binding](usage.md#phoenix-installation).

For richer output, use `AttestoMCP.Server.Content` and
`AttestoMCP.Server.Result`. Inside a tool handler,
`Result.tool_from_context/2,3` uses the running server's output budget and
canonicalization policy. Add an `output_schema` when the client depends on
a particular structured result. See [handler results](../README.md#handler-results).

Add other primitives only as needed:

| Feature | When to use it | Reference |
| --- | --- | --- |
| Resources and URI templates | Expose readable content with stable identifiers. | [Registration](usage.md#registration) |
| Prompts and completions | Provide reusable message templates and argument suggestions. | [Registration](usage.md#registration) |
| Caller-specific guidance | Explain workflow through `instructions_provider`. | [Server guidance](usage.md#server-guidance) |
| Tool presentation | Customize visible descriptions, titles, icons, or application metadata. | [Tool presentation](usage.md#tool-presentation) |
| Request metadata | Read client-supplied application metadata through `context.request_meta`. | [Request metadata](usage.md#request-metadata) |
| Identity and schema export | Add `server_icons` or `export_schema_dialect`. | [Identity](usage.md#server-identity-and-icons), [dialects](usage.md#json-schema-dialects) |
| Cache hints | Set bounded modern client freshness without caching HTTP responses. | [Cache hints](usage.md#cache-hints) |

Guidance, tool presentation, icons, and client metadata do not authorize an
operation. Treat request metadata as untrusted. Keep private cache hints for
personalized content; public hints require an explicit policy and content
that is safe to publish. These features are optional additions to the same
registered server, not prerequisites for getting a tool working.

Use `AttestoMCP.Server.Test` for focused checks of tools, resources, prompts,
completion, discovery, and lists. Keep transport tests for token enforcement,
header mirroring, framing, and session negotiation. The Livebook demonstrates
both a focused dispatch check and real loopback HTTP requests.

## Prepare for deployment

Before moving the local example to a shared endpoint, complete these host-owned
settings:

| Area | Deployment decision |
| --- | --- |
| Issuer and keys | Use the real authorization server, persistent key management, registered clients, and explicit grants/consent. Replace the notebook's temporary signer. |
| Public address | Pin HTTPS resource/audience and trusted proxy normalization. Authenticate before parsing request bodies. |
| Identity and policy | Load valid principals, select stable session bindings, enforce revocation and application permissions, and configure sender constraints when used. |
| Persistence | Choose stores for the protocol revisions and approval flows you actually enable. Migrate before use. |
| Multiple nodes | Arrange routing and shared state/signing keys; a shared session table alone does not distribute local streams or pending requests. |
| Limits | Keep finite body, JSON, metadata, frame, timeout, queue, and concurrency limits aligned with expected data sizes. |
| Operations | Monitor telemetry, test refusal paths and restart behavior, and verify clients against the revisions you enable. |

`2026-07-28` is session-free; earlier supported revisions use client sessions.
The default ETS session store is local and lost on restart. PostgreSQL can
persist session records, while streaming and pending work retain separate
routing needs. Shared cursor and request-state secrets must remain consistent
where callers can move between nodes. See
[sessions and clustering](usage.md#atomic-startup-telemetry-and-durable-sessions)
and [limits](usage.md#limits-and-scope-policy).

## Add advanced interactions when required

[Multi-round requests and subscriptions](usage.md#modern-subscriptions-and-interactive-requests)
cover user input, URL approvals, sampling, roots, and resource updates.
Use them when a specific tool or client workflow needs that interaction.
Bind retries to the returned request state and echo the actual requested input
keys; preserve the original operation and application metadata. URL approvals
need their own persistence and authenticated host approval flow.

The reference also covers [multiple MCP mounts](usage.md#three-named-mcp-servers-in-one-phoenix-host),
[telemetry](usage.md#telemetry), and [protocol-era separation](usage.md#era-separation).
Tasks are disabled in this release. Review the
[conformance evidence](../CONFORMANCE.md) for tested revisions and the limits
of its claims, and the [migration guide](migration.md) when upgrading.
