defmodule AttestoMCP.Server.P5BanditTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server

  @modern "2026-07-28"
  @resource "https://mcp.example.com/mcp"

  test "real Bandit serves modern JSON and rejects q-zero Accept" do
    {:ok, _apps} = Application.ensure_all_started(:bandit)
    {:ok, server} = Server.start_link([])
    :ok = Server.register_tool(server, "echo", %{handler: fn _, _ -> {:ok, "ok"} end})

    :ok =
      Server.register_tool(server, "progress", %{
        handler: fn _args, context ->
          :ok = context.progress.("p5", 1, 1)
          {:ok, "done"}
        end
      })

    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())

    {:ok, bandit} =
      Bandit.start_link(
        plug:
          {Server.Plug,
           server: server,
           path: "/mcp",
           stream_keepalive_ms: 50,
           auth: [config: config, resource: @resource]},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    Process.unlink(bandit)
    on_exit(fn -> if Process.alive?(bandit), do: ThousandIsland.stop(bandit) end)
    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list",
        "params" => %{
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => @modern,
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }
        }
      })

    response = request(port, token, "application/json, text/event-stream", body)
    assert response =~ " 200 "
    assert response =~ "\"resultType\":\"complete\""

    progress_body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/call",
        "params" => %{
          "name" => "progress",
          "arguments" => %{},
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => @modern,
            "io.modelcontextprotocol/clientCapabilities" => %{},
            "progressToken" => "p5"
          }
        }
      })

    progress = request_stream(port, token, "tools/call", "progress", progress_body)
    assert progress =~ "notifications/progress"
    assert progress =~ "\"resultType\":\"complete\""

    subscription_body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "subscriptions/listen",
        "params" => %{
          "notifications" => %{"toolsListChanged" => true},
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => @modern,
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }
        }
      })

    {:ok, subscription_socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])

    :ok =
      :gen_tcp.send(
        subscription_socket,
        stream_wire(token, "subscriptions/listen", nil, subscription_body)
      )

    acknowledged = recv_until_marker(subscription_socket, "", "subscriptions/acknowledged")
    assert acknowledged =~ "subscriptions/acknowledged"
    :ok = Server.register_tool(server, "new", %{handler: fn _, _ -> {:ok, "new"} end})

    invalidation =
      recv_until_marker(subscription_socket, acknowledged, "notifications/tools/list_changed")

    assert invalidation =~ "notifications/tools/list_changed"
    :gen_tcp.close(subscription_socket)

    malformed = request(port, token, "application/json;q=0, text/event-stream", body)
    assert malformed =~ " 400 "
  end

  test "real Bandit auth verifier failures consume one bucket without double-send" do
    {:ok, _apps} = Application.ensure_all_started(:bandit)
    {:ok, server} = Server.start_link(rate_limits: %{auth_failures: %{burst: 1, window_ms: 500}})
    handler_id = {__MODULE__, :callback_auth_refusal, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:attesto_mcp_server, :auth, :refusal],
        &__MODULE__.bandit_auth_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, bandit} =
      Bandit.start_link(
        plug:
          {Server.Plug,
           server: server,
           path: "/mcp",
           auth: [config: fn -> raise "test verifier failure" end, resource: @resource]},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    Process.unlink(bandit)
    on_exit(fn -> if Process.alive?(bandit), do: ThousandIsland.stop(bandit) end)
    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)

    body = "not-json"
    first = request(port, "forged", "application/json, text/event-stream", body)
    second = request(port, "forged", "application/json, text/event-stream", body)

    assert {401, first_body} = response_status_body(first)
    assert {429, second_body} = response_status_body(second)
    assert Jason.decode!(first_body)["error"] == "invalid_token"
    assert Jason.decode!(second_body)["error"] == "rate_limited"
    assert_receive {:bandit_auth_refusal, %{category: :invalid_credentials}}, 1_000
    assert_receive {:bandit_auth_refusal, %{category: :invalid_credentials}}, 1_000
    refute_receive {:bandit_auth_refusal, _}, 50
    refute second =~ "AlreadySentError"

    Process.sleep(550)

    assert {401, _} =
             response_status_body(
               request(port, "forged", "application/json, text/event-stream", body)
             )
  end

  test "real Bandit ordinary invalid auth is 401 then 429 with one refusal event each" do
    {:ok, _apps} = Application.ensure_all_started(:bandit)
    {:ok, server} = Server.start_link(rate_limits: %{auth_failures: %{burst: 1, window_ms: 150}})
    config = AttestoMCP.Test.Factory.config()
    valid = AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_read()])
    handler_id = {__MODULE__, :auth_refusal, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:attesto_mcp_server, :auth, :refusal],
        &__MODULE__.bandit_auth_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, bandit} =
      Bandit.start_link(
        plug:
          {Server.Plug, server: server, path: "/mcp", auth: [config: config, resource: @resource]},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    Process.unlink(bandit)
    on_exit(fn -> if Process.alive?(bandit), do: ThousandIsland.stop(bandit) end)
    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)

    body = "not-json"
    first = request(port, "forged", "application/json, text/event-stream", body)
    second = request(port, "forged", "application/json, text/event-stream", body)

    assert {401, first_body} = response_status_body(first)
    assert {429, second_body} = response_status_body(second)
    assert Jason.decode!(first_body)["error"] == "invalid_token"
    assert Jason.decode!(second_body)["error"] == "rate_limited"
    assert_receive {:bandit_auth_refusal, %{category: :invalid_credentials}}, 1_000
    assert_receive {:bandit_auth_refusal, %{category: :invalid_credentials}}, 1_000
    refute_receive {:bandit_auth_refusal, _}, 50

    Process.sleep(180)

    healthy_body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 5,
        "method" => "tools/list",
        "params" => %{
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => @modern,
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }
        }
      })

    healthy = request(port, valid, "application/json, text/event-stream", healthy_body)
    assert {200, _} = response_status_body(healthy)
  end

  test "real Bandit disconnect reclaims only the owning modern stream" do
    {:ok, _apps} = Application.ensure_all_started(:bandit)
    {:ok, server} = Server.start_link(max_concurrency: 2)
    parent = self()

    assert :ok =
             Server.register_tool(server, "disconnect-slow", %{
               input_schema: %{"type" => "object"},
               handler: fn _arguments, _context ->
                 send(parent, :disconnect_handler_started)
                 Process.sleep(5_000)
                 send(parent, :disconnect_handler_late)
                 {:ok, "late"}
               end
             })

    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())

    {:ok, bandit} =
      Bandit.start_link(
        plug:
          {Server.Plug,
           server: server,
           path: "/mcp",
           stream_keepalive_ms: 50,
           auth: [config: config, resource: @resource]},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    Process.unlink(bandit)
    on_exit(fn -> if Process.alive?(bandit), do: ThousandIsland.stop(bandit) end)
    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 44,
        "method" => "tools/call",
        "params" => %{
          "name" => "disconnect-slow",
          "arguments" => %{},
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => @modern,
            "io.modelcontextprotocol/clientCapabilities" => %{},
            "progressToken" => "disconnect-progress"
          }
        }
      })

    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, stream_wire(token, "tools/call", "disconnect-slow", body))
    assert_receive :disconnect_handler_started, 1_000

    peer_body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 46,
        "method" => "tools/list",
        "params" => %{
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => @modern,
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }
        }
      })

    peer =
      Task.async(fn -> request(port, token, "application/json, text/event-stream", peer_body) end)

    assert {200, _} = response_status_body(Task.await(peer, 1_000))

    :ok = :gen_tcp.close(socket)

    assert eventually(fn -> Server.stats(server).active_requests == 0 end)
    assert eventually(fn -> Server.stats(server).active == 0 end)
    refute_receive :disconnect_handler_late, 750

    healthy_body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 45,
        "method" => "tools/list",
        "params" => %{
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => @modern,
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }
        }
      })

    assert {200, _} =
             response_status_body(
               request(port, token, "application/json, text/event-stream", healthy_body)
             )
  end

  defp request(port, token, accept, body) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])

    wire =
      [
        "POST /mcp HTTP/1.1\r\n",
        "Host: 127.0.0.1\r\n",
        "Authorization: Bearer ",
        token,
        "\r\n",
        "Content-Type: application/json\r\n",
        "Accept: ",
        accept,
        "\r\n",
        "Mcp-Protocol-Version: ",
        @modern,
        "\r\n",
        "Mcp-Method: tools/list\r\n",
        "Content-Length: ",
        Integer.to_string(byte_size(body)),
        "\r\n\r\n",
        body
      ]
      |> IO.iodata_to_binary()

    :ok = :gen_tcp.send(socket, wire)
    response = recv_all(socket, "")
    :gen_tcp.close(socket)
    response
  end

  defp request_stream(port, token, method, name, body) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])

    :ok = :gen_tcp.send(socket, stream_wire(token, method, name, body))
    response = recv_until_marker(socket, "", "resultType")
    :gen_tcp.close(socket)
    response
  end

  defp stream_wire(token, method, name, body) do
    name_header = if is_binary(name), do: ["Mcp-Name: ", name, "\r\n"], else: []

    [
      "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n",
      "Authorization: Bearer ",
      token,
      "\r\nContent-Type: application/json\r\nAccept: application/json, text/event-stream\r\n",
      "Mcp-Protocol-Version: ",
      @modern,
      "\r\nMcp-Method: ",
      method,
      "\r\n",
      name_header,
      "Content-Length: ",
      Integer.to_string(byte_size(body)),
      "\r\n\r\n",
      body
    ]
    |> IO.iodata_to_binary()
  end

  defp response_status_body(response) do
    [head, body] = String.split(response, "\r\n\r\n", parts: 2)
    [_http, status | _] = String.split(head, " ", trim: true)
    {String.to_integer(status), body}
  end

  def bandit_auth_event(_event, _measurements, metadata, parent) do
    send(parent, {:bandit_auth_refusal, metadata})
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} ->
        next = acc <> data

        if String.contains?(next, "\r\n\r\n") and content_complete?(next),
          do: next,
          else: recv_all(socket, next)

      {:error, :closed} ->
        acc

      {:error, _} ->
        acc
    end
  end

  defp recv_until_marker(socket, acc, marker) do
    if String.contains?(acc, marker) do
      acc
    else
      case :gen_tcp.recv(socket, 0, 2_000) do
        {:ok, data} -> recv_until_marker(socket, acc <> data, marker)
        _ -> acc
      end
    end
  end

  defp content_complete?(wire) do
    case Regex.run(~r/content-length:\s*(\d+)/i, wire, capture: :all_but_first) do
      [length] ->
        [_head, body] = String.split(wire, "\r\n\r\n", parts: 2)
        byte_size(body) >= String.to_integer(length)

      _ ->
        false
    end
  end
end
