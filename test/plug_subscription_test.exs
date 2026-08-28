defmodule AttestoMCP.Server.PlugSubscriptionTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AttestoMCP.Server

  @resource "https://mcp.example.com/mcp"
  @version "2026-07-28"

  test "subscription open requires the complete filter scope union" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource]
      )

    denied =
      AttestoMCP.Test.Factory.access_token(config, scopes: [])
      |> then(&listen_conn(plug, &1, 90, %{"toolsListChanged" => true}))
      |> AttestoMCP.Server.Plug.call(plug)

    assert denied.status == 403

    assert Jason.decode!(denied.resp_body)["error"]["data"]["required_scopes"] == [
             AttestoMCP.Scopes.tools_read()
           ]

    [challenge] = get_resp_header(denied, "www-authenticate")
    assert challenge =~ ~s(scope="mcp:tools:read")

    assert challenge =~
             ~s(resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp")

    partial =
      AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_read()])
      |> then(
        &listen_conn(plug, &1, 91, %{"toolsListChanged" => true, "promptsListChanged" => true})
      )
      |> AttestoMCP.Server.Plug.call(plug)

    assert partial.status == 403

    assert Jason.decode!(partial.resp_body)["error"]["data"]["required_scopes"] == [
             AttestoMCP.Scopes.tools_read(),
             AttestoMCP.Scopes.prompts_read()
           ]

    configured_plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        scope_map: %{"subscriptions/listen" => ["mcp:subscriptions:read"]},
        auth: [config: config, resource: @resource]
      )

    configured =
      AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_read()])
      |> then(&listen_conn(configured_plug, &1, 92, %{"toolsListChanged" => true}))
      |> AttestoMCP.Server.Plug.call(configured_plug)

    assert configured.status == 403

    assert Jason.decode!(configured.resp_body)["error"]["data"]["required_scopes"] == [
             AttestoMCP.Scopes.tools_read(),
             "mcp:subscriptions:read"
           ]
  end

  test "authenticated HTTP listen emits acknowledgment, event, and correlated final response" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()

    token =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [AttestoMCP.Scopes.tools_read()]
      )

    parent = self()

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource]
      )

    request = %{
      "jsonrpc" => "2.0",
      "id" => 99,
      "method" => "subscriptions/listen",
      "params" => %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @version,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        },
        "notifications" => %{"toolsListChanged" => true}
      }
    }

    pid =
      spawn(fn ->
        conn =
          conn(:post, "/mcp", Jason.encode!(request))
          |> put_req_header("authorization", "Bearer " <> token)
          |> put_req_header("content-type", "application/json")
          |> put_req_header("accept", "application/json, text/event-stream")
          |> put_req_header("mcp-protocol-version", @version)
          |> put_req_header("mcp-method", "subscriptions/listen")

        result = AttestoMCP.Server.Plug.call(conn, plug)
        send(parent, {:subscription_done, result})
      end)

    Process.sleep(50)
    Server.publish(server, %{"type" => "toolsListChanged"})
    Process.sleep(50)
    Server.close_subscription(server, 99, pid)

    assert_receive {:subscription_done, conn}, 2_000
    assert conn.status == 200

    messages =
      conn.resp_body
      |> String.split("\n\n", trim: true)
      |> Enum.map(fn event ->
        event |> String.split("data: ", parts: 2) |> List.last() |> Jason.decode!()
      end)

    assert Enum.at(messages, 0)["method"] == "notifications/subscriptions/acknowledged"
    assert Enum.at(messages, 1)["method"] == "notifications/tools/list_changed"
    assert Enum.at(messages, 2)["id"] == 99
    assert get_in(Enum.at(messages, 2), ["result", "resultType"]) == "complete"
    refute Process.alive?(pid)
  end

  @tag :t25_catalog_invalidation_http
  test "authenticated HTTP catalog registration emits tools invalidation" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_read()])
    parent = self()

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource]
      )

    pid =
      spawn(fn ->
        request = %{
          "jsonrpc" => "2.0",
          "id" => 109,
          "method" => "subscriptions/listen",
          "params" => %{
            "_meta" => %{
              "io.modelcontextprotocol/protocolVersion" => @version,
              "io.modelcontextprotocol/clientCapabilities" => %{}
            },
            "notifications" => %{"toolsListChanged" => true}
          }
        }

        conn =
          conn(:post, "/mcp", Jason.encode!(request))
          |> put_req_header("authorization", "Bearer " <> token)
          |> put_req_header("content-type", "application/json")
          |> put_req_header("accept", "application/json, text/event-stream")
          |> put_req_header("mcp-protocol-version", @version)
          |> put_req_header("mcp-method", "subscriptions/listen")

        send(parent, {:catalog_stream, AttestoMCP.Server.Plug.call(conn, plug)})
      end)

    Process.sleep(50)

    assert :ok =
             Server.register_tool(server, "registered_after_open", %{
               handler: fn _, _ -> {:ok, "ok"} end
             })

    Process.sleep(50)
    Server.close_subscription(server, 109, pid)

    assert_receive {:catalog_stream, conn}, 2_000
    messages = stream_messages(conn)
    assert Enum.at(messages, 0)["method"] == "notifications/subscriptions/acknowledged"
    assert Enum.at(messages, 1)["method"] == "notifications/tools/list_changed"
    assert List.last(messages)["id"] == 109
    refute Process.alive?(pid)
  end

  test "concurrent HTTP subscriptions remain isolated when one closes" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()

    token =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [AttestoMCP.Scopes.tools_read(), AttestoMCP.Scopes.prompts_read()]
      )

    parent = self()

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource]
      )

    first = start_stream(parent, plug, token, 100, %{"toolsListChanged" => true})
    second = start_stream(parent, plug, token, 101, %{"promptsListChanged" => true})
    Process.sleep(100)

    Server.publish(server, %{"type" => "toolsListChanged"})
    Server.publish(server, %{"type" => "promptsListChanged"})
    Process.sleep(50)
    Server.close_subscription(server, 100, first)

    assert_receive {:subscription_done, 100, first_conn}, 2_000
    first_messages = stream_messages(first_conn)

    assert Enum.map(first_messages, & &1["method"]) == [
             "notifications/subscriptions/acknowledged",
             "notifications/tools/list_changed",
             nil
           ]

    assert List.last(first_messages)["id"] == 100
    assert get_in(List.last(first_messages), ["result", "resultType"]) == "complete"

    assert Enum.all?(
             first_messages,
             &(get_in(&1, ["params", "_meta", "io.modelcontextprotocol/subscriptionId"]) in [
                 nil,
                 100
               ])
           )

    Server.publish(server, %{"type" => "toolsListChanged"})
    Server.publish(server, %{"type" => "promptsListChanged"})
    Process.sleep(50)
    Server.close_subscription(server, 101, second)

    assert_receive {:subscription_done, 101, second_conn}, 2_000
    second_messages = stream_messages(second_conn)

    assert Enum.map(second_messages, & &1["method"]) == [
             "notifications/subscriptions/acknowledged",
             "notifications/prompts/list_changed",
             "notifications/prompts/list_changed",
             nil
           ]

    assert List.last(second_messages)["id"] == 101
    assert get_in(List.last(second_messages), ["result", "resultType"]) == "complete"

    assert Enum.all?(
             second_messages,
             &(get_in(&1, ["params", "_meta", "io.modelcontextprotocol/subscriptionId"]) in [
                 nil,
                 101
               ])
           )

    refute Process.alive?(first)
    refute Process.alive?(second)
  end

  test "a timed-out HTTP subscription leaves no terminal signal for a reused id" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_read()])

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        subscription_timeout: 15,
        auth: [config: config, resource: @resource]
      )

    first =
      plug
      |> listen_conn(token, 140, %{"toolsListChanged" => true})
      |> AttestoMCP.Server.Plug.call(plug)

    assert Enum.map(stream_messages(first), & &1["method"]) == [
             "notifications/subscriptions/acknowledged",
             nil
           ]

    refute_receive {:mcp_subscription_close, 140}, 25
    refute_receive {:mcp_subscription_cancel, 140}, 25

    second =
      plug
      |> listen_conn(token, 140, %{"toolsListChanged" => true})
      |> AttestoMCP.Server.Plug.call(plug)

    assert Enum.map(stream_messages(second), & &1["method"]) == [
             "notifications/subscriptions/acknowledged",
             nil
           ]

    refute_receive {:mcp_subscription_close, 140}, 25
    refute_receive {:mcp_subscription_cancel, 140}, 25
  end

  defp start_stream(parent, plug, token, id, filter) do
    spawn(fn ->
      request = %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => "subscriptions/listen",
        "params" => %{
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => @version,
            "io.modelcontextprotocol/clientCapabilities" => %{}
          },
          "notifications" => filter
        }
      }

      conn =
        conn(:post, "/mcp", Jason.encode!(request))
        |> put_req_header("authorization", "Bearer " <> token)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> put_req_header("mcp-protocol-version", @version)
        |> put_req_header("mcp-method", "subscriptions/listen")

      send(parent, {:subscription_done, id, AttestoMCP.Server.Plug.call(conn, plug)})
    end)
  end

  defp listen_conn(_plug, token, id, filter) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "subscriptions/listen",
      "params" => %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @version,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        },
        "notifications" => filter
      }
    }

    conn(:post, "/mcp", Jason.encode!(request))
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("mcp-protocol-version", @version)
    |> put_req_header("mcp-method", "subscriptions/listen")
  end

  defp stream_messages(conn) do
    conn.resp_body
    |> String.split("\n\n", trim: true)
    |> Enum.map(fn event ->
      event |> String.split("data: ", parts: 2) |> List.last() |> Jason.decode!()
    end)
  end
end
