defmodule AttestoMCP.Server.PlugSubscriptionTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AttestoMCP.Server

  @resource "https://mcp.example.com/mcp"
  @version "2026-07-28"
  @legacy "2025-11-25"

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

  test "DPoP subscription delivery retains custom auth assigns without reloading an opaque principal" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    parent = self()

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
    refute_receive {:principal_policy, 2, _allowed, _sender}, 50
    assert Agent.get(policy, & &1.calls) == 1

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

  test "legacy DPoP stream delivery retains its sender binding and opaque principal" do
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
    refute_receive {:principal_policy, 3, _allowed, _sender}, 50
    assert Agent.get(policy, & &1.calls) == 2

    assert :ok = Server.delete_session(server, session_id)
    assert_receive {:legacy_stream_done, conn}, 2_000
    assert conn.status == 200
    assert conn.resp_body =~ ": keepalive"
    assert conn.resp_body =~ "notifications/tools/list_changed"
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
