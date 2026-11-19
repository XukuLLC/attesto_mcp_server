defmodule AttestoMCP.Server.ChallengeScopeSelectionTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias AttestoMCP.Server
  alias AttestoMCP.Test.Factory

  @resource "https://mcp.example.com/mcp"
  @metadata_url "https://mcp.example.com/.well-known/oauth-protected-resource/mcp"
  @anonymous_challenge ~s(Bearer resource_metadata="#{@metadata_url}")
  @legacy_versions ["2025-06-18", "2025-11-25"]
  @modern "2026-07-28"
  @initialize_scope "mcp:tools"
  @tools [
    {"reports", "reports:read"},
    {"inventory", "inventory:read"},
    {"billing", "billing:read"}
  ]
  @supported_scopes [@initialize_scope, "mcp:tools:read" | Enum.map(@tools, &elem(&1, 1))]
  @credentials [nil, "invalid"]

  setup do
    {:ok, server} = Server.start_link([])
    %{server: server, config: Factory.config()}
  end

  test "clients select all advertised scopes by default and the method minimum when hinted",
       ctx do
    for {name, scope} <- @tools do
      assert :ok =
               Server.register_tool(ctx.server, name, %{
                 required_scopes: [scope],
                 handler: fn _, _ -> {:ok, "called"} end
               })
    end

    default_plug = init_plug(ctx, [])
    opt_in_plug = init_plug(ctx, challenge_scopes: &Server.Plug.method_challenge_scopes/1)
    all_scopes = MapSet.new(@supported_scopes)

    requests =
      Enum.map(@legacy_versions, &{&1, "initialize", [], [@initialize_scope]}) ++
        [
          {@modern, "tools/list", [{"mcp-method", "tools/list"}], @supported_scopes},
          {@modern, "tools/call", [{"mcp-method", "tools/call"}, {"mcp-name", "reports"}],
           @supported_scopes},
          {@modern, "initialize", [], [@initialize_scope]}
        ]

    for {version, method, headers, hinted_scopes} <- requests, token <- @credentials do
      response = request(default_plug, token, version, method, headers)
      assert client_scopes(response, default_plug) == all_scopes

      response = request(opt_in_plug, token, version, method, headers)
      assert client_scopes(response, opt_in_plug) == MapSet.new(hinted_scopes)
    end
  end

  test "default anonymous, invalid-token, and expired-token headers match 3.10.0", ctx do
    plug = init_plug(ctx, [])

    {:ok, %{access_token: expired}} =
      Attesto.Token.mint(
        ctx.config,
        %{
          claims: %{"client_id" => "client-1"},
          kind: "user",
          sub: "usr_123",
          scopes: @supported_scopes
        },
        lifetime: 1,
        now: DateTime.add(DateTime.utc_now(), -60, :second)
      )

    for version <- [@modern | @legacy_versions],
        headers <- [[], [{"mcp-method", "initialize"}]] do
      assert request(plug, nil, version, "initialize", headers) |> challenge() ==
               @anonymous_challenge

      assert request(plug, "invalid", version, "initialize", headers) |> challenge() ==
               token_challenge("invalid_token")

      assert request(plug, expired, version, "initialize", headers) |> challenge() ==
               token_challenge("expired")
    end
  end

  test "a host can omit scope or set a static list", ctx do
    assert_challenge_scopes(ctx, [], "")

    assert_challenge_scopes(
      ctx,
      ["reports:read", "billing:read"],
      ~s(, scope="reports:read billing:read")
    )
  end

  test "a scope callback receives the request conn once per challenge", ctx do
    callback = fn conn ->
      send(self(), {:scope_callback, get_req_header(conn, "mcp-method")})
      if conn.request_path == "/mcp", do: ["reports:read"], else: []
    end

    assert_challenge_scopes(ctx, callback, ~s(, scope="reports:read"))
    assert_received {:scope_callback, ["initialize"]}
    assert_received {:scope_callback, ["initialize"]}
    refute_received {:scope_callback, _method}
  end

  test "empty and invalid callback results omit scope and preserve resource metadata", ctx do
    for result <- [[], "reports:read", ["invalid scope"], ["reports:read" | :invalid]] do
      assert_challenge_scopes(ctx, fn _conn -> result end, "")
    end
  end

  test "a raising scope callback preserves a metadata-only 401 on both paths", ctx do
    plug = init_plug(ctx, challenge_scopes: fn _conn -> raise "scope callback failure" end)

    for token <- @credentials do
      response = request(plug, token, @modern, "initialize", [])
      assert challenge(response) == @anonymous_challenge

      assert Jason.decode!(response.resp_body) == %{
               "error" => "invalid_token",
               "error_description" => "authentication required"
             }
    end
  end

  test "invalid scope options raise at init and name the option", ctx do
    for value <- [
          ["invalid scope"],
          ["reports:read" | :invalid],
          :invalid,
          fn -> [] end,
          fn _, _ -> [] end
        ] do
      assert_raise ArgumentError, ~r/:challenge_scopes/, fn ->
        init_plug(ctx, challenge_scopes: value)
      end
    end
  end

  test "the method callback returns no scopes outside the server plug" do
    assert Server.Plug.method_challenge_scopes(conn(:post, "/mcp")) == []
  end

  test "a verifier exception preserves the configured static and method hints", ctx do
    credential = fn _conn -> raise "credential callback failure" end

    for {option, scope} <- [
          {["reports:read"], "reports:read"},
          {&Server.Plug.method_challenge_scopes/1, @initialize_scope}
        ] do
      plug = init_plug(ctx, credential_from_conn: credential, challenge_scopes: option)

      assert request(plug, nil, @modern, "initialize", []) |> challenge() ==
               @anonymous_challenge <> ~s(, scope="#{scope}")
    end
  end

  defp init_plug(ctx, auth) do
    Server.Plug.init(
      server: ctx.server,
      auth: [config: ctx.config, resource: @resource] ++ auth,
      default_scopes: [@initialize_scope],
      scopes_supported: @supported_scopes,
      scope_policy: %{"tools/list" => :visible_definitions, "tools/call" => :selected_definition}
    )
  end

  defp request(plug, token, version, method, headers) do
    params =
      case method do
        "initialize" ->
          %{
            "protocolVersion" => version,
            "capabilities" => %{},
            "clientInfo" => %{"name" => "client", "version" => "1"}
          }

        "tools/call" ->
          %{"name" => "reports", "arguments" => %{}}

        "tools/list" ->
          %{}
      end

    payload =
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})

    conn =
      conn(:post, "/mcp", payload)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", version)

    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn

    Enum.reduce(headers, conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
    |> Server.Plug.call(plug)
  end

  defp client_scopes(response, plug) do
    challenge = challenge(response)

    [metadata_url] =
      Regex.run(~r/\bresource_metadata="([^"]+)"/, challenge, capture: :all_but_first)

    metadata = Server.Plug.call(conn(:get, metadata_url), plug)
    assert metadata.status == 200
    assert %{"scopes_supported" => scopes_supported} = Jason.decode!(metadata.resp_body)
    assert scopes_supported == @supported_scopes

    case Regex.run(~r/\bscope="([^"]*)"/, challenge, capture: :all_but_first) do
      [scopes] ->
        scopes |> String.split(" ", trim: true) |> MapSet.new()

      nil ->
        MapSet.new(scopes_supported)
    end
  end

  defp assert_challenge_scopes(ctx, option, suffix) do
    plug = init_plug(ctx, challenge_scopes: option)
    headers = [{"mcp-method", "initialize"}]

    assert request(plug, nil, @modern, "initialize", headers) |> challenge() ==
             @anonymous_challenge <> suffix

    assert request(plug, "invalid", @modern, "initialize", headers) |> challenge() ==
             token_challenge("invalid_token") <> suffix
  end

  defp challenge(response) do
    assert response.status == 401
    assert [challenge] = get_resp_header(response, "www-authenticate")
    challenge
  end

  defp token_challenge(description) do
    ~s(Bearer error="invalid_token", error_description="#{description}", resource_metadata="#{@metadata_url}")
  end
end
