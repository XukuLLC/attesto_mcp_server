defmodule AttestoMCP.Server.P12TransportTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Plug.Conn
  import Plug.Test

  alias AttestoMCP.Server
  alias AttestoMCP.Server.JSONRPC
  alias AttestoMCP.Server.Stdio

  @modern "2026-07-28"
  @legacy "2025-11-25"
  @resource "https://mcp.example.com/mcp"

  test "same-session legacy streaming POSTs isolate progress and responses" do
    {:ok, _apps} = Application.ensure_all_started(:bandit)
    parent = self()
    {:ok, server} = Server.start_link(max_concurrency: 4)

    assert :ok =
             Server.register_tool(server, "legacy-stream", %{
               input_schema: %{
                 "type" => "object",
                 "properties" => %{"tag" => %{"type" => "string"}},
                 "required" => ["tag"]
               },
               handler: fn %{"tag" => tag}, context ->
                 send(parent, {:legacy_started, tag})
                 assert :ok = context.progress.("progress-#{tag}", 1, nil)
                 Process.sleep(if tag == "a", do: 300, else: 120)
                 send(parent, {:legacy_finished, tag})
                 {:ok, %{"tag" => tag}}
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
    session_id = legacy_session(port, token)
    socket_a = connect(port)
    socket_b = connect(port)

    :ok =
      send_request(
        socket_a,
        "POST",
        "/mcp",
        legacy_headers(token, session_id) ++ [{"mcp-name", "legacy-stream"}],
        legacy_stream_body(101, "a")
      )

    :ok =
      send_request(
        socket_b,
        "POST",
        "/mcp",
        legacy_headers(token, session_id) ++ [{"mcp-name", "legacy-stream"}],
        legacy_stream_body(102, "b")
      )

    {_head_a, _initial_a} = recv_headers(socket_a)
    {_head_b, initial_b} = recv_headers(socket_b)
    assert_receive {:legacy_started, "a"}, 1_000
    assert_receive {:legacy_started, "b"}, 1_000
    :ok = :gen_tcp.close(socket_a)
    {body_b, _rest_b} = recv_until(socket_b, initial_b, ~s("id":102))
    assert body_b =~ "progress-b"
    refute body_b =~ "progress-a"
    assert body_b =~ ~s("tag":"b")
    assert_receive {:legacy_finished, "a"}, 1_000
    :ok = :gen_tcp.close(socket_b)
    assert eventually(fn -> Server.stats(server).active_requests == 0 end)
    assert Server.stats(server).active == 0
  end

  test "stale legacy stream teardown cannot remove its replacement and normalized resource scopes are enforced" do
    {:ok, server} = Server.start_link([])
    assert {:ok, session} = Server.new_session(server, "usr_123")

    assert :ok =
             Server.negotiate_session(
               server,
               session.id,
               "usr_123",
               nil,
               @legacy,
               %{"sampling" => %{}}
             )

    assert :ok = Server.mark_initialized(server, session.id)
    assert :ok = Server.subscribe_resource(server, session.id, "usr_123", nil, "test://scoped")

    assert :ok =
             Server.register_resource(server, "test://scoped", %{
               "name" => "scoped",
               "requiredScopes" => ["mcp:resource:secret"],
               "handler" => fn _, _ -> {:ok, [%{"uri" => "test://scoped", "text" => "ok"}]} end
             })

    parent = self()

    stale = spawn(fn -> legacy_stream_relay(parent, :stale_event) end)

    assert {:ok, stale_ref} =
             Server.open_legacy_stream(server, session.id, "usr_123", nil, stale, fn _ -> true end)

    replacement = spawn(fn -> legacy_stream_relay(parent, :replacement_event) end)

    assert {:ok, replacement_ref} =
             Server.open_legacy_stream(server, session.id, "usr_123", nil, replacement, fn %{
                                                                                             required_scopes:
                                                                                               scopes
                                                                                           } ->
               send(parent, {:resource_event_scopes, scopes})
               true
             end)

    sampling =
      Task.async(fn ->
        Server.request_client(
          server,
          session.id,
          "usr_123",
          nil,
          "sampling/createMessage",
          %{"messages" => []},
          1_000
        )
      end)

    assert_receive {:replacement_event,
                    {:mcp_legacy_event, ^replacement_ref, _id,
                     %{"method" => "sampling/createMessage"} = request}},
                   1_000

    refute_receive {:stale_event, {:mcp_legacy_event, ^stale_ref, _, _}}, 100
    Server.ack_legacy_stream(server, replacement_ref)

    assert :ok =
             Server.deliver_client_response(server, session.id, "usr_123", nil, %{
               kind: :response,
               id: request["id"],
               result: %{
                 "role" => "assistant",
                 "content" => %{"type" => "text", "text" => "replacement"},
                 "model" => "test-model"
               },
               error: nil
             })

    assert {:ok, %{"model" => "test-model"}} = Task.await(sampling, 1_000)

    Process.exit(stale, :kill)
    assert eventually(fn -> Server.stats(server).legacy_streams == 1 end)
    assert :ok = Server.publish(server, %{"type" => "resourceUpdated", "uri" => "test://scoped"})
    assert_receive {:resource_event_scopes, scopes}, 1_000
    assert "mcp:resources:read" in scopes
    assert "mcp:resource:secret" in scopes
    assert_receive {:replacement_event, {:mcp_legacy_event, ^replacement_ref, _id, event}}, 1_000
    assert event["method"] == "notifications/resources/updated"
    refute_receive {:stale_event, {:mcp_legacy_event, ^stale_ref, _, _}}, 100
    Server.ack_legacy_stream(server, replacement_ref)
    Server.close_legacy_stream(server, replacement_ref)
    send(replacement, :stop)
  end

  test "legacy client requests wait briefly for their owned stream to become ready" do
    parent = self()
    {:ok, server} = Server.start_link([])
    assert {:ok, session} = Server.new_session(server, "late-stream", nil)

    assert :ok =
             Server.negotiate_session(
               server,
               session.id,
               "late-stream",
               nil,
               @legacy,
               %{"sampling" => %{}}
             )

    assert :ok = Server.mark_initialized(server, session.id)

    request =
      Task.async(fn ->
        Server.request_client(
          server,
          session.id,
          "late-stream",
          nil,
          "sampling/createMessage",
          %{"messages" => []},
          1_000
        )
      end)

    Process.sleep(50)
    sink = spawn(fn -> legacy_stream_relay(parent, :late_stream_event) end)

    assert {:ok, stream_ref} =
             Server.open_legacy_stream(server, session.id, "late-stream", nil, sink)

    assert_receive {:late_stream_event,
                    {:mcp_legacy_event, ^stream_ref, _event_id,
                     %{"method" => "sampling/createMessage"} = event}},
                   1_000

    Server.ack_legacy_stream(server, stream_ref)

    assert :ok =
             Server.deliver_client_response(server, session.id, "late-stream", nil, %{
               kind: :response,
               id: event["id"],
               result: %{
                 "role" => "assistant",
                 "content" => %{"type" => "text", "text" => "ready"},
                 "model" => "test-model"
               },
               error: nil
             })

    assert {:ok, %{"model" => "test-model"}} = Task.await(request, 1_000)
    assert :ok = Server.close_legacy_stream(server, stream_ref)
    send(sink, :stop)
  end

  test "identified unknown method preserves its ID and terminates across core, Plug, Bandit, and stdio" do
    {:ok, server} = Server.start_link([])
    id = 901

    assert {^id, %{"error" => %{"code" => -32601}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: id, method: "unknown/method", params: modern_meta()},
               %{principal: "usr_123"},
               version: @modern
             )

    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())

    plug =
      Server.Plug.init(server: server, path: "/mcp", auth: [config: config, resource: @resource])

    plug_conn =
      conn(:post, "/mcp", Jason.encode!(unknown_wire(id + 1)))
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", @modern)
      |> put_req_header("mcp-method", "unknown/method")
      |> Server.Plug.call(plug)

    assert plug_conn.status == 404
    assert Jason.decode!(plug_conn.resp_body)["id"] == id + 1
    assert Jason.decode!(plug_conn.resp_body)["error"]["code"] == -32601

    stdio =
      capture_io(Jason.encode!(unknown_wire(id + 2)) <> "\n", fn ->
        Stdio.run(server, principal: "stdio-unknown")
      end)

    [stdio_message] = stdio |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert stdio_message["id"] == id + 2
    assert stdio_message["error"]["code"] == -32601
    {:ok, _apps} = Application.ensure_all_started(:bandit)

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
    socket = connect(port)

    :ok =
      send_request(
        socket,
        "POST",
        "/mcp",
        [
          {"host", "127.0.0.1"},
          {"authorization", "Bearer " <> token},
          {"content-type", "application/json"},
          {"accept", "application/json, text/event-stream"},
          {"mcp-protocol-version", @modern},
          {"mcp-method", "unknown/method"}
        ],
        Jason.encode!(unknown_wire(id + 3))
      )

    {head, rest} = recv_headers(socket)
    head_lines = String.split(head, "\r\n", trim: true)
    {response_body, _} = recv_body(socket, parse_headers(head_lines), rest)
    assert [_, "404" | _] = String.split(hd(head_lines), " ")
    assert Jason.decode!(response_body)["id"] == id + 3
    assert Jason.decode!(response_body)["error"]["code"] == -32601
    :gen_tcp.close(socket)
  end

  test "unsupported subscription aliases remain ordinary unknown methods" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())

    plug =
      Server.Plug.init(server: server, path: "/mcp", auth: [config: config, resource: @resource])

    response =
      call_http(
        plug,
        token,
        unknown_wire(905, "notifications/subscribe"),
        @modern,
        "application/json, text/event-stream"
      )

    assert response.status == 404
    assert %{"id" => 905, "error" => %{"code" => -32601}} = Jason.decode!(response.resp_body)
  end

  test "dated decode and dispatch preserve declared extension members and handler metadata" do
    assert {:ok, %{kind: :request, extensions: %{"x-request" => %{"trace" => true}}}} =
             JSONRPC.decode(
               Jason.encode!(%{
                 "jsonrpc" => "2.0",
                 "id" => 1,
                 "method" => "tools/call",
                 "params" => %{"name" => "extensions", "arguments" => %{}},
                 "x-request" => %{"trace" => true}
               })
             )

    {:ok, server} = Server.start_link([])

    assert :ok =
             Server.register_tool(server, "extensions", %{
               handler: fn _, context -> {:ok, %{"seen" => context[:request_extensions]}} end
             })

    for {version, extension} <- [{@modern, "x-modern"}, {@legacy, "x-legacy"}] do
      payload = %{
        "jsonrpc" => "2.0",
        "id" => version,
        "method" => "tools/call",
        "params" =>
          if(version == @modern,
            do: Map.merge(modern_meta(), %{"name" => "extensions", "arguments" => %{}}),
            else: %{"name" => "extensions", "arguments" => %{}}
          ),
        extension => %{"preserve" => true}
      }

      assert {:ok, request} = JSONRPC.decode(Jason.encode!(payload))
      assert request.extensions[extension]["preserve"] == true

      assert {^version, %{"result" => result}} =
               Server.dispatch(server, request, %{principal: "extension"}, version: version)

      assert get_in(result, ["structuredContent", "seen", extension, "preserve"]) == true
    end
  end

  test "POST media negotiation covers legacy initialize/request/notification and modern request/notification" do
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())
    {:ok, server} = Server.start_link([])

    plug =
      Server.Plug.init(server: server, path: "/mcp", auth: [config: config, resource: @resource])

    modern_request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/list",
      "params" => modern_meta()
    }

    modern_notification = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => Map.merge(modern_meta(), %{"requestId" => 99})
    }

    assert call_http(plug, token, modern_request, @modern, "application/json, text/event-stream").status ==
             200

    assert call_http(
             plug,
             token,
             modern_notification,
             @modern,
             "application/json, text/event-stream"
           ).status == 202

    legacy_initialize = %{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @legacy,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "p12", "version" => "1"}
      }
    }

    initialized =
      call_http(plug, token, legacy_initialize, nil, "application/json, text/event-stream")

    assert initialized.status == 200
    session_id = get_resp_header(initialized, "mcp-session-id") |> List.first()
    assert is_binary(session_id)
    assert :ok = Server.mark_initialized(server, session_id)
    legacy_request = %{"jsonrpc" => "2.0", "id" => 3, "method" => "ping", "params" => %{}}

    legacy_notification = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/initialized",
      "params" => %{}
    }

    assert call_http(
             plug,
             token,
             legacy_request,
             @legacy,
             "application/json, text/event-stream",
             session_id
           ).status == 200

    assert call_http(
             plug,
             token,
             legacy_notification,
             @legacy,
             "application/json, text/event-stream",
             session_id
           ).status == 202

    for {body, version, session} <- [
          {modern_request, @modern, nil},
          {modern_notification, @modern, nil},
          {legacy_initialize, nil, nil},
          {legacy_request, @legacy, session_id},
          {legacy_notification, @legacy, session_id}
        ] do
      assert call_http(plug, token, body, version, "application/json", session).status == 400
    end
  end

  test "POST accepts JSON already decoded by a Phoenix-style parser pipeline" do
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())
    {:ok, server} = Server.start_link([])

    plug =
      Server.Plug.init(server: server, path: "/mcp", auth: [config: config, resource: @resource])

    payload = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @legacy,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "parsed-body-client", "version" => "1"}
      }
    }

    parser = Plug.Parsers.init(parsers: [:json], json_decoder: Jason)

    parsed_conn =
      conn(:post, "/mcp", Jason.encode!(payload))
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> Plug.Parsers.call(parser)

    assert parsed_conn.body_params == payload

    response = Server.Plug.call(parsed_conn, plug)

    assert response.status == 200
    assert Jason.decode!(response.resp_body)["result"]["protocolVersion"] == @legacy
  end

  test "POST reads raw JSON left behind by a pass-through parser" do
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())
    {:ok, server} = Server.start_link([])

    plug =
      Server.Plug.init(server: server, path: "/mcp", auth: [config: config, resource: @resource])

    payload = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @legacy,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "pass-through-client", "version" => "1"}
      }
    }

    parser = Plug.Parsers.init(parsers: [:urlencoded], pass: ["application/json"])

    parsed_conn =
      conn(:post, "/mcp", Jason.encode!(payload))
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> Plug.Parsers.call(parser)

    assert %Plug.Conn.Unfetched{} = parsed_conn.body_params

    # Some host pipelines mark a passed-through body as fetched without
    # consuming it. Preserve raw-body compatibility for that connection state.
    parsed_conn = %{parsed_conn | body_params: %{}}

    response = Server.Plug.call(parsed_conn, plug)

    assert response.status == 200
    assert Jason.decode!(response.resp_body)["result"]["protocolVersion"] == @legacy
  end

  test "many nil-ID notifications do not collide or leak ownership" do
    {:ok, server} = Server.start_link(max_concurrency: 64, per_principal_concurrency: 64)
    gate = make_ref()
    owner = {:legacy_session, "shared-notification-owner"}

    jobs =
      for _index <- 1..50 do
        Task.async(fn ->
          receive do
            ^gate -> :ok
          end

          Server.dispatch(
            server,
            %{kind: :notification, method: "notifications/initialized", params: %{}},
            %{principal: "notification-owner"},
            version: @legacy,
            transport: :http,
            owner: owner
          )
        end)
      end

    Enum.each(jobs, &send(&1.pid, gate))
    assert Enum.all?(Task.await_many(jobs, 5_000), &(&1 == :notification))

    assert eventually(fn -> Server.stats(server).active_requests == 0 end)
    assert eventually(fn -> Server.stats(server).active == 0 end)
  end

  test "many modern nil-ID notifications tolerate response-owner deaths" do
    {:ok, server} = Server.start_link(max_concurrency: 4)

    owners =
      for _index <- 1..50 do
        spawn(fn ->
          Server.dispatch(
            server,
            %{kind: :notification, method: "notifications/initialized", params: %{}},
            %{principal: "notification-owner"},
            version: @modern
          )
        end)
      end

    monitors = Enum.map(owners, &Process.monitor/1)

    Enum.each(owners, fn owner ->
      if rem(:erlang.phash2(owner), 3) == 0, do: Process.exit(owner, :kill)
    end)

    Enum.each(monitors, fn monitor ->
      assert_receive {:DOWN, ^monitor, :process, _owner, _reason}, 1_000
    end)

    assert eventually(fn -> Server.stats(server).active_requests == 0 end)
    assert eventually(fn -> Server.stats(server).active == 0 end)
  end

  test "fast detached legacy requests retain exact terminal telemetry" do
    parent = self()
    telemetry_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        telemetry_id,
        [
          [:attesto_mcp_server, :request, :start],
          [:attesto_mcp_server, :request, :stop],
          [:attesto_mcp_server, :request, :exception]
        ],
        &__MODULE__.telemetry_handler/4,
        parent
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)
    {:ok, server} = Server.start_link(max_concurrency: 128, per_principal_concurrency: 128)
    owner = {:legacy_session, "fast-request-owner"}

    jobs =
      for id <- 1..100 do
        Task.async(fn ->
          Server.dispatch(
            server,
            %{kind: :request, id: id, method: "unknown/method", params: %{}},
            %{principal: "fast-request-principal"},
            version: @legacy,
            transport: :http,
            owner: owner
          )
        end)
      end

    results = Task.await_many(jobs, 5_000)

    Enum.each(Enum.zip(1..100, results), fn {id, result} ->
      assert {^id, %{"error" => %{"code" => -32601}}} = result
    end)

    events =
      for _index <- 1..200 do
        assert_receive event = {:detached_telemetry, _name, _measurements, _metadata}, 5_000
        event
      end

    starts =
      Enum.filter(events, fn
        {:detached_telemetry, [:attesto_mcp_server, :request, :start], _, _} -> true
        _ -> false
      end)

    terminals = events -- starts
    assert length(starts) == 100
    assert length(terminals) == 100

    start_correlations =
      MapSet.new(starts, fn {:detached_telemetry, _, _, metadata} ->
        metadata.correlation_id
      end)

    terminal_correlations =
      MapSet.new(terminals, fn {:detached_telemetry, event, _, metadata} ->
        assert event == [:attesto_mcp_server, :request, :stop]
        assert metadata.outcome == -32601
        metadata.correlation_id
      end)

    assert terminal_correlations == start_correlations
    assert eventually(fn -> Server.stats(server).active_requests == 0 end)
    assert Server.stats(server).active == 0
  end

  test "detached legacy work remains cancellable after its response owner dies" do
    parent = self()
    telemetry_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        telemetry_id,
        [
          [:attesto_mcp_server, :request, :start],
          [:attesto_mcp_server, :request, :stop],
          [:attesto_mcp_server, :request, :exception],
          [:attesto_mcp_server, :cancellation, :request],
          [:attesto_mcp_server, :cancellation, :stop]
        ],
        &__MODULE__.telemetry_handler/4,
        parent
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)
    {:ok, server} = Server.start_link(max_concurrency: 1)

    assert :ok =
             Server.register_tool(server, "detached-cancel", %{
               handler: fn _, _context ->
                 send(parent, :detached_started)
                 Process.sleep(5_000)
                 {:ok, %{"late" => true}}
               end
             })

    request = %{
      kind: :request,
      id: 77,
      method: "tools/call",
      params: %{"name" => "detached-cancel", "arguments" => %{}}
    }

    owner =
      spawn(fn ->
        Server.dispatch(
          server,
          request,
          %{principal: "legacy-owner"},
          version: @legacy,
          transport: :http,
          owner: {:legacy_session, "session-77"}
        )
      end)

    assert_receive :detached_started, 1_000
    Process.exit(owner, :kill)
    assert eventually(fn -> Server.stats(server).active_requests == 1 end)

    assert :ok =
             Server.cancel_request(
               server,
               "legacy-owner",
               77,
               {:legacy_session, "session-77"}
             )

    assert eventually(fn -> Server.stats(server).active_requests == 0 end)
    assert Server.stats(server).active == 0

    assert_receive {:detached_telemetry, [:attesto_mcp_server, :request, :start], _,
                    %{method: "tools/call", correlation_id: correlation}}

    assert correlation =~ ~r/^[0-9a-f]{16}$/

    assert_receive {:detached_telemetry, [:attesto_mcp_server, :cancellation, :request], _,
                    %{correlation_id: ^correlation, outcome: :requested}}

    assert_receive {:detached_telemetry, [:attesto_mcp_server, :cancellation, :stop], _,
                    %{correlation_id: ^correlation, outcome: :cancelled}}

    assert_receive {:detached_telemetry, [:attesto_mcp_server, :request, :stop], _,
                    %{correlation_id: ^correlation, outcome: :cancelled}}

    refute_receive {:detached_telemetry, [:attesto_mcp_server, :request, :stop], _,
                    %{correlation_id: ^correlation}},
                   100

    refute_receive {:detached_telemetry, [:attesto_mcp_server, :request, :exception], _,
                    %{correlation_id: ^correlation}},
                   100
  end

  def telemetry_handler(event, measurements, metadata, receiver),
    do: send(receiver, {:detached_telemetry, event, measurements, metadata})

  defp legacy_stream_relay(parent, tag) do
    receive do
      :stop ->
        :ok

      message = {:mcp_legacy_event, _ref, _event_id, _event} ->
        send(parent, {tag, message})
        legacy_stream_relay(parent, tag)
    end
  end

  defp modern_meta,
    do: %{
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => @modern,
        "io.modelcontextprotocol/clientCapabilities" => %{}
      }
    }

  defp unknown_wire(id, method \\ "unknown/method"),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" =>
        Map.update!(modern_meta(), "_meta", &Map.put(&1, "progressToken", "unknown-progress"))
    }

  defp legacy_session(port, token) do
    socket = connect(port)

    {200, headers, _body} =
      request(
        socket,
        "POST",
        "/mcp",
        [
          {"host", "127.0.0.1"},
          {"authorization", "Bearer " <> token},
          {"accept", "application/json, text/event-stream"},
          {"content-type", "application/json"}
        ],
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => @legacy,
            "capabilities" => %{},
            "clientInfo" => %{"name" => "p12", "version" => "1"}
          }
        })
      )

    session_id = List.first(headers["mcp-session-id"])

    {202, _headers, _body} =
      request(
        socket,
        "POST",
        "/mcp",
        [
          {"host", "127.0.0.1"},
          {"authorization", "Bearer " <> token},
          {"accept", "application/json, text/event-stream"},
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

    :gen_tcp.close(socket)
    session_id
  end

  defp legacy_headers(token, session_id),
    do: [
      {"host", "127.0.0.1"},
      {"authorization", "Bearer " <> token},
      {"accept", "application/json, text/event-stream"},
      {"content-type", "application/json"},
      {"mcp-session-id", session_id},
      {"mcp-protocol-version", @legacy}
    ]

  defp legacy_stream_body(id, tag),
    do:
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => "tools/call",
        "params" => %{
          "name" => "legacy-stream",
          "arguments" => %{"tag" => tag},
          "_meta" => %{"progressToken" => "progress-#{tag}"}
        }
      })

  defp call_http(plug, token, body, version, accept, session_id \\ nil) do
    conn =
      conn(:post, "/mcp", Jason.encode!(body))
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", accept)
      |> put_req_header("mcp-method", body["method"])

    conn = if version, do: put_req_header(conn, "mcp-protocol-version", version), else: conn
    conn = if session_id, do: put_req_header(conn, "mcp-session-id", session_id), else: conn
    Server.Plug.call(conn, plug)
  end

  defp connect(port),
    do:
      (
        {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
        socket
      )

  defp send_request(socket, method, path, headers, body) do
    headers = headers ++ [{"content-length", Integer.to_string(byte_size(body))}]

    :gen_tcp.send(
      socket,
      IO.iodata_to_binary([
        method,
        " ",
        path,
        " HTTP/1.1\r\n",
        Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
        "\r\n",
        body
      ])
    )
  end

  defp request(socket, method, path, headers, body) do
    :ok = send_request(socket, method, path, headers, body)
    {head, rest} = recv_headers(socket)
    [status_line | header_lines] = String.split(head, "\r\n", trim: true)
    [_, status] = Regex.run(~r/^HTTP\/\d\.\d (\d+)/, status_line)
    headers = parse_headers(header_lines)
    {body, _} = recv_body(socket, headers, rest)
    {String.to_integer(status), headers, body}
  end

  defp recv_headers(socket, buffer \\ <<>>) do
    case :binary.match(buffer, "\r\n\r\n") do
      {offset, 4} ->
        {binary_part(buffer, 0, offset),
         binary_part(buffer, offset + 4, byte_size(buffer) - offset - 4)}

      :nomatch ->
        {:ok, chunk} = :gen_tcp.recv(socket, 0, 1_000)
        recv_headers(socket, buffer <> chunk)
    end
  end

  defp recv_until(socket, buffer, marker) do
    if String.contains?(buffer, marker) do
      {buffer, <<>>}
    else
      {:ok, chunk} = :gen_tcp.recv(socket, 0, 2_000)
      recv_until(socket, buffer <> chunk, marker)
    end
  end

  defp parse_headers(lines),
    do:
      Enum.group_by(
        lines,
        fn line -> line |> String.split(":", parts: 2) |> hd() |> String.downcase() end,
        fn line -> line |> String.split(":", parts: 2) |> List.last() |> String.trim() end
      )

  defp recv_body(socket, headers, rest) do
    case headers["content-length"] do
      [length] -> recv_exact(socket, rest, String.to_integer(length))
      _ -> {rest, <<>>}
    end
  end

  defp recv_exact(_socket, buffer, needed) when byte_size(buffer) >= needed,
    do: {binary_part(buffer, 0, needed), binary_part(buffer, needed, byte_size(buffer) - needed)}

  defp recv_exact(socket, buffer, needed) do
    {:ok, chunk} = :gen_tcp.recv(socket, 0, 1_000)
    recv_exact(socket, buffer <> chunk, needed)
  end

  defp eventually(fun, attempts \\ 100),
    do:
      if(fun.(),
        do: true,
        else:
          if(attempts == 0,
            do: false,
            else:
              (
                Process.sleep(10)
                eventually(fun, attempts - 1)
              )
          )
      )
end
