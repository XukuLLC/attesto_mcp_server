defmodule AttestoMCP.Server.PlugSubscriptionTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AttestoMCP.Server

  @resource "https://mcp.example.com/mcp"
  @version "2026-07-28"
  @legacy "2025-11-25"

  def telemetry_handler(event, measurements, metadata, parent) do
    send(parent, {:telemetry_event, event, measurements, metadata})
  end

  def sleep_handler(_event, _measurements, _metadata, ms), do: Process.sleep(ms)

  def notify_then_sleep_handler(event, measurements, metadata, {parent, ms}) do
    send(parent, {:telemetry_event, event, measurements, metadata})
    Process.sleep(ms)
  end

  defmodule ClosingAdapter do
    @moduledoc false
    # The Plug.Test adapter, except that every chunk after the first `allowed`
    # fails as it does once the client has disconnected.
    @behaviour Plug.Conn.Adapter

    alias Plug.Adapters.Test.Conn, as: TestConn

    def wrap(%Plug.Conn{adapter: {TestConn, state}} = conn, allowed),
      do: %{conn | adapter: {__MODULE__, {state, allowed}}}

    @impl true
    def chunk({_state, 0}, _body), do: {:error, :closed}

    def chunk({state, allowed}, body) do
      {:ok, data, state} = TestConn.chunk(state, body)
      {:ok, data, {state, allowed - 1}}
    end

    @impl true
    def send_chunked({state, allowed}, status, headers) do
      {:ok, data, state} = TestConn.send_chunked(state, status, headers)
      {:ok, data, {state, allowed}}
    end

    @impl true
    def send_resp({state, allowed}, status, headers, body) do
      {:ok, data, state} = TestConn.send_resp(state, status, headers, body)
      {:ok, data, {state, allowed}}
    end

    @impl true
    def send_file({state, allowed}, status, headers, path, offset, length) do
      {:ok, data, state} = TestConn.send_file(state, status, headers, path, offset, length)
      {:ok, data, {state, allowed}}
    end

    @impl true
    def read_req_body({state, allowed}, opts) do
      {tag, data, state} = TestConn.read_req_body(state, opts)
      {tag, data, {state, allowed}}
    end

    @impl true
    def inform({state, _allowed}, status, headers), do: TestConn.inform(state, status, headers)

    @impl true
    def upgrade({state, allowed}, protocol, opts) do
      case TestConn.upgrade(state, protocol, opts) do
        {:ok, state} -> {:ok, {state, allowed}}
        error -> error
      end
    end

    @impl true
    def push({state, _allowed}, path, headers), do: TestConn.push(state, path, headers)

    @impl true
    def get_peer_data({state, _allowed}), do: TestConn.get_peer_data(state)

    @impl true
    def get_sock_data({state, _allowed}), do: TestConn.get_sock_data(state)

    @impl true
    def get_ssl_data({state, _allowed}), do: TestConn.get_ssl_data(state)

    @impl true
    def get_http_protocol({state, _allowed}), do: TestConn.get_http_protocol(state)
  end

  test "delivery verifier options reject mismatched sender bindings" do
    config = AttestoMCP.Test.Factory.config()
    verify_opts = [expected_typ: "access", trusted_audiences: [@resource]]

    first_jwk = JOSE.JWK.generate_key({:ec, :secp256r1})
    second_jwk = JOSE.JWK.generate_key({:ec, :secp256r1})
    {_proof, first_jkt} = AttestoMCP.Test.Factory.dpop_proof("placeholder", jwk: first_jwk)
    {_proof, second_jkt} = AttestoMCP.Test.Factory.dpop_proof("placeholder", jwk: second_jwk)
    dpop_token = AttestoMCP.Test.Factory.access_token(config, dpop_jkt: first_jkt)

    assert {:ok, _claims} =
             Attesto.Token.verify(
               config,
               dpop_token,
               Keyword.put(verify_opts, :dpop_jkt, first_jkt)
             )

    assert {:error, _reason} =
             Attesto.Token.verify(
               config,
               dpop_token,
               Keyword.put(verify_opts, :dpop_jkt, second_jkt)
             )

    assert {:error, _reason} = Attesto.Token.verify(config, dpop_token, verify_opts)

    first_thumbprint =
      :crypto.hash(:sha256, "certificate-a")
      |> Base.url_encode64(padding: false)

    second_thumbprint =
      :crypto.hash(:sha256, "certificate-b")
      |> Base.url_encode64(padding: false)

    mtls_token =
      AttestoMCP.Test.Factory.access_token(config, mtls_cert_thumbprint: first_thumbprint)

    assert {:ok, _claims} =
             Attesto.Token.verify(
               config,
               mtls_token,
               Keyword.put(verify_opts, :mtls_cert_thumbprint, first_thumbprint)
             )

    assert {:error, _reason} =
             Attesto.Token.verify(
               config,
               mtls_token,
               Keyword.put(verify_opts, :mtls_cert_thumbprint, second_thumbprint)
             )

    assert {:error, _reason} = Attesto.Token.verify(config, mtls_token, verify_opts)
  end

  test "subscription open requires the complete filter scope union" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource]
      )

    denied =
      AttestoMCP.Test.Factory.access_token(config, scopes: [])
      |> then(&listen_conn(plug, &1, 90, %{"toolsListChanged" => true}))
      |> AttestoMCP.Server.Plug.call(plug)

    assert denied.status == 403

    assert Jason.decode!(denied.resp_body)["error"]["data"]["required_scopes"] == [
             AttestoMCP.Scopes.tools_read()
           ]

    [challenge] = get_resp_header(denied, "www-authenticate")
    assert challenge =~ ~s(scope="mcp:tools:read")

    assert challenge =~
             ~s(resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp")

    partial =
      AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_read()])
      |> then(
        &listen_conn(plug, &1, 91, %{"toolsListChanged" => true, "promptsListChanged" => true})
      )
      |> AttestoMCP.Server.Plug.call(plug)

    assert partial.status == 403

    assert Jason.decode!(partial.resp_body)["error"]["data"]["required_scopes"] == [
             AttestoMCP.Scopes.tools_read(),
             AttestoMCP.Scopes.prompts_read()
           ]

    configured_plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        scope_map: %{"subscriptions/listen" => ["mcp:subscriptions:read"]},
        auth: [config: config, resource: @resource]
      )

    configured =
      AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_read()])
      |> then(&listen_conn(configured_plug, &1, 92, %{"toolsListChanged" => true}))
      |> AttestoMCP.Server.Plug.call(configured_plug)

    assert configured.status == 403

    assert Jason.decode!(configured.resp_body)["error"]["data"]["required_scopes"] == [
             AttestoMCP.Scopes.tools_read(),
             "mcp:subscriptions:read"
           ]
  end

  test "authenticated HTTP listen emits acknowledgment, event, and correlated final response" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()

    token =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [AttestoMCP.Scopes.tools_read()]
      )

    parent = self()

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource]
      )

    request = %{
      "jsonrpc" => "2.0",
      "id" => 99,
      "method" => "subscriptions/listen",
      "params" => %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @version,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        },
        "notifications" => %{"toolsListChanged" => true}
      }
    }

    pid =
      spawn(fn ->
        conn =
          conn(:post, "/mcp", Jason.encode!(request))
          |> put_req_header("authorization", "Bearer " <> token)
          |> put_req_header("content-type", "application/json")
          |> put_req_header("accept", "application/json, text/event-stream")
          |> put_req_header("mcp-protocol-version", @version)
          |> put_req_header("mcp-method", "subscriptions/listen")

        result = AttestoMCP.Server.Plug.call(conn, plug)
        send(parent, {:subscription_done, result})
      end)

    Process.sleep(50)
    Server.publish(server, %{"type" => "toolsListChanged"})
    Process.sleep(50)
    Server.close_subscription(server, 99, pid)

    assert_receive {:subscription_done, conn}, 2_000
    assert conn.status == 200

    messages =
      conn.resp_body
      |> String.split("\n\n", trim: true)
      |> Enum.map(fn event ->
        event |> String.split("data: ", parts: 2) |> List.last() |> Jason.decode!()
      end)

    assert Enum.at(messages, 0)["method"] == "notifications/subscriptions/acknowledged"
    assert Enum.at(messages, 1)["method"] == "notifications/tools/list_changed"
    assert Enum.at(messages, 2)["id"] == 99
    assert get_in(Enum.at(messages, 2), ["result", "resultType"]) == "complete"
    refute Process.alive?(pid)
  end

  test "subscription delivery reuses the configured trusted audience policy" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    gateway = "https://gateway.example.net/proxy/mcp"
    parent = self()

    token =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [AttestoMCP.Scopes.tools_read()],
        audience: gateway
      )

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [
          config: config,
          resource: @resource,
          trusted_audiences: [@resource, gateway]
        ]
      )

    id = 114
    pid = start_stream(parent, plug, token, id, %{"toolsListChanged" => true})

    assert :ok = await_subscriptions(server, 1)
    assert :ok = Server.publish(server, %{"type" => "toolsListChanged"})
    Server.close_subscription(server, id, pid)

    assert_receive {:subscription_done, ^id, conn}, 2_000

    assert Enum.map(stream_messages(conn), & &1["method"]) == [
             "notifications/subscriptions/acknowledged",
             "notifications/tools/list_changed",
             nil
           ]

    refute Process.alive?(pid)
  end

  test "DPoP subscription delivery rechecks the principal and suppresses events after revocation" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    parent = self()
    event = [:attesto_mcp_server, :subscription, :suppressed]
    handler_id = {__MODULE__, :principal_recheck, make_ref()}
    :ok = :telemetry.attach(handler_id, event, &__MODULE__.telemetry_handler/4, parent)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    policy =
      start_supervised!({Agent, fn -> %{allowed: true, calls: 0} end})

    principal = principal_policy(policy, parent)
    replay_table = :ets.new(:subscription_dpop_replay, [:set, :public])

    replay_check = fn replay_key, _ttl ->
      if :ets.insert_new(replay_table, {replay_key, true}), do: :ok, else: {:error, :replay}
    end

    jwk = JOSE.JWK.generate_key({:ec, :secp256r1})
    {_unused, jkt} = AttestoMCP.Test.Factory.dpop_proof("placeholder", jwk: jwk)

    token =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [AttestoMCP.Scopes.tools_read()],
        dpop_jkt: jkt
      )

    {proof, ^jkt} =
      AttestoMCP.Test.Factory.dpop_proof(token, jwk: jwk, htu: @resource)

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [
          config: config,
          resource: @resource,
          replay_check: replay_check,
          htu: fn _conn -> @resource end,
          principal: principal,
          claims_key: :host_claims,
          context_key: :host_context,
          principal_key: :host_principal,
          scopes_key: :host_scopes,
          sender_key: :host_sender
        ]
      )

    id = 110

    pid =
      spawn(fn ->
        conn =
          listen_conn(plug, token, id, %{"toolsListChanged" => true})
          |> assign(:attesto_mcp_claims, :untrusted)
          |> assign(:attesto_context, :untrusted)
          |> assign(:attesto_mcp_principal, :untrusted)
          |> assign(:attesto_mcp_scopes, :untrusted)
          |> assign(:attesto_mcp_sender, :untrusted)
          |> put_req_header("authorization", "DPoP " <> token)
          |> put_req_header("dpop", proof)

        send(parent, {:opaque_principal_stream, AttestoMCP.Server.Plug.call(conn, plug)})
      end)

    assert_receive {:principal_policy, 1, true, %{binding: :dpop, jkt: ^jkt}}, 1_000
    assert :ok = await_subscriptions(server, 1)

    assert :ok = Server.publish(server, %{"type" => "toolsListChanged"})
    assert_receive {:principal_policy, 2, true, %{binding: :dpop, jkt: ^jkt}}, 1_000

    Agent.update(policy, &%{&1 | allowed: false})
    assert :ok = Server.publish(server, %{"type" => "toolsListChanged"})
    assert_receive {:principal_policy, 3, false, %{binding: :dpop, jkt: ^jkt}}, 1_000

    assert_receive {:telemetry_event, ^event, %{count: 1},
                    %{reason: :authorization, transport: :core}},
                   1_000

    assert Agent.get(policy, & &1.calls) == 3

    Server.close_subscription(server, id, pid)

    assert_receive {:opaque_principal_stream, conn}, 2_000

    assert conn.assigns.host_claims == conn.assigns.attesto_mcp_claims
    assert conn.assigns.host_context == conn.assigns.attesto_context
    assert conn.assigns.host_principal == conn.assigns.attesto_mcp_principal
    assert conn.assigns.host_scopes == conn.assigns.attesto_mcp_scopes
    assert conn.assigns.host_sender == conn.assigns.attesto_mcp_sender

    assert Enum.map(stream_messages(conn), & &1["method"]) == [
             "notifications/subscriptions/acknowledged",
             "notifications/tools/list_changed",
             nil
           ]

    refute Process.alive?(pid)
  end

  for outcome <- [:refused, :deleted, :different_owner, :binding_refused, :same_owner] do
    @outcome outcome
    test "delivery ends on #{@outcome} unless the current binding still owns the subscription" do
      server = start_supervised!({Server, []})
      policy = start_supervised!({Agent, fn -> :initial end})
      config = AttestoMCP.Test.Factory.config()
      parent = self()

      loader = fn claims, _sender ->
        case Agent.get(policy, & &1) do
          :refused -> {:error, :revoked}
          :deleted -> {:ok, nil}
          :different_owner -> {:ok, %{id: "different", revision: 2}}
          :binding_refused -> {:ok, %{id: nil, revision: 2}}
          :same_owner -> {:ok, %{id: claims["sub"], revision: 2}}
          :initial -> {:ok, %{id: claims["sub"], revision: 1}}
        end
      end

      binding = fn principal ->
        send(parent, {:bound, principal})
        principal.id
      end

      plug =
        AttestoMCP.Server.Plug.init(
          server: server,
          path: "/mcp",
          principal_binding: binding,
          auth: [config: config, resource: @resource, principal: loader]
        )

      token =
        AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_read()])

      id = 996
      pid = start_stream(parent, plug, token, id, %{"toolsListChanged" => true})
      assert :ok = await_subscriptions(server, 1)
      assert_receive {:bound, %{revision: 1}}
      Agent.update(policy, fn _ -> @outcome end)
      assert :ok = Server.publish(server, %{"type" => "toolsListChanged"})

      if @outcome == :same_owner do
        assert_receive {:bound, %{id: "usr_123", revision: 2}}, 1_000
        assert :ok = await_subscriptions(server, 1)
        Server.close_subscription(server, id, pid)
        assert_receive {:subscription_done, ^id, conn}, 2_000

        assert Enum.count(
                 stream_messages(conn),
                 &(&1["method"] == "notifications/tools/list_changed")
               ) == 1
      else
        assert :ok = await_subscriptions(server, 0)
        assert_receive {:subscription_done, ^id, conn}, 2_000

        refute Enum.any?(
                 stream_messages(conn),
                 &(&1["method"] == "notifications/tools/list_changed")
               )
      end

      refute Process.alive?(pid)
    end
  end

  test "mTLS subscription delivery retains the verified certificate binding" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    parent = self()
    cert = AttestoMCP.Test.Factory.self_signed_cert_der()
    {:ok, thumbprint} = Attesto.MTLS.compute_thumbprint(cert)

    token =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [AttestoMCP.Scopes.tools_read()],
        mtls_cert_thumbprint: thumbprint
      )

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [
          config: config,
          resource: @resource,
          cert_der: fn _conn -> cert end
        ]
      )

    id = 111
    pid = start_stream(parent, plug, token, id, %{"toolsListChanged" => true})

    assert :ok = await_subscriptions(server, 1)
    assert :ok = Server.publish(server, %{"type" => "toolsListChanged"})

    Server.close_subscription(server, id, pid)

    assert_receive {:subscription_done, ^id, conn}, 2_000

    assert Enum.map(stream_messages(conn), & &1["method"]) == [
             "notifications/subscriptions/acknowledged",
             "notifications/tools/list_changed",
             nil
           ]

    refute Process.alive?(pid)
  end

  test "subscription delivery preserves the token-subject fallback without a principal callback" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    parent = self()

    token =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [AttestoMCP.Scopes.tools_read()]
      )

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource, principal: nil]
      )

    id = 113
    pid = start_stream(parent, plug, token, id, %{"toolsListChanged" => true})

    assert :ok = await_subscriptions(server, 1)
    assert :ok = Server.publish(server, %{"type" => "toolsListChanged"})
    Server.close_subscription(server, id, pid)

    assert_receive {:subscription_done, ^id, conn}, 2_000

    assert Enum.map(stream_messages(conn), & &1["method"]) == [
             "notifications/subscriptions/acknowledged",
             "notifications/tools/list_changed",
             nil
           ]

    refute Process.alive?(pid)
  end

  test "subscription delivery accepts an explicit null optional client_id" do
    {:ok, server} = Server.start_link([])
    base_config = AttestoMCP.Test.Factory.config()
    parent = self()

    config = %{
      base_config
      | principal_kinds: [Attesto.PrincipalKind.new("user", "usr_")]
    }

    {:ok, %{access_token: token}} =
      Attesto.Token.mint(config, %{
        claims: %{"client_id" => nil},
        kind: "user",
        scopes: [AttestoMCP.Scopes.tools_read()],
        sub: "usr_123"
      })

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [
          config: config,
          resource: @resource,
          principal: fn claims, _sender ->
            send(parent, {:null_client_principal, claims["client_id"]})
            {:ok, claims["sub"]}
          end
        ]
      )

    id = 115
    pid = start_stream(self(), plug, token, id, %{"toolsListChanged" => true})

    assert_receive {:null_client_principal, nil}, 1_000
    assert :ok = await_subscriptions(server, 1)
    assert :ok = Server.publish(server, %{"type" => "toolsListChanged"})
    assert_receive {:null_client_principal, nil}, 1_000
    Server.close_subscription(server, id, pid)

    assert_receive {:subscription_done, ^id, conn}, 2_000

    assert Enum.map(stream_messages(conn), & &1["method"]) == [
             "notifications/subscriptions/acknowledged",
             "notifications/tools/list_changed",
             nil
           ]

    refute Process.alive?(pid)
  end

  test "Phoenix subscription delivery reruns revocation and principal loading" do
    config_module = Module.concat([AttestoPhoenix, Config])
    adapter_module = Module.concat([AttestoPhoenix, DPoP, Adapter])
    protected_resource_module = Module.concat([AttestoPhoenix, ProtectedResource])
    callback_module = Module.concat([AttestoPhoenix, Callback])

    modules = [callback_module, protected_resource_module, adapter_module, config_module]

    Enum.each(modules, fn module ->
      :code.purge(module)
      :code.delete(module)
    end)

    config = AttestoMCP.Test.Factory.config()
    policy = start_supervised!({Agent, fn -> true end})

    runtime_key = {
      __MODULE__,
      :phoenix_stream_reauthorization,
      System.unique_integer([:positive, :monotonic])
    }

    :persistent_term.put(runtime_key, %{config: config, owner: self(), policy: policy})

    on_exit(fn ->
      :persistent_term.erase(runtime_key)

      Enum.each(modules, fn module ->
        :code.purge(module)
        :code.delete(module)
      end)
    end)

    Module.create(
      config_module,
      quote do
        def from_otp_app(:stream_reauthorization),
          do: :persistent_term.get(unquote(Macro.escape(runtime_key)))

        def to_attesto_config(%{config: config}), do: config

        def with_request_config(_config, fun), do: fun.()

        def load_principal_fun(%{owner: owner}),
          do: {__MODULE__, :load_principal, [owner]}

        def load_principal(subject, owner) do
          send(owner, {:phoenix_principal_loaded, subject})
          {:ok, %{subject: subject}}
        end
      end,
      Macro.Env.location(__ENV__)
    )

    Module.create(
      adapter_module,
      quote do
        def protected_resource_opts(_config), do: []
      end,
      Macro.Env.location(__ENV__)
    )

    Module.create(
      protected_resource_module,
      quote do
        def access_token_revoked?(%{owner: owner, policy: policy}, claims) do
          active? = Agent.get(policy, & &1)
          send(owner, {:phoenix_revocation_checked, claims["sub"], active?})
          not active?
        end
      end,
      Macro.Env.location(__ENV__)
    )

    Module.create(
      callback_module,
      quote do
        def invoke({module, function, extra}, args), do: apply(module, function, args ++ extra)
      end,
      Macro.Env.location(__ENV__)
    )

    auth_opts =
      :stream_reauthorization
      |> AttestoMCP.Server.Phoenix.protected_resource_options()
      |> Keyword.put(:resource, @resource)

    {:ok, server} = Server.start_link([])

    token =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [AttestoMCP.Scopes.tools_read()]
      )

    plug = AttestoMCP.Server.Plug.init(server: server, path: "/mcp", auth: auth_opts)
    id = 116
    pid = start_stream(self(), plug, token, id, %{"toolsListChanged" => true})

    assert_receive {:phoenix_revocation_checked, "usr_123", true}, 1_000
    assert_receive {:phoenix_principal_loaded, "usr_123"}, 1_000
    assert :ok = await_subscriptions(server, 1)

    Agent.update(policy, fn _active? -> false end)
    assert :ok = Server.publish(server, %{"type" => "toolsListChanged"})
    assert_receive {:phoenix_revocation_checked, "usr_123", false}, 1_000
    refute_receive {:phoenix_principal_loaded, "usr_123"}, 50

    Server.close_subscription(server, id, pid)
    assert_receive {:subscription_done, ^id, conn}, 2_000

    assert Enum.map(stream_messages(conn), & &1["method"]) == [
             "notifications/subscriptions/acknowledged",
             nil
           ]

    refute Process.alive?(pid)
  end

  test "legacy DPoP stream rechecks the principal and suppresses events after revocation" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    parent = self()

    policy =
      start_supervised!({Agent, fn -> %{allowed: true, calls: 0} end})

    replay_table = :ets.new(:legacy_subscription_dpop_replay, [:set, :public])

    replay_check = fn replay_key, _ttl ->
      if :ets.insert_new(replay_table, {replay_key, true}), do: :ok, else: {:error, :replay}
    end

    jwk = JOSE.JWK.generate_key({:ec, :secp256r1})
    {_unused, jkt} = AttestoMCP.Test.Factory.dpop_proof("placeholder", jwk: jwk)

    token =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: AttestoMCP.Scopes.all(),
        dpop_jkt: jkt
      )

    {initialize_proof, ^jkt} =
      AttestoMCP.Test.Factory.dpop_proof(token, jwk: jwk, htu: @resource)

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [
          config: config,
          resource: @resource,
          replay_check: replay_check,
          htu: fn _conn -> @resource end,
          principal: principal_policy(policy, parent)
        ]
      )

    session_id =
      initialize_legacy_session(plug, token, [
        {"authorization", "DPoP " <> token},
        {"dpop", initialize_proof}
      ])

    assert_receive {:principal_policy, 1, true, %{binding: :dpop, jkt: ^jkt}}, 1_000
    assert :ok = Server.mark_initialized(server, session_id)

    {stream_proof, ^jkt} =
      AttestoMCP.Test.Factory.dpop_proof(token,
        jwk: jwk,
        htm: "GET",
        htu: @resource
      )

    pid =
      spawn(fn ->
        conn =
          conn(:get, "/mcp")
          |> put_req_header("authorization", "DPoP " <> token)
          |> put_req_header("dpop", stream_proof)
          |> put_req_header("accept", "text/event-stream")
          |> put_req_header("mcp-session-id", session_id)
          |> put_req_header("mcp-protocol-version", @legacy)

        send(parent, {:legacy_stream_done, AttestoMCP.Server.Plug.call(conn, plug)})
      end)

    assert_receive {:principal_policy, 2, true, %{binding: :dpop, jkt: ^jkt}}, 1_000
    assert :ok = await_legacy_streams(server, 1)

    assert :ok = Server.publish(server, %{"type" => "toolsListChanged"})
    assert_receive {:principal_policy, 3, true, %{binding: :dpop, jkt: ^jkt}}, 1_000

    Agent.update(policy, &%{&1 | allowed: false})
    assert :ok = Server.publish(server, %{"type" => "toolsListChanged"})
    assert_receive {:principal_policy, 4, false, %{binding: :dpop, jkt: ^jkt}}, 1_000
    assert Agent.get(policy, & &1.calls) == 4

    assert :ok = Server.delete_session(server, session_id)
    assert_receive {:legacy_stream_done, conn}, 2_000
    assert conn.status == 200
    assert conn.resp_body =~ ": keepalive"
    assert conn.resp_body =~ "notifications/tools/list_changed"

    assert length(Regex.scan(~r/notifications\/tools\/list_changed/, conn.resp_body)) == 1

    refute Process.alive?(pid)
  end

  test "legacy mTLS stream delivery retains its verified certificate binding" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    parent = self()
    cert = AttestoMCP.Test.Factory.self_signed_cert_der()
    {:ok, thumbprint} = Attesto.MTLS.compute_thumbprint(cert)

    token =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: AttestoMCP.Scopes.all(),
        mtls_cert_thumbprint: thumbprint
      )

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [
          config: config,
          resource: @resource,
          cert_der: fn _conn -> cert end
        ]
      )

    session_id = initialize_legacy_session(plug, token)
    assert :ok = Server.mark_initialized(server, session_id)

    pid =
      spawn(fn ->
        conn =
          conn(:get, "/mcp")
          |> put_req_header("authorization", "Bearer " <> token)
          |> put_req_header("accept", "text/event-stream")
          |> put_req_header("mcp-session-id", session_id)
          |> put_req_header("mcp-protocol-version", @legacy)

        send(parent, {:legacy_mtls_stream_done, AttestoMCP.Server.Plug.call(conn, plug)})
      end)

    assert :ok = await_legacy_streams(server, 1)
    assert :ok = Server.publish(server, %{"type" => "toolsListChanged"})
    assert :ok = Server.delete_session(server, session_id)

    assert_receive {:legacy_mtls_stream_done, conn}, 2_000
    assert conn.status == 200
    assert conn.resp_body =~ ": keepalive"
    assert conn.resp_body =~ "notifications/tools/list_changed"
    refute Process.alive?(pid)
  end

  @tag :t25_catalog_invalidation_http
  test "authenticated HTTP catalog registration emits tools invalidation" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_read()])
    parent = self()

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource]
      )

    pid =
      spawn(fn ->
        request = %{
          "jsonrpc" => "2.0",
          "id" => 109,
          "method" => "subscriptions/listen",
          "params" => %{
            "_meta" => %{
              "io.modelcontextprotocol/protocolVersion" => @version,
              "io.modelcontextprotocol/clientCapabilities" => %{}
            },
            "notifications" => %{"toolsListChanged" => true}
          }
        }

        conn =
          conn(:post, "/mcp", Jason.encode!(request))
          |> put_req_header("authorization", "Bearer " <> token)
          |> put_req_header("content-type", "application/json")
          |> put_req_header("accept", "application/json, text/event-stream")
          |> put_req_header("mcp-protocol-version", @version)
          |> put_req_header("mcp-method", "subscriptions/listen")

        send(parent, {:catalog_stream, AttestoMCP.Server.Plug.call(conn, plug)})
      end)

    Process.sleep(50)

    assert :ok =
             Server.register_tool(server, "registered_after_open", %{
               handler: fn _, _ -> {:ok, "ok"} end
             })

    Process.sleep(50)
    Server.close_subscription(server, 109, pid)

    assert_receive {:catalog_stream, conn}, 2_000
    messages = stream_messages(conn)
    assert Enum.at(messages, 0)["method"] == "notifications/subscriptions/acknowledged"
    assert Enum.at(messages, 1)["method"] == "notifications/tools/list_changed"
    assert List.last(messages)["id"] == 109
    refute Process.alive?(pid)
  end

  test "concurrent HTTP subscriptions remain isolated when one closes" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()

    token =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [AttestoMCP.Scopes.tools_read(), AttestoMCP.Scopes.prompts_read()]
      )

    parent = self()

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource]
      )

    first = start_stream(parent, plug, token, 100, %{"toolsListChanged" => true})
    second = start_stream(parent, plug, token, 101, %{"promptsListChanged" => true})
    Process.sleep(100)

    Server.publish(server, %{"type" => "toolsListChanged"})
    Server.publish(server, %{"type" => "promptsListChanged"})
    Process.sleep(50)
    Server.close_subscription(server, 100, first)

    assert_receive {:subscription_done, 100, first_conn}, 2_000
    first_messages = stream_messages(first_conn)

    assert Enum.map(first_messages, & &1["method"]) == [
             "notifications/subscriptions/acknowledged",
             "notifications/tools/list_changed",
             nil
           ]

    assert List.last(first_messages)["id"] == 100
    assert get_in(List.last(first_messages), ["result", "resultType"]) == "complete"

    assert Enum.all?(
             first_messages,
             &(get_in(&1, ["params", "_meta", "io.modelcontextprotocol/subscriptionId"]) in [
                 nil,
                 100
               ])
           )

    Server.publish(server, %{"type" => "toolsListChanged"})
    Server.publish(server, %{"type" => "promptsListChanged"})
    Process.sleep(50)
    Server.close_subscription(server, 101, second)

    assert_receive {:subscription_done, 101, second_conn}, 2_000
    second_messages = stream_messages(second_conn)

    assert Enum.map(second_messages, & &1["method"]) == [
             "notifications/subscriptions/acknowledged",
             "notifications/prompts/list_changed",
             "notifications/prompts/list_changed",
             nil
           ]

    assert List.last(second_messages)["id"] == 101
    assert get_in(List.last(second_messages), ["result", "resultType"]) == "complete"

    assert Enum.all?(
             second_messages,
             &(get_in(&1, ["params", "_meta", "io.modelcontextprotocol/subscriptionId"]) in [
                 nil,
                 101
               ])
           )

    refute Process.alive?(first)
    refute Process.alive?(second)
  end

  test "a timed-out HTTP subscription leaves no terminal signal for a reused id" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_read()])

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        subscription_timeout: 15,
        auth: [config: config, resource: @resource]
      )

    first =
      plug
      |> listen_conn(token, 140, %{"toolsListChanged" => true})
      |> AttestoMCP.Server.Plug.call(plug)

    assert Enum.map(stream_messages(first), & &1["method"]) == [
             "notifications/subscriptions/acknowledged",
             nil
           ]

    refute_receive {:mcp_subscription_close, 140}, 25
    refute_receive {:mcp_subscription_cancel, 140}, 25

    second =
      plug
      |> listen_conn(token, 140, %{"toolsListChanged" => true})
      |> AttestoMCP.Server.Plug.call(plug)

    assert Enum.map(stream_messages(second), & &1["method"]) == [
             "notifications/subscriptions/acknowledged",
             nil
           ]

    refute_receive {:mcp_subscription_close, 140}, 25
    refute_receive {:mcp_subscription_cancel, 140}, 25
  end

  test "keepalives do not extend an HTTP subscription past subscription_timeout" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_read()])
    attach_telemetry([[:attesto_mcp_server, :stream, :close]])

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        stream_keepalive_ms: 5,
        subscription_timeout: 500,
        auth: [config: config, resource: @resource]
      )

    started = System.monotonic_time(:millisecond)
    {pid, monitor} = start_deadline_stream(plug, token, 150)

    # A keepalive every 5 ms used to restart the 500 ms timeout, so the stream
    # stayed open for as long as keepalives were written.
    assert_receive {:subscription_done, 150, conn, leftover}, 3_000
    assert System.monotonic_time(:millisecond) - started >= 500
    assert conn.status == 200
    assert leftover == []

    events = String.split(conn.resp_body, "\n\n", trim: true)
    {keepalives, data} = Enum.split_with(events, &(&1 == ": keepalive"))
    assert length(keepalives) >= 2

    messages =
      Enum.map(data, fn event ->
        event |> String.split("data: ", parts: 2) |> List.last() |> Jason.decode!()
      end)

    assert Enum.map(messages, & &1["method"]) == [
             "notifications/subscriptions/acknowledged",
             nil
           ]

    assert List.last(events) == List.last(data)
    assert List.last(messages)["id"] == 150
    assert get_in(List.last(messages), ["result", "resultType"]) == "complete"

    assert_receive {:telemetry_event, [:attesto_mcp_server, :stream, :close], _,
                    %{transport: :http, outcome: :timeout}}

    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
    assert :ok = await_subscriptions(server, 0)
  end

  test "events do not extend an HTTP subscription past subscription_timeout" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_read()])
    attach_telemetry([[:attesto_mcp_server, :subscription, :open]])

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        subscription_timeout: 500,
        auth: [config: config, resource: @resource]
      )

    started = System.monotonic_time(:millisecond)
    {pid, monitor} = start_deadline_stream(plug, token, 151)
    assert_receive {:telemetry_event, [:attesto_mcp_server, :subscription, :open], _, _}, 1_000
    publisher = publish_tools_list_changed_every(server, 5)

    # An event every 5 ms used to restart the 500 ms timeout in the same way.
    assert_receive {:subscription_done, 151, conn, leftover}, 3_000
    elapsed = System.monotonic_time(:millisecond) - started
    stop_publisher(publisher)

    assert elapsed >= 500
    assert leftover == []
    messages = stream_messages(conn)
    assert hd(messages)["method"] == "notifications/subscriptions/acknowledged"

    assert Enum.count(messages, &(&1["method"] == "notifications/tools/list_changed")) >= 2

    assert List.last(messages)["id"] == 151
    assert get_in(List.last(messages), ["result", "resultType"]) == "complete"
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
    assert :ok = await_subscriptions(server, 0)
  end

  test "an HTTP listen whose dispatch outlasts subscription_timeout ends at once with its acknowledgement" do
    # The progress notification is buffered ahead of the acknowledgement.
    {:ok, server} =
      Server.start_link(
        handler_task_init: fn _caller, context ->
          :ok = context.progress.("listen-progress", 1, nil)
          Process.sleep(100)
          :ok
        end
      )

    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_read()])

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        stream_keepalive_ms: 5,
        subscription_timeout: 20,
        auth: [config: config, resource: @resource]
      )

    {pid, monitor} =
      start_buffered_stream(plug, token, 153, [{:mcp_subscription_backpressure, 153}])

    # Dispatch takes 100 ms, past the 20 ms deadline, so the stream writes only
    # the acknowledgement and the final response and ends without waiting.
    assert_receive {:subscription_done, 153, conn, leftover}, 2_000
    assert leftover == []

    assert Enum.map(stream_messages(conn), & &1["method"]) == [
             "notifications/subscriptions/acknowledged",
             nil
           ]

    assert List.last(stream_messages(conn))["id"] == 153
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
    assert :ok = await_subscriptions(server, 0)
  end

  test "an HTTP listen whose dispatch fails after subscription_timeout leaves nothing queued" do
    {:ok, server} =
      Server.start_link(
        request_timeout: 100,
        handler_task_init: fn _caller, context ->
          :ok = context.progress.("listen-progress", 1, nil)
          :ok = context.progress.("listen-progress", 2, nil)
          Process.sleep(300)
          :ok
        end
      )

    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_read()])

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        subscription_timeout: 20,
        auth: [config: config, resource: @resource]
      )

    {pid, monitor} = start_buffered_stream(plug, token, 154, [])

    # Dispatch times out at 100 ms with an error and no subscription. Past the
    # deadline the buffered progress is dropped, not written or left queued.
    assert_receive {:subscription_done, 154, conn, leftover}, 2_000
    assert leftover == []
    refute conn.resp_body =~ "notifications/progress"
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
  end

  test "an HTTP listen whose client disconnects during the flush leaves nothing queued" do
    {:ok, server} =
      Server.start_link(
        request_timeout: 100,
        handler_task_init: fn _caller, context ->
          :ok = context.progress.("listen-progress", 1, nil)
          :ok = context.progress.("listen-progress", 2, nil)
          Process.sleep(300)
          :ok
        end
      )

    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_read()])

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource]
      )

    # The first progress write fails; the second progress is still buffered.
    {pid, monitor} =
      start_buffered_stream(plug, token, 155, [], &ClosingAdapter.wrap(&1, 0))

    assert_receive {:subscription_done, 155, _conn, leftover}, 2_000
    assert leftover == []
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
  end

  test "an HTTP listen whose dispatch fails after its subscription opened closes that subscription" do
    {:ok, server} = Server.start_link(request_timeout: 50)
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_read()])
    parent = self()
    handler_id = {__MODULE__, :slow_subscription_open, make_ref()}

    # Runs inside the subscription registry after it sends the acknowledgement,
    # so the open outlasts the 50 ms request timeout and dispatch fails.
    :ok =
      :telemetry.attach(
        handler_id,
        [:attesto_mcp_server, :subscription, :open],
        &__MODULE__.sleep_handler/4,
        200
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource]
      )

    pid =
      spawn(fn ->
        conn =
          plug
          |> listen_conn(token, 156, %{"toolsListChanged" => true})
          |> AttestoMCP.Server.Plug.call(plug)

        # Still the subscription's owner, so only an explicit close removes it.
        send(parent, {:subscription_done, 156, conn, Server.stats(server).subscriptions})
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    monitor = Process.monitor(pid)

    assert_receive {:subscription_done, 156, conn, open_subscriptions}, 2_000
    assert open_subscriptions == 0
    assert hd(stream_messages(conn))["method"] == "notifications/subscriptions/acknowledged"
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
  end

  test "an HTTP listen whose client disconnects after a successful dispatch closes its subscription at once" do
    # The progress notification is buffered ahead of the acknowledgement, so
    # the failed write carries no subscription id.
    {:ok, server} =
      Server.start_link(
        handler_task_init: fn _caller, context ->
          :ok = context.progress.("listen-progress", 1, nil)
          :ok
        end
      )

    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_read()])
    parent = self()

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource]
      )

    request = %{
      "jsonrpc" => "2.0",
      "id" => 157,
      "method" => "subscriptions/listen",
      "params" => %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @version,
          "io.modelcontextprotocol/clientCapabilities" => %{},
          "progressToken" => "listen-progress"
        },
        "notifications" => %{"toolsListChanged" => true}
      }
    }

    pid =
      spawn(fn ->
        conn(:post, "/mcp", Jason.encode!(request))
        |> put_req_header("authorization", "Bearer " <> token)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> put_req_header("mcp-protocol-version", @version)
        |> put_req_header("mcp-method", "subscriptions/listen")
        |> ClosingAdapter.wrap(0)
        |> AttestoMCP.Server.Plug.call(plug)

        {:messages, messages} = Process.info(self(), :messages)
        leftover = Enum.filter(messages, &subscription_message?/1)
        send(parent, {:subscription_done, 157, Server.stats(server).subscriptions, leftover})
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    monitor = Process.monitor(pid)

    # Keepalives are 15 s apart, so waiting for one to fail would miss this.
    assert_receive {:subscription_done, 157, open_subscriptions, leftover}, 2_000
    assert open_subscriptions == 0
    assert leftover == []
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
  end

  test "a failed HTTP listen leaves the same process's other subscription with that id open" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_read()])
    parent = self()

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource]
      )

    params = %{
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => @version,
        "io.modelcontextprotocol/clientCapabilities" => %{}
      },
      "notifications" => %{"toolsListChanged" => true}
    }

    pid =
      spawn(fn ->
        # A custom transport in this process already holds subscription 158.
        {158, %{"result" => _}} =
          Server.dispatch(
            server,
            %{kind: :request, id: 158, method: "subscriptions/listen", params: params},
            %{principal: "shared-owner", scopes: [AttestoMCP.Scopes.tools_read()]},
            version: @version
          )

        conn =
          plug
          |> listen_conn(token, 158, %{"toolsListChanged" => true})
          |> AttestoMCP.Server.Plug.call(plug)

        send(parent, {:subscription_done, 158, conn, Server.stats(server).subscriptions})
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    monitor = Process.monitor(pid)

    assert_receive {:subscription_done, 158, conn, open_subscriptions}, 2_000
    refute conn.resp_body =~ "subscriptions/acknowledged"
    assert open_subscriptions == 1
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
  end

  test "an HTTP listen whose acknowledgement write fails leaves nothing queued" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_read()])

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource]
      )

    # The failed acknowledgement write closes the subscription itself, so the
    # stream's own cleanup finds nothing left to close.
    {pid, monitor} =
      start_buffered_stream(
        plug,
        token,
        159,
        [{:mcp_subscription_backpressure, 159}],
        &ClosingAdapter.wrap(&1, 0)
      )

    assert_receive {:subscription_done, 159, _conn, leftover}, 2_000
    assert leftover == []
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
    assert :ok = await_subscriptions(server, 0)
  end

  test "an HTTP subscription event that reaches the stream after its deadline is not written" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_read()])

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        subscription_timeout: 1_000,
        auth: [config: config, resource: @resource]
      )

    started = System.monotonic_time(:millisecond)
    {pid, monitor} = start_deadline_stream(plug, token, 160)
    on_exit(fn -> resume_quietly(pid) end)

    # The stream waits for messages with an event already queued and resumes
    # past its deadline, as a long scheduler delay would leave it.
    assert :ok = await_waiting_in(pid, {AttestoMCP.Server.Plug, :await_subscription_message, 8})
    :erlang.suspend_process(pid)
    assert :ok = Server.publish(server, %{"type" => "toolsListChanged"})

    assert :ok =
             await_message_queued(
               pid,
               &match?(
                 {:mcp_subscription, _, 160, %{"method" => "notifications/tools/list_changed"}},
                 &1
               )
             )

    assert System.monotonic_time(:millisecond) - started < 1_000
    # The deadline was set before the stream reached its receive, so a full
    # timeout from here is past it.
    Process.sleep(1_200)
    :erlang.resume_process(pid)

    assert_receive {:subscription_done, 160, conn, leftover}, 2_000
    assert leftover == []

    assert Enum.map(stream_messages(conn), & &1["method"]) == [
             "notifications/subscriptions/acknowledged",
             nil
           ]

    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
    assert :ok = await_subscriptions(server, 0)
  end

  test "a failed HTTP listen whose subscription something else closed leaves nothing queued" do
    {:ok, server} = Server.start_link(request_timeout: 50)
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_read()])
    handler_id = {__MODULE__, :closed_elsewhere, make_ref()}

    # The open outlasts the 50 ms request timeout, so dispatch fails after the
    # acknowledgement has gone out.
    :ok =
      :telemetry.attach(
        handler_id,
        [:attesto_mcp_server, :subscription, :open],
        &__MODULE__.notify_then_sleep_handler/4,
        {self(), 200}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource]
      )

    {pid, monitor} =
      start_buffered_stream(plug, token, 161, [{:mcp_subscription_backpressure, 161}])

    # Queued in the registry ahead of the stream's own cleanup, this close
    # removes the subscription and sends its close notice to the stream.
    assert_receive {:telemetry_event, [:attesto_mcp_server, :subscription, :open], _, _}, 1_000
    assert :ok = Server.close_subscription(server, 161, pid)

    assert_receive {:subscription_done, 161, conn, leftover}, 2_000
    assert leftover == []
    assert hd(stream_messages(conn))["method"] == "notifications/subscriptions/acknowledged"
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
  end

  test "an HTTP listen closed elsewhere whose client disconnects before its acknowledgement leaves nothing queued" do
    # The progress notification is buffered ahead of the acknowledgement, and
    # its write fails, so the acknowledgement is never read.
    {:ok, server} =
      Server.start_link(
        handler_task_init: fn _caller, context ->
          :ok = context.progress.("listen-progress", 1, nil)
          :ok
        end
      )

    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_read()])
    handler_id = {__MODULE__, :closed_elsewhere_unread, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:attesto_mcp_server, :subscription, :open],
        &__MODULE__.notify_then_sleep_handler/4,
        {self(), 200}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource]
      )

    {pid, monitor} =
      start_buffered_stream(
        plug,
        token,
        162,
        [{:mcp_subscription_backpressure, 162}],
        &ClosingAdapter.wrap(&1, 0)
      )

    assert_receive {:telemetry_event, [:attesto_mcp_server, :subscription, :open], _, _}, 1_000
    assert :ok = Server.close_subscription(server, 162, pid)

    assert_receive {:subscription_done, 162, _conn, leftover}, 2_000
    assert leftover == []
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
  end

  test "a failed HTTP listen keeps the close notice of another subscription its process held under that id" do
    # Only the HTTP listen's dispatch is slow, so it times out before opening.
    {:ok, server} =
      Server.start_link(
        request_timeout: 50,
        handler_task_init: fn _caller, context ->
          if context[:principal] != "shared-owner", do: Process.sleep(200)
          :ok
        end
      )

    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_read()])
    parent = self()

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource]
      )

    params = %{
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => @version,
        "io.modelcontextprotocol/clientCapabilities" => %{}
      },
      "notifications" => %{"toolsListChanged" => true}
    }

    pid =
      spawn(fn ->
        # A custom transport in this process holds subscription 163, which
        # something else then closes, leaving its close notice here.
        {163, %{"result" => _}} =
          Server.dispatch(
            server,
            %{kind: :request, id: 163, method: "subscriptions/listen", params: params},
            %{principal: "shared-owner", scopes: [AttestoMCP.Scopes.tools_read()]},
            version: @version
          )

        send(parent, {:custom_subscription_open, self()})

        receive do
          :custom_subscription_closed -> :ok
        end

        _conn =
          plug
          |> listen_conn(token, 163, %{"toolsListChanged" => true})
          |> AttestoMCP.Server.Plug.call(plug)

        {:messages, messages} = Process.info(self(), :messages)
        send(parent, {:subscription_done, 163, {:mcp_subscription_close, 163} in messages})
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    monitor = Process.monitor(pid)

    assert_receive {:custom_subscription_open, ^pid}, 1_000
    assert :ok = Server.close_subscription(server, 163, pid)
    send(pid, :custom_subscription_closed)

    assert_receive {:subscription_done, 163, close_notice_kept?}, 2_000
    assert close_notice_kept?
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
  end

  test "a failed HTTP listen whose open was still queued at cleanup leaves nothing queued" do
    {:ok, server} = Server.start_link(request_timeout: 300)
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_read()])
    parent = self()
    registry = GenServer.call(server, :subscriptions)

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource]
      )

    # The registry stalls with the listen's open queued, then an outside
    # close, then the stream's own cleanup after dispatch times out.
    :ok = :sys.suspend(registry)
    on_exit(fn -> if Process.alive?(registry), do: :sys.resume(registry) end)
    {pid, monitor} = start_buffered_stream(plug, token, 164, [])
    assert :ok = await_queue_length(registry, 1)
    spawn(fn -> send(parent, {:outside_close, Server.close_subscription(server, 164, pid)}) end)
    assert :ok = await_queue_length(registry, 2)
    assert :ok = await_queue_length(registry, 3)
    {:messages, queued} = Process.info(registry, :messages)

    assert [
             {:"$gen_call", _, {:open, 164, _, _, _, _, _, _, _}},
             {:"$gen_call", _, {:close, 164, ^pid}},
             {:"$gen_call", _, {:close_tagged, 164, ^pid, _}}
           ] = queued

    :ok = :sys.resume(registry)

    assert_receive {:outside_close, :ok}, 2_000
    assert_receive {:subscription_done, 164, _conn, leftover}, 2_000
    assert leftover == []
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
  end

  defp await_queue_length(pid, length, attempts \\ 400)

  defp await_queue_length(_pid, _length, 0), do: {:error, :timeout}

  defp await_queue_length(pid, length, attempts) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, queued} when queued >= length ->
        :ok

      _ ->
        Process.sleep(5)
        await_queue_length(pid, length, attempts - 1)
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

  # Like start_deadline_stream/3, with a progress token on the listen and
  # messages already in the stream process's mailbox before it starts. They
  # stand in for messages that reached the stream for this subscription and
  # were still queued when its deadline passed.
  defp start_buffered_stream(plug, token, id, queued, wrap \\ & &1) do
    parent = self()

    request = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "subscriptions/listen",
      "params" => %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @version,
          "io.modelcontextprotocol/clientCapabilities" => %{},
          "progressToken" => "listen-progress"
        },
        "notifications" => %{"toolsListChanged" => true}
      }
    }

    pid =
      spawn(fn ->
        Enum.each(queued, &send(self(), &1))

        conn =
          conn(:post, "/mcp", Jason.encode!(request))
          |> put_req_header("authorization", "Bearer " <> token)
          |> put_req_header("content-type", "application/json")
          |> put_req_header("accept", "application/json, text/event-stream")
          |> put_req_header("mcp-protocol-version", @version)
          |> put_req_header("mcp-method", "subscriptions/listen")
          |> wrap.()
          |> AttestoMCP.Server.Plug.call(plug)

        {:messages, messages} = Process.info(self(), :messages)

        send(
          parent,
          {:subscription_done, id, conn, Enum.filter(messages, &subscription_message?/1)}
        )
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    {pid, Process.monitor(pid)}
  end

  # Runs one listen in its own process. When the stream ends, that process
  # reports the response and any subscription messages left in its mailbox.
  defp start_deadline_stream(plug, token, id) do
    parent = self()

    pid =
      spawn(fn ->
        conn =
          plug
          |> listen_conn(token, id, %{"toolsListChanged" => true})
          |> AttestoMCP.Server.Plug.call(plug)

        {:messages, messages} = Process.info(self(), :messages)

        send(
          parent,
          {:subscription_done, id, conn, Enum.filter(messages, &subscription_message?/1)}
        )
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    {pid, Process.monitor(pid)}
  end

  defp subscription_message?(message) when is_tuple(message) and tuple_size(message) > 0 do
    elem(message, 0) in [
      :mcp_subscription,
      :mcp_subscription_pre_ack,
      :mcp_subscription_backpressure,
      :mcp_subscription_keepalive,
      :mcp_subscription_close,
      :mcp_subscription_cancel
    ]
  end

  defp subscription_message?(_message), do: false

  defp attach_telemetry(events) do
    handler_id = {__MODULE__, :deadline, make_ref()}
    :ok = :telemetry.attach_many(handler_id, events, &__MODULE__.telemetry_handler/4, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)
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

  defp start_stream(parent, plug, token, id, filter) do
    spawn(fn ->
      request = %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => "subscriptions/listen",
        "params" => %{
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => @version,
            "io.modelcontextprotocol/clientCapabilities" => %{}
          },
          "notifications" => filter
        }
      }

      conn =
        conn(:post, "/mcp", Jason.encode!(request))
        |> put_req_header("authorization", "Bearer " <> token)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> put_req_header("mcp-protocol-version", @version)
        |> put_req_header("mcp-method", "subscriptions/listen")

      send(parent, {:subscription_done, id, AttestoMCP.Server.Plug.call(conn, plug)})
    end)
  end

  defp listen_conn(_plug, token, id, filter) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "subscriptions/listen",
      "params" => %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @version,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        },
        "notifications" => filter
      }
    }

    conn(:post, "/mcp", Jason.encode!(request))
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("mcp-protocol-version", @version)
    |> put_req_header("mcp-method", "subscriptions/listen")
  end

  defp principal_policy(policy, parent) do
    fn claims, sender ->
      {allowed, call} =
        Agent.get_and_update(policy, fn state ->
          call = state.calls + 1
          {{state.allowed, call}, %{state | calls: call}}
        end)

      send(parent, {:principal_policy, call, allowed, sender})

      if allowed do
        {:ok, %{subject: claims["sub"], status: :active}}
      else
        {:error, :revoked}
      end
    end
  end

  defp initialize_legacy_session(plug, token, auth_headers \\ nil) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 112,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @legacy,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "subscription-test", "version" => "1.0"}
      }
    }

    conn =
      conn(:post, "/mcp", Jason.encode!(request))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", @legacy)

    conn =
      Enum.reduce(auth_headers || [{"authorization", "Bearer " <> token}], conn, fn
        {name, value}, conn -> put_req_header(conn, name, value)
      end)
      |> AttestoMCP.Server.Plug.call(plug)

    assert conn.status == 200
    conn |> get_resp_header("mcp-session-id") |> List.first()
  end

  defp await_subscriptions(server, expected, attempts \\ 100)

  defp await_subscriptions(_server, _expected, 0), do: {:error, :timeout}

  defp await_subscriptions(server, expected, attempts) do
    if Server.stats(server).subscriptions == expected do
      :ok
    else
      Process.sleep(10)
      await_subscriptions(server, expected, attempts - 1)
    end
  end

  defp await_legacy_streams(server, expected, attempts \\ 100)

  defp await_legacy_streams(_server, _expected, 0), do: {:error, :timeout}

  defp await_legacy_streams(server, expected, attempts) do
    if Server.stats(server).legacy_streams == expected do
      :ok
    else
      Process.sleep(10)
      await_legacy_streams(server, expected, attempts - 1)
    end
  end

  defp stream_messages(conn) do
    conn.resp_body
    |> String.split("\n\n", trim: true)
    |> Enum.map(fn event ->
      event |> String.split("data: ", parts: 2) |> List.last() |> Jason.decode!()
    end)
  end
end
