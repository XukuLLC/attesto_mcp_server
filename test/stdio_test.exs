defmodule AttestoMCP.Server.StdioTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AttestoMCP.Server
  alias AttestoMCP.Server.Stdio

  defmodule FailInitializationStore do
    @moduledoc false
    @behaviour AttestoMCP.Server.SessionStore

    alias AttestoMCP.Server.SessionStore.ETS

    defdelegate save(store, key, record), to: ETS
    defdelegate load(store, key), to: ETS
    defdelegate delete(store, key), to: ETS
    defdelegate list_active(store), to: ETS
    defdelegate update_ttl(store, key, now), to: ETS
    defdelegate cleanup_expired(store), to: ETS

    def update(store, key, fun) do
      ETS.update(store, key, fn record ->
        case fun.(record) do
          {:ok, %{"initialized" => true}} -> {:error, :write_failed}
          result -> result
        end
      end)
    end
  end

  test "legacy stdio accepts a structured principal" do
    {:ok, server} = Server.start_link([])

    input =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "structured-principal", "version" => "1.0"}
        }
      }) <> "\n"

    principal = %URI{scheme: "https", host: "example.com", path: "/principal"}

    output =
      capture_io(input, fn ->
        assert :ok = Stdio.run(server, context: %{principal: principal})
      end)

    assert get_in(Jason.decode!(String.trim(output)), ["result", "protocolVersion"]) ==
             "2025-11-25"
  end

  test "legacy stdio stays uninitialized when durable initialization fails" do
    {:ok, store} = start_supervised(AttestoMCP.Server.SessionStore.ETS)

    {:ok, server} =
      start_supervised(
        {Server,
         session_store: {FailInitializationStore, store},
         session_namespace: "stdio-failed-initialization"}
      )

    input =
      [
        %{
          jsonrpc: "2.0",
          id: 1,
          method: "initialize",
          params: %{
            "protocolVersion" => "2025-11-25",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "failed-initialization", "version" => "1.0"}
          }
        },
        %{jsonrpc: "2.0", method: "notifications/initialized", params: %{}},
        %{jsonrpc: "2.0", id: 2, method: "tools/list", params: %{}}
      ]
      |> Enum.map_join("\n", &Jason.encode!/1)
      |> Kernel.<>("\n")

    output = capture_io(input, fn -> Stdio.run(server, principal: "stdio-write-failure") end)
    messages = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    assert Enum.find(messages, &(&1["id"] == 1))["result"]["protocolVersion"] == "2025-11-25"

    assert get_in(Enum.find(messages, &(&1["id"] == 2)), ["error", "data", "reason"]) ==
             "initialized_notification_required"
  end

  test "interleaves modern request IDs and drains workers at EOF" do
    {:ok, server} = Server.start_link(max_concurrency: 4)

    assert :ok =
             Server.register_tool(server, "slow", %{
               input_schema: %{"type" => "object"},
               handler: fn %{"delay" => delay}, _ ->
                 Process.sleep(delay)
                 {:ok, %{"delay" => delay}}
               end
             })

    metadata = %{
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities" => %{}
      },
      "name" => "slow"
    }

    input =
      [
        %{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: Map.put(metadata, "arguments", %{"delay" => 30})
        },
        %{
          jsonrpc: "2.0",
          id: 2,
          method: "tools/call",
          params: Map.put(metadata, "arguments", %{"delay" => 0})
        }
      ]
      |> Enum.map_join("\n", &Jason.encode!/1)
      |> Kernel.<>("\n")

    output = capture_io(input, fn -> Stdio.run(server, principal: "stdio-test") end)
    messages = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    assert Enum.map(messages, & &1["id"]) |> Enum.sort() == [1, 2]
  end

  test "stdio rejects missing modern envelope metadata as invalid params" do
    {:ok, server} = Server.start_link([])

    inputs =
      [
        %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{}},
        %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "initialize",
          "params" => %{"_meta" => %{"io.modelcontextprotocol/clientCapabilities" => %{}}}
        },
        %{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "initialize",
          "params" => %{
            "_meta" => %{"io.modelcontextprotocol/protocolVersion" => "2026-07-28"}
          }
        }
      ]

    {:ok, input_state} = Agent.start_link(fn -> inputs end)

    input = fn ->
      Agent.get_and_update(input_state, fn
        [] -> {:eof, []}
        [request | rest] -> {Jason.encode!(request) <> "\n", rest}
      end)
    end

    output = capture_io(fn -> Stdio.run(server, principal: "stdio-meta", input: input) end)

    messages = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.map(messages, & &1["id"]) |> Enum.sort() == [1, 2, 3]
    assert Enum.all?(messages, &(get_in(&1, ["error", "code"]) == -32602))
  end

  test "stdio rejects non-object metadata and continues serving later frames" do
    {:ok, server} = Server.start_link([])

    input =
      [
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"_meta" => 5}
        },
        %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "ping",
          "params" => %{"_meta" => ["invalid"]}
        },
        %{"jsonrpc" => "2.0", "id" => 3, "method" => "ping", "params" => %{}}
      ]
      |> Enum.map_join("\n", &Jason.encode!/1)
      |> Kernel.<>("\n")

    output = capture_io(input, fn -> Stdio.run(server, principal: "stdio-meta-scalar") end)
    messages = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    assert Enum.map(messages, & &1["id"]) |> Enum.sort() == [1, 2, 3]
    assert Enum.find(messages, &(&1["id"] == 1))["error"]["code"] == -32602
    assert Enum.find(messages, &(&1["id"] == 2))["error"]["code"] == -32602
    assert Enum.find(messages, &(&1["id"] == 3))["result"] == %{}
  end

  test "stdio rejects an unsupported legacy revision" do
    {:ok, server} = Server.start_link([])

    input =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 90,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-03-26",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "unsupported-client", "version" => "1.0"}
        }
      }) <> "\n"

    output = capture_io(input, fn -> Stdio.run(server, principal: "stdio-retired") end)
    [message] = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert message["id"] == 90
    assert message["error"]["code"] == -32022

    assert message["error"]["data"]["supported"] == ["2025-11-25", "2025-06-18"]
  end

  test "stdio reports an unsupported version for a legacy-shaped modern offer" do
    {:ok, server} = Server.start_link([])

    input =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 91,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2026-07-28",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "legacy-negotiator", "version" => "1.0"}
        }
      }) <> "\n"

    output = capture_io(input, fn -> Stdio.run(server, principal: "stdio-negotiator") end)
    [message] = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert message["error"]["code"] == -32022
    assert message["error"]["data"]["requested"] == "2026-07-28"

    assert message["error"]["data"]["supported"] == ["2025-11-25", "2025-06-18"]
  end

  test "stdio permits ping before legacy initialization" do
    {:ok, server} = Server.start_link([])

    input =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 93,
        "method" => "ping",
        "params" => %{}
      }) <> "\n"

    output = capture_io(input, fn -> Stdio.run(server, principal: "stdio-preinitialize") end)
    [message] = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert message == %{"jsonrpc" => "2.0", "id" => 93, "result" => %{}}
  end

  test "stdio rejects 2025-06-18 in a modern metadata envelope" do
    {:ok, server} = Server.start_link([])

    input =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 92,
        "method" => "initialize",
        "params" => %{
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => "2025-06-18",
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }
        }
      }) <> "\n"

    output = capture_io(input, fn -> Stdio.run(server, principal: "stdio-envelope") end)
    [message] = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert message["error"]["code"] == -32022

    assert message["error"]["data"]["supported"] == [
             "2026-07-28",
             "2025-11-25",
             "2025-06-18"
           ]
  end

  test "stdio cannot renegotiate an initialized session" do
    {:ok, server} = Server.start_link([])

    lines = [
      {0,
       %{
         "jsonrpc" => "2.0",
         "id" => 1,
         "method" => "initialize",
         "params" => %{
           "protocolVersion" => "2025-06-18",
           "capabilities" => %{"elicitation" => %{}},
           "clientInfo" => %{"name" => "stdio-renegotiation", "version" => "1.0"}
         }
       }},
      {500, %{"jsonrpc" => "2.0", "method" => "notifications/initialized", "params" => %{}}},
      {500,
       %{
         "jsonrpc" => "2.0",
         "id" => 2,
         "method" => "initialize",
         "params" => %{
           "protocolVersion" => "2025-11-25",
           "capabilities" => %{},
           "clientInfo" => %{"name" => "stdio-renegotiation", "version" => "1.0"}
         }
       }}
    ]

    {:ok, source} = Agent.start_link(fn -> lines end)

    input = fn ->
      Agent.get_and_update(source, fn
        [{delay, line} | rest] ->
          Process.sleep(delay)
          {Jason.encode!(line) <> "\n", rest}

        [] ->
          {:eof, []}
      end)
    end

    output =
      capture_io(fn -> Stdio.run(server, principal: "stdio-renegotiation", input: input) end)

    messages = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    assert Enum.find(messages, &(&1["id"] == 1))["result"]["protocolVersion"] ==
             "2025-06-18"

    renegotiation = Enum.find(messages, &(&1["id"] == 2))
    assert renegotiation["error"]["code"] == -32600
    assert renegotiation["error"]["data"]["reason"] == "initialize_session_rejected"
  end

  test "modern stdio subscription cancels explicitly without affecting an interleaved request" do
    {:ok, server} = Server.start_link(max_concurrency: 4)

    assert :ok =
             Server.register_tool(server, "echo", %{
               input_schema: %{"type" => "object"},
               handler: fn arguments, _ ->
                 Process.sleep(50)
                 {:ok, arguments}
               end
             })

    request = %{
      jsonrpc: "2.0",
      id: 50,
      method: "subscriptions/listen",
      params: %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        },
        "notifications" => %{"toolsListChanged" => true}
      }
    }

    call = %{
      jsonrpc: "2.0",
      id: 51,
      method: "tools/call",
      params: %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        },
        "name" => "echo",
        "arguments" => %{"value" => "interleaved"}
      }
    }

    cancellation = %{
      jsonrpc: "2.0",
      method: "notifications/cancelled",
      params: %{"requestId" => 50}
    }

    {:ok, step} = Agent.start_link(fn -> 0 end)

    input = fn ->
      case Agent.get_and_update(step, fn
             0 -> {Jason.encode!(request) <> "\n", 1}
             1 -> {:delay_call, 2}
             2 -> {:delay_cancel, 3}
             3 -> {:eof, 3}
           end) do
        :delay_call ->
          Process.sleep(80)
          Jason.encode!(call) <> "\n"

        :delay_cancel ->
          Process.sleep(1)
          Jason.encode!(cancellation) <> "\n"

        value ->
          value
      end
    end

    # The callback pauses between the listen, the interleaved call, and the
    # targeted cancellation so the subscription remains live while the call runs.
    output =
      capture_io(fn ->
        Stdio.run(server, principal: "stdio-subscription", input: input)
      end)

    messages = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.at(messages, 0)["method"] == "notifications/subscriptions/acknowledged"
    assert Enum.any?(messages, &(&1["id"] == 50))
    assert Enum.any?(messages, &(&1["id"] == 51))

    assert Enum.find_index(messages, &(&1["id"] == 50)) <
             Enum.find_index(messages, &(&1["id"] == 51))

    final = Enum.find(messages, &(&1["id"] == 50))
    assert get_in(final, ["result", "resultType"]) == "complete"
  end

  @tag :t25_catalog_invalidation_stdio
  test "stdio subscription receives registry catalog invalidation" do
    {:ok, server} = Server.start_link(max_concurrency: 4)
    parent = self()

    request = %{
      jsonrpc: "2.0",
      id: 70,
      method: "subscriptions/listen",
      params: %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        },
        "notifications" => %{"toolsListChanged" => true}
      }
    }

    {:ok, step} = Agent.start_link(fn -> 0 end)

    input = fn ->
      reader_pid = self()

      case Agent.get_and_update(step, fn
             0 ->
               {Jason.encode!(request) <> "\n", 1}

             1 ->
               send(parent, {:stdio_input_waiting, reader_pid})
               {:wait, 2}

             2 ->
               {:wait, 2}
           end) do
        :wait ->
          receive do
            :continue -> :eof
            {:line, line} -> line
          end

        value ->
          value
      end
    end

    runner =
      spawn(fn ->
        output =
          capture_io(fn ->
            Stdio.run(server, principal: "stdio-catalog", input: input)
          end)

        send(parent, {:stdio_catalog_output, output})
      end)

    assert_receive {:stdio_input_waiting, input_pid}, 1_000
    Process.sleep(100)

    assert :ok =
             Server.register_tool(server, "stdio_registered", %{
               handler: fn _, _ -> {:ok, "ok"} end
             })

    Process.sleep(300)

    cancellation =
      Jason.encode!(%{
        jsonrpc: "2.0",
        method: "notifications/cancelled",
        params: %{"requestId" => 70}
      }) <> "\n"

    send(input_pid, {:line, cancellation})
    send(input_pid, :continue)

    assert_receive {:stdio_catalog_output, output}, 2_000
    messages = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.at(messages, 0)["method"] == "notifications/subscriptions/acknowledged"
    assert Enum.any?(messages, &(&1["method"] == "notifications/tools/list_changed"))
    assert Enum.any?(messages, &(&1["id"] == 70))
    refute Process.alive?(runner)
  end

  test "an unknown stdio cancellation cannot cancel another owner's subscription" do
    {:ok, server} = Server.start_link(max_concurrency: 4)
    parent = self()

    params = %{
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities" => %{}
      },
      "notifications" => %{"toolsListChanged" => true}
    }

    assert {88, %{"result" => %{"resultType" => "complete"}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 88, method: "subscriptions/listen", params: params},
               %{principal: "subscription-owner"},
               version: "2026-07-28",
               on_event: fn event -> send(parent, {:owned_subscription_event, event}) end
             )

    assert_receive {:owned_subscription_event,
                    %{"method" => "notifications/subscriptions/acknowledged"}}

    cancellation =
      Jason.encode!(%{
        jsonrpc: "2.0",
        method: "notifications/cancelled",
        params: %{"requestId" => 88}
      }) <> "\n"

    assert "" ==
             capture_io(cancellation, fn ->
               Stdio.run(server, principal: "unrelated-stdio-client")
             end)

    refute_receive {:mcp_subscription_cancel, 88}, 25
    assert :ok = Server.publish(server, %{"type" => "toolsListChanged"})

    assert_receive {:mcp_subscription, _tag, 88,
                    %{"method" => "notifications/tools/list_changed"}}

    assert :ok = Server.close_subscription(server, 88)
    refute_receive {:mcp_subscription_close, 88}, 25
  end

  test "legacy stdio negotiates initialize before interleaved requests" do
    {:ok, server} = Server.start_link(max_concurrency: 4)

    assert :ok =
             Server.register_tool(server, "legacy_echo", %{
               input_schema: %{"type" => "object"},
               handler: fn arguments, _ -> {:ok, arguments} end
             })

    input =
      [
        %{
          jsonrpc: "2.0",
          id: 1,
          method: "initialize",
          params: %{
            "protocolVersion" => "2025-11-25",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "stdio-test", "version" => "1.0"}
          }
        },
        %{jsonrpc: "2.0", method: "notifications/initialized", params: %{}},
        %{
          jsonrpc: "2.0",
          id: 2,
          method: "tools/call",
          params: %{"name" => "legacy_echo", "arguments" => %{"value" => 2}}
        },
        %{jsonrpc: "2.0", id: 3, method: "ping", params: %{}}
      ]
      |> Enum.map_join("\n", &Jason.encode!/1)
      |> Kernel.<>("\n")

    output = capture_io(input, fn -> Stdio.run(server, principal: "stdio-legacy") end)
    messages = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    assert Enum.map(messages, & &1["id"]) |> Enum.filter(&(&1 != nil)) |> Enum.sort() == [1, 2, 3]
    assert Enum.find(messages, &(&1["id"] == 1))["result"]["protocolVersion"] == "2025-11-25"
  end

  test "rejected legacy stdio subscriptions do not refresh the session idle timer" do
    {:ok, server} = Server.start_link(session_idle_timeout: 500)

    lines = [
      {0,
       %{
         jsonrpc: "2.0",
         id: 1,
         method: "initialize",
         params: %{
           "protocolVersion" => "2025-11-25",
           "capabilities" => %{},
           "clientInfo" => %{"name" => "stdio-subscription-bounds", "version" => "1.0"}
         }
       }},
      {100, %{jsonrpc: "2.0", method: "notifications/initialized", params: %{}}},
      {300,
       %{
         jsonrpc: "2.0",
         id: 2,
         method: "resources/subscribe",
         params: %{"uri" => "urn:" <> String.duplicate("x", 4_093)}
       }},
      {400, %{jsonrpc: "2.0", id: 3, method: "tools/list", params: %{}}}
    ]

    {:ok, source} = Agent.start_link(fn -> lines end)

    input = fn ->
      Agent.get_and_update(source, fn
        [{delay, message} | rest] ->
          Process.sleep(delay)
          {Jason.encode!(message) <> "\n", rest}

        [] ->
          {:eof, []}
      end)
    end

    output =
      capture_io(fn ->
        Stdio.run(server, principal: "stdio-subscription-bounds", input: input)
      end)

    messages = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    rejection = Enum.find(messages, &(&1["id"] == 2))
    assert rejection["error"]["data"]["reason"] == "invalid_resource_uri"

    expired_follow_up = Enum.find(messages, &(&1["id"] == 3))
    assert expired_follow_up["error"]["data"]["reason"] == "initialized_notification_required"
  end

  test "stdio completes a 2025-06-18 initialize, list, and call sequence" do
    {:ok, server} = Server.start_link(max_concurrency: 4)

    assert :ok =
             Server.register_tool(server, "compat_add", %{
               icons: [%{src: "https://example.test/icon.png"}],
               input_schema: %{
                 "type" => "object",
                 "properties" => %{
                   "left" => %{"type" => "integer"},
                   "right" => %{"type" => "integer"}
                 },
                 "required" => ["left", "right"]
               },
               handler: fn %{"left" => left, "right" => right}, _ ->
                 {:ok, Integer.to_string(left + right)}
               end
             })

    input =
      [
        %{
          jsonrpc: "2.0",
          id: 1,
          method: "initialize",
          params: %{
            "protocolVersion" => "2025-06-18",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "stdio-compat", "version" => "1.0"}
          }
        },
        %{jsonrpc: "2.0", method: "notifications/initialized", params: %{}},
        %{jsonrpc: "2.0", id: 2, method: "tools/list", params: %{}},
        %{
          jsonrpc: "2.0",
          id: 3,
          method: "tools/call",
          params: %{"name" => "compat_add", "arguments" => %{"left" => 34, "right" => -11}}
        }
      ]
      |> Enum.map_join("\n", &Jason.encode!/1)
      |> Kernel.<>("\n")

    output = capture_io(input, fn -> Stdio.run(server, principal: "stdio-compat") end)
    messages = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    assert Enum.find(messages, &(&1["id"] == 1))["result"]["protocolVersion"] == "2025-06-18"

    assert [%{"name" => "compat_add"} = tool] =
             Enum.find(messages, &(&1["id"] == 2))["result"]["tools"]

    refute Map.has_key?(tool, "icons")

    assert [%{"type" => "text", "text" => "23"}] =
             Enum.find(messages, &(&1["id"] == 3))["result"]["content"]
  end

  test "legacy stdio routes a typed server-originated sampling response" do
    {:ok, server} = Server.start_link(max_concurrency: 4)
    {:ok, request_agent} = Agent.start_link(fn -> nil end)

    assert :ok =
             Server.register_tool(server, "asks_client", %{
               input_schema: %{"type" => "object"},
               handler: fn _arguments, context ->
                 case context.client_request.("sampling/createMessage", %{"messages" => []}) do
                   {:ok, _response} -> {:ok, "completed"}
                   _ -> {:error, :client_request_failed}
                 end
               end
             })

    lines = [
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 10,
        method: "initialize",
        params: %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{"sampling" => %{}},
          "clientInfo" => %{"name" => "stdio-test", "version" => "1.0"}
        }
      }) <> "\n",
      Jason.encode!(%{jsonrpc: "2.0", method: "notifications/initialized", params: %{}}) <> "\n",
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 11,
        method: "tools/call",
        params: %{"name" => "asks_client", "arguments" => %{}}
      }) <> "\n"
    ]

    {:ok, step} = Agent.start_link(fn -> 0 end)

    input = fn ->
      case Agent.get_and_update(step, fn
             0 -> {Enum.at(lines, 0), 1}
             1 -> {Enum.at(lines, 1), 2}
             2 -> {Enum.at(lines, 2), 3}
             3 -> {await_stdio_response(request_agent), 4}
             4 -> {:eof, 4}
           end) do
        value -> value
      end
    end

    output =
      capture_io(fn ->
        Stdio.run(
          server,
          principal: "stdio-client",
          input: input,
          on_server_request: fn event -> Agent.update(request_agent, fn _ -> event end) end
        )
      end)

    messages = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    request = Enum.find(messages, &(&1["method"] == "sampling/createMessage"))
    assert is_map(request)
    assert Enum.any?(messages, &(&1["id"] == 10))
    assert Enum.any?(messages, &(&1["id"] == 11))
    assert Enum.find(messages, &(&1["id"] == 11))["result"]["resultType"] == nil
  end

  test "legacy stdio interleaves typed sampling, elicitation, and roots responses" do
    {:ok, server} = Server.start_link(max_concurrency: 6, client_request_timeout: 100)
    request_agent = start_supervised!({Agent, fn -> [] end})
    parent = self()

    tools = [
      {"stdio_sample", "sampling/createMessage", %{"messages" => []}},
      {"stdio_elicit", "elicitation/create", %{"message" => "confirm"}},
      {"stdio_roots", "roots/list", %{}}
    ]

    Enum.each(tools, fn {name, method, params} ->
      assert :ok =
               Server.register_tool(server, name, %{
                 input_schema: %{"type" => "object"},
                 handler: fn _arguments, context ->
                   result = context.client_request.(method, params)
                   send(parent, {:stdio_handler_result, name, result})
                   {:ok, "done"}
                 end
               })
    end)

    lines = [
      %{
        jsonrpc: "2.0",
        id: 30,
        method: "initialize",
        params: %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{"sampling" => %{}, "elicitation" => %{}, "roots" => %{}},
          "clientInfo" => %{"name" => "stdio-test", "version" => "1.0"}
        }
      },
      %{jsonrpc: "2.0", method: "notifications/initialized", params: %{}},
      %{
        jsonrpc: "2.0",
        id: 31,
        method: "tools/call",
        params: %{"name" => "stdio_sample", "arguments" => %{}}
      },
      %{
        jsonrpc: "2.0",
        id: 32,
        method: "tools/call",
        params: %{"name" => "stdio_elicit", "arguments" => %{}}
      },
      %{
        jsonrpc: "2.0",
        id: 33,
        method: "tools/call",
        params: %{"name" => "stdio_roots", "arguments" => %{}}
      }
    ]

    {:ok, step} = Agent.start_link(fn -> 0 end)

    input = fn ->
      case Agent.get_and_update(step, fn
             index when index < length(lines) ->
               {Jason.encode!(Enum.at(lines, index)) <> "\n", index + 1}

             5 ->
               {:response, 6}

             6 ->
               {:response, 7}

             7 ->
               {:response, 8}

             _ ->
               {:eof, 8}
           end) do
        :response -> await_typed_stdio_response(request_agent)
        value -> value
      end
    end

    output =
      capture_io(fn ->
        Stdio.run(
          server,
          principal: "stdio-typed",
          input: input,
          on_server_request: fn event -> Agent.update(request_agent, &(&1 ++ [event])) end
        )
      end)

    messages = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.count(messages, &(&1["method"] == "sampling/createMessage")) == 1
    assert Enum.count(messages, &(&1["method"] == "elicitation/create")) == 1
    assert Enum.count(messages, &(&1["method"] == "roots/list")) == 1
    assert_receive {:stdio_handler_result, "stdio_sample", {:ok, %{"role" => "assistant"}}}, 1_000
    assert_receive {:stdio_handler_result, "stdio_elicit", {:ok, %{"action" => "accept"}}}, 1_000
    assert_receive {:stdio_handler_result, "stdio_roots", {:ok, %{"roots" => [_]}}}, 1_000
  end

  defp await_typed_stdio_response(agent) do
    case Agent.get_and_update(agent, fn
           [event | rest] -> {{:event, event}, rest}
           [] -> {:wait, []}
         end) do
      {:event, event} ->
        result =
          case event["method"] do
            "sampling/createMessage" ->
              %{
                "role" => "assistant",
                "content" => %{"type" => "text", "text" => "ok"},
                "model" => "stdio-model",
                "stopReason" => "endTurn"
              }

            "elicitation/create" ->
              %{"action" => "accept", "content" => %{"answer" => "yes"}}

            "roots/list" ->
              %{"roots" => [%{"uri" => "file:///workspace", "name" => "workspace"}]}
          end

        Jason.encode!(%{jsonrpc: "2.0", id: event["id"], result: result}) <> "\n"

      :wait ->
        Process.sleep(5)
        await_typed_stdio_response(agent)
    end
  end

  defp await_stdio_response(agent) do
    case Agent.get(agent, & &1) do
      nil ->
        Process.sleep(10)
        await_stdio_response(agent)

      event ->
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: event["id"],
          result: %{
            "role" => "assistant",
            "content" => %{"type" => "text", "text" => "ok"},
            "model" => "stdio-model",
            "stopReason" => "endTurn"
          }
        }) <> "\n"
    end
  end
end
