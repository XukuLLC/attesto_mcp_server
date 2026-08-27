defmodule AttestoMCP.Server.P4RegressionTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AttestoMCP.Server
  alias AttestoMCP.Server.JSONRPC
  alias AttestoMCP.Server.Schema

  @resource "https://mcp.example.com/mcp"
  @modern "2026-07-28"

  test "legacy initialize omits a nil instructions field" do
    {:ok, server} = Server.start_link([])

    assert {1, %{"result" => result}} =
             Server.dispatch(
               server,
               %{
                 kind: :request,
                 id: 1,
                 method: "initialize",
                 params: %{
                   "protocolVersion" => "2025-11-25",
                   "capabilities" => %{},
                   "clientInfo" => %{"name" => "p4-test", "version" => "1.0"}
                 }
               },
               %{principal: "legacy"},
               version: "2025-11-25"
             )

    refute Map.has_key?(result, "instructions")
  end

  test "mixed MRTR requests are filtered to declared client capabilities" do
    {:ok, server} = Server.start_link([])

    assert :ok =
             Server.register_tool(server, "mixed_inputs", %{
               input_schema: %{"type" => "object"},
               handler: fn _, _ ->
                 {:input_required,
                  %{
                    "sampling" => %{
                      "method" => "sampling/createMessage",
                      "params" => %{
                        "messages" => [
                          %{
                            "role" => "user",
                            "content" => %{"type" => "text", "text" => "sample"}
                          }
                        ]
                      }
                    },
                    "elicitation" => %{
                      "method" => "elicitation/create",
                      "params" => %{
                        "message" => "confirm",
                        "requestedSchema" => %{"type" => "object"}
                      }
                    }
                  }}
               end
             })

    request = fn id, capabilities ->
      %{
        kind: :request,
        id: id,
        method: "tools/call",
        params: %{
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => @modern,
            "io.modelcontextprotocol/clientCapabilities" => capabilities
          },
          "name" => "mixed_inputs",
          "arguments" => %{}
        }
      }
    end

    assert {1, %{"result" => %{"resultType" => "input_required", "inputRequests" => requests}}} =
             Server.dispatch(server, request.(1, %{"sampling" => %{}}), %{principal: "mrtr"},
               version: @modern
             )

    assert map_size(requests) == 1
    assert [%{"method" => "sampling/createMessage"}] = Map.values(requests)

    assert {2,
            %{
              "error" => %{
                "code" => -32021,
                "data" => %{"requiredCapabilities" => %{"sampling" => %{}, "elicitation" => %{}}}
              }
            }} =
             Server.dispatch(server, request.(2, %{}), %{principal: "mrtr"}, version: @modern)
  end

  test "Accept is strict media-range negotiation" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_read()])

    for accept <- [
          "application/json;q=0, text/event-stream",
          "application/jsonx, text/event-stream",
          "application/json, text/event-streaming",
          "application/json;q=bogus, text/event-stream",
          "*/*"
        ] do
      conn = http_conn(server, config, token, "tools/list", accept)
      assert conn.status == 400, inspect(accept)
    end

    assert http_conn(server, config, token, "tools/list", "application/json, text/event-stream").status ==
             200

    assert http_conn(
             server,
             config,
             token,
             "tools/list",
             "application/json;q=1, text/event-stream;q=1"
           ).status ==
             200
  end

  test "Attesto authentication runs before malformed or oversized body work" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_read()])

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource]
      )

    base =
      conn(:post, "/mcp", "not-json")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")

    assert AttestoMCP.Server.Plug.call(base, plug).status == 401

    forged = put_req_header(base, "authorization", "Bearer forged")
    assert AttestoMCP.Server.Plug.call(forged, plug).status == 401

    valid = put_req_header(base, "authorization", "Bearer " <> token)
    assert AttestoMCP.Server.Plug.call(valid, plug).status == 400
  end

  test "invalid decoded requests retain a valid JSON-RPC id" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_read()])

    payload =
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => 42, "method" => "tools/list", "params" => []})

    conn =
      conn(:post, "/mcp", payload)
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource]
      )

    response = AttestoMCP.Server.Plug.call(conn, plug)

    assert Jason.decode!(response.resp_body)["id"] == 42
    assert JSONRPC.recover_id(payload) == 42
  end

  test "request stop duration is elapsed and nonnegative" do
    {:ok, server} = Server.start_link([])
    parent = self()
    handler_id = {:p4_duration, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:attesto_mcp_server, :request, :stop],
        &__MODULE__.handle_event/4,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {1, %{"result" => _}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 1, method: "tools/list", params: modern_meta()},
               %{principal: "duration"},
               version: @modern
             )

    assert_receive {:request_stop, %{duration: duration}, %{outcome: :ok}}, 1_000
    assert is_integer(duration) and duration >= 0
  end

  test "caller death reclaims the active request permit" do
    {:ok, server} = Server.start_link(max_concurrency: 1, per_principal_concurrency: 1)
    parent = self()

    :ok =
      Server.register_tool(server, "slow_owner", %{
        input_schema: %{"type" => "object"},
        handler: fn _, _ ->
          send(parent, :owner_started)
          Process.sleep(5_000)
          {:ok, "late"}
        end
      })

    request = %{
      kind: :request,
      id: 1,
      method: "tools/call",
      params: %{"name" => "slow_owner", "arguments" => %{}}
    }

    caller =
      spawn(fn ->
        Server.dispatch(server, request, %{principal: "owner"}, version: "2025-11-25")
      end)

    assert_receive :owner_started, 1_000
    Process.exit(caller, :kill)

    assert eventually(fn -> Server.stats(server).active == 0 end)

    assert {2, %{"result" => _}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 2, method: "ping", params: modern_meta()},
               %{principal: "owner"},
               version: "2025-11-25",
               timeout: 10
             )
  end

  test "independent HTTP owners may reuse the same wire request ID" do
    {:ok, server} = Server.start_link(max_concurrency: 2, per_principal_concurrency: 2)
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_call()])
    parent = self()

    assert :ok =
             Server.register_tool(server, "same_id", %{
               input_schema: %{"type" => "object"},
               handler: fn _, _ ->
                 Process.sleep(50)
                 {:ok, "ok"}
               end
             })

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource]
      )

    for _ <- 1..2 do
      spawn(fn ->
        response = http_tool_conn(plug, token, 7)
        send(parent, {:same_id_response, response.status, Jason.decode!(response.resp_body)})
      end)
    end

    assert_receive {:same_id_response, 200, %{"id" => 7}}, 2_000
    assert_receive {:same_id_response, 200, %{"id" => 7}}, 2_000
  end

  test "negative JSON Schema numeric bounds are accepted" do
    assert :ok =
             Schema.validate_schema(%{
               "type" => "number",
               "minimum" => -10,
               "maximum" => -1,
               "exclusiveMinimum" => -9.5,
               "exclusiveMaximum" => -1.5
             })
  end

  test "minimal tools receive valid catalog defaults and invalid identities fail closed" do
    {:ok, server} = Server.start_link([])
    assert :ok = Server.register_tool(server, "minimal", %{handler: fn _, _ -> {:ok, "ok"} end})

    assert {:error, {:invalid_definition, :identity}} =
             Server.register_tool(server, "bad name", %{})

    assert {:error, {:invalid_definition, :identity}} =
             Server.register_tool(server, String.duplicate("a", 65), %{})

    assert {1, %{"result" => %{"tools" => [tool]}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 1, method: "tools/list", params: modern_meta()},
               %{principal: "catalog"},
               version: @modern
             )

    assert tool["name"] == "minimal"
    assert is_binary(tool["description"])
    assert tool["inputSchema"] == %{"type" => "object"}
  end

  test "configured HTTP rate limits reject bursts and refill" do
    {:ok, server} =
      Server.start_link(
        rate_limits: %{
          calls: %{burst: 1, window_ms: 50},
          completion: false,
          subscriptions: false,
          auth_failures: %{burst: 2, window_ms: 50}
        }
      )

    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_read()])
    first = http_conn(server, config, token, "tools/list", "application/json, text/event-stream")
    second = http_conn(server, config, token, "tools/list", "application/json, text/event-stream")

    assert first.status == 200
    assert second.status == 429
    Process.sleep(60)

    assert http_conn(server, config, token, "tools/list", "application/json, text/event-stream").status ==
             200
  end

  test "a pinned resource without a usable verifier is rejected at startup" do
    {:ok, server} = Server.start_link([])

    assert_raise ArgumentError, ~r/auth must configure/, fn ->
      AttestoMCP.Server.Plug.init(server: server, path: "/mcp", auth: [resource: @resource])
    end
  end

  test "server startup rejects unknown and ill-typed options" do
    for options <- [
          [unknown_option: true],
          [clustered: "yes"],
          [scope_map: %{"tools/list" => "tools.read"}],
          [capabilities: %{"tools" => :not_json}]
        ] do
      parent = self()

      pid =
        spawn(fn ->
          Process.flag(:trap_exit, true)
          send(parent, {:startup_result, Server.start_link(options)})
        end)

      assert_receive {:startup_result, {:error, _}}, 1_000
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    end

    assert {:ok, server} = Server.start_link(scope_map: %{"tools/list" => ["tools.read"]})
    assert is_pid(server)
    GenServer.stop(server)
  end

  test "modern envelope metadata omissions are invalid params over HTTP" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_read()])

    for params <- [
          %{},
          %{"_meta" => %{"io.modelcontextprotocol/protocolVersion" => @modern}},
          %{
            "_meta" => %{
              "io.modelcontextprotocol/clientCapabilities" => %{}
            }
          }
        ] do
      response = http_conn_with_params(server, config, token, "tools/list", params)
      assert response.status == 400
      assert Jason.decode!(response.resp_body)["error"]["code"] == -32602
    end
  end

  test "safe custom resource schemes are readable without dereference" do
    {:ok, server} = Server.start_link([])

    assert :ok =
             Server.register_resource(server, "test://static-text", %{
               handler: fn %{uri: uri}, _ ->
                 {:ok, %{"contents" => [%{"uri" => uri, "text" => "fixture"}]}}
               end
             })

    params =
      Map.merge(modern_meta(), %{
        "uri" => "test://static-text"
      })

    assert {1, %{"result" => %{"contents" => [%{"text" => "fixture"}]}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 1, method: "resources/read", params: params},
               %{principal: "resource-test"},
               version: @modern
             )

    assert {2, %{"error" => %{"code" => -32602}}} =
             Server.dispatch(
               server,
               %{
                 kind: :request,
                 id: 2,
                 method: "resources/read",
                 params: Map.put(params, "uri", "http://127.0.0.1/private")
               },
               %{principal: "resource-test"},
               version: @modern
             )
  end

  defp modern_meta(extra \\ %{}),
    do: %{
      "_meta" =>
        Map.merge(
          %{
            "io.modelcontextprotocol/protocolVersion" => @modern,
            "io.modelcontextprotocol/clientCapabilities" => %{}
          },
          extra
        )
    }

  defp http_conn(server, config, token, method, accept) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => modern_meta()
    }

    http_conn_with_params(server, config, token, method, request["params"], accept)
  end

  defp http_conn_with_params(
         server,
         config,
         token,
         method,
         params,
         accept \\ "application/json, text/event-stream"
       ) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => params
    }

    conn(:post, "/mcp", Jason.encode!(request))
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", accept)
    |> put_req_header("mcp-protocol-version", @modern)
    |> put_req_header("mcp-method", method)
    |> then(fn conn ->
      plug =
        AttestoMCP.Server.Plug.init(
          server: server,
          path: "/mcp",
          scope_map: %{method => [AttestoMCP.Scopes.tools_read()]},
          auth: [config: config, resource: @resource]
        )

      AttestoMCP.Server.Plug.call(conn, plug)
    end)
  end

  defp http_tool_conn(plug, token, id) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => Map.merge(modern_meta(), %{"name" => "same_id", "arguments" => %{}})
    }

    conn(:post, "/mcp", Jason.encode!(request))
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("mcp-protocol-version", @modern)
    |> put_req_header("mcp-method", "tools/call")
    |> put_req_header("mcp-name", "same_id")
    |> AttestoMCP.Server.Plug.call(plug)
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  def handle_event(_event, measurements, metadata, parent),
    do: send(parent, {:request_stop, measurements, metadata})
end
