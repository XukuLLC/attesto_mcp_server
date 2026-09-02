defmodule AttestoMCP.Server.PrincipalBindingMountAuthorizationTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AttestoMCP.Server
  alias AttestoMCP.Server.Session

  @resource "https://mcp.example.com/mcp"
  @modern "2026-07-28"
  @legacy "2025-11-25"

  defmodule Callbacks do
    @moduledoc false

    def binding(%{id: id}), do: id
    def shared_binding(_principal), do: "shared-binding"

    def authorize(events, context) do
      Agent.update(events, &(&1 ++ [{:authorize, context}]))
      context.principal.role == :admin
    end
  end

  defmodule BodyReadProbeAdapter do
    @moduledoc false

    def read_req_body({payload, events}, opts) do
      Agent.update(events, &(&1 ++ [:body_read]))
      {result, body, next_payload} = Plug.Adapters.Test.Conn.read_req_body(payload, opts)
      {result, body, {next_payload, events}}
    end

    def send_resp({payload, events}, status, headers, body) do
      {:ok, sent_body, next_payload} =
        Plug.Adapters.Test.Conn.send_resp(payload, status, headers, body)

      {:ok, sent_body, {next_payload, events}}
    end
  end

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

  test "a stable binding owns legacy sessions while handlers receive each loaded principal", %{
    config: config,
    server: server
  } do
    parent = self()
    {:ok, loads} = Agent.start_link(fn -> 0 end)

    principal_loader = fn claims, _sender ->
      load = Agent.get_and_update(loads, fn current -> {current + 1, current + 1} end)
      {:ok, %{id: claims["sub"], load: load, role: :admin}}
    end

    assert :ok =
             Server.register_tool(server, "identity", %{
               handler: fn _, context ->
                 send(parent, {:handler_context, context})
                 {:ok, "ok"}
               end
             })

    plug =
      build_plug(server, config,
        auth_principal: principal_loader,
        principal_binding: {Callbacks, :binding}
      )

    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())
    initialized = legacy_initialize(plug, token)

    assert initialized.status == 200
    [session_id] = get_resp_header(initialized, "mcp-session-id")
    assert {:ok, session} = Server.get_session(server, session_id, "usr_123")
    assert session.principal == "usr_123"
    assert :ok = Server.mark_initialized(server, session_id)

    called = legacy_tool_call(plug, token, session_id, "identity")
    assert called.status == 200

    assert_receive {:handler_context, context}
    assert context.principal == %{id: "usr_123", load: 2, role: :admin}
    assert context.principal_binding == "usr_123"
    assert context.attesto_mcp_principal == context.principal

    stream = Task.async(fn -> legacy_get(plug, token, session_id) end)
    assert eventually(fn -> Server.stats(server).legacy_streams == 1 end)
    assert :ok = Server.publish(server, %{"type" => "toolsListChanged"})
    assert :ok = Server.delete_session(server, session_id)

    streamed = Task.await(stream, 2_000)
    assert streamed.status == 200
    assert streamed.resp_body =~ "notifications/tools/list_changed"
  end

  test "omitting principal_binding retains loaded-principal equality semantics", %{
    config: config,
    server: server
  } do
    parent = self()
    {:ok, loads} = Agent.start_link(fn -> 0 end)

    principal_loader = fn claims, _sender ->
      load = Agent.get_and_update(loads, fn current -> {current + 1, current + 1} end)
      {:ok, %{id: claims["sub"], load: load}}
    end

    assert :ok =
             Server.register_tool(server, "unchanged-default", %{
               handler: fn _, _ ->
                 send(parent, :default_handler_called)
                 {:ok, "unexpected"}
               end
             })

    plug = build_plug(server, config, auth_principal: principal_loader)
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())
    initialized = legacy_initialize(plug, token)
    [session_id] = get_resp_header(initialized, "mcp-session-id")
    assert :ok = Server.mark_initialized(server, session_id)

    rejected = legacy_tool_call(plug, token, session_id, "unchanged-default")
    assert rejected.status == 404

    assert get_in(Jason.decode!(rejected.resp_body), ["error", "data", "reason"]) ==
             "session_not_found"

    refute_receive :default_handler_called
  end

  test "two loaded principals with one binding share legacy session ownership", %{
    config: config,
    server: server
  } do
    parent = self()
    {:ok, principals} = Agent.start_link(fn -> [%{id: "principal-a"}, %{id: "principal-b"}] end)

    principal_loader = fn _claims, _sender ->
      Agent.get_and_update(principals, fn [principal | rest] -> {principal, rest} end)
      |> then(&{:ok, &1})
    end

    assert :ok =
             Server.register_tool(server, "shared-owner", %{
               handler: fn _, context ->
                 send(parent, {:shared_owner_context, context})
                 {:ok, "ok"}
               end
             })

    plug =
      build_plug(server, config,
        auth_principal: principal_loader,
        principal_binding: {Callbacks, :shared_binding}
      )

    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())
    initialized = legacy_initialize(plug, token)
    assert initialized.status == 200
    [session_id] = get_resp_header(initialized, "mcp-session-id")
    assert :ok = Server.mark_initialized(server, session_id)

    response = legacy_tool_call(plug, token, session_id, "shared-owner")

    assert response.status == 200
    assert_receive {:shared_owner_context, %{principal: %{id: "principal-b"}}}
  end

  test "mount authorization follows authentication and precedes body reading and dispatch", %{
    config: config,
    server: server
  } do
    {:ok, events} = Agent.start_link(fn -> [] end)

    principal_loader = fn claims, _sender ->
      Agent.update(events, &(&1 ++ [:principal_loaded]))
      {:ok, %{id: claims["sub"], role: :viewer}}
    end

    assert :ok =
             Server.register_tool(server, "guarded", %{
               handler: fn _, _ ->
                 Agent.update(events, &(&1 ++ [:handler]))
                 {:ok, "unexpected"}
               end
             })

    plug =
      build_plug(server, config,
        auth_principal: principal_loader,
        authorize: {Callbacks, :authorize, [events]}
      )

    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())

    unauthenticated =
      modern_tool_request("guarded")
      |> probe_body_reads(events)
      |> Server.Plug.call(plug)

    assert unauthenticated.status == 401
    assert Agent.get(events, & &1) == []

    for method <- [:post, :get, :delete] do
      Agent.update(events, fn _ -> [] end)

      request =
        case method do
          :post -> modern_tool_request("guarded") |> probe_body_reads(events)
          :get -> conn(:get, "/mcp") |> put_req_header("accept", "text/event-stream")
          :delete -> conn(:delete, "/mcp")
        end

      response =
        request
        |> put_private(:attesto_mcp_handler_context, %{
          principal: %{id: "forged", role: :admin}
        })
        |> assign(:attesto_mcp_principal_binding, "forged")
        |> put_req_header("authorization", "Bearer " <> token)
        |> Server.Plug.call(plug)

      assert response.status == 403
      assert response.resp_body == "forbidden"
      assert get_resp_header(response, "www-authenticate") == []

      assert [:principal_loaded, {:authorize, context}] = Agent.get(events, & &1)
      assert context.principal == %{id: "usr_123", role: :viewer}
      assert context.principal_binding == context.principal
    end
  end

  test "an allowed mount callback and context builder each run once", %{
    config: config,
    server: server
  } do
    parent = self()
    {:ok, calls} = Agent.start_link(fn -> %{authorize: 0, context_builder: 0} end)

    principal_loader = fn claims, _sender ->
      {:ok, %{id: claims["sub"], role: :admin}}
    end

    context_builder = fn _conn ->
      Agent.update(calls, &Map.update!(&1, :context_builder, fn count -> count + 1 end))
      %{request_marker: "host"}
    end

    authorize = fn context ->
      Agent.update(calls, &Map.update!(&1, :authorize, fn count -> count + 1 end))
      context.principal.role == :admin and context.host_context.request_marker == "host"
    end

    assert :ok =
             Server.register_tool(server, "allowed", %{
               handler: fn _, context ->
                 send(parent, {:allowed_context, context})
                 {:ok, "ok"}
               end
             })

    plug =
      build_plug(server, config,
        auth_principal: principal_loader,
        principal_binding: & &1.id,
        context_builder: context_builder,
        authorize: authorize
      )

    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())

    response =
      modern_tool_request("allowed")
      |> put_req_header("authorization", "Bearer " <> token)
      |> Server.Plug.call(plug)

    assert response.status == 200
    assert Agent.get(calls, & &1) == %{authorize: 1, context_builder: 1}

    assert_receive {:allowed_context, context}
    assert context.principal == %{id: "usr_123", role: :admin}
    assert context.principal_binding == "usr_123"
    assert context.host_context == %{request_marker: "host"}
  end

  test "binding callback validation and runtime failures fail closed before body reading", %{
    config: config,
    server: server
  } do
    assert_raise ArgumentError,
                 ~r/:principal_binding must be a supported one-argument callback/,
                 fn ->
                   build_plug(server, config, principal_binding: :not_a_callback)
                 end

    assert_raise ArgumentError, ~r/:authorize must be a supported one-argument callback/, fn ->
      build_plug(server, config, authorize: fn _, _ -> true end)
    end

    base_options = [server: server, path: "/mcp", auth: [config: config, resource: @resource]]

    assert_raise ArgumentError, ~r/:principal_binding must be configured at most once/, fn ->
      Server.Plug.init(
        base_options ++
          [principal_binding: & &1, principal_binding: & &1]
      )
    end

    assert_raise ArgumentError, ~r/:authorize must be configured at most once/, fn ->
      Server.Plug.init(base_options ++ [authorize: fn _ -> true end, authorize: fn _ -> true end])
    end

    {:ok, events} = Agent.start_link(fn -> [] end)
    plug = build_plug(server, config, principal_binding: fn _principal -> self() end)
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())

    response =
      modern_tool_request("missing")
      |> probe_body_reads(events)
      |> put_req_header("authorization", "Bearer " <> token)
      |> Server.Plug.call(plug)

    assert response.status == 500

    assert get_in(Jason.decode!(response.resp_body), ["error", "data", "reason"]) ==
             "principal_binding_failure"

    assert Agent.get(events, & &1) == []

    raising_policy = build_plug(server, config, authorize: fn _ -> raise "private detail" end)

    denied =
      modern_tool_request("missing")
      |> probe_body_reads(events)
      |> put_req_header("authorization", "Bearer " <> token)
      |> Server.Plug.call(raising_policy)

    assert denied.status == 403
    assert denied.resp_body == "forbidden"
    refute denied.resp_body =~ "private detail"
    assert Agent.get(events, & &1) == []
  end

  test "existing version-1 durable rows retain their field and decoding contract" do
    encoded_principal = "alice" |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)
    encoded_tenant = "tenant-a" |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)

    existing_record = %{
      "format_version" => 1,
      "id" => "existing-session",
      "principal" => encoded_principal,
      "tenant" => encoded_tenant,
      "protocol_version" => @legacy,
      "initialized" => true,
      "created_at_ms" => 1,
      "last_seen_ms" => 1,
      "absolute_timeout_ms" => 86_400_000,
      "idle_timeout_ms" => 1_800_000,
      "client_capabilities" => %{},
      "resource_subscriptions" => %{},
      "logging_level" => nil
    }

    assert {:ok, session} = Session.from_record(existing_record)
    assert session.principal == "alice"
    assert session.tenant == "tenant-a"
    assert {:ok, rewritten} = Session.to_record(session)
    assert rewritten["format_version"] == 1
    assert rewritten["principal"] == encoded_principal
    refute Map.has_key?(rewritten, "principal_binding")
  end

  defp build_plug(server, config, opts) do
    auth = [config: config, resource: @resource]

    auth =
      case Keyword.fetch(opts, :auth_principal) do
        {:ok, callback} -> Keyword.put(auth, :principal, callback)
        :error -> auth
      end

    plug_opts =
      [server: server, path: "/mcp", auth: auth]
      |> Keyword.merge(Keyword.take(opts, [:principal_binding, :context_builder, :authorize]))

    Server.Plug.init(plug_opts)
  end

  defp legacy_initialize(plug, token) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @legacy,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "binding-test", "version" => "1.0"}
      }
    }

    conn(:post, "/mcp", Jason.encode!(request))
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> Server.Plug.call(plug)
  end

  defp legacy_tool_call(plug, token, session_id, name) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => %{}}
    }

    conn(:post, "/mcp", Jason.encode!(request))
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("mcp-session-id", session_id)
    |> put_req_header("mcp-protocol-version", @legacy)
    |> Server.Plug.call(plug)
  end

  defp legacy_get(plug, token, session_id) do
    conn(:get, "/mcp")
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("accept", "text/event-stream")
    |> put_req_header("mcp-session-id", session_id)
    |> put_req_header("mcp-protocol-version", @legacy)
    |> Server.Plug.call(plug)
  end

  defp modern_tool_request(name) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 3,
      "method" => "tools/call",
      "params" => %{
        "name" => name,
        "arguments" => %{},
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @modern,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    conn(:post, "/mcp", Jason.encode!(request))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("mcp-protocol-version", @modern)
    |> put_req_header("mcp-method", "tools/call")
    |> put_req_header("mcp-name", name)
  end

  defp probe_body_reads(%Plug.Conn{adapter: {Plug.Adapters.Test.Conn, payload}} = conn, events) do
    %{conn | adapter: {BodyReadProbeAdapter, {payload, events}}}
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
