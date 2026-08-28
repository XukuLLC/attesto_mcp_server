defmodule AttestoMCP.Server.ConformanceFixtureTest do
  @moduledoc """
  Authenticated Bandit fixture for the two frozen server requirement sets.

  This is intentionally package-owned preflight evidence, not a replacement
  for the official conformance runner. `MCP_REQUIREMENTS` selects the era so
  the same fixture can be run independently for each frozen revision.
  """

  use ExUnit.Case, async: false

  @modern "2026-07-28"
  @legacy "2025-11-25"
  @resource "https://mcp.example.com/mcp"

  test "authenticated Bandit fixture serves the selected frozen era" do
    version = System.get_env("MCP_REQUIREMENTS", @modern)
    assert version in [@modern, @legacy]

    {:ok, _apps} = Application.ensure_all_started(:bandit)
    {:ok, server} = AttestoMCP.Server.start_link([])
    register_frozen_primitives(server)

    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())

    {:ok, bandit} =
      Bandit.start_link(
        plug:
          {AttestoMCP.Server.Plug,
           server: server, path: "/mcp", auth: [config: config, resource: @resource]},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    Process.unlink(bandit)

    on_exit(fn ->
      if Process.alive?(bandit), do: ThousandIsland.stop(bandit)
      if Process.alive?(server), do: GenServer.stop(server)
    end)

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)

    case version do
      @modern -> modern_probe(port, token)
      @legacy -> legacy_probe(port, token)
    end
  end

  defp register_frozen_primitives(server) do
    assert :ok =
             AttestoMCP.Server.register_tool(server, "echo", %{
               description: "Return its input",
               input_schema: %{"type" => "object"},
               handler: fn params, _ -> {:ok, params} end
             })

    assert :ok =
             AttestoMCP.Server.register_resource(server, "test://static-text", %{
               handler: fn %{uri: uri}, _ ->
                 {:ok, %{"contents" => [%{"uri" => uri, "text" => "fixture"}]}}
               end
             })

    assert :ok =
             AttestoMCP.Server.register_resource(server, "test://static-binary", %{
               handler: fn %{uri: uri}, _ ->
                 {:ok,
                  %{
                    "contents" => [
                      %{
                        "uri" => uri,
                        "blob" => Base.encode64("fixture"),
                        "mimeType" => "text/plain"
                      }
                    ]
                  }}
               end
             })

    assert :ok =
             AttestoMCP.Server.register_resource_template(server, "test://template/{id}/data", %{
               handler: fn %{uri: uri}, _ ->
                 {:ok, %{"contents" => [%{"uri" => uri, "text" => "template"}]}}
               end
             })

    assert :ok =
             AttestoMCP.Server.register_prompt(server, "greeting", %{
               description: "A greeting",
               arguments: [%{"name" => "name", "required" => true}],
               handler: fn %{arguments: %{"name" => name}}, _ ->
                 {:ok, [%{"role" => "user", "content" => %{"type" => "text", "text" => name}}]}
               end
             })

    assert :ok =
             AttestoMCP.Server.register_completion(server, "greeting-completion", %{
               ref: %{"type" => "ref/prompt", "name" => "greeting"},
               handler: fn _, _ -> {:ok, ["Ada", "Grace"]} end
             })
  end

  defp modern_probe(port, token) do
    list =
      request(
        port,
        token,
        "tools/list",
        modern_params(),
        [{"mcp-protocol-version", @modern}, {"mcp-method", "tools/list"}]
      )

    assert list.status == 200
    assert list.body["result"]["tools"] != []

    call =
      request(
        port,
        token,
        "tools/call",
        Map.merge(modern_params(), %{"name" => "echo", "arguments" => %{"hello" => "world"}}),
        [
          {"mcp-protocol-version", @modern},
          {"mcp-method", "tools/call"},
          {"mcp-name", "echo"}
        ]
      )

    assert call.status == 200
    assert call.body["result"]["resultType"] == "complete"

    prompt =
      request(
        port,
        token,
        "prompts/get",
        Map.merge(modern_params(), %{"name" => "greeting", "arguments" => %{"name" => "Ada"}}),
        [
          {"mcp-protocol-version", @modern},
          {"mcp-method", "prompts/get"},
          {"mcp-name", "greeting"}
        ]
      )

    assert prompt.status == 200
    assert prompt.body["result"]["resultType"] == "complete"
    assert get_in(prompt.body, ["result", "messages", Access.at(0), "content", "text"]) == "Ada"
  end

  defp legacy_probe(port, token) do
    init =
      request(
        port,
        token,
        "initialize",
        %{
          "protocolVersion" => @legacy,
          "capabilities" => %{},
          "clientInfo" => %{"name" => "conformance-fixture", "version" => "1.0"}
        },
        []
      )

    assert init.status == 200
    session = List.first(init.headers["mcp-session-id"])
    assert is_binary(session)

    initialized =
      request(
        port,
        token,
        "notifications/initialized",
        %{},
        [{"mcp-session-id", session}, {"mcp-protocol-version", @legacy}],
        notification: true
      )

    assert initialized.status in [200, 202]

    list =
      request(
        port,
        token,
        "tools/list",
        %{},
        [{"mcp-session-id", session}, {"mcp-protocol-version", @legacy}]
      )

    assert list.status == 200
    assert list.body["result"]["tools"] != []

    prompt =
      request(
        port,
        token,
        "prompts/get",
        %{"name" => "greeting", "arguments" => %{"name" => "Grace"}},
        [{"mcp-session-id", session}, {"mcp-protocol-version", @legacy}]
      )

    assert prompt.status == 200
    assert get_in(prompt.body, ["result", "messages", Access.at(0), "content", "text"]) == "Grace"
  end

  defp modern_params,
    do: %{
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => @modern,
        "io.modelcontextprotocol/clientCapabilities" => %{}
      }
    }

  defp request(port, token, method, params, extra_headers, opts \\ []) do
    id =
      if Keyword.get(opts, :notification, false),
        do: nil,
        else: System.unique_integer([:positive])

    payload =
      %{"jsonrpc" => "2.0", "method" => method, "params" => params}
      |> then(fn payload -> if is_nil(id), do: payload, else: Map.put(payload, "id", id) end)

    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])

    headers =
      [
        {"Host", "127.0.0.1"},
        {"Authorization", "Bearer " <> token},
        {"Content-Type", "application/json"},
        {"Accept", "application/json, text/event-stream"}
      ] ++ extra_headers

    body = Jason.encode!(payload)

    wire =
      ["POST /mcp HTTP/1.1\r\n"] ++
        Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end) ++
        ["Content-Length: ", Integer.to_string(byte_size(body)), "\r\n\r\n", body]

    :ok = :gen_tcp.send(socket, wire)
    response = recv_response(socket, <<>>)
    :gen_tcp.close(socket)
    response
  end

  defp recv_response(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} ->
        next = acc <> data

        case String.split(next, "\r\n\r\n", parts: 2) do
          [head, body] ->
            length =
              head
              |> String.split("\r\n")
              |> Enum.find_value(0, fn line ->
                case String.split(line, ":", parts: 2) do
                  [name, value] ->
                    if String.downcase(name) == "content-length" do
                      String.trim(value) |> String.to_integer()
                    end

                  _ ->
                    nil
                end
              end)

            if byte_size(body) >= length,
              do: parse_response(head, binary_part(body, 0, length)),
              else: recv_response(socket, next)

          _ ->
            recv_response(socket, next)
        end

      {:error, :closed} ->
        parse_response("HTTP/1.1 500 closed", "")

      {:error, reason} ->
        parse_response("HTTP/1.1 500 #{reason}", "")
    end
  end

  defp parse_response(head, body) do
    [status_line | lines] = String.split(head, "\r\n", trim: true)
    [_, status] = Regex.run(~r/^HTTP\/\d\.\d (\d+)/, status_line)

    headers =
      Enum.reduce(lines, %{}, fn line, acc ->
        case String.split(line, ":", parts: 2) do
          [name, value] ->
            Map.update(
              acc,
              String.downcase(name),
              [String.trim(value)],
              &[String.trim(value) | &1]
            )

          _ ->
            acc
        end
      end)

    decoded_body = if body == "", do: %{}, else: Jason.decode!(body)
    %{status: String.to_integer(status), headers: headers, body: decoded_body}
  end
end
