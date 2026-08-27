defmodule AttestoMCP.Server.LegacyCoreTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server

  @legacy "2025-11-25"

  test "legacy ping, logging, and initialization negotiate only the frozen version" do
    {:ok, server} = Server.start_link([])

    assert {1, %{"result" => %{}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 1, method: "ping", params: %{}},
               %{principal: "legacy"},
               version: @legacy
             )

    assert {2, %{"result" => %{}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 2, method: "logging/setLevel", params: %{"level" => "info"}},
               %{principal: "legacy"},
               version: @legacy
             )

    assert {3, %{"error" => %{"code" => -32602}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 3, method: "logging/setLevel", params: %{"level" => "nope"}},
               %{principal: "legacy"},
               version: @legacy
             )

    assert {4, %{"result" => %{"protocolVersion" => @legacy, "capabilities" => capabilities}}} =
             Server.dispatch(
               server,
               %{
                 kind: :request,
                 id: 4,
                 method: "initialize",
                 params: %{
                   "protocolVersion" => @legacy,
                   "protocolVersions" => [@legacy],
                   "capabilities" => %{},
                   "clientInfo" => %{"name" => "legacy-test", "version" => "1.0"}
                 }
               },
               %{principal: "legacy"},
               version: @legacy
             )

    assert capabilities["resources"]["subscribe"] == true
    assert capabilities["logging"] == %{}

    assert {5, %{"error" => %{"code" => -32022, "data" => data}}} =
             Server.dispatch(
               server,
               %{
                 kind: :request,
                 id: 5,
                 method: "initialize",
                 params: %{
                   "protocolVersion" => "2026-07-28",
                   "capabilities" => %{},
                   "clientInfo" => %{"name" => "legacy-test", "version" => "1.0"}
                 }
               },
               %{principal: "legacy"},
               version: @legacy
             )

    assert data["requested"] == "2026-07-28"
    assert data["supported"] == [@legacy]
  end

  test "legacy resource subscriptions filter one-route SSE delivery and close on delete" do
    {:ok, server} = Server.start_link([])
    {:ok, session} = Server.new_session(server, "legacy", "tenant")

    assert :ok = Server.negotiate_session(server, session.id, "legacy", "tenant", @legacy, %{})
    assert :ok = Server.mark_initialized(server, session.id)
    assert {:error, :not_found} = Server.get_session(server, session.id, "other", "tenant")
    assert {:error, :not_found} = Server.get_session(server, session.id, "legacy", "other")

    assert {:ok, stream} =
             Server.open_legacy_stream(server, session.id, "legacy", "tenant", self())

    assert {10, %{"result" => %{}}} =
             Server.dispatch(
               server,
               %{
                 kind: :request,
                 id: 10,
                 method: "resources/subscribe",
                 params: %{"uri" => "urn:one"}
               },
               %{
                 principal: "legacy",
                 tenant: "tenant",
                 session_id: session.id,
                 client_capabilities: %{"sampling" => %{}}
               },
               version: @legacy
             )

    Server.publish(server, %{"type" => "resource", "uri" => "urn:other"})
    refute_receive {:mcp_legacy_event, ^stream, _, _}, 100

    Server.publish(server, %{"type" => "resource", "uri" => "urn:one"})
    assert_receive {:mcp_legacy_event, ^stream, event_id, event}, 1_000
    assert event_id == 1
    assert event["method"] == "notifications/resources/updated"

    Server.delete_session(server, session.id)
    assert_receive {:mcp_legacy_close, ^stream, :session_deleted}, 1_000
  end

  test "legacy server-originated requests require initialized negotiated capability and route responses" do
    {:ok, server} = Server.start_link([])
    {:ok, session} = Server.new_session(server, "legacy", "tenant")

    assert :ok =
             Server.negotiate_session(
               server,
               session.id,
               "legacy",
               "tenant",
               @legacy,
               %{"sampling" => %{}}
             )

    assert {:error, :not_found} =
             Server.open_legacy_stream(server, session.id, "legacy", "tenant", self())

    assert :ok = Server.mark_initialized(server, session.id)

    assert {:ok, stream} =
             Server.open_legacy_stream(server, session.id, "legacy", "tenant", self())

    parent = self()

    assert :ok =
             Server.register_tool(server, "asks_client", %{
               input_schema: %{"type" => "object"},
               handler: fn _arguments, context ->
                 result = context.client_request.("sampling/createMessage", %{"messages" => []})
                 send(parent, {:client_result, result})
                 {:ok, "done"}
               end
             })

    dispatch =
      spawn(fn ->
        send(
          parent,
          {:dispatch,
           Server.dispatch(
             server,
             %{
               kind: :request,
               id: 20,
               method: "tools/call",
               params: %{"name" => "asks_client", "arguments" => %{}}
             },
             %{principal: "legacy", tenant: "tenant", session_id: session.id},
             version: @legacy
           )}
        )
      end)

    {_event_id, request} = receive_legacy_server_request(stream)
    assert request["method"] == "sampling/createMessage"
    request_id = request["id"]

    assert :ok =
             Server.deliver_client_response(
               server,
               session.id,
               "legacy",
               "tenant",
               %{
                 kind: :response,
                 id: request_id,
                 result: %{
                   "role" => "assistant",
                   "content" => %{"type" => "text", "text" => "ok"},
                   "model" => "legacy-model",
                   "stopReason" => "endTurn"
                 },
                 error: nil
               }
             )

    assert_receive {:client_result,
                    {:ok,
                     %{
                       "role" => "assistant",
                       "content" => %{"type" => "text", "text" => "ok"},
                       "model" => "legacy-model",
                       "stopReason" => "endTurn"
                     }}},
                   1_000

    assert_receive {:dispatch, {20, %{"result" => %{"content" => _}}}}, 1_000
    refute Process.alive?(dispatch)

    assert {:error, :not_found} =
             Server.deliver_client_response(
               server,
               session.id,
               "legacy",
               "tenant",
               %{kind: :response, id: request_id, result: %{}, error: nil}
             )
  end

  test "100 randomized legacy session and stream ownership iterations stay bounded" do
    {:ok, server} = Server.start_link([])
    random = :rand.seed_s(:exsplus, {17, 29, 41})

    {_random, count} =
      Enum.reduce(1..100, {random, 0}, fn index, {rand, count} ->
        {:ok, session} = Server.new_session(server, "owner-#{index}", "tenant-#{rem(index, 3)}")

        assert :ok =
                 Server.negotiate_session(
                   server,
                   session.id,
                   session.principal,
                   session.tenant,
                   @legacy,
                   %{}
                 )

        assert :ok = Server.mark_initialized(server, session.id)

        assert {:ok, stream} =
                 Server.open_legacy_stream(
                   server,
                   session.id,
                   session.principal,
                   session.tenant,
                   self()
                 )

        {choice, rand} = :rand.uniform_s(3, rand)

        case choice do
          1 ->
            Server.publish(server, %{"type" => "toolsListChanged"})
            assert :ok = Server.delete_session(server, session.id)
            assert_receive {:mcp_legacy_close, ^stream, :session_deleted}, 1_000

          2 ->
            assert :ok = Server.close_legacy_stream(server, stream)
            assert :ok = Server.delete_session(server, session.id)

          3 ->
            assert :ok = Server.delete_session(server, session.id)
            assert_receive {:mcp_legacy_close, ^stream, :session_deleted}, 1_000
        end

        assert {:error, :not_found} =
                 Server.get_session(server, session.id, session.principal, session.tenant)

        {rand, count + 1}
      end)

    assert count == 100
  end

  test "legacy server requests return typed sampling, elicitation, and roots results" do
    {:ok, server} = Server.start_link(client_request_timeout: 25)
    {:ok, session} = Server.new_session(server, "legacy", "tenant")

    assert :ok =
             Server.negotiate_session(
               server,
               session.id,
               "legacy",
               "tenant",
               @legacy,
               %{"sampling" => %{}, "elicitation" => %{}, "roots" => %{}}
             )

    assert :ok = Server.mark_initialized(server, session.id)

    assert {:ok, stream} =
             Server.open_legacy_stream(server, session.id, "legacy", "tenant", self())

    parent = self()

    methods = [
      {"sample", "sampling/createMessage", %{"messages" => []}},
      {"elicit", "elicitation/create", %{"message" => "confirm"}},
      {"roots", "roots/list", %{}}
    ]

    Enum.each(methods, fn {name, method, params} ->
      assert :ok =
               Server.register_tool(server, name, %{
                 input_schema: %{"type" => "object"},
                 handler: fn _arguments, context ->
                   result = context.client_request.(method, params)
                   send(parent, {:handler_result, name, result})
                   {:ok, "complete"}
                 end
               })
    end)

    dispatches =
      Enum.map(methods, fn {name, _method, _params} ->
        spawn(fn ->
          send(
            parent,
            {:dispatch_result, name,
             Server.dispatch(
               server,
               %{
                 kind: :request,
                 id: name,
                 method: "tools/call",
                 params: %{"name" => name, "arguments" => %{}}
               },
               %{principal: "legacy", tenant: "tenant", session_id: session.id},
               version: @legacy
             )}
          )
        end)
      end)

    requests =
      Enum.map(1..3, fn _ ->
        {_event_id, request} = receive_legacy_server_request(stream)
        {request["id"], request["method"]}
      end)

    Enum.each(requests, fn
      {id, "sampling/createMessage"} ->
        assert :ok =
                 Server.deliver_client_response(server, session.id, "legacy", "tenant", %{
                   kind: :response,
                   id: id,
                   result: %{
                     "role" => "assistant",
                     "content" => %{"type" => "text", "text" => "ok"},
                     "model" => "model",
                     "stopReason" => "endTurn"
                   },
                   error: nil
                 })

      _ ->
        :ok
    end)

    Enum.each(requests, fn
      {id, "elicitation/create"} ->
        assert :ok =
                 Server.deliver_client_response(server, session.id, "legacy", "tenant", %{
                   kind: :response,
                   id: id,
                   result: %{"action" => "accept", "content" => %{"answer" => "yes"}},
                   error: nil
                 })

      {id, "roots/list"} ->
        assert :ok =
                 Server.deliver_client_response(server, session.id, "legacy", "tenant", %{
                   kind: :response,
                   id: id,
                   result: %{"roots" => [%{"uri" => "file:///workspace", "name" => "workspace"}]},
                   error: nil
                 })

      _ ->
        :ok
    end)

    assert_receive {:handler_result, "sample", {:ok, %{"role" => "assistant"}}}, 1_000
    assert_receive {:handler_result, "elicit", {:ok, %{"action" => "accept"}}}, 1_000
    assert_receive {:handler_result, "roots", {:ok, %{"roots" => [_]}}}, 1_000

    Enum.each(dispatches, fn _pid ->
      assert_receive {:dispatch_result, _name, {_id, %{"result" => %{"content" => _}}}}, 1_000
    end)
  end

  test "legacy server request errors, invalid results, and expiry are correlated" do
    {:ok, server} = Server.start_link(client_request_timeout: 20)
    {:ok, session} = Server.new_session(server, "legacy", "tenant")

    assert :ok =
             Server.negotiate_session(
               server,
               session.id,
               "legacy",
               "tenant",
               @legacy,
               %{"sampling" => %{}}
             )

    assert :ok = Server.mark_initialized(server, session.id)

    assert {:ok, stream} =
             Server.open_legacy_stream(server, session.id, "legacy", "tenant", self())

    parent = self()

    for {name, mode} <- [{"error", :error}, {"invalid", :invalid}, {"timeout", :timeout}] do
      assert :ok =
               Server.register_tool(server, name, %{
                 input_schema: %{"type" => "object"},
                 handler: fn _arguments, context ->
                   result = context.client_request.("sampling/createMessage", %{"messages" => []})
                   send(parent, {:handler_result, name, result})
                   {:ok, Atom.to_string(mode)}
                 end
               })
    end

    spawn(fn ->
      Server.dispatch(
        server,
        %{
          kind: :request,
          id: "error",
          method: "tools/call",
          params: %{"name" => "error", "arguments" => %{}}
        },
        %{principal: "legacy", tenant: "tenant", session_id: session.id},
        version: @legacy
      )
    end)

    {_event_id, error_request} = receive_legacy_server_request(stream)

    assert {:error, {:client_error, %{"code" => -1, "message" => "declined"}}} =
             Server.deliver_client_response(server, session.id, "legacy", "tenant", %{
               kind: :response,
               id: error_request["id"],
               result: nil,
               error: %{"code" => -1, "message" => "declined"}
             })

    assert_receive {:handler_result, "error", {:error, {:client_error, %{"code" => -1}}}}, 1_000

    spawn(fn ->
      Server.dispatch(
        server,
        %{
          kind: :request,
          id: "invalid",
          method: "tools/call",
          params: %{"name" => "invalid", "arguments" => %{}}
        },
        %{principal: "legacy", tenant: "tenant", session_id: session.id},
        version: @legacy
      )
    end)

    {_event_id, invalid_request} = receive_legacy_server_request(stream)

    assert {:error, :invalid_response} =
             Server.deliver_client_response(server, session.id, "legacy", "tenant", %{
               kind: :response,
               id: invalid_request["id"],
               result: %{"role" => "assistant"},
               error: nil
             })

    assert_receive {:handler_result, "invalid", {:error, :invalid_response}}, 1_000

    spawn(fn ->
      Server.dispatch(
        server,
        %{
          kind: :request,
          id: "timeout",
          method: "tools/call",
          params: %{"name" => "timeout", "arguments" => %{}}
        },
        %{principal: "legacy", tenant: "tenant", session_id: session.id},
        version: @legacy
      )
    end)

    {_event_id, timeout_request} = receive_legacy_server_request(stream)
    assert_receive {:handler_result, "timeout", {:error, :timeout}}, 1_000

    assert {:error, :not_found} =
             Server.deliver_client_response(server, session.id, "legacy", "tenant", %{
               kind: :response,
               id: timeout_request["id"],
               result: %{
                 "role" => "assistant",
                 "content" => %{"type" => "text", "text" => "late"},
                 "model" => "model",
                 "stopReason" => "endTurn"
               },
               error: nil
             })
  end

  defp receive_legacy_server_request(stream) do
    receive do
      {:mcp_legacy_event, ^stream, event_id, %{"method" => method} = request}
      when method in ["sampling/createMessage", "elicitation/create", "roots/list"] ->
        {event_id, request}

      {:mcp_legacy_event, ^stream, _event_id, _notification} ->
        receive_legacy_server_request(stream)
    after
      1_000 ->
        flunk("timed out waiting for a legacy server request")
    end
  end
end
