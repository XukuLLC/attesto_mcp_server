defmodule AttestoMCP.Server.P2BCacheTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AttestoMCP.Server

  @resource "https://mcp.example.com/mcp"
  @version "2026-07-28"

  setup do
    {:ok, server} =
      DynamicSupervisor.start_child(
        AttestoMCP.Server.DynamicSupervisor,
        {Server, []}
      )

    {:ok, config: AttestoMCP.Test.Factory.config(), server: server}
  end

  setup %{server: server} do
    assert :ok =
             Server.register_tool(server, "cache_tool", %{handler: fn _, _ -> {:ok, "ok"} end})

    assert :ok =
             Server.register_resource(server, "urn:cache", %{
               handler: fn _, _ ->
                 {:ok, %{"contents" => [%{"uri" => "urn:cache", "text" => "ok"}]}}
               end
             })

    on_exit(fn ->
      DynamicSupervisor.terminate_child(AttestoMCP.Server.DynamicSupervisor, server)
    end)

    :ok
  end

  @tag :g15
  @tag :t39
  test "authenticated catalog and resource responses are private and vary by authorization", %{
    config: config,
    server: server
  } do
    token =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [
          AttestoMCP.Scopes.tools_read(),
          AttestoMCP.Scopes.resources_read(),
          AttestoMCP.Scopes.tools_call()
        ]
      )

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        scope_map: %{
          "tools/list" => [AttestoMCP.Scopes.tools_read()],
          "resources/read" => [AttestoMCP.Scopes.resources_read()],
          "tools/call" => [AttestoMCP.Scopes.tools_call()]
        },
        auth: [config: config, resource: @resource]
      )

    list = call(plug, token, "tools/list", %{})
    resource = call(plug, token, "resources/read", %{"uri" => "urn:cache"})

    for conn <- [list, resource] do
      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      assert get_resp_header(conn, "vary") == ["authorization"]
    end

    assert Jason.decode!(list.resp_body)["result"]["cacheScope"] == "private"
    assert Jason.decode!(resource.resp_body)["result"]["cacheScope"] == "private"
  end

  @tag :g15
  @tag :t29
  test "MRTR responses are private and public cache configuration cannot vary by caller", %{
    config: config,
    server: server
  } do
    assert :ok =
             Server.register_tool(server, "needs_input", %{
               handler: fn _, _ ->
                 {:input_required,
                  %{
                    "choice" => %{
                      "method" => "elicitation/create",
                      "params" => %{
                        "message" => "choose",
                        "requestedSchema" => %{"type" => "object"}
                      }
                    }
                  }}
               end
             })

    token = AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_call()])

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        scope_map: %{"tools/call" => [AttestoMCP.Scopes.tools_call()]},
        auth: [config: config, resource: @resource]
      )

    conn =
      call(
        plug,
        token,
        "tools/call",
        %{
          "name" => "needs_input",
          "arguments" => %{},
          "_meta" => %{
            "io.modelcontextprotocol/clientCapabilities" => %{"elicitation" => %{}}
          }
        }
      )

    assert conn.status == 200
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "vary") == ["authorization"]
    assert Jason.decode!(conn.resp_body)["result"]["resultType"] == "input_required"
  end

  defp call(plug, token, method, params) do
    metadata =
      Map.merge(
        %{
          "io.modelcontextprotocol/protocolVersion" => @version,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        },
        Map.get(params, "_meta", %{})
      )

    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => Map.put(params, "_meta", metadata)
    }

    conn =
      conn(:post, "/mcp", Jason.encode!(request))
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", @version)
      |> put_req_header("mcp-method", method)

    conn =
      if method in ["tools/call", "resources/read"],
        do:
          put_req_header(conn, "mcp-name", request["params"]["name"] || request["params"]["uri"]),
        else: conn

    AttestoMCP.Server.Plug.call(conn, plug)
  end
end
