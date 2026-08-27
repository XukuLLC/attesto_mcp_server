defmodule AttestoMCP.Server.LegacyBanditTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server

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
    {initial, _} = recv_until(stream_socket, ": keepalive", initial)

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
      recv_until(stream_socket, "sampling/createMessage", initial)

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
    {_first, first_wire} = recv_until(stream_socket, "notifications/tools/list_changed", initial)
    assert first_wire =~ "id: 2"

    Server.publish(server, %{"type" => "toolsListChanged"})
    {_second, second_wire} = recv_until(stream_socket, "id: 3", first_wire)
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

  defp connect(port) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    socket
  end

  defp send_request(socket, method, path, headers, body) do
    headers = headers ++ [{"content-length", Integer.to_string(byte_size(body))}]

    request =
      [method, " ", path, " HTTP/1.1\r\n"] ++
        Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end) ++
        ["\r\n", body]

    :gen_tcp.send(socket, IO.iodata_to_binary(request))
  end

  defp request(socket, method, path, headers, body) do
    :ok = send_request(socket, method, path, headers, body)
    {head, rest} = recv_headers(socket)
    [status_line | header_lines] = String.split(head, "\r\n", trim: true)
    [_, status] = Regex.run(~r/^HTTP\/\d\.\d (\d+)/, status_line)
    headers = parse_headers(header_lines)
    {body, _rest} = recv_body(socket, headers, rest)
    {String.to_integer(status), headers, body}
  end

  defp recv_headers(socket, buffer \\ <<>>) do
    case :binary.match(buffer, "\r\n\r\n") do
      {offset, 4} ->
        head = binary_part(buffer, 0, offset)
        rest = binary_part(buffer, offset + 4, byte_size(buffer) - offset - 4)
        {head, rest}

      :nomatch ->
        {:ok, chunk} = :gen_tcp.recv(socket, 0, 1_000)
        recv_headers(socket, buffer <> chunk)
    end
  end

  defp parse_headers(lines) do
    Enum.group_by(
      lines,
      fn line -> line |> String.split(":", parts: 2) |> hd() |> String.downcase() end,
      fn line ->
        line |> String.split(":", parts: 2) |> List.last() |> String.trim()
      end
    )
  end

  defp recv_body(socket, headers, rest) do
    case headers["content-length"] do
      [length] ->
        needed = String.to_integer(length)
        recv_exact(socket, rest, needed)

      _ ->
        {rest, <<>>}
    end
  end

  defp recv_exact(_socket, buffer, needed) when byte_size(buffer) >= needed,
    do: {binary_part(buffer, 0, needed), binary_part(buffer, needed, byte_size(buffer) - needed)}

  defp recv_exact(socket, buffer, needed) do
    {:ok, chunk} = :gen_tcp.recv(socket, 0, 1_000)
    recv_exact(socket, buffer <> chunk, needed)
  end

  defp recv_until(socket, marker, buffer) do
    if String.contains?(buffer, marker) do
      {buffer, buffer}
    else
      {:ok, chunk} = :gen_tcp.recv(socket, 0, 1_000)
      recv_until(socket, marker, buffer <> chunk)
    end
  end

  defp assert_receive_closed(socket) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:error, :closed} -> :ok
      {:ok, _chunk} -> assert_receive_closed(socket)
      {:error, reason} -> flunk("expected stream close, got #{inspect(reason)}")
    end
  end
end
