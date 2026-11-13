defmodule AttestoMCP.Server.StdioTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AttestoMCP.Server
  alias AttestoMCP.Server.Stdio

  def telemetry_handler(event, measurements, metadata, parent) do
    send(parent, {:telemetry_event, event, measurements, metadata})
  end

  defmodule ErrorReplyServer do
    @moduledoc false
    use GenServer

    def start_link(reason), do: GenServer.start_link(__MODULE__, reason)

    @impl true
    def init(reason), do: {:ok, reason}

    @impl true
    def handle_call(:options, _from, reason),
      do: {:reply, [max_json_bytes: 1_000_000], reason}

    @impl true
    def handle_call({:new_session, _principal, _tenant, _opts}, _from, reason),
      do: {:reply, {:error, reason}, reason}
  end

  defmodule RecoveringReadinessStore do
    @moduledoc false
    @behaviour AttestoMCP.Server.SessionStore

    alias AttestoMCP.Server.SessionStore.ETS

    @impl true
    def save(store, key, record), do: ETS.save(store.ets, key, record)

    @impl true
    def delete(store, key), do: ETS.delete(store.ets, key)

    @impl true
    def list_active(store), do: ETS.list_active(store.ets)

    @impl true
    def update_ttl(store, key, now), do: ETS.update_ttl(store.ets, key, now)

    @impl true
    def update(store, key, fun), do: ETS.update(store.ets, key, fun)

    @impl true
    def cleanup_expired(store), do: ETS.cleanup_expired(store.ets)

    @impl true
    def load(store, key) do
      case Agent.get_and_update(store.first_load, fn
             true -> {:unavailable, false}
             false -> {:available, false}
           end) do
        :unavailable -> {:error, :session_store_unavailable}
        :available -> ETS.load(store.ets, key)
      end
    end
  end

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

  test "stdio startup maps an unrecognized session error to a neutral tuple" do
    {:ok, server} = ErrorReplyServer.start_link({:private_failure, "do not expose"})

    assert {:error, :session_store_unavailable} =
             Stdio.run(server, input: fn -> :eof end)
  end

  test "stdio startup reports the configured per-principal session limit" do
    {:ok, server} = Server.start_link(max_sessions_per_principal: 1)
    assert {:ok, _session} = Server.new_session(server, "bounded-principal")

    assert {:error, :session_limit} =
             Stdio.run(server, principal: "bounded-principal", input: fn -> :eof end)
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

  test "legacy stdio pins a readiness outage through dispatch after store recovery" do
    parent = self()
    ets = start_supervised!(AttestoMCP.Server.SessionStore.ETS)
    first_load = start_supervised!({Agent, fn -> true end})

    {:ok, server} =
      Server.start_link(
        session_store: {RecoveringReadinessStore, %{ets: ets, first_load: first_load}},
        scope_map: %{"tools/call" => ["stdio.call"]}
      )

    assert :ok =
             Server.register_tool(server, "should_not_run", %{
               input_schema: %{"type" => "object"},
               handler: fn _arguments, _context ->
                 send(parent, :stdio_handler_dispatched)
                 {:ok, %{}}
               end
             })

    input =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 2,
        method: "tools/call",
        params: %{"name" => "should_not_run", "arguments" => %{}}
      }) <> "\n"

    output =
      capture_io(input, fn ->
        Stdio.run(
          server,
          context: %{principal: "stdio-readiness", scopes: ["stdio.call"]}
        )
      end)

    messages = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    rejection = Enum.find(messages, &(&1["id"] == 2))
    assert rejection["error"]["data"]["reason"] == "session_store_unavailable"
    refute_received :stdio_handler_dispatched
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

    output =
      capture_io(input, fn ->
        Stdio.run(server, principal: "stdio-test", eof_grace_ms: 1_000)
      end)

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
        Stdio.run(server,
          principal: "stdio-subscription",
          input: input,
          eof_grace_ms: 1_000
        )
      end)

    messages = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.at(messages, 0)["method"] == "notifications/subscriptions/acknowledged"
    assert Enum.any?(messages, &(&1["id"] == 50))
    assert Enum.any?(messages, &(&1["id"] == 51))

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
            Stdio.run(server,
              principal: "stdio-catalog",
              scopes: [AttestoMCP.Scopes.tools_read()],
              input: input
            )
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

  test "events do not extend a stdio subscription past subscription_timeout" do
    {:ok, server} = Server.start_link(max_concurrency: 4)
    parent = self()
    handler_id = {__MODULE__, :stdio_deadline, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:attesto_mcp_server, :subscription, :open],
          [:attesto_mcp_server, :subscription, :close]
        ],
        &__MODULE__.telemetry_handler/4,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    request = %{
      jsonrpc: "2.0",
      id: 72,
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

    # The reader gives up after five seconds, so a failed test leaves no
    # blocked reader behind.
    input = fn ->
      case Agent.get_and_update(step, fn
             0 -> {Jason.encode!(request) <> "\n", 1}
             1 -> {:wait, 2}
             2 -> {:eof, 2}
           end) do
        :wait ->
          send(parent, {:stdio_input_waiting, self()})

          receive do
            :continue -> :eof
          after
            5_000 -> :eof
          end

        value ->
          value
      end
    end

    started = System.monotonic_time(:millisecond)

    runner =
      spawn(fn ->
        output =
          capture_io(fn ->
            Stdio.run(server,
              principal: "stdio-deadline",
              scopes: [AttestoMCP.Scopes.tools_read()],
              input: input,
              subscription_timeout: 500
            )
          end)

        send(parent, {:stdio_deadline_output, output})
      end)

    on_exit(fn -> Process.exit(runner, :kill) end)
    runner_monitor = Process.monitor(runner)

    assert_receive {:telemetry_event, [:attesto_mcp_server, :subscription, :open], _, _}, 1_000
    publisher = publish_tools_list_changed_every(server, 5)

    # An event every 5 ms used to restart the 500 ms timeout, so the
    # subscription stayed open for as long as events arrived.
    assert_receive {:telemetry_event, [:attesto_mcp_server, :subscription, :close], _, _}, 3_000
    assert System.monotonic_time(:millisecond) - started >= 500

    assert_receive {:stdio_input_waiting, input_pid}, 1_000
    send(input_pid, :continue)
    assert_receive {:stdio_deadline_output, output}, 2_000
    stop_publisher(publisher)

    messages = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert hd(messages)["method"] == "notifications/subscriptions/acknowledged"

    assert Enum.count(messages, &(&1["method"] == "notifications/tools/list_changed")) >= 2

    assert List.last(messages)["id"] == 72
    assert get_in(List.last(messages), ["result", "resultType"]) == "complete"
    assert_receive {:DOWN, ^runner_monitor, :process, ^runner, :normal}, 1_000
  end

  test "a stdio subscription event the writer reaches after the deadline is not written" do
    {:ok, server} = Server.start_link(max_concurrency: 4)
    parent = self()
    handler_id = {__MODULE__, :stdio_late_event, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:attesto_mcp_server, :subscription, :open],
          [:attesto_mcp_server, :subscription, :close]
        ],
        &__MODULE__.telemetry_handler/4,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    request = %{
      jsonrpc: "2.0",
      id: 73,
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
      case Agent.get_and_update(step, fn
             0 -> {Jason.encode!(request) <> "\n", 1}
             1 -> {:wait, 2}
             2 -> {:eof, 2}
           end) do
        :wait ->
          send(parent, {:stdio_input_waiting, self()})

          receive do
            :continue -> :eof
          after
            5_000 -> :eof
          end

        value ->
          value
      end
    end

    started = System.monotonic_time(:millisecond)

    runner =
      spawn(fn ->
        output =
          capture_io(fn ->
            Stdio.run(server,
              principal: "stdio-late-event",
              scopes: [AttestoMCP.Scopes.tools_read()],
              input: input,
              subscription_timeout: 1_000
            )
          end)

        send(parent, {:stdio_late_event_output, output})
      end)

    on_exit(fn -> Process.exit(runner, :kill) end)
    on_exit(fn -> resume_quietly(runner) end)
    runner_monitor = Process.monitor(runner)
    assert_receive {:telemetry_event, [:attesto_mcp_server, :subscription, :open], _, _}, 1_000
    assert_receive {:stdio_input_waiting, input_pid}, 1_000

    # The writer is descheduled while the worker hands it an event, and resumes
    # only after the worker's deadline has closed the subscription.
    assert :ok = await_waiting_in(runner, {AttestoMCP.Server.Stdio, :loop, 7})
    :erlang.suspend_process(runner)
    assert :ok = Server.publish(server, %{"type" => "toolsListChanged"})

    assert :ok =
             await_message_queued(runner, fn
               {:stdio_subscription_event, _, 73,
                %{"method" => "notifications/tools/list_changed"}} ->
                 true

               {:stdio_event, _, %{"method" => "notifications/tools/list_changed"}} ->
                 true

               _ ->
                 false
             end)

    assert System.monotonic_time(:millisecond) - started < 1_000
    assert_receive {:telemetry_event, [:attesto_mcp_server, :subscription, :close], _, _}, 3_000
    :erlang.resume_process(runner)

    send(input_pid, :continue)
    assert_receive {:stdio_late_event_output, output}, 2_000

    messages = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    assert Enum.map(messages, &(&1["method"] || &1["id"])) == [
             "notifications/subscriptions/acknowledged",
             73
           ]

    assert_receive {:DOWN, ^runner_monitor, :process, ^runner, :normal}, 1_000
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
               %{
                 principal: "subscription-owner",
                 scopes: [AttestoMCP.Scopes.tools_read()]
               },
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
    {:ok, store} = start_supervised(AttestoMCP.Server.SessionStore.ETS)
    namespace = "stdio-subscription-bounds"

    {:ok, server} =
      Server.start_link(
        session_store: {AttestoMCP.Server.SessionStore.ETS, store},
        session_namespace: namespace,
        session_idle_timeout: 500
      )

    lines = [
      {fn -> :ok end,
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
      {fn -> await_durable_session(store, namespace, &(&1.version == "2025-11-25")) end,
       %{jsonrpc: "2.0", method: "notifications/initialized", params: %{}}},
      {fn -> await_durable_session(store, namespace, & &1.initialized) end,
       %{
         jsonrpc: "2.0",
         id: 2,
         method: "resources/subscribe",
         params: %{"uri" => "urn:" <> String.duplicate("x", 4_093)}
       }},
      {fn -> Process.sleep(800) end, %{jsonrpc: "2.0", id: 3, method: "tools/list", params: %{}}}
    ]

    {:ok, source} = Agent.start_link(fn -> lines end)

    input = fn ->
      Agent.get_and_update(source, fn
        [{before_read, message} | rest] ->
          before_read.()
          {Jason.encode!(message) <> "\n", rest}

        [] ->
          {:eof, []}
      end)
    end

    output =
      capture_io(fn ->
        Stdio.run(
          server,
          principal: "stdio-subscription-bounds",
          input: input,
          eof_grace_ms: 1_000
        )
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
    {:ok, server} = Server.start_link(max_concurrency: 6, client_request_timeout: 1_000)
    request_agent = start_supervised!({Agent, fn -> [] end})
    parent = self()

    tools = [
      {"stdio_sample", "sampling/createMessage", %{"messages" => []}},
      {"stdio_elicit", "elicitation/create",
       %{"message" => "confirm", "requestedSchema" => %{"type" => "object"}}},
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

  defp await_durable_session(store, namespace, predicate) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    await_durable_session(store, namespace, predicate, deadline)
  end

  defp await_durable_session(store, namespace, predicate, deadline) do
    session =
      case AttestoMCP.Server.SessionStore.ETS.list_active(store) do
        {:ok, records} ->
          Enum.find_value(records, fn
            {{^namespace, _id}, record} ->
              case AttestoMCP.Server.Session.from_record(record) do
                {:ok, session} -> session
                _ -> nil
              end

            _ ->
              nil
          end)

        _ ->
          nil
      end

    cond do
      session && predicate.(session) ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(1)
        await_durable_session(store, namespace, predicate, deadline)

      true ->
        flunk("legacy stdio session did not reach the expected lifecycle state")
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

  defp await_waiting_in(pid, mfa, attempts \\ 400)

  defp await_waiting_in(_pid, _mfa, 0), do: {:error, :timeout}

  defp await_waiting_in(pid, mfa, attempts) do
    case Process.info(pid, [:current_function, :status]) do
      [current_function: ^mfa, status: :waiting] ->
        :ok

      _ ->
        Process.sleep(5)
        await_waiting_in(pid, mfa, attempts - 1)
    end
  end

  # Waits until a message matching `queued?` is in the process's mailbox.
  defp await_message_queued(pid, queued?, attempts \\ 400)

  defp await_message_queued(_pid, _queued?, 0), do: {:error, :timeout}

  defp await_message_queued(pid, queued?, attempts) do
    {:messages, messages} = Process.info(pid, :messages)

    if Enum.any?(messages, queued?) do
      :ok
    else
      Process.sleep(5)
      await_message_queued(pid, queued?, attempts - 1)
    end
  end

  defp resume_quietly(pid) do
    :erlang.resume_process(pid)
  rescue
    ArgumentError -> :ok
  end

  defp publish_tools_list_changed_every(server, interval_ms) do
    spawn_link(fn -> publish_tools_list_changed_loop(server, interval_ms) end)
  end

  defp publish_tools_list_changed_loop(server, interval_ms) do
    receive do
      :stop -> :ok
    after
      interval_ms ->
        :ok = Server.publish(server, %{"type" => "toolsListChanged"})
        publish_tools_list_changed_loop(server, interval_ms)
    end
  end

  defp stop_publisher(publisher) do
    monitor = Process.monitor(publisher)
    send(publisher, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^publisher, :normal}, 1_000
  end
end
