defmodule AttestoMCP.Server.MessageLimitConsistencyTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AttestoMCP.Server
  alias AttestoMCP.Server.{Content, JSONRPC, Output, Result, Schema}

  @resource "https://mcp.example.com/mcp"
  @version "2026-07-28"
  @legacy "2025-11-25"
  @limit 2_048
  @large_budget 8_000_000

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

  test "configured JSON value budget accepts just below and exactly at its boundary" do
    below = String.duplicate("a", @limit - 3)
    exact = String.duplicate("a", @limit - 2)
    over = String.duplicate("a", @limit - 1)

    assert byte_size(Jason.encode!(below)) == @limit - 1
    assert byte_size(Jason.encode!(exact)) == @limit
    assert byte_size(Jason.encode!(over)) == @limit + 1

    assert :ok = Schema.json_value(below, max_bytes: @limit)
    assert :ok = Schema.json_value(exact, max_bytes: @limit)
    assert {:error, :not_json} = Schema.json_value(over, max_bytes: @limit)

    assert {:ok, ^below} = Output.canonicalize(below, max_bytes: @limit)
    assert {:ok, ^exact} = Output.canonicalize(exact, max_bytes: @limit)
    assert {:error, :not_json} = Output.canonicalize(over, max_bytes: @limit)
  end

  test "configured budget applies to large enum and const schema values" do
    value = String.duplicate("v", Schema.max_instance_bytes() + 100_000)
    schema_with_enum = %{"enum" => [value]}
    schema_with_const = %{"const" => value}

    assert :ok = Schema.validate(value, schema_with_enum, max_bytes: @large_budget)
    assert :ok = Schema.validate(value, schema_with_const, max_bytes: @large_budget)
    assert {:error, :not_json} = Schema.validate(value, schema_with_enum)
    assert {:error, :not_json} = Schema.validate(value, schema_with_const)
  end

  test "JSON-RPC fallback stays within the minimum budget and bounds oversized IDs" do
    min_budget = Schema.min_allowed_instance_bytes()

    message = %{
      "jsonrpc" => "2.0",
      "id" => String.duplicate("i", 256),
      "result" => String.duplicate("x", min_budget)
    }

    encoded = JSONRPC.encode(message, max_bytes: min_budget)
    decoded = Jason.decode!(encoded)

    assert byte_size(encoded) <= min_budget
    assert decoded["id"] == message["id"]
    assert decoded["error"]["code"] == -32603

    smaller = JSONRPC.encode(message, max_bytes: 300)
    assert byte_size(smaller) <= 300
    assert Jason.decode!(smaller)["id"] == nil

    assert_raise ArgumentError, ~r/max_json_bytes must be between/, fn ->
      Server.init(max_json_bytes: min_budget - 1)
    end
  end

  test "one configured byte budget governs HTTP, JSON-RPC, schema validation, and dispatch", %{
    config: config,
    server: _default_server
  } do
    server =
      start_server(
        max_json_bytes: @limit + 1,
        max_body_bytes: @limit + 1,
        max_message_bytes: @limit + 1
      )

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

  test "the default budget stays at 2 MB and finite overrides govern every transport", %{
    server: server
  } do
    too_large = Schema.max_instance_bytes() + 1

    assert_raise ArgumentError, ~r/JSON value budget/, fn ->
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

    large_server =
      start_server(
        max_json_bytes: @large_budget,
        max_body_bytes: @large_budget,
        max_message_bytes: @large_budget
      )

    assert %{server: ^large_server} =
             Server.Plug.init(
               server: large_server,
               path: "/mcp",
               max_body_bytes: @large_budget,
               max_message_bytes: @large_budget,
               auth: [issuer: "https://issuer.example", resource: @resource]
             )

    assert :ok =
             Server.Stdio.run(large_server,
               input: fn -> :eof end,
               max_message_bytes: @large_budget
             )

    assert_raise ArgumentError, ~r/JSON value budget/, fn ->
      Server.Plug.init(
        server: large_server,
        path: "/mcp",
        max_message_bytes: @large_budget + 1,
        auth: [issuer: "https://issuer.example", resource: @resource]
      )
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

    for invalid <- [0, -1, Schema.max_allowed_instance_bytes() + 1] do
      assert_raise ArgumentError, ~r/max_json_bytes must be between/, fn ->
        Server.init(max_json_bytes: invalid)
      end
    end
  end

  test "raising the JSON budget does not silently raise HTTP input defaults", %{
    config: config,
    server: _default_server
  } do
    server =
      start_server(
        max_json_bytes: @large_budget,
        max_body_bytes: nil,
        max_message_bytes: nil
      )

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
                 send(owner, {:handled_with_default_limits, byte_size(payload)})
                 {:ok, "accepted"}
               end
             })

    token =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [AttestoMCP.Scopes.tools_call()],
        audience: @resource
      )

    plug =
      Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource]
      )

    message_over_default = request_body(1_000_001)

    message_response =
      message_over_default
      |> request(token)
      |> Server.Plug.call(plug)

    assert get_in(Jason.decode!(message_response.resp_body), ["error", "data", "reason"]) ==
             "message_too_large"

    body_over_default = request_body(2_000_001)

    body_response =
      body_over_default
      |> request(token)
      |> Server.Plug.call(plug)

    assert get_in(Jason.decode!(body_response.resp_body), ["error", "data", "reason"]) ==
             "body_too_large"

    refute_receive {:handled_with_default_limits, _}

    smaller_server = start_server(max_json_bytes: 1_500_000)

    smaller_plug =
      Server.Plug.init(
        server: smaller_server,
        path: "/mcp",
        auth: [config: config, resource: @resource]
      )

    smaller_budget_response =
      request_body(1_500_001)
      |> request(token)
      |> Server.Plug.call(smaller_plug)

    assert get_in(Jason.decode!(smaller_budget_response.resp_body), [
             "error",
             "data",
             "reason"
           ]) == "body_too_large"

    for key <- [:max_body_bytes, :max_message_bytes] do
      assert_raise ArgumentError, ~r/#{key} cannot exceed/, fn ->
        Server.init([max_json_bytes: 1_500_000] ++ [{key, 1_500_001}])
      end
    end
  end

  test "server initialization rejects non-integer max_json_bytes values" do
    for invalid <- ["2048", 2.5] do
      assert_raise ArgumentError, ~r/:max_json_bytes must be between/, fn ->
        Server.init(max_json_bytes: invalid)
      end
    end
  end

  test "configured 8 MB budget accepts authenticated schema input and resource output above 2 MB",
       %{config: config} do
    server =
      start_server(
        max_json_bytes: @large_budget,
        max_body_bytes: @large_budget,
        max_message_bytes: @large_budget
      )

    owner = self()

    assert :ok =
             Server.register_tool(server, "large-input", %{
               input_schema: %{
                 "type" => "object",
                 "properties" => %{"payload" => %{"type" => "string"}},
                 "required" => ["payload"],
                 "additionalProperties" => false
               },
               handler: fn %{"payload" => payload}, _context ->
                 send(owner, {:large_input_handled, byte_size(payload)})
                 {:ok, "accepted"}
               end
             })

    tool_token =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [AttestoMCP.Scopes.tools_call()],
        audience: @resource
      )

    large_input = String.duplicate("a", Schema.max_instance_bytes() + 100_000)

    tool_body =
      payload_for("large-input", large_input)
      |> Jason.encode!()

    assert byte_size(tool_body) > Schema.max_instance_bytes()
    assert byte_size(tool_body) < @large_budget

    tool_response =
      tool_body
      |> request(tool_token, "tools/call", "large-input")
      |> Server.Plug.call(plug(server, config, @large_budget, @large_budget))

    assert tool_response.status == 200
    assert %{"result" => %{"isError" => false}} = Jason.decode!(tool_response.resp_body)
    assert_receive {:large_input_handled, input_bytes}
    assert input_bytes > Schema.max_instance_bytes()

    blob = Base.encode64(:binary.copy(<<0>>, 1_600_000))

    resource_result =
      "urn:large-resource"
      |> Content.resource_blob(blob, max_json_bytes: @large_budget)
      |> Result.resource(max_json_bytes: @large_budget)

    assert IO.iodata_length(Jason.encode_to_iodata!(resource_result)) >
             Schema.max_instance_bytes()

    assert :ok =
             Server.register_resource(server, "urn:large-resource", %{
               handler: fn _input, _context -> {:ok, resource_result} end
             })

    resource_token =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [AttestoMCP.Scopes.resources_read()],
        audience: @resource
      )

    resource_body =
      %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "resources/read",
        "params" => modern(%{"uri" => "urn:large-resource"})
      }
      |> Jason.encode!()

    resource_response =
      resource_body
      |> request(resource_token, "resources/read", "urn:large-resource")
      |> Server.Plug.call(plug(server, config, @large_budget, @large_budget))

    assert resource_response.status == 200, resource_response.resp_body

    assert %{
             "result" => %{
               "contents" => [%{"uri" => "urn:large-resource", "blob" => ^blob}]
             }
           } = Jason.decode!(resource_response.resp_body)
  end

  test "configured budget validates large server and legacy client capabilities" do
    padding = String.duplicate("c", Schema.max_instance_bytes() + 100_000)
    capabilities = %{"experimental" => %{"padding" => padding}}

    {:ok, server} =
      Server.start_link(
        max_json_bytes: @large_budget,
        capabilities: capabilities
      )

    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    assert Server.options(server)[:capabilities] == capabilities

    assert {1, %{"result" => %{"protocolVersion" => @legacy}}} =
             Server.dispatch(
               server,
               %{
                 kind: :request,
                 id: 1,
                 method: "initialize",
                 params: %{
                   "protocolVersion" => @legacy,
                   "capabilities" => capabilities,
                   "clientInfo" => %{"name" => "bounded", "version" => "1"}
                 }
               },
               %{principal: "bounded"},
               version: @legacy
             )
  end

  test "configured budget reaches registry startup, registration, and replacement schemas", %{
    server: default_server
  } do
    const_value = String.duplicate("s", Schema.max_instance_bytes() + 100_000)

    input_schema = %{
      "type" => "object",
      "properties" => %{"value" => %{"const" => const_value}}
    }

    assert byte_size(Jason.encode!(input_schema)) > Schema.max_instance_bytes()
    assert byte_size(Jason.encode!(input_schema)) < @large_budget

    registration = {:tool, "startup-large-schema", %{input_schema: input_schema}}

    {:ok, startup_server} =
      Server.start_link(
        max_json_bytes: @large_budget,
        registrations: [registration]
      )

    on_exit(fn -> stop_if_running(startup_server) end)

    assert [%{name: "startup-large-schema"}] =
             Server.snapshot(startup_server).tool |> Map.values()

    {:ok, dynamic_server} = Server.start_link(max_json_bytes: @large_budget)
    on_exit(fn -> stop_if_running(dynamic_server) end)

    assert :ok =
             Server.register_tool(dynamic_server, "dynamic-large-schema", %{
               input_schema: input_schema
             })

    assert :ok =
             Server.replace_catalog(dynamic_server, [
               {:tool, "replacement-large-schema", %{input_schema: input_schema}}
             ])

    assert [%{name: "replacement-large-schema"}] =
             Server.snapshot(dynamic_server).tool |> Map.values()

    assert {:error, _reason} =
             Server.register_tool(default_server, "default-large-schema", %{
               input_schema: input_schema
             })
  end

  test "registry restart preserves the configured schema budget" do
    const_value = String.duplicate("r", Schema.max_instance_bytes() + 100_000)
    input_schema = %{"type" => "object", "properties" => %{"value" => %{"const" => const_value}}}
    {:ok, server} = Server.start_link(max_json_bytes: @large_budget)
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    assert :ok =
             Server.register_tool(server, "restart-large-schema", input_schema: input_schema)

    old_registry = :sys.get_state(server).registry
    Process.exit(old_registry, :kill)

    new_registry =
      Enum.reduce_while(1..100, nil, fn _, _acc ->
        registry = :sys.get_state(server).registry

        if registry != old_registry and is_pid(registry) and Process.alive?(registry) do
          {:halt, registry}
        else
          Process.sleep(10)
          {:cont, nil}
        end
      end)

    assert is_pid(new_registry)

    assert [%{name: "restart-large-schema"}] =
             Server.snapshot(server).tool |> Map.values()
  end

  test "named server budget is inherited by Plug and stdio adapters" do
    name = __MODULE__.BudgetServer

    {:ok, _server} =
      Server.start_link(
        name: name,
        max_json_bytes: @large_budget
      )

    on_exit(fn ->
      if Process.whereis(name), do: GenServer.stop(name)
    end)

    assert %{server: ^name} =
             Server.Plug.init(
               server: name,
               path: "/mcp",
               max_body_bytes: @large_budget,
               max_message_bytes: @large_budget,
               auth: [issuer: "https://issuer.example", resource: @resource]
             )

    assert :ok =
             Server.Stdio.run(name,
               input: fn -> :eof end,
               max_message_bytes: @large_budget
             )

    assert_raise ArgumentError, ~r/JSON value budget/, fn ->
      Server.Plug.init(
        server: name,
        path: "/mcp",
        max_message_bytes: @large_budget + 1,
        auth: [issuer: "https://issuer.example", resource: @resource]
      )
    end

    assert_raise ArgumentError, ~r/max_message_bytes must be between/, fn ->
      Server.Stdio.run(name, input: fn -> :eof end, max_message_bytes: @large_budget + 1)
    end
  end

  test "late-bound named Plug revalidates transport limits across server restarts", %{
    config: config
  } do
    name = __MODULE__.LateBoundBudgetServer

    on_exit(fn ->
      if Process.whereis(name), do: GenServer.stop(name)
    end)

    plug =
      Server.Plug.init(
        server: name,
        path: "/mcp",
        max_body_bytes: @large_budget,
        max_message_bytes: @large_budget,
        auth: [config: config, resource: @resource]
      )

    unavailable = conn(:get, "/mcp") |> Server.Plug.call(plug)
    assert unavailable.status == 503
    assert unavailable.resp_body == "service unavailable"

    {:ok, large_server} =
      Server.start_link(
        name: name,
        max_json_bytes: @large_budget
      )

    large_output = String.duplicate("o", Schema.max_instance_bytes() + 100_000)

    assert :ok =
             Server.register_tool(large_server, "late-large-output", %{
               handler: fn _arguments, _context -> {:ok, large_output} end
             })

    token =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [AttestoMCP.Scopes.tools_call()],
        audience: @resource
      )

    request_body =
      "late-large-output"
      |> payload_for("")
      |> Jason.encode!()

    response =
      request_body
      |> request(token, "tools/call", "late-large-output")
      |> Server.Plug.call(plug)

    assert response.status == 200
    assert byte_size(response.resp_body) > Schema.max_instance_bytes()

    assert get_in(Jason.decode!(response.resp_body), ["result", "content"]) == [
             %{"type" => "text", "text" => large_output}
           ]

    :ok = GenServer.stop(large_server)
    {:ok, _default_server} = Server.start_link(name: name)

    stale_state_response =
      request_body
      |> request(token, "tools/call", "late-large-output")
      |> Server.Plug.call(plug)

    assert stale_state_response.status == 503
    assert stale_state_response.resp_body == "service unavailable"

    assert_raise ArgumentError, ~r/JSON value budget/, fn ->
      Server.Plug.init(
        server: name,
        path: "/mcp",
        max_body_bytes: @large_budget,
        max_message_bytes: @large_budget,
        auth: [config: config, resource: @resource]
      )
    end
  end

  test "public notifications use the configured server value budget", %{server: default_server} do
    large_server = start_server(max_json_bytes: @large_budget)
    padding = String.duplicate("p", Schema.max_instance_bytes() + 100_000)

    notification = %{
      "type" => "resourceUpdated",
      "uri" => "urn:large-notification",
      "_meta" => %{"padding" => padding}
    }

    assert :ok = Server.publish(large_server, notification)
    assert {:error, :invalid_notification} = Server.publish(default_server, notification)
  end

  test "handler notifications use the configured server value budget" do
    {:ok, server} =
      Server.start_link(
        max_json_bytes: @large_budget,
        capabilities: %{"logging" => %{}}
      )

    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    owner = self()
    data = String.duplicate("d", Schema.max_instance_bytes() + 100_000)

    assert :ok =
             Server.register_tool(server, "large-notify", %{
               handler: fn _arguments, context ->
                 result =
                   context.notify.(%{
                     "jsonrpc" => "2.0",
                     "method" => "notifications/message",
                     "params" => %{"level" => "info", "data" => data}
                   })

                 send(owner, {:large_notify_result, result})
                 {:ok, "accepted"}
               end
             })

    params =
      modern(%{"name" => "large-notify", "arguments" => %{}})
      |> put_in(["_meta", "io.modelcontextprotocol/logLevel"], "info")

    assert {1, %{"result" => %{"resultType" => "complete"}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 1, method: "tools/call", params: params},
               %{principal: "bounded"},
               version: @version,
               on_event: fn event ->
                 send(owner, {:large_notification, event})
                 :ok
               end
             )

    assert_receive {:large_notify_result, :ok}
    assert_receive {:large_notification, %{"method" => "notifications/message"}}
  end

  test "stdio output honors its complete-frame budget" do
    {:ok, server} =
      Server.start_link(
        max_json_bytes: @large_budget,
        server_name: String.duplicate("n", 1_000)
      )

    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    {:ok, source} = Agent.start_link(fn -> 0 end)

    input = fn ->
      Agent.get_and_update(source, fn
        0 ->
          {Jason.encode!(%{
             "jsonrpc" => "2.0",
             "id" => 1,
             "method" => "initialize",
             "params" => %{
               "protocolVersion" => @legacy,
               "capabilities" => %{},
               "clientInfo" => %{"name" => "bounded", "version" => "1"}
             }
           }) <> "\n", 1}

        _ ->
          {:eof, 1}
      end)
    end

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = Server.Stdio.run(server, input: input, max_message_bytes: 512)
      end)

    assert byte_size(output) <= 512
    assert String.ends_with?(output, "\n")
    assert %{"id" => 1, "error" => %{"code" => -32603}} = Jason.decode!(output)
  end

  test "stdio preserves a normal response whose JSON is 511 bytes" do
    {:ok, text_size} = Agent.start_link(fn -> 0 end)
    {:ok, server} = Server.start_link([])
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    assert :ok =
             Server.register_tool(server, "exact-frame", %{
               handler: fn _arguments, _context ->
                 {:ok, String.duplicate("x", Agent.get(text_size, & &1))}
               end
             })

    request = %{
      kind: :request,
      id: 1,
      method: "tools/call",
      params: %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @version,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        },
        "name" => "exact-frame",
        "arguments" => %{}
      }
    }

    {1, response} = Server.dispatch(server, request, %{principal: "bounded"}, version: @version)
    response_bytes = byte_size(Jason.encode!(response))
    assert response_bytes < 511
    target_text_size = 511 - response_bytes
    :ok = Agent.update(text_size, fn _ -> target_text_size end)

    wire_request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => request.params
    }

    {:ok, input_state} = Agent.start_link(fn -> :request end)

    input = fn ->
      Agent.get_and_update(input_state, fn
        :request -> {Jason.encode!(wire_request) <> "\n", :eof}
        :eof -> {:eof, :eof}
      end)
    end

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok =
                 Server.Stdio.run(server,
                   context: %{principal: "bounded"},
                   input: input,
                   max_message_bytes: 512
                 )
      end)

    assert byte_size(output) == 512

    assert Jason.decode!(output)["result"]["content"] == [
             %{"type" => "text", "text" => String.duplicate("x", target_text_size)}
           ]
  end

  test "stdio input frame boundaries include the line-feed delimiter" do
    {:ok, server} = Server.start_link([])
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    base = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @legacy,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "bounded", "version" => "1"},
        "padding" => ""
      }
    }

    base_bytes = byte_size(Jason.encode!(base))

    exact_payload =
      base
      |> put_in(["params", "padding"], String.duplicate("x", 511 - base_bytes))
      |> Jason.encode!()

    over_payload =
      base
      |> put_in(["params", "padding"], String.duplicate("x", 512 - base_bytes))
      |> Jason.encode!()

    exact_wire = exact_payload <> "\n"
    over_wire = over_payload <> "\n"
    assert byte_size(exact_wire) == 512
    assert byte_size(over_wire) == 513

    exact_output =
      ExUnit.CaptureIO.capture_io(exact_wire, fn ->
        assert :ok = Server.Stdio.run(server, max_message_bytes: 512)
      end)

    assert byte_size(exact_output) <= 512
    assert String.ends_with?(exact_output, "\n")
    assert Jason.decode!(exact_output)["id"] == 1

    over_output =
      ExUnit.CaptureIO.capture_io(over_wire, fn ->
        assert :ok = Server.Stdio.run(server, max_message_bytes: 512)
      end)

    assert byte_size(over_output) <= 512
    assert String.ends_with?(over_output, "\n")

    assert get_in(Jason.decode!(over_output), ["error", "data", "reason"]) ==
             "message_too_large"
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

  test "server-owned result fields cannot push a constructor result over a configured bound" do
    server =
      start_server(
        max_json_bytes: @large_budget,
        max_body_bytes: @large_budget,
        max_message_bytes: @large_budget
      )

    text_bytes = @large_budget - 39

    result =
      String.duplicate("x", text_bytes)
      |> Content.text(max_json_bytes: @large_budget)
      |> Result.tool(max_json_bytes: @large_budget)

    assert IO.iodata_length(Jason.encode_to_iodata!(result)) == @large_budget

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
    payload_for("bounded", value)
  end

  defp payload_for(name, value) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{
        "name" => name,
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

  defp stop_if_running(server) do
    GenServer.stop(server)
  catch
    :exit, _reason -> :ok
  end

  defp request(body, token, method \\ "tools/call", name \\ "bounded") do
    request =
      conn(:post, "/mcp", body)
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", @version)
      |> put_req_header("mcp-method", method)

    if is_binary(name), do: put_req_header(request, "mcp-name", name), else: request
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
