Mix.install([{:attesto_mcp_server, path: Path.expand("..", __DIR__)}, {:bandit, "~> 1.6"}])

{:ok, server} = AttestoMCP.Server.start_link(name: :attesto_mcp_bandit_example)

auth_config =
  Attesto.Config.new(
    issuer: "https://issuer.example",
    audience: "http://127.0.0.1:4000/mcp",
    keystore: Attesto.Keystore.Static,
    principal_kinds: [
      Attesto.PrincipalKind.new("user", "usr_",
        required_claims: [{"client_id", :non_empty_string}]
      )
    ]
  )

:ok =
  AttestoMCP.Server.register_tool(server, "echo", %{
    description: "Return its input",
    input_schema: %{"type" => "object"},
    handler: fn params, _context -> {:ok, params} end
  })

plug =
  {
    AttestoMCP.Server.Plug,
    # This credential-free example starts safely and returns 401 until a host
    # supplies a token signed by its own issuer. No token issuer or secret is
    # embedded in the example.
    server: server,
    path: "/mcp",
    auth: [config: auth_config, resource: "http://127.0.0.1:4000/mcp"]
  }

{:ok, _pid} = Bandit.start_link(plug: plug, scheme: :http, ip: {127, 0, 0, 1}, port: 4000)
IO.puts(:stderr, "MCP server listening on http://127.0.0.1:4000/mcp")
Process.sleep(:infinity)
