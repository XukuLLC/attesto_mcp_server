defmodule AttestoMCP.Server.LegacyBanditTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server
  alias AttestoMCP.Server.TestSupport.HTTPClient

  import AttestoMCP.Server.TestSupport.HTTPClient,
    only: [
      connect: 1,
      parse_headers: 1,
      recv_headers: 1,
      request: 5,
      send_request: 5
    ]

  @resource "https://mcp.example.com/mcp"
  @legacy "2025-11-25"

  test "Bandit delivers legacy SSE keepalive and delayed events incrementally" do
    {:ok, _started_apps} = Application.ensure_all_started(:bandit)
    {:ok, server} = Server.start_link([])
    parent = self()

    assert :ok =
             Server.register_tool(server, "bandit_client_request", %{
               input_schema: %{"type" => "object"},
               handler: fn _arguments, context ->
                 result = context.client_request.("sampling/createMessage", %{"messages" => []})
                 send(parent, {:bandit_handler_result, result})
                 {:ok, "complete"}
               end
             })

    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())

    plug_opts = [
      server: server,
      path: "/mcp",
      legacy_keepalive_ms: 100,
      auth: [config: config, resource: @resource]
    ]

    {:ok, bandit} =
      Bandit.start_link(
        plug: {AttestoMCP.Server.Plug, plug_opts},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    Process.unlink(bandit)

    on_exit(fn ->
      if Process.alive?(bandit) do
        try do
          ThousandIsland.stop(bandit)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)

    init_socket = connect(port)

    {200, init_headers, init_body} =
      request(
        init_socket,
        "POST",
        "/mcp",
        common_headers(token) ++ [{"content-type", "application/json"}],
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => @legacy,
            "capabilities" => %{"sampling" => %{}},
            "clientInfo" => %{"name" => "bandit-test", "version" => "1.0"}
          }
        })
      )

    assert Jason.decode!(init_body)["result"]["protocolVersion"] == @legacy
    [session_id] = Map.fetch!(init_headers, "mcp-session-id")

    {_status, _headers, _body} =
      request(
        init_socket,
        "POST",
        "/mcp",
        common_headers(token) ++
          [
            {"content-type", "application/json"},
            {"mcp-session-id", session_id},
            {"mcp-protocol-version", @legacy}
          ],
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "notifications/initialized",
          "params" => %{}
        })
      )

    :gen_tcp.close(init_socket)
    stream_socket = connect(port)

    :ok =
      send_request(
        stream_socket,
        "GET",
        "/mcp",
        Enum.reject(common_headers(token), fn {name, _value} -> name == "accept" end) ++
          [
            {"accept", "text/event-stream"},
            {"mcp-session-id", session_id},
            {"mcp-protocol-version", @legacy}
          ],
        ""
      )

    {stream_head, initial} = recv_headers(stream_socket)
    [_stream_status | stream_header_lines] = String.split(stream_head, "\r\n", trim: true)
    stream_headers = parse_headers(stream_header_lines)
    assert [content_type] = stream_headers["content-type"]
    assert String.starts_with?(content_type, "text/event-stream")
    {initial, _} = HTTPClient.recv_until(stream_socket, ": keepalive", initial)

    spawn(fn ->
      result =
        Server.dispatch(
          server,
          %{
            kind: :request,
            id: 40,
            method: "tools/call",
            params: %{"name" => "bandit_client_request", "arguments" => %{}}
          },
          %{principal: "usr_123", tenant: nil, session_id: session_id},
          version: @legacy
        )

      send(parent, {:bandit_dispatch_result, result})
    end)

    {_request_fragment, request_wire} =
      HTTPClient.recv_until(stream_socket, "sampling/createMessage", initial)

    [request_id] = Regex.run(~r/"id":"([^"]+)"/, request_wire, capture: :all_but_first)
    response_socket = connect(port)

    {202, _response_headers, _response_body} =
      request(
        response_socket,
        "POST",
        "/mcp",
        common_headers(token) ++
          [
            {"content-type", "application/json"},
            {"mcp-session-id", session_id},
            {"mcp-protocol-version", @legacy}
          ],
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => request_id,
          "result" => %{
            "role" => "assistant",
            "content" => %{"type" => "text", "text" => "ok"},
            "model" => "bandit-model",
            "stopReason" => "endTurn"
          }
        })
      )

    :gen_tcp.close(response_socket)
    assert_receive {:bandit_handler_result, {:ok, %{"role" => "assistant"}}}, 1_000
    assert_receive {:bandit_dispatch_result, {40, %{"result" => %{"content" => _}}}}, 1_000

    duplicate_socket = connect(port)

    {400, _duplicate_headers, duplicate_body} =
      request(
        duplicate_socket,
        "POST",
        "/mcp",
        common_headers(token) ++
          [
            {"content-type", "application/json"},
            {"mcp-session-id", session_id},
            {"mcp-protocol-version", @legacy}
          ],
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => request_id,
          "result" => %{
            "role" => "assistant",
            "content" => %{"type" => "text", "text" => "late"},
            "model" => "bandit-model",
            "stopReason" => "endTurn"
          }
        })
      )

    assert Jason.decode!(duplicate_body)["error"]["data"]["reason"] == "unsolicited_response"
    :gen_tcp.close(duplicate_socket)

    Server.publish(server, %{"type" => "toolsListChanged"})

    {_first, first_wire} =
      HTTPClient.recv_until(stream_socket, "notifications/tools/list_changed", initial)

    assert first_wire =~ "id: 2"

    Server.publish(server, %{"type" => "toolsListChanged"})
    {_second, second_wire} = HTTPClient.recv_until(stream_socket, "id: 3", first_wire)
    assert second_wire =~ "notifications/tools/list_changed"

    delete_socket = connect(port)

    {200, _delete_headers, _delete_body} =
      request(
        delete_socket,
        "DELETE",
        "/mcp",
        common_headers(token) ++
          [
            {"mcp-session-id", session_id},
            {"mcp-protocol-version", @legacy}
          ],
        ""
      )

    :gen_tcp.close(delete_socket)
    assert_receive_closed(stream_socket)
    :gen_tcp.close(stream_socket)
  end

  defp common_headers(token),
    do: [
      {"host", "127.0.0.1"},
      {"authorization", "Bearer " <> token},
      {"accept", "application/json, text/event-stream"}
    ]

  defp assert_receive_closed(socket) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:error, :closed} -> :ok
      {:ok, _chunk} -> assert_receive_closed(socket)
      {:error, reason} -> flunk("expected stream close, got #{inspect(reason)}")
    end
  end
end
