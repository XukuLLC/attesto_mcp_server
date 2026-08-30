defmodule AttestoMCP.Server.MessageLimitConsistencyTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AttestoMCP.Server
  alias AttestoMCP.Server.{Content, Result, Schema}

  @resource "https://mcp.example.com/mcp"
  @version "2026-07-28"
  @legacy "2025-11-25"
  @limit 2_048

  setup do
    {:ok, server} =
      DynamicSupervisor.start_child(
        AttestoMCP.Server.DynamicSupervisor,
        {Server, []}
      )

    on_exit(fn ->
      DynamicSupervisor.terminate_child(AttestoMCP.Server.DynamicSupervisor, server)
    end)

    %{config: AttestoMCP.Test.Factory.config(), server: server}
  end

  test "one configured byte budget governs HTTP, JSON-RPC, schema validation, and dispatch", %{
    config: config,
    server: server
  } do
    owner = self()

    assert :ok =
             Server.register_tool(server, "bounded", %{
               input_schema: %{
                 "type" => "object",
                 "properties" => %{"payload" => %{"type" => "string"}},
                 "required" => ["payload"],
                 "additionalProperties" => false
               },
               handler: fn %{"payload" => payload}, _context ->
                 send(owner, {:handled, byte_size(payload)})
                 {:ok, "accepted"}
               end
             })

    token =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [AttestoMCP.Scopes.tools_call()],
        audience: @resource
      )

    exact = request_body(@limit)
    assert byte_size(exact) == @limit

    exact_response =
      exact
      |> request(token)
      |> Server.Plug.call(plug(server, config, @limit, @limit))

    assert exact_response.status == 200
    assert %{"result" => %{"isError" => false}} = Jason.decode!(exact_response.resp_body)
    assert_receive {:handled, payload_bytes}
    assert payload_bytes > 0

    one_over = request_body(@limit + 1)

    message_response =
      one_over
      |> request(token)
      |> Server.Plug.call(plug(server, config, @limit + 1, @limit))

    assert get_in(Jason.decode!(message_response.resp_body), ["error", "data", "reason"]) ==
             "message_too_large"

    body_response =
      one_over
      |> request(token)
      |> Server.Plug.call(plug(server, config, @limit, @limit + 1))

    assert get_in(Jason.decode!(body_response.resp_body), ["error", "data", "reason"]) ==
             "body_too_large"

    refute_receive {:handled, _}
  end

  test "transport limits cannot promise more than schema validation accepts", %{server: server} do
    too_large = Schema.max_instance_bytes() + 1

    assert_raise ArgumentError, ~r/schema-instance ceiling/, fn ->
      Server.Plug.init(
        server: server,
        path: "/mcp",
        max_message_bytes: too_large,
        auth: [issuer: "https://issuer.example", resource: @resource]
      )
    end

    assert_raise ArgumentError, ~r/max_message_bytes must be between/, fn ->
      Server.Stdio.run(server, input: fn -> :eof end, max_message_bytes: too_large)
    end

    for key <- [:max_body_bytes, :max_message_bytes] do
      assert_raise ArgumentError, ~r/#{key} must be a positive integer/, fn ->
        Server.init([{key, 0}])
      end

      assert_raise ArgumentError, ~r/#{key} must be a positive integer/, fn ->
        Server.Plug.init(
          [
            server: server,
            path: "/mcp",
            auth: [issuer: "https://issuer.example", resource: @resource]
          ] ++ [{key, 0}]
        )
      end
    end

    assert_raise ArgumentError, ~r/max_message_bytes must be between/, fn ->
      Server.Stdio.run(server, input: fn -> :eof end, max_message_bytes: 0)
    end
  end

  test "oversized completion output fails closed in both protocol eras", %{server: server} do
    oversized = String.duplicate("x", Schema.max_instance_bytes() + 1)

    assert :ok =
             Server.register_completion(server, "oversized", %{
               ref: %{"type" => "ref/prompt", "name" => "oversized"},
               handler: fn _input, _context -> {:ok, [oversized]} end
             })

    base = %{
      "ref" => %{"type" => "ref/prompt", "name" => "oversized"},
      "argument" => %{"name" => "topic", "value" => "x"}
    }

    for {id, version, params} <- [
          {10, @version, modern(base)},
          {11, @legacy, base}
        ] do
      assert {^id,
              %{
                "error" => %{
                  "code" => -32603,
                  "data" => %{"reason" => "invalid_completion_result"}
                }
              }} = dispatch(server, id, "completion/complete", params, version)
    end
  end

  test "server-owned result fields cannot push a constructor result over the wire bound", %{
    server: server
  } do
    text_bytes = Schema.max_instance_bytes() - 39
    result = Result.tool(Content.text(String.duplicate("x", text_bytes)))

    assert IO.iodata_length(Jason.encode_to_iodata!(result)) == Schema.max_instance_bytes()

    assert :ok =
             Server.register_tool(server, "exact-bound", %{
               handler: fn _arguments, _context -> {:ok, result} end
             })

    assert {20, %{"error" => %{"code" => -32603, "data" => %{"reason" => "invalid_result"}}}} =
             dispatch(
               server,
               20,
               "tools/call",
               modern(%{"name" => "exact-bound", "arguments" => %{}}),
               @version
             )
  end

  test "oversized server identity and instructions fail closed at final assembly" do
    oversized = String.duplicate("x", Schema.max_instance_bytes() + 1)
    server_with_name = start_server(server_name: oversized)

    assert {30, %{"error" => %{"code" => -32603, "data" => %{"reason" => "invalid_result"}}}} =
             dispatch(server_with_name, 30, "server/discover", modern(%{}), @version)

    server_with_instructions = start_server(instructions: oversized)

    initialize = %{
      "protocolVersion" => @legacy,
      "capabilities" => %{},
      "clientInfo" => %{"name" => "client", "version" => "1"}
    }

    assert {31, %{"error" => %{"code" => -32603, "data" => %{"reason" => "invalid_result"}}}} =
             dispatch(server_with_instructions, 31, "initialize", initialize, @legacy)
  end

  test "aggregate catalog pages fail closed in both protocol eras", %{server: server} do
    name = "catalog-bound"
    base_schema = %{"type" => "object", "x-padding" => ""}

    base_definition = %{
      "name" => name,
      "description" => "Tool " <> name,
      "inputSchema" => base_schema,
      "annotations" => %{}
    }

    base_bytes = IO.iodata_length(Jason.encode_to_iodata!([base_definition]))
    padding = String.duplicate("x", Schema.max_instance_bytes() - base_bytes)
    input_schema = %{base_schema | "x-padding" => padding}

    exact_definition = put_in(base_definition, ["inputSchema"], input_schema)

    assert IO.iodata_length(Jason.encode_to_iodata!([exact_definition])) ==
             Schema.max_instance_bytes()

    assert :ok =
             Server.replace_catalog(server, [
               {:tool, name,
                %{
                  input_schema: input_schema,
                  handler: fn _arguments, _context -> {:ok, "ok"} end
                }}
             ])

    for {id, version, params} <- [
          {40, @version, modern(%{})},
          {41, @legacy, %{}}
        ] do
      assert {^id,
              %{
                "error" => %{"code" => -32603, "data" => %{"reason" => "invalid_result"}}
              }} = dispatch(server, id, "tools/list", params, version)
    end
  end

  defp request_body(bytes) do
    base = payload("") |> Jason.encode!()
    payload(String.duplicate("a", bytes - byte_size(base))) |> Jason.encode!()
  end

  defp payload(value) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{
        "name" => "bounded",
        "arguments" => %{"payload" => value},
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @version,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }
  end

  defp modern(params) do
    Map.put(params, "_meta", %{
      "io.modelcontextprotocol/protocolVersion" => @version,
      "io.modelcontextprotocol/clientCapabilities" => %{}
    })
  end

  defp dispatch(server, id, method, params, version) do
    Server.dispatch(
      server,
      %{kind: :request, id: id, method: method, params: params},
      %{principal: "bounded"},
      version: version
    )
  end

  defp start_server(opts) do
    {:ok, server} =
      DynamicSupervisor.start_child(
        AttestoMCP.Server.DynamicSupervisor,
        {Server, opts}
      )

    on_exit(fn ->
      DynamicSupervisor.terminate_child(AttestoMCP.Server.DynamicSupervisor, server)
    end)

    server
  end

  defp request(body, token) do
    conn(:post, "/mcp", body)
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("mcp-protocol-version", @version)
    |> put_req_header("mcp-method", "tools/call")
    |> put_req_header("mcp-name", "bounded")
  end

  defp plug(server, config, max_body_bytes, max_message_bytes) do
    Server.Plug.init(
      server: server,
      path: "/mcp",
      max_body_bytes: max_body_bytes,
      max_message_bytes: max_message_bytes,
      auth: [config: config, resource: @resource]
    )
  end
end
