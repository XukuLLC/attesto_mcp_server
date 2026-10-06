defmodule AttestoMCP.Server.CachePolicyTransportTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Plug.Conn
  import Plug.Test

  alias AttestoMCP.Server
  alias AttestoMCP.Server.Stdio
  alias AttestoMCP.Server.Test, as: ServerTest

  @resource "https://mcp.example.com/mcp"
  @modern "2026-07-28"

  @policy [
    methods: %{
      "server/discover" => [ttl_ms: 11_000],
      "tools/list" => [ttl_ms: 12_000, scope: :public],
      "resources/read" => [ttl_ms: 13_000]
    }
  ]

  setup do
    server =
      start_supervised!(
        Supervisor.child_spec(
          {Server, allow_public_cache: true, cache_policy: @policy},
          id: make_ref()
        )
      )

    assert :ok = Server.register_tool(server, "lookup", %{handler: fn _, _ -> {:ok, "ok"} end})

    assert :ok =
             Server.register_resource(server, "urn:doc", %{
               handler: fn _, _ ->
                 {:ok, %{"contents" => [%{"uri" => "urn:doc", "text" => "body"}]}}
               end
             })

    %{server: server, config: AttestoMCP.Test.Factory.config()}
  end

  @expected %{
    "server/discover" => %{"ttlMs" => 11_000, "cacheScope" => "private"},
    "tools/list" => %{"ttlMs" => 12_000, "cacheScope" => "public"},
    "resources/read" => %{"ttlMs" => 13_000, "cacheScope" => "private"}
  }

  test "direct dispatch, HTTP, and stdio emit the same protocol hints", %{
    server: server,
    config: config
  } do
    direct = %{
      "server/discover" => hints(ServerTest.discover(server)),
      "tools/list" => hints(ServerTest.list_tools(server)),
      "resources/read" => hints(ServerTest.read_resource(server, "urn:doc"))
    }

    assert direct == @expected

    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())

    plug =
      Server.Plug.init(server: server, path: "/mcp", auth: [config: config, resource: @resource])

    http =
      Map.new(@expected, fn {method, _hints} ->
        conn = http_call(plug, token, method, params_for(method))
        assert conn.status == 200, conn.resp_body
        # MCP hints never relax HTTP caching for a protected endpoint.
        assert get_resp_header(conn, "cache-control") == ["private, no-store"]
        assert get_resp_header(conn, "vary") == ["authorization"]
        {method, conn.resp_body |> Jason.decode!() |> hints()}
      end)

    assert http == @expected

    input =
      @expected
      |> Map.keys()
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {method, id} ->
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => id,
          "method" => method,
          "params" => Map.put(params_for(method), "_meta", modern_meta())
        })
      end)
      |> Kernel.<>("\n")

    output = capture_io(input, fn -> Stdio.run(server, principal: "stdio-cache") end)
    messages = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    stdio =
      @expected
      |> Map.keys()
      |> Enum.with_index(1)
      |> Map.new(fn {method, id} ->
        {method, messages |> Enum.find(&(&1["id"] == id)) |> hints()}
      end)

    assert stdio == @expected
  end

  test "an HTTP definition policy keeps a public catalog private", %{
    server: server,
    config: config
  } do
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())

    plug =
      Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource],
        scope_policy: %{"tools/list" => :visible_definitions}
      )

    conn = http_call(plug, token, "tools/list", %{})
    assert conn.status == 200, conn.resp_body
    result = Jason.decode!(conn.resp_body)["result"]
    assert Enum.map(result["tools"], & &1["name"]) == ["lookup"]
    assert result["cacheScope"] == "private"
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
  end

  defp hints(%{"result" => result}), do: Map.take(result, ["ttlMs", "cacheScope"])

  defp params_for("resources/read"), do: %{"uri" => "urn:doc"}
  defp params_for(_method), do: %{}

  defp modern_meta do
    %{
      "io.modelcontextprotocol/protocolVersion" => @modern,
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }
  end

  defp http_call(plug, token, method, params) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => Map.put(params, "_meta", modern_meta())
    }

    conn =
      conn(:post, "/mcp", Jason.encode!(request))
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", @modern)
      |> put_req_header("mcp-method", method)

    conn =
      if method in ["tools/call", "resources/read"],
        do: put_req_header(conn, "mcp-name", params["name"] || params["uri"]),
        else: conn

    Server.Plug.call(conn, plug)
  end
end
