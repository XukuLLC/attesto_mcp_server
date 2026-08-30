defmodule AttestoMCP.Server.LegacyPlugTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AttestoMCP.Server

  @resource "https://mcp.example.com/mcp"
  @legacy "2025-11-25"
  @legacy_2025_06_18 "2025-06-18"
  @short_session_timeout_ms 500
  @http_race_timeout_ms 120_000

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
        protocol_version: @legacy_2025_06_18
      )

    assert wrong_version.status == 400
    assert Jason.decode!(wrong_version.resp_body)["error"]["code"] == -32020
  end

  test "authenticated HTTP session negotiates and enforces 2025-06-18" do
    {:ok, server} = Server.start_link([])

    assert :ok =
             Server.register_tool(server, "versioned_http", %{
               icons: [%{src: "https://example.test/icon.png"}],
               handler: fn _, _ -> {:ok, "ok"} end
             })

    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())
    plug = plug(server, config)

    initialized =
      call(
        plug,
        token,
        "POST",
        %{
          "jsonrpc" => "2.0",
          "id" => 21,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => @legacy_2025_06_18,
            "capabilities" => %{},
            "clientInfo" => %{"name" => "compat-http", "version" => "1.0"}
          }
        },
        protocol_version: @legacy_2025_06_18
      )

    assert initialized.status == 200
    assert Jason.decode!(initialized.resp_body)["result"]["protocolVersion"] == @legacy_2025_06_18
    session_id = initialized |> get_resp_header("mcp-session-id") |> List.first()

    before_initialized =
      call(
        plug,
        token,
        "POST",
        %{"jsonrpc" => "2.0", "id" => 20, "method" => "tools/list", "params" => %{}},
        session_id: session_id,
        protocol_version: @legacy_2025_06_18
      )

    assert before_initialized.status == 400

    missing_version =
      conn(
        :post,
        "/mcp",
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 24, "method" => "ping", "params" => %{}})
      )
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("mcp-session-id", session_id)
      |> AttestoMCP.Server.Plug.call(plug)

    assert missing_version.status == 200
    assert Jason.decode!(missing_version.resp_body)["result"] == %{}

    notification =
      call(
        plug,
        token,
        "POST",
        %{"jsonrpc" => "2.0", "method" => "notifications/initialized", "params" => %{}},
        session_id: session_id,
        protocol_version: @legacy_2025_06_18
      )

    assert notification.status == 202

    listed =
      call(
        plug,
        token,
        "POST",
        %{"jsonrpc" => "2.0", "id" => 22, "method" => "tools/list", "params" => %{}},
        session_id: session_id,
        protocol_version: @legacy_2025_06_18
      )

    assert listed.status == 200
    assert [listed_tool] = Jason.decode!(listed.resp_body)["result"]["tools"]
    assert listed_tool["name"] == "versioned_http"
    refute Map.has_key?(listed_tool, "icons")

    mismatched =
      call(
        plug,
        token,
        "POST",
        %{"jsonrpc" => "2.0", "id" => 23, "method" => "ping", "params" => %{}},
        session_id: session_id,
        protocol_version: @legacy
      )

    assert mismatched.status == 400
    assert Jason.decode!(mismatched.resp_body)["error"]["code"] == -32020

    parent = self()

    stream =
      spawn(fn ->
        conn =
          conn(:get, "/mcp")
          |> put_req_header("authorization", "Bearer " <> token)
          |> put_req_header("accept", "text/event-stream")
          |> put_req_header("mcp-session-id", session_id)

        send(parent, {:compat_stream_done, AttestoMCP.Server.Plug.call(conn, plug)})
      end)

    Process.sleep(50)
    Server.publish(server, %{"type" => "toolsListChanged"})
    Process.sleep(50)

    deleted =
      conn(:delete, "/mcp")
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("mcp-session-id", session_id)
      |> AttestoMCP.Server.Plug.call(plug)

    assert deleted.status == 200
    assert_receive {:compat_stream_done, stream_conn}, 2_000
    assert stream_conn.status == 200
    assert stream_conn.resp_body =~ "notifications/tools/list_changed"
    refute Process.alive?(stream)
  end

  test "legacy initialize header honors the configured revision set" do
    {:ok, server} = Server.start_link(protocol_versions: [@legacy])
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
          "id" => 22,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => @legacy,
            "capabilities" => %{},
            "clientInfo" => %{"name" => "legacy-plug", "version" => "1.0"}
          }
        },
        protocol_version: @legacy_2025_06_18
      )

    assert rejected.status == 400
    assert Jason.decode!(rejected.resp_body)["error"]["code"] == -32020
  end

  test "HTTP does not treat 2025-06-18 modern metadata as a modern request" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())
    plug = plug(server, config)

    request = %{
      "jsonrpc" => "2.0",
      "id" => 25,
      "method" => "tools/list",
      "params" => %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @legacy_2025_06_18,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    without_session =
      call(plug, token, "POST", request, protocol_version: @legacy_2025_06_18)

    assert without_session.status == 400

    assert Jason.decode!(without_session.resp_body)["error"]["data"]["reason"] ==
             "legacy_session_required"

    modern_header = call(plug, token, "POST", request, protocol_version: "2026-07-28")
    assert modern_header.status == 400

    assert Jason.decode!(modern_header.resp_body)["error"]["data"]["reason"] ==
             "body_header_mismatch"
  end

  test "legacy HTTP rejects non-object metadata before streaming selection" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())
    plug = plug(server, config)
    session_id = initialize_session(plug, token)
    assert :ok = Server.mark_initialized(server, session_id)

    rejected =
      call(
        plug,
        token,
        "POST",
        %{
          "jsonrpc" => "2.0",
          "id" => 26,
          "method" => "resources/read",
          "params" => %{"uri" => "urn:legacy", "_meta" => 5}
        },
        session_id: session_id,
        protocol_version: @legacy
      )

    assert rejected.status == 200
    assert Jason.decode!(rejected.resp_body)["error"]["code"] == -32602

    recovered =
      call(
        plug,
        token,
        "POST",
        %{"jsonrpc" => "2.0", "id" => 27, "method" => "ping", "params" => %{}},
        session_id: session_id,
        protocol_version: @legacy
      )

    assert recovered.status == 200
  end

  test "rejected legacy resource subscriptions do not refresh the session idle timer" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())
    plug = plug(server, config)
    session_id = initialize_session(plug, token)

    assert {:ok, before_initialized_rejection} =
             Server.peek_session(server, session_id, "usr_123", nil)

    Process.sleep(5)

    before_initialized =
      call(
        plug,
        token,
        "POST",
        %{
          "jsonrpc" => "2.0",
          "id" => 27,
          "method" => "resources/subscribe",
          "params" => %{"uri" => "urn:before-initialized"}
        },
        session_id: session_id,
        protocol_version: @legacy
      )

    assert before_initialized.status == 400

    assert Jason.decode!(before_initialized.resp_body)["error"]["data"]["reason"] ==
             "initialized_notification_required"

    assert {:ok, after_initialized_rejection} =
             Server.peek_session(server, session_id, "usr_123", nil)

    assert after_initialized_rejection.last_seen == before_initialized_rejection.last_seen
    assert :ok = Server.mark_initialized(server, session_id)

    for index <- 1..128 do
      assert :ok =
               Server.subscribe_resource(server, session_id, "usr_123", nil, "urn:#{index}")
    end

    assert {:ok, before_rejections} =
             Server.peek_session(server, session_id, "usr_123", nil)

    Process.sleep(5)

    at_limit =
      call(
        plug,
        token,
        "POST",
        %{
          "jsonrpc" => "2.0",
          "id" => 28,
          "method" => "resources/subscribe",
          "params" => %{"uri" => "urn:129"}
        },
        session_id: session_id,
        protocol_version: @legacy
      )

    assert at_limit.status == 200

    assert Jason.decode!(at_limit.resp_body)["error"]["data"]["reason"] ==
             "resource_subscription_limit"

    assert {:ok, after_limit} = Server.peek_session(server, session_id, "usr_123", nil)
    assert after_limit.last_seen == before_rejections.last_seen

    Process.sleep(5)

    oversized =
      call(
        plug,
        token,
        "POST",
        %{
          "jsonrpc" => "2.0",
          "id" => 29,
          "method" => "resources/subscribe",
          "params" => %{"uri" => "urn:" <> String.duplicate("x", 4_093)}
        },
        session_id: session_id,
        protocol_version: @legacy
      )

    assert oversized.status == 200

    assert Jason.decode!(oversized.resp_body)["error"]["data"]["reason"] ==
             "invalid_resource_uri"

    assert {:ok, after_oversized} = Server.peek_session(server, session_id, "usr_123", nil)
    assert after_oversized.last_seen == before_rejections.last_seen

    Process.sleep(5)

    duplicate =
      call(
        plug,
        token,
        "POST",
        %{
          "jsonrpc" => "2.0",
          "id" => 30,
          "method" => "resources/subscribe",
          "params" => %{"uri" => "urn:1"}
        },
        session_id: session_id,
        protocol_version: @legacy
      )

    assert duplicate.status == 200
    assert Jason.decode!(duplicate.resp_body)["result"] == %{}
    assert {:ok, after_success} = Server.peek_session(server, session_id, "usr_123", nil)
    assert after_success.last_seen > after_oversized.last_seen
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
    sessions_before = Server.stats(server).sessions

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
    assert Server.stats(server).sessions == sessions_before
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
    {:ok, server} = Server.start_link(session_idle_timeout: 60_000)
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

    {:ok, expiry_server} =
      Server.start_link(session_idle_timeout: @short_session_timeout_ms)

    expiry_plug = plug(expiry_server, config)
    expiry_session_id = initialize_session(expiry_plug, token)
    assert Server.mark_initialized(expiry_server, expiry_session_id) == :ok

    assert eventually_until(
             fn -> Server.stats(expiry_server).sessions == 0 end,
             deadline(@short_session_timeout_ms + 5_000)
           )

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
      Server.start_link(
        session_absolute_timeout: @short_session_timeout_ms,
        session_idle_timeout: 10_000
      )

    absolute_plug = plug(absolute_server, config)
    absolute_session_id = initialize_session(absolute_plug, token)
    assert Server.mark_initialized(absolute_server, absolute_session_id) == :ok

    assert eventually_until(
             fn -> Server.stats(absolute_server).sessions == 0 end,
             deadline(@short_session_timeout_ms + 5_000)
           )

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

  @tag timeout: 130_000
  test "public HTTP initialized/request races remain bounded across 100 schedules" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())
    plug = plug(server, config)
    task_supervisor = start_supervised!(Task.Supervisor)
    race_deadline = deadline(@http_race_timeout_ms)

    runner =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        run_public_http_races(task_supervisor, plug, token, race_deadline)
      end)

    assert [:ok] = await_task_results!([runner], race_deadline, "HTTP race runner")
  end

  defp run_public_http_races(task_supervisor, plug, token, race_deadline) do
    for index <- 1..100 do
      session_id = initialize_session(plug, token)
      owner = self()
      barrier = make_ref()

      notification = fn ->
        send(owner, {barrier, :ready, self()})

        receive do
          {^barrier, :go} -> :ok
        end

        conn =
          call(
            plug,
            token,
            "POST",
            %{"jsonrpc" => "2.0", "method" => "notifications/initialized", "params" => %{}},
            session_id: session_id
          )

        {:initialized, conn.status}
      end

      normal = fn ->
        send(owner, {barrier, :ready, self()})

        receive do
          {^barrier, :go} -> :ok
        end

        conn =
          call(
            plug,
            token,
            "POST",
            %{"jsonrpc" => "2.0", "id" => index, "method" => "tools/list", "params" => %{}},
            session_id: session_id
          )

        reason =
          if conn.status == 400,
            do: get_in(Jason.decode!(conn.resp_body), ["error", "data", "reason"]),
            else: nil

        {:normal, {conn.status, reason}}
      end

      racers =
        if rem(index, 2) == 0,
          do: [notification, normal],
          else: [normal, notification]

      tasks =
        Enum.map(racers, &Task.Supervisor.async_nolink(task_supervisor, &1))

      await_task_barrier!(tasks, barrier, race_deadline, "HTTP racers")
      Enum.each(tasks, &send(&1.pid, {barrier, :go}))

      outcomes = tasks |> await_task_results!(race_deadline, "HTTP racers") |> Map.new()

      assert outcomes[:initialized] == 202

      case outcomes[:normal] do
        {200, nil} ->
          :ok

        {400, "initialized_notification_required"} ->
          :ok
      end

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

    :ok
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

  defp await_task_barrier!(tasks, barrier, deadline, label) do
    pending = MapSet.new(tasks, & &1.pid)

    case await_task_barrier(pending, barrier, deadline) do
      :ok ->
        :ok

      {:timeout, pending} ->
        Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
        flunk("#{label} did not reach the barrier: #{MapSet.size(pending)} pending")
    end
  end

  defp await_task_barrier(pending, barrier, deadline) do
    if MapSet.size(pending) == 0 do
      :ok
    else
      receive do
        {^barrier, :ready, pid} ->
          await_task_barrier(MapSet.delete(pending, pid), barrier, deadline)
      after
        remaining(deadline) -> {:timeout, pending}
      end
    end
  end

  defp await_task_results!(tasks, deadline, label) do
    results = Task.yield_many(tasks, remaining(deadline))

    if Enum.any?(results, &match?({_task, nil}, &1)) do
      Enum.each(results, fn
        {task, nil} -> Task.shutdown(task, :brutal_kill)
        _completed -> :ok
      end)

      flunk("#{label} exceeded the absolute deadline")
    end

    Enum.map(results, fn
      {_task, {:ok, value}} -> value
      {_task, {:exit, reason}} -> flunk("#{label} exited: #{inspect(reason)}")
    end)
  end

  defp eventually_until(fun, deadline) do
    cond do
      fun.() ->
        true

      remaining(deadline) > 0 ->
        Process.sleep(min(remaining(deadline), 10))
        eventually_until(fun, deadline)

      true ->
        false
    end
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

  defp deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
