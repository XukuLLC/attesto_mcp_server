defmodule AttestoMCP.Server.P8P9NotificationsTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server

  @modern "2026-07-28"
  @legacy "2025-11-25"

  test "modern logLevel is validated and filters request-scoped notifications" do
    {:ok, server} = Server.start_link(capabilities: %{"logging" => %{}})
    owner = self()

    assert :ok =
             Server.register_tool(server, "notify", %{
               description: "notification test",
               input_schema: %{"type" => "object"},
               handler: fn _args, context ->
                 result =
                   context.notify.(%{
                     "jsonrpc" => "2.0",
                     "method" => "notifications/message",
                     "params" => %{"level" => "info", "data" => "hello"}
                   })

                 send(owner, {:notify_result, result})
                 {:ok, "done"}
               end
             })

    invalid =
      dispatch(
        server,
        1,
        "tools/call",
        tool_params("notify", %{
          "io.modelcontextprotocol/logLevel" => "verbose"
        }),
        @modern
      )

    assert {1, %{"error" => %{"code" => -32602, "data" => %{"reason" => "invalid_log_level"}}}} =
             invalid

    suppressed =
      dispatch(
        server,
        2,
        "tools/call",
        tool_params("notify", %{}),
        @modern,
        fn event ->
          send(owner, {:notification, event})
          :ok
        end
      )

    assert {2, %{"result" => %{"resultType" => "complete"}}} = suppressed
    assert_receive {:notify_result, {:error, :logging_disabled}}
    refute_receive {:notification, _}

    delivered =
      dispatch(
        server,
        3,
        "tools/call",
        tool_params("notify", %{"io.modelcontextprotocol/logLevel" => "info"}),
        @modern,
        fn event ->
          send(owner, {:notification, event})
          :ok
        end
      )

    assert {3, %{"result" => %{"resultType" => "complete"}}} = delivered
    assert_receive {:notify_result, :ok}
    assert_receive {:notification, %{"method" => "notifications/message"}}

    filtered =
      dispatch(
        server,
        4,
        "tools/call",
        tool_params("notify", %{"io.modelcontextprotocol/logLevel" => "warning"}),
        @modern,
        fn event ->
          send(owner, {:notification, event})
          :ok
        end
      )

    assert {4, %{"result" => %{"resultType" => "complete"}}} = filtered
    assert_receive {:notify_result, {:error, :log_filtered}}
  end

  test "notify reports unsupported when an HTTP JSON response has no event sink" do
    {:ok, server} = Server.start_link(capabilities: %{"logging" => %{}})
    owner = self()

    assert :ok =
             Server.register_tool(server, "json_notify", %{
               handler: fn _args, context ->
                 send(owner, {:notify_result, context.notify.(log_event("info", "hello"))})
                 {:ok, "done"}
               end
             })

    assert {5, %{"result" => %{"resultType" => "complete"}}} =
             dispatch(
               server,
               5,
               "tools/call",
               tool_params("json_notify", %{"io.modelcontextprotocol/logLevel" => "info"}),
               @modern
             )

    assert_receive {:notify_result, {:error, :unsupported}}
  end

  test "notify rejects request injection, malformed params, and floods" do
    {:ok, server} = Server.start_link(max_queue: 2)
    owner = self()

    assert :ok =
             Server.register_tool(server, "bad_notify", %{
               description: "bad notification test",
               input_schema: %{"type" => "object"},
               handler: fn _args, context ->
                 results = [
                   context.notify.(%{
                     "jsonrpc" => "2.0",
                     "id" => 99,
                     "method" => "notifications/message",
                     "params" => %{"level" => "info", "data" => "bad"}
                   }),
                   context.notify.(%{
                     "jsonrpc" => "2.0",
                     "method" => "notifications/message",
                     "params" => %{"level" => "info", "data" => self()}
                   }),
                   context.notify.(%{
                     "jsonrpc" => "2.0",
                     "method" => "sampling/createMessage",
                     "params" => %{}
                   }),
                   context.notify.(%{
                     "jsonrpc" => "2.0",
                     "method" => "notifications/progress",
                     "params" => %{"progressToken" => "p", "progress" => 1}
                   })
                 ]

                 send(owner, {:notify_results, results})
                 {:ok, "done"}
               end
             })

    result =
      dispatch(
        server,
        1,
        "tools/call",
        tool_params("bad_notify", %{"io.modelcontextprotocol/logLevel" => "info"}),
        @modern,
        fn event ->
          send(owner, {:notification, event})
          :ok
        end
      )

    assert {1, %{"result" => %{"resultType" => "complete"}}} = result

    assert_receive {:notify_results,
                    [
                      {:error, :notification_envelope},
                      {:error, :notification_not_json},
                      {:error, :notification_method},
                      {:error, :progress_must_use_context_progress}
                    ]}
  end

  test "legacy logging level persists by session and suppresses lower severities" do
    {:ok, server} = Server.start_link([])
    {:ok, session} = Server.new_session(server, "legacy-user", "tenant")

    initialize = %{
      kind: :request,
      id: 1,
      method: "initialize",
      params: %{
        "protocolVersion" => @legacy,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "test", "version" => "1"}
      }
    }

    assert {1, %{"result" => _}} =
             Server.dispatch(server, initialize, session_context(session), version: @legacy)

    :ok = Server.mark_initialized(server, session.id)

    assert {2, %{"result" => %{}}} =
             Server.dispatch(
               server,
               %{
                 kind: :request,
                 id: 2,
                 method: "logging/setLevel",
                 params: %{"level" => "warning"}
               },
               session_context(session),
               version: @legacy
             )

    owner = self()

    assert :ok =
             Server.register_tool(server, "legacy_notify", %{
               description: "legacy notification test",
               input_schema: %{"type" => "object"},
               handler: fn _args, context ->
                 results = [
                   context.notify.(log_event("info", "quiet")),
                   context.notify.(log_event("error", "loud"))
                 ]

                 send(owner, {:legacy_notify_results, results})
                 {:ok, "done"}
               end
             })

    response =
      Server.dispatch(
        server,
        %{
          kind: :request,
          id: 3,
          method: "tools/call",
          params: %{"name" => "legacy_notify", "arguments" => %{}}
        },
        session_context(session),
        version: @legacy,
        on_event: fn event ->
          send(owner, {:legacy_event, event})
          :ok
        end
      )

    assert {3, %{"result" => %{}}} = response
    assert_receive {:legacy_notify_results, [{:error, :log_filtered}, :ok]}
    assert_receive {:legacy_event, %{"method" => "notifications/message"}}
  end

  test "public publish rejects request injection and malformed logging events" do
    {:ok, server} = Server.start_link([])

    assert {:error, :invalid_notification} =
             Server.publish(server, %{
               "jsonrpc" => "2.0",
               "id" => 1,
               "method" => "sampling/createMessage",
               "params" => %{}
             })

    assert {:error, :invalid_notification} =
             Server.publish(server, %{
               "jsonrpc" => "2.0",
               "method" => "notifications/message",
               "params" => %{"level" => "info"}
             })

    assert :ok = Server.publish(server, %{"type" => "toolsListChanged"})

    assert {:error, :invalid_notification} =
             Server.publish(server, %{
               "jsonrpc" => "2.0",
               "method" => "notifications/progress",
               "params" => %{"progressToken" => "p", "progress" => 1}
             })
  end

  test "legacy standing streams never receive published request injections" do
    {:ok, server} = Server.start_link([])
    {:ok, session} = Server.new_session(server, "legacy-publish", "tenant")

    assert :ok =
             Server.negotiate_session(
               server,
               session.id,
               "legacy-publish",
               "tenant",
               @legacy,
               %{}
             )

    assert :ok = Server.mark_initialized(server, session.id)

    assert {:ok, stream} =
             Server.open_legacy_stream(server, session.id, "legacy-publish", "tenant", self())

    assert {:error, :invalid_notification} =
             Server.publish(server, %{
               "jsonrpc" => "2.0",
               "id" => 12,
               "method" => "sampling/createMessage",
               "params" => %{}
             })

    assert {:error, :invalid_notification} =
             Server.publish(server, %{
               "jsonrpc" => "2.0",
               "method" => "notifications/message",
               "params" => %{"level" => "info"}
             })

    refute_receive {:mcp_legacy_event, ^stream, _, _}, 100
    assert :ok = Server.close_legacy_stream(server, stream)
  end

  test "successful registry mutation reaches an owned legacy list-changed stream" do
    {:ok, server} = Server.start_link([])
    {:ok, session} = Server.new_session(server, "legacy-register", "tenant")

    assert :ok =
             Server.negotiate_session(
               server,
               session.id,
               "legacy-register",
               "tenant",
               @legacy,
               %{}
             )

    assert :ok = Server.mark_initialized(server, session.id)

    assert {:ok, stream} =
             Server.open_legacy_stream(server, session.id, "legacy-register", "tenant", self())

    assert :ok =
             Server.register_tool(server, "registered_after_stream", %{
               description: "legacy invalidation fixture",
               input_schema: %{"type" => "object"},
               handler: fn _, _ -> {:ok, "ok"} end
             })

    assert_receive {:mcp_legacy_event, ^stream, _,
                    %{"method" => "notifications/tools/list_changed"}},
                   1_000
  end

  test "modern HTTP cancellation notifications do not cancel response work" do
    {:ok, server} = Server.start_link([])
    parent = self()

    assert :ok =
             Server.register_tool(server, "slow", %{
               description: "slow cancellation fixture",
               input_schema: %{"type" => "object"},
               handler: fn _args, _context ->
                 send(parent, :slow_started)
                 Process.sleep(40)
                 {:ok, "finished"}
               end
             })

    request = %{
      kind: :request,
      id: 9,
      method: "tools/call",
      params: tool_params("slow", %{})
    }

    caller =
      Task.async(fn ->
        Server.dispatch(server, request, %{principal: "http-caller"},
          version: @modern,
          transport: :http
        )
      end)

    assert_receive :slow_started

    assert :notification =
             Server.dispatch(
               server,
               %{
                 kind: :notification,
                 method: "notifications/cancelled",
                 params: %{"requestId" => 9}
               },
               %{principal: "http-caller"},
               version: @modern,
               transport: :http
             )

    assert {9, %{"result" => %{"resultType" => "complete"}}} = Task.await(caller, 1_000)
  end

  defp dispatch(server, id, method, params, version, on_event \\ nil) do
    options = [version: version]

    options =
      if is_function(on_event, 1), do: Keyword.put(options, :on_event, on_event), else: options

    Server.dispatch(
      server,
      %{kind: :request, id: id, method: method, params: params},
      %{principal: "modern-user", scopes: []},
      options
    )
  end

  defp tool_params(name, meta) do
    %{
      "name" => name,
      "arguments" => %{},
      "_meta" =>
        Map.merge(
          %{
            "io.modelcontextprotocol/protocolVersion" => @modern,
            "io.modelcontextprotocol/clientCapabilities" => %{}
          },
          meta
        )
    }
  end

  defp session_context(session),
    do: %{principal: "legacy-user", tenant: "tenant", session_id: session.id}

  defp log_event(level, data),
    do: %{
      "jsonrpc" => "2.0",
      "method" => "notifications/message",
      "params" => %{"level" => level, "data" => data}
    }
end
