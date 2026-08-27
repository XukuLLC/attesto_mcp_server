defmodule AttestoMCP.Server.LegacyPlugTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AttestoMCP.Server

  @resource "https://mcp.example.com/mcp"
  @legacy "2025-11-25"

  test "authenticated legacy initialize persists version and waits for initialized" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())
    plug = plug(server, config)

    ping_first =
      call(
        plug,
        token,
        "POST",
        %{"jsonrpc" => "2.0", "id" => 0, "method" => "ping", "params" => %{}},
        []
      )

    assert ping_first.status == 200

    initialized =
      call(
        plug,
        token,
        "POST",
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => @legacy,
            "capabilities" => %{
              "sampling" => %{},
              "elicitation" => %{},
              "roots" => %{}
            },
            "clientInfo" => %{"name" => "legacy-plug", "version" => "1.0"}
          }
        },
        []
      )

    assert initialized.status == 200
    session_id = initialized |> get_resp_header("mcp-session-id") |> List.first()
    assert is_binary(session_id) and session_id != ""
    assert Jason.decode!(initialized.resp_body)["result"]["protocolVersion"] == @legacy

    ping_before =
      call(
        plug,
        token,
        "POST",
        %{"jsonrpc" => "2.0", "id" => 2, "method" => "ping", "params" => %{}},
        session_id: session_id
      )

    assert ping_before.status == 200

    initialized_notification =
      call(
        plug,
        token,
        "POST",
        %{"jsonrpc" => "2.0", "method" => "notifications/initialized", "params" => %{}},
        session_id: session_id
      )

    assert initialized_notification.status == 202

    subscribed =
      call(
        plug,
        token,
        "POST",
        %{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "resources/subscribe",
          "params" => %{"uri" => "urn:legacy"}
        },
        session_id: session_id
      )

    assert subscribed.status == 200

    wrong_version =
      call(
        plug,
        token,
        "POST",
        %{"jsonrpc" => "2.0", "id" => 4, "method" => "ping", "params" => %{}},
        session_id: session_id,
        protocol_version: "2024-01-01"
      )

    assert wrong_version.status == 400
    assert Jason.decode!(wrong_version.resp_body)["error"]["code"] == -32020
  end

  test "legacy GET is a standing incremental stream and DELETE closes only its owner" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())
    plug = plug(server, config)
    session_id = initialize_session(plug, token)
    assert :ok = Server.mark_initialized(server, session_id)
    parent = self()

    stream =
      spawn(fn ->
        conn =
          conn(:get, "/mcp")
          |> put_req_header("authorization", "Bearer " <> token)
          |> put_req_header("accept", "text/event-stream")
          |> put_req_header("mcp-session-id", session_id)
          |> put_req_header("mcp-protocol-version", @legacy)

        send(parent, {:stream_done, AttestoMCP.Server.Plug.call(conn, plug)})
      end)

    Process.sleep(50)
    Server.publish(server, %{"type" => "toolsListChanged"})
    Process.sleep(50)

    deleted =
      conn(:delete, "/mcp")
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("mcp-session-id", session_id)
      |> put_req_header("mcp-protocol-version", @legacy)
      |> AttestoMCP.Server.Plug.call(plug)

    assert deleted.status == 200
    assert_receive {:stream_done, stream_conn}, 2_000
    assert stream_conn.status == 200
    assert stream_conn.resp_body =~ ": keepalive"
    assert stream_conn.resp_body =~ "notifications/tools/list_changed"
    assert stream_conn.resp_body =~ "id: 1"
    refute Process.alive?(stream)

    after_delete =
      call(
        plug,
        token,
        "POST",
        %{"jsonrpc" => "2.0", "id" => 9, "method" => "ping", "params" => %{}},
        session_id: session_id
      )

    assert after_delete.status == 404

    get_after_delete =
      conn(:get, "/mcp")
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("accept", "text/event-stream")
      |> put_req_header("mcp-session-id", session_id)
      |> put_req_header("mcp-protocol-version", @legacy)
      |> AttestoMCP.Server.Plug.call(plug)

    assert get_after_delete.status == 404
  end

  test "owned legacy GET and DELETE report negotiated-version errors as 400" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())
    plug = plug(server, config)
    session_id = initialize_session(plug, token)
    assert :ok = Server.mark_initialized(server, session_id)

    get =
      conn(:get, "/mcp")
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("accept", "text/event-stream")
      |> put_req_header("mcp-session-id", session_id)
      |> put_req_header("mcp-protocol-version", "2024-01-01")
      |> AttestoMCP.Server.Plug.call(plug)

    assert get.status == 400
    assert Jason.decode!(get.resp_body)["error"]["code"] == -32020

    delete =
      conn(:delete, "/mcp")
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("mcp-session-id", session_id)
      |> put_req_header("mcp-protocol-version", "2024-01-01")
      |> AttestoMCP.Server.Plug.call(plug)

    assert delete.status == 400
    assert Jason.decode!(delete.resp_body)["error"]["code"] == -32020
  end

  test "unsupported legacy initialization does not issue a usable session" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())
    plug = plug(server, config)

    rejected =
      call(
        plug,
        token,
        "POST",
        %{
          "jsonrpc" => "2.0",
          "id" => 11,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => "2026-07-28",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "legacy-plug", "version" => "1.0"}
          }
        },
        []
      )

    assert rejected.status == 400
    assert get_resp_header(rejected, "mcp-session-id") == []
    assert Jason.decode!(rejected.resp_body)["error"]["code"] == -32022
  end

  test "two concurrent legacy GET streams receive one routed event and both close" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())
    plug = plug(server, config)
    session_id = initialize_session(plug, token)
    assert :ok = Server.mark_initialized(server, session_id)
    parent = self()

    start_legacy_get(parent, plug, token, session_id)
    start_legacy_get(parent, plug, token, session_id)
    Process.sleep(50)
    Server.publish(server, %{"type" => "toolsListChanged"})
    Process.sleep(50)
    assert :ok = Server.delete_session(server, session_id)

    assert_receive {:stream_done, first}, 2_000
    assert_receive {:stream_done, second}, 2_000
    bodies = [first.resp_body, second.resp_body]
    assert Enum.count(bodies, &String.contains?(&1, "notifications/tools/list_changed")) == 1
  end

  test "each legacy HTTP leg authenticates and binds the negotiated session" do
    {:ok, server} = Server.start_link(session_idle_timeout: 100)
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())
    plug = plug(server, config)

    missing_post =
      conn(:post, "/mcp", Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> AttestoMCP.Server.Plug.call(plug)

    assert missing_post.status == 401
    assert get_resp_header(missing_post, "www-authenticate") != []

    missing_get =
      conn(:get, "/mcp")
      |> put_req_header("accept", "text/event-stream")
      |> AttestoMCP.Server.Plug.call(plug)

    assert missing_get.status == 401

    missing_delete =
      conn(:delete, "/mcp")
      |> put_req_header("accept", "text/event-stream")
      |> AttestoMCP.Server.Plug.call(plug)

    assert missing_delete.status == 401

    invalid_post =
      conn(:post, "/mcp", Jason.encode!(%{"jsonrpc" => "2.0", "id" => 2, "method" => "ping"}))
      |> put_req_header("authorization", "Bearer invalid")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> AttestoMCP.Server.Plug.call(plug)

    assert invalid_post.status == 401

    invalid_get =
      conn(:get, "/mcp")
      |> put_req_header("authorization", "Bearer invalid")
      |> put_req_header("accept", "text/event-stream")
      |> AttestoMCP.Server.Plug.call(plug)

    assert invalid_get.status == 401

    invalid_delete =
      conn(:delete, "/mcp")
      |> put_req_header("authorization", "Bearer invalid")
      |> put_req_header("accept", "text/event-stream")
      |> AttestoMCP.Server.Plug.call(plug)

    assert invalid_delete.status == 401

    initialized =
      call(
        plug,
        token,
        "POST",
        %{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => @legacy,
            "capabilities" => %{},
            "clientInfo" => %{"name" => "legacy-plug", "version" => "1.0"}
          }
        },
        []
      )

    session_id = List.first(get_resp_header(initialized, "mcp-session-id"))
    init_result = Jason.decode!(initialized.resp_body)["result"]
    refute Map.has_key?(init_result["capabilities"], "resumption")
    refute Map.has_key?(init_result["capabilities"], "replication")

    early_call =
      call(
        plug,
        token,
        "POST",
        %{"jsonrpc" => "2.0", "id" => 4, "method" => "tools/list", "params" => %{}},
        session_id: session_id
      )

    assert early_call.status == 400

    ready =
      call(
        plug,
        token,
        "POST",
        %{"jsonrpc" => "2.0", "method" => "notifications/initialized", "params" => %{}},
        session_id: session_id
      )

    assert ready.status == 202

    matching_version =
      call(
        plug,
        token,
        "POST",
        %{"jsonrpc" => "2.0", "id" => 30, "method" => "ping", "params" => %{}},
        session_id: session_id,
        protocol_version: @legacy
      )

    assert matching_version.status == 200

    omitted_version =
      call(
        plug,
        token,
        "POST",
        %{"jsonrpc" => "2.0", "id" => 31, "method" => "ping", "params" => %{}},
        session_id: session_id
      )

    assert omitted_version.status == 200

    insufficient_scope_token = AttestoMCP.Test.Factory.access_token(config, scopes: [])

    insufficient =
      call(
        plug,
        insufficient_scope_token,
        "POST",
        %{"jsonrpc" => "2.0", "id" => 32, "method" => "tools/list", "params" => %{}},
        session_id: session_id
      )

    assert insufficient.status == 403
    [insufficient_challenge] = get_resp_header(insufficient, "www-authenticate")
    assert insufficient_challenge =~ ~s(error="insufficient_scope")
    assert insufficient_challenge =~ ~s(scope="mcp:tools:read")
    assert insufficient_challenge =~ "resource_metadata="

    wrong_principal_token = mint_token(config, "usr_456", nil, AttestoMCP.Scopes.all())

    wrong_principal =
      call(
        plug,
        wrong_principal_token,
        "POST",
        %{"jsonrpc" => "2.0", "id" => 33, "method" => "ping", "params" => %{}},
        session_id: session_id
      )

    assert wrong_principal.status == 404

    wrong_tenant_token = mint_token(config, "usr_123", "tenant-b", AttestoMCP.Scopes.all())

    wrong_tenant =
      call(
        plug,
        wrong_tenant_token,
        "POST",
        %{"jsonrpc" => "2.0", "id" => 34, "method" => "ping", "params" => %{}},
        session_id: session_id
      )

    assert wrong_tenant.status == 404

    wrong_version =
      call(
        plug,
        token,
        "POST",
        %{"jsonrpc" => "2.0", "id" => 5, "method" => "ping", "params" => %{}},
        session_id: session_id,
        protocol_version: "2024-01-01"
      )

    assert wrong_version.status == 400

    conflicting_initialize =
      call(
        plug,
        token,
        "POST",
        %{
          "jsonrpc" => "2.0",
          "id" => 35,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => @legacy,
            "capabilities" => %{},
            "clientInfo" => %{"name" => "legacy-plug", "version" => "1.0"}
          }
        },
        protocol_version: "2024-01-01"
      )

    assert conflicting_initialize.status == 400

    stats_before_flood = Server.stats(server)

    for index <- 1..100 do
      flood =
        call(
          plug,
          token,
          "POST",
          %{"jsonrpc" => "2.0", "id" => 40_000 + index, "method" => "ping", "params" => %{}},
          session_id: "invalid-#{index}-#{:erlang.unique_integer([:positive])}"
        )

      assert flood.status == 404
    end

    assert Server.stats(server).sessions == stats_before_flood.sessions
    assert Server.stats(server).legacy_streams == stats_before_flood.legacy_streams

    wrong_id =
      call(
        plug,
        token,
        "POST",
        %{"jsonrpc" => "2.0", "id" => 6, "method" => "ping", "params" => %{}},
        session_id: "missing-session"
      )

    assert wrong_id.status == 404

    {:ok, expiry_server} = Server.start_link(session_idle_timeout: 2)
    expiry_plug = plug(expiry_server, config)
    expiry_session_id = initialize_session(expiry_plug, token)
    assert Server.mark_initialized(expiry_server, expiry_session_id) == :ok
    Process.sleep(10)

    expired =
      call(
        expiry_plug,
        token,
        "POST",
        %{"jsonrpc" => "2.0", "id" => 7, "method" => "ping", "params" => %{}},
        session_id: expiry_session_id
      )

    assert expired.status == 404

    {:ok, absolute_server} =
      Server.start_link(session_absolute_timeout: 2, session_idle_timeout: 1_000)

    absolute_plug = plug(absolute_server, config)
    absolute_session_id = initialize_session(absolute_plug, token)
    assert Server.mark_initialized(absolute_server, absolute_session_id) == :ok
    Process.sleep(10)

    absolute_expired =
      call(
        absolute_plug,
        token,
        "POST",
        %{"jsonrpc" => "2.0", "id" => 8, "method" => "ping", "params" => %{}},
        session_id: absolute_session_id
      )

    assert absolute_expired.status == 404
  end

  test "legacy initialization never advertises resumption and rejects Last-Event-ID" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())
    plug = plug(server, config)
    session_id = initialize_session(plug, token)

    response =
      call(
        plug,
        token,
        "POST",
        %{"jsonrpc" => "2.0", "method" => "notifications/initialized", "params" => %{}},
        session_id: session_id
      )

    assert response.status == 202
    refute Map.has_key?(response.resp_headers |> Map.new(), "last-event-id")

    get =
      conn(:get, "/mcp")
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("accept", "text/event-stream")
      |> put_req_header("mcp-session-id", session_id)
      |> put_req_header("mcp-protocol-version", @legacy)
      |> put_req_header("last-event-id", "1")
      |> AttestoMCP.Server.Plug.call(plug)

    assert get.status == 405
  end

  test "public HTTP initialized/request races remain bounded across 100 schedules" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())
    plug = plug(server, config)
    parent = self()

    for index <- 1..100 do
      session_id = initialize_session(plug, token)

      notification = fn ->
        Process.sleep(rem(index, 5))

        conn =
          call(
            plug,
            token,
            "POST",
            %{"jsonrpc" => "2.0", "method" => "notifications/initialized", "params" => %{}},
            session_id: session_id
          )

        send(parent, {:race, :initialized, conn.status})
      end

      normal = fn ->
        Process.sleep(rem(index + 2, 5))

        conn =
          call(
            plug,
            token,
            "POST",
            %{"jsonrpc" => "2.0", "id" => index, "method" => "tools/list", "params" => %{}},
            session_id: session_id
          )

        send(parent, {:race, :normal, conn.status})
      end

      if rem(index, 2) == 0 do
        spawn(notification)
        spawn(normal)
      else
        spawn(normal)
        spawn(notification)
      end

      statuses =
        Enum.map(1..2, fn _ ->
          assert_receive {:race, kind, status}, 1_000
          {kind, status}
        end)
        |> Map.new()

      assert statuses[:initialized] == 202
      normal_status = statuses[:normal]
      assert normal_status == 200

      deleted =
        call(
          plug,
          token,
          "DELETE",
          nil,
          session_id: session_id,
          protocol_version: @legacy
        )

      assert deleted.status == 200
    end
  end

  test "handler rejection reasons become safe correlated errors and endpoint recovers" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())
    plug = plug(server, config)

    assert :ok =
             Server.register_tool(server, "raises", %{
               input_schema: %{"type" => "object"},
               handler: fn _arguments, _context -> raise "secret-handler-reason" end
             })

    assert :ok =
             Server.register_tool(server, "throws", %{
               input_schema: %{"type" => "object"},
               handler: fn _arguments, _context -> throw({:internal, "secret-throw-reason"}) end
             })

    session_id = initialize_session(plug, token)

    ready =
      call(
        plug,
        token,
        "POST",
        %{"jsonrpc" => "2.0", "method" => "notifications/initialized", "params" => %{}},
        session_id: session_id
      )

    assert ready.status == 202

    for {id, name} <- [{50, "raises"}, {51, "throws"}] do
      response =
        call(
          plug,
          token,
          "POST",
          %{
            "jsonrpc" => "2.0",
            "id" => id,
            "method" => "tools/call",
            "params" => %{"name" => name, "arguments" => %{}}
          },
          session_id: session_id
        )

      assert response.status == 500
      body = Jason.decode!(response.resp_body)
      assert body["id"] == id
      assert body["error"]["code"] == -32603
      refute response.resp_body =~ "secret-"
    end

    recovered =
      call(
        plug,
        token,
        "POST",
        %{"jsonrpc" => "2.0", "id" => 52, "method" => "ping", "params" => %{}},
        session_id: session_id
      )

    assert recovered.status == 200
  end

  test "initialize callback rejects structured and arbitrary reasons safely" do
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())

    callbacks = [
      fn _context, _params -> {:error, %{secret: "structured-secret"}} end,
      fn _context, _params -> raise "arbitrary-secret" end
    ]

    Enum.each(callbacks, fn callback ->
      {:ok, server} = Server.start_link(initialize_callback: callback)
      plug = plug(server, config)

      rejected =
        call(
          plug,
          token,
          "POST",
          %{
            "jsonrpc" => "2.0",
            "id" => 60,
            "method" => "initialize",
            "params" => %{
              "protocolVersion" => @legacy,
              "capabilities" => %{},
              "clientInfo" => %{"name" => "legacy-plug", "version" => "1.0"}
            }
          },
          []
        )

      assert rejected.status == 500
      body = Jason.decode!(rejected.resp_body)
      assert body["id"] == 60
      assert body["error"]["code"] == -32603
      refute rejected.resp_body =~ "secret"

      ping =
        call(
          plug,
          token,
          "POST",
          %{"jsonrpc" => "2.0", "id" => 61, "method" => "ping", "params" => %{}},
          []
        )

      assert ping.status == 200
    end)
  end

  defp initialize_session(plug, token) do
    conn =
      call(
        plug,
        token,
        "POST",
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => @legacy,
            "capabilities" => %{},
            "clientInfo" => %{"name" => "legacy-plug", "version" => "1.0"}
          }
        },
        []
      )

    assert conn.status == 200
    List.first(get_resp_header(conn, "mcp-session-id"))
  end

  defp start_legacy_get(parent, plug, token, session_id) do
    spawn(fn ->
      conn =
        conn(:get, "/mcp")
        |> put_req_header("authorization", "Bearer " <> token)
        |> put_req_header("accept", "text/event-stream")
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("mcp-protocol-version", @legacy)

      send(parent, {:stream_done, AttestoMCP.Server.Plug.call(conn, plug)})
    end)
  end

  defp plug(server, config),
    do:
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource]
      )

  defp mint_token(config, subject, tenant, scopes) do
    claims =
      if is_nil(tenant),
        do: %{"client_id" => "client-#{subject}"},
        else: %{"client_id" => "client-#{subject}", "tenant" => tenant}

    principal = %{
      claims: claims,
      kind: "user",
      scopes: scopes,
      sub: subject
    }

    {:ok, token} = Attesto.Token.mint(config, principal)
    token.access_token
  end

  defp call(plug, token, method, body, opts) do
    conn =
      conn(
        String.to_atom(String.downcase(method)),
        "/mcp",
        if(body, do: Jason.encode!(body), else: "")
      )
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("accept", "application/json, text/event-stream")

    conn =
      if method == "POST",
        do: put_req_header(conn, "content-type", "application/json"),
        else: conn

    conn =
      case Keyword.get(opts, :session_id) do
        nil -> conn
        id -> put_req_header(conn, "mcp-session-id", id)
      end

    conn =
      case Keyword.get(opts, :protocol_version) do
        nil -> conn
        version -> put_req_header(conn, "mcp-protocol-version", version)
      end

    AttestoMCP.Server.Plug.call(conn, plug)
  end
end
