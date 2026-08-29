defmodule AttestoMCP.Server.HostExtensionsTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AttestoMCP.Server
  alias AttestoMCP.Server.Result
  alias AttestoMCP.Server.Subscriptions

  @modern "2026-07-28"
  @resource "https://mcp.example.com/mcp"

  defmodule Callbacks do
    @moduledoc false

    def context(prefix, conn), do: %{source: prefix, request_path: conn.request_path}

    def allow_operator(context), do: context.host_context == %{group: "operators"}

    def allow_group(group, context), do: context.host_context == %{group: group}

    def task_init(parent, caller, context) do
      send(parent, {:task_init, self(), caller, context.method})
      :ok
    end

    def report(parent, report) do
      send(parent, {:reported_exception, report})
      :ok
    end

    def telemetry(event, _measurements, metadata, parent) do
      send(parent, {:host_telemetry, event, metadata})
    end
  end

  test "HTTP context builders expose host data only under the reserved host key" do
    parent = self()
    {:ok, server} = start_server()

    assert :ok =
             Server.register_tool(server, "inspect-context", %{
               handler: fn _arguments, context ->
                 send(parent, {:handler_context, context})
                 {:ok, "ok"}
               end
             })

    config = AttestoMCP.Test.Factory.config()
    scope = AttestoMCP.Scopes.tools_call()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: [scope])

    state =
      Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource],
        scope_map: %{"tools/call" => [scope]},
        context_builder: fn conn ->
          %{principal: "forged", scopes: ["admin"], request_path: conn.request_path}
        end
      )

    response = modern_tool_call(state, token, "inspect-context")
    assert response.status == 200

    assert_receive {:handler_context, context}
    assert context.host_context == %{principal: "forged", scopes: ["admin"], request_path: "/mcp"}
    refute context.principal == "forged"
    assert scope in context.scopes

    mfa_state =
      Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource],
        scope_map: %{"tools/call" => [scope]},
        context_builder: {Callbacks, :context, [:mfa]}
      )

    assert modern_tool_call(mfa_state, token, "inspect-context").status == 200
    assert_receive {:handler_context, %{host_context: %{source: :mfa, request_path: "/mcp"}}}
  end

  test "definition authorization receives isolated host context and denies neutrally" do
    parent = self()
    {:ok, server} = start_server()

    assert :ok =
             Server.register_tool(server, "host-authorized", %{
               authorize: fn context ->
                 send(parent, {:authorize_context, context})
                 context.host_context == %{group: "operators"}
               end,
               handler: fn _arguments, _context ->
                 send(parent, :host_authorized_handler)
                 {:ok, "ok"}
               end
             })

    config = AttestoMCP.Test.Factory.config()
    scope = AttestoMCP.Scopes.tools_call()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: [scope])

    state = fn group ->
      Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource],
        scope_map: %{"tools/call" => [scope]},
        context_builder: fn _conn -> %{group: group} end
      )
    end

    assert modern_tool_call(state.("operators"), token, "host-authorized").status == 200

    assert_receive {:authorize_context, %{host_context: %{group: "operators"}}}
    assert_receive :host_authorized_handler

    denied = modern_tool_call(state.("auditors"), token, "host-authorized")
    assert denied.status == 200
    assert Jason.decode!(denied.resp_body)["error"]["code"] == -32602
    assert_receive {:authorize_context, %{host_context: %{group: "auditors"}}}
    refute_received :host_authorized_handler

    for {name, authorize} <- [
          {"mfa-authorized", {Callbacks, :allow_operator}},
          {"prefixed-mfa-authorized", {Callbacks, :allow_group, ["operators"]}}
        ] do
      assert :ok =
               Server.register_tool(server, name, %{
                 authorize: authorize,
                 handler: fn _arguments, _context -> {:ok, "ok"} end
               })

      assert modern_tool_call(state.("operators"), token, name).status == 200

      denied = modern_tool_call(state.("auditors"), token, name)
      assert denied.status == 200
      assert Jason.decode!(denied.resp_body)["error"]["code"] == -32602
    end
  end

  test "invalid or raising context builders fail closed and never invoke handlers" do
    parent = self()
    {:ok, server} = start_server()

    assert :ok =
             Server.register_tool(server, "guarded", %{
               handler: fn _arguments, _context ->
                 send(parent, :guarded_handler_called)
                 {:ok, "no"}
               end
             })

    config = AttestoMCP.Test.Factory.config()
    scope = AttestoMCP.Scopes.tools_call()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: [scope])

    for builder <- [fn _conn -> :not_a_map end, fn _conn -> raise "private detail" end] do
      state =
        Server.Plug.init(
          server: server,
          path: "/mcp",
          auth: [config: config, resource: @resource],
          scope_map: %{"tools/call" => [scope]},
          context_builder: builder
        )

      response = modern_tool_call(state, token, "guarded")
      assert response.status == 500
      refute response.resp_body =~ "private detail"
      refute_receive :guarded_handler_called, 25
    end
  end

  test "safe business errors are explicit while arbitrary failures remain private" do
    {:ok, server} = start_server()

    assert :ok =
             Server.register_tool(server, "safe-tool", %{
               output_schema: %{
                 "type" => "object",
                 "required" => ["value"],
                 "properties" => %{"value" => %{"type" => "string"}}
               },
               handler: fn _arguments, _context ->
                 {:error, Result.error("payment declined", "payment_declined")}
               end
             })

    assert :ok =
             Server.register_tool(server, "private-tool", %{
               handler: fn _arguments, _context -> {:error, {:secret, "do not disclose"}} end
             })

    assert :ok =
             Server.register_prompt(server, "safe-prompt", %{
               handler: fn _arguments, _context ->
                 {:error, Result.error("prompt unavailable", "prompt_busy")}
               end
             })

    assert :ok =
             Server.register_resource(server, "urn:safe", %{
               handler: fn _arguments, _context ->
                 {:error, Result.error("resource temporarily unavailable")}
               end
             })

    assert :ok =
             Server.register_resource(server, "urn:private", %{
               handler: fn _arguments, _context -> {:error, "private upstream detail"} end
             })

    assert :ok =
             Server.register_tool(server, "forged-tool", %{
               handler: fn _arguments, _context ->
                 {:error,
                  %Result.ClientError{
                    message: String.duplicate("private", 1_000),
                    code: String.duplicate("x", 129)
                  }}
               end
             })

    safe_tool = dispatch(server, 1, "tools/call", %{"name" => "safe-tool", "arguments" => %{}})
    assert get_in(safe_tool, ["result", "isError"]) == true
    refute Map.has_key?(safe_tool["result"], "structuredContent")
    assert get_in(safe_tool, ["result", "_meta", "io.attesto/errorCode"]) == "payment_declined"
    assert get_in(safe_tool, ["result", "content", Access.at(0), "text"]) == "payment declined"

    private_tool =
      dispatch(server, 2, "tools/call", %{"name" => "private-tool", "arguments" => %{}})

    assert get_in(private_tool, ["result", "isError"]) == true

    assert get_in(private_tool, ["result", "content", Access.at(0), "text"]) ==
             "tool execution failed"

    refute inspect(private_tool) =~ "do not disclose"

    safe_prompt =
      dispatch(server, 3, "prompts/get", %{"name" => "safe-prompt", "arguments" => %{}})

    assert get_in(safe_prompt, ["error", "code"]) == -32_000
    assert get_in(safe_prompt, ["error", "message"]) == "prompt unavailable"
    assert get_in(safe_prompt, ["error", "data", "code"]) == "prompt_busy"

    safe_resource = dispatch(server, 4, "resources/read", %{"uri" => "urn:safe"})
    assert get_in(safe_resource, ["error", "code"]) == -32_000
    assert get_in(safe_resource, ["error", "message"]) == "resource temporarily unavailable"

    private_resource = dispatch(server, 40, "resources/read", %{"uri" => "urn:private"})
    assert get_in(private_resource, ["error", "code"]) == -32603
    refute inspect(private_resource) =~ "private upstream detail"

    forged =
      dispatch(server, 5, "tools/call", %{"name" => "forged-tool", "arguments" => %{}})

    assert get_in(forged, ["result", "content", Access.at(0), "text"]) ==
             "tool execution failed"

    refute inspect(forged) =~ "privateprivate"

    assert_raise ArgumentError, fn -> Result.error(String.duplicate("x", 4_097)) end
    assert_raise ArgumentError, fn -> Result.error("message", String.duplicate("x", 129)) end
  end

  test "default scopes replace generic defaults while explicit method scopes take precedence" do
    {:ok, server} = start_server()

    assert :ok =
             Server.register_tool(server, "scoped", %{
               handler: fn _arguments, _context -> {:ok, "ok"} end
             })

    config = AttestoMCP.Test.Factory.config()
    default_scope = "workspace.access"
    catalog_scope = "catalog.read"

    state =
      Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource],
        default_scopes: [default_scope],
        scope_map: %{"tools/list" => [catalog_scope], "tools/call" => []}
      )

    default_token = AttestoMCP.Test.Factory.access_token(config, scopes: [default_scope])

    generic_token =
      AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_call()])

    catalog_token = AttestoMCP.Test.Factory.access_token(config, scopes: [catalog_scope])

    assert modern_http_call(
             state,
             default_token,
             "tools/call",
             %{"name" => "scoped", "arguments" => %{}}
           ).status == 200

    assert modern_http_call(
             state,
             generic_token,
             "tools/call",
             %{"name" => "scoped", "arguments" => %{}}
           ).status == 403

    assert modern_http_call(state, default_token, "tools/list", %{}).status == 403
    assert modern_http_call(state, catalog_token, "tools/list", %{}).status == 200
  end

  test "subscription scopes union host event scopes after explicit/default precedence" do
    {:ok, server} = start_server()
    config = AttestoMCP.Test.Factory.config()
    default_scope = "workspace.access"
    listen_scope = "events.listen"
    event_scope = "events.receive"
    notifications = %{"toolsListChanged" => true}

    default_state =
      Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource],
        default_scopes: [default_scope],
        subscription_scopes: [event_scope],
        subscription_timeout: 20
      )

    default_only = AttestoMCP.Test.Factory.access_token(config, scopes: [default_scope])

    default_union =
      AttestoMCP.Test.Factory.access_token(config, scopes: [default_scope, event_scope])

    assert modern_http_call(default_state, default_only, "subscriptions/listen", %{
             "notifications" => notifications
           }).status == 403

    assert modern_http_call(default_state, default_union, "subscriptions/listen", %{
             "notifications" => notifications
           }).status == 200

    explicit_state =
      Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource],
        default_scopes: [default_scope],
        scope_map: %{"subscriptions/listen" => [listen_scope]},
        subscription_scopes: [event_scope],
        subscription_timeout: 20
      )

    explicit_union =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [AttestoMCP.Scopes.tools_read(), listen_scope, event_scope]
      )

    assert modern_http_call(explicit_state, default_union, "subscriptions/listen", %{
             "notifications" => notifications
           }).status == 403

    assert modern_http_call(explicit_state, explicit_union, "subscriptions/listen", %{
             "notifications" => notifications
           }).status == 200
  end

  test "worker initialization runs in the handler task and failures are reported generically" do
    parent = self()

    {:ok, server} =
      start_server(
        handler_task_init: {Callbacks, :task_init, [parent]},
        exception_reporter: {Callbacks, :report, [parent]}
      )

    assert :ok =
             Server.register_tool(server, "worker", %{
               handler: fn _arguments, _context ->
                 send(parent, {:handler_pid, self()})
                 {:ok, "ok"}
               end
             })

    assert get_in(dispatch(server, 5, "tools/call", %{"name" => "worker", "arguments" => %{}}), [
             "result",
             "isError"
           ]) != true

    assert_receive {:task_init, worker, caller, "tools/call"}
    assert caller == self()
    assert_receive {:handler_pid, ^worker}

    {:ok, failing} =
      start_server(
        handler_task_init: fn _caller, _context -> raise "private initialization failure" end,
        exception_reporter: {Callbacks, :report, [parent]}
      )

    assert :ok =
             Server.register_tool(failing, "blocked", %{
               handler: fn _arguments, _context ->
                 send(parent, :blocked_handler_called)
                 {:ok, "no"}
               end
             })

    failed = dispatch(failing, 6, "tools/call", %{"name" => "blocked", "arguments" => %{}})
    assert get_in(failed, ["error", "code"]) == -32603
    refute inspect(failed) =~ "private initialization failure"
    refute_receive :blocked_handler_called, 25
    assert_receive {:reported_exception, %{source: :handler_task_init, reason: %RuntimeError{}}}
  end

  test "atomic registration rolls back, coalesces invalidations, restores, and supports startup batches" do
    {:ok, server} = start_server()
    subscriptions = GenServer.call(server, :subscriptions)

    assert {:ok, "catalog"} =
             Subscriptions.open(
               subscriptions,
               "alice",
               nil,
               "catalog",
               %{
                 "toolsListChanged" => true,
                 "promptsListChanged" => true,
                 "resourcesListChanged" => true
               },
               self(),
               :catalog,
               nil
             )

    assert_receive {:mcp_subscription, :catalog, "catalog", _ack}

    registrations = [
      {:tool, "one", %{handler: fn _, _ -> {:ok, "one"} end}},
      {:tool, "two", %{handler: fn _, _ -> {:ok, "two"} end}},
      {:prompt, "prompt", %{handler: fn _, _ -> {:ok, %{"messages" => []}} end}},
      {:resource, "urn:item", %{handler: fn _, _ -> {:ok, %{"contents" => []}} end}}
    ]

    assert :ok = Server.register_all(server, registrations)

    assert_receive {:mcp_subscription, :catalog, "catalog",
                    %{"method" => "notifications/tools/list_changed"}}

    assert_receive {:mcp_subscription, :catalog, "catalog",
                    %{"method" => "notifications/prompts/list_changed"}}

    assert_receive {:mcp_subscription, :catalog, "catalog",
                    %{"method" => "notifications/resources/list_changed"}}

    refute_receive {:mcp_subscription, :catalog, "catalog", _extra}, 50

    before = Server.snapshot(server)

    assert {:error, {:duplicate, :tool, "one"}} =
             Server.register_all(server, [
               {:tool, "three", %{handler: fn _, _ -> {:ok, "three"} end}},
               {:tool, "one", %{handler: fn _, _ -> {:ok, "duplicate"} end}}
             ])

    assert Server.snapshot(server) == before
    refute_receive {:mcp_subscription, :catalog, "catalog", _rollback_event}, 50

    registry = GenServer.call(server, :registry)
    Process.exit(registry, :kill)
    assert eventually(fn -> Server.snapshot(server) == before end)

    startup = [
      {:tool, "startup", %{handler: fn _, _ -> {:ok, "ready"} end}}
    ]

    {:ok, startup_server} = start_server(registrations: startup)
    assert Map.has_key?(Server.snapshot(startup_server).tool, "startup")

    assert {:error, :too_many_registrations} =
             Server.register_all(server, List.duplicate({:tool, "bounded", %{}}, 1_001))
  end

  test "trusted telemetry metadata is bounded and unknown methods are normalized" do
    parent = self()
    handler_id = "host-extensions-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:attesto_mcp_server, :request, :start],
          [:attesto_mcp_server, :handler, :start],
          [:attesto_mcp_server, :handler, :stop]
        ],
        &Callbacks.telemetry/4,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, server} =
      start_server(server_name: "payments", telemetry_metadata: %{deployment: "west"})

    assert :ok =
             Server.register_tool(server, "telemetry", %{
               handler: fn _, _ -> {:ok, "ok"} end
             })

    _result = dispatch(server, 7, "tools/call", %{"name" => "telemetry", "arguments" => %{}})

    assert_receive {:host_telemetry, [:attesto_mcp_server, :request, :start], request_metadata}
    assert request_metadata.deployment == "west"
    assert request_metadata.server == "payments"

    assert_receive {:host_telemetry, [:attesto_mcp_server, :handler, :start], handler_metadata}
    assert handler_metadata.deployment == "west"
    assert handler_metadata.primitive_type == :tool
    assert handler_metadata.primitive_identity == "telemetry"

    assert_receive {:host_telemetry, [:attesto_mcp_server, :handler, :stop], stop_metadata}
    assert stop_metadata.deployment == "west"

    unknown = %{
      kind: :request,
      id: 8,
      method: "private/method/name",
      params: modern_params(%{})
    }

    _result = Server.dispatch(server, unknown, %{principal: "alice"}, version: @modern)
    assert_receive {:host_telemetry, [:attesto_mcp_server, :request, :start], unknown_metadata}
    assert unknown_metadata.method == :unknown
    refute inspect(unknown_metadata) =~ "private/method/name"

    assert_invalid_start([telemetry_metadata: %{method: "forged"}], "no reserved keys")
  end

  test "child specs use stable independent ids" do
    assert Server.child_spec([]).id == Server
    assert Server.child_spec(name: :primary_mcp).id == :primary_mcp
    assert Server.child_spec(name: :secondary_mcp).id == :secondary_mcp
    assert_raise ArgumentError, fn -> Server.child_spec(name: "not-an-atom") end
  end

  test "slow subscription authorization cannot block or terminate the server" do
    parent = self()
    {:ok, server} = start_server()
    subscriptions = GenServer.call(server, :subscriptions)

    authorize = fn _context ->
      send(parent, {:subscription_authorizing, self()})

      receive do
        :continue_subscription -> true
      after
        1_000 -> false
      end
    end

    assert {:ok, "slow"} =
             Subscriptions.open(
               subscriptions,
               "alice",
               nil,
               "slow",
               %{"toolsListChanged" => true},
               self(),
               :slow,
               authorize
             )

    assert_receive {:mcp_subscription, :slow, "slow", _ack}

    publish = Task.async(fn -> Server.publish(server, %{"type" => "toolsListChanged"}) end)
    assert {:ok, :ok} = Task.yield(publish, 200)
    assert_receive {:subscription_authorizing, authorizer}, 200

    options = Task.async(fn -> Server.options(server) end)
    assert {:ok, opts} = Task.yield(options, 200)
    assert is_list(opts)
    assert Process.alive?(server)

    send(authorizer, :continue_subscription)
    assert_receive {:mcp_subscription, :slow, "slow", event}, 500
    assert event["method"] == "notifications/tools/list_changed"
  end

  test "subscription recovery preserves trusted telemetry metadata" do
    parent = self()
    handler_id = "subscription-recovery-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:attesto_mcp_server, :subscription, :open],
        &Callbacks.telemetry/4,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, server} = start_server(telemetry_metadata: %{deployment: "west"})
    previous = GenServer.call(server, :subscriptions)
    Process.exit(previous, :kill)

    assert eventually(fn ->
             current = GenServer.call(server, :subscriptions)
             current != previous and Process.alive?(current)
           end)

    recovered = GenServer.call(server, :subscriptions)

    assert {:ok, "recovered"} =
             Subscriptions.open(
               recovered,
               "alice",
               nil,
               "recovered",
               %{"toolsListChanged" => true},
               self(),
               :recovered,
               nil
             )

    assert_receive {:host_telemetry, [:attesto_mcp_server, :subscription, :open], metadata}
    assert metadata.deployment == "west"
  end

  test "unexpected messages are ignored and status reports redact private server options" do
    {:ok, server} =
      start_server(
        cursor_secret: "cursor-private",
        request_state_secret: "request-state-private"
      )

    send(server, {:unexpected, make_ref()})
    GenServer.cast(server, {:unexpected_cast, make_ref()})
    assert {:error, :unsupported} = GenServer.call(server, {:unexpected_call, make_ref()})
    assert is_list(Server.options(server))
    assert Process.alive?(server)

    status = Server.format_status(%{state: :sys.get_state(server), reason: :test})
    refute Keyword.has_key?(status.state.opts, :cursor_secret)
    refute Keyword.has_key?(status.state.opts, :request_state_secret)
    assert status.reason == :test
  end

  defp start_server(opts \\ []) do
    start_supervised(%{Server.child_spec(opts) | id: make_ref()})
  end

  defp modern_tool_call(state, token, name) do
    modern_http_call(state, token, "tools/call", %{"name" => name, "arguments" => %{}})
  end

  defp modern_http_call(state, token, method, params) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => modern_params(params)
    }

    conn =
      conn(:post, "/mcp", Jason.encode!(request))
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", @modern)
      |> put_req_header("mcp-method", method)

    conn =
      if method in ["tools/call", "resources/read"] do
        put_req_header(conn, "mcp-name", params["name"] || params["uri"])
      else
        conn
      end

    Server.Plug.call(conn, state)
  end

  defp dispatch(server, id, method, params) do
    request = %{kind: :request, id: id, method: method, params: modern_params(params)}
    {^id, response} = Server.dispatch(server, request, %{principal: "alice"}, version: @modern)
    response
  end

  defp modern_params(params) do
    Map.put(params, "_meta", %{
      "io.modelcontextprotocol/protocolVersion" => @modern,
      "io.modelcontextprotocol/clientCapabilities" => %{}
    })
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
  catch
    :exit, _ ->
      Process.sleep(10)
      eventually(fun, attempts - 1)
  end

  defp assert_invalid_start(opts, expected) do
    {_pid, monitor} = spawn_monitor(fn -> Server.start_link(opts) end)
    assert_receive {:DOWN, ^monitor, :process, _pid, reason}, 1_000
    assert inspect(reason) =~ expected
  end
end
