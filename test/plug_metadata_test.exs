defmodule AttestoMCP.Server.PlugMetadataTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test
  alias AttestoMCP.Server

  setup do
    {:ok, server} =
      DynamicSupervisor.start_child(
        AttestoMCP.Server.DynamicSupervisor,
        {Server, []}
      )

    on_exit(fn ->
      DynamicSupervisor.terminate_child(AttestoMCP.Server.DynamicSupervisor, server)
    end)

    {:ok, server: server}
  end

  test "protected-resource metadata is public and JSON encoded", %{server: server} do
    conn = conn(:get, "/.well-known/oauth-protected-resource/mcp")

    opts =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [issuer: "https://issuer.example", resource: "http://www.example.com/mcp"]
      )

    conn = AttestoMCP.Server.Plug.call(conn, opts)
    assert conn.status == 200
    assert %{"resource" => "http://www.example.com/mcp"} = Jason.decode!(conn.resp_body)
  end

  test "metadata resolves a documented config callback", %{server: server} do
    conn = conn(:get, "/.well-known/oauth-protected-resource/mcp")

    opts =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [
          resource: "http://www.example.com/mcp",
          config: fn -> %{issuer: "https://issuer.example"} end
        ]
      )

    conn = AttestoMCP.Server.Plug.call(conn, opts)
    assert conn.status == 200

    assert %{"authorization_servers" => ["https://issuer.example"]} =
             Jason.decode!(conn.resp_body)
  end

  test "top-level resource options normalize into the auth boundary", %{server: server} do
    conn = conn(:get, "/.well-known/oauth-protected-resource/mcp")

    opts =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        resource: "http://www.example.com/mcp",
        auth: [issuer: "https://issuer.example"]
      )

    conn = AttestoMCP.Server.Plug.call(conn, opts)
    assert Jason.decode!(conn.resp_body)["resource"] == "http://www.example.com/mcp"

    assert_raise ArgumentError, ~r/conflicting/, fn ->
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        resource: "http://one.example/mcp",
        auth: [issuer: "https://issuer.example", resource: "http://two.example/mcp"]
      )
    end
  end

  test "unsupported verbs are rejected before dispatch", %{server: server} do
    conn = conn(:put, "/mcp")

    opts =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [issuer: "https://issuer.example", resource: "http://www.example.com/mcp"]
      )

    conn = AttestoMCP.Server.Plug.call(conn, opts)
    assert conn.status == 405
  end

  test "stream selection options are validated at Plug init", %{server: server} do
    base = [
      server: server,
      path: "/mcp",
      auth: [issuer: "https://issuer.example", resource: "http://www.example.com/mcp"]
    ]

    state =
      AttestoMCP.Server.Plug.init(base ++ [stream_tools: ["progress"], stream_all_tools: false])

    assert state.opts[:stream_tools] == ["progress"]
    assert state.opts[:stream_all_tools] == false

    assert_raise ArgumentError, ~r/stream_all_tools/, fn ->
      AttestoMCP.Server.Plug.init(base ++ [stream_all_tools: :yes])
    end

    assert_raise ArgumentError, ~r/stream_tools/, fn ->
      AttestoMCP.Server.Plug.init(base ++ [stream_tools: ["progress", "progress"]])
    end

    assert_raise ArgumentError, ~r/stream_tools/, fn ->
      AttestoMCP.Server.Plug.init(base ++ [stream_tools: "progress"])
    end
  end

  test "protected traffic fails closed with an RFC 9728 challenge", %{server: server} do
    conn =
      conn(:post, "/mcp", "{}") |> put_req_header("accept", "application/json, text/event-stream")

    opts =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [issuer: "https://issuer.example", resource: "http://www.example.com/mcp"]
      )

    conn = AttestoMCP.Server.Plug.call(conn, opts)
    assert conn.status == 401
    assert [challenge] = get_resp_header(conn, "www-authenticate")
    assert String.contains?(challenge, "resource_metadata=")
  end

  test "named server Plug state is escape-safe before startup" do
    state =
      AttestoMCP.Server.Plug.init(
        server: :late_mcp_server,
        path: "/mcp",
        auth: [issuer: "https://issuer.example", resource: "http://www.example.com/mcp"]
      )

    assert is_tuple(Macro.escape(state))

    conn = AttestoMCP.Server.Plug.call(conn(:get, "/mcp"), state)
    assert conn.status == 503
  end

  test "Plug rejects unsafe paths and unknown options", %{server: server} do
    base = [
      server: server,
      auth: [issuer: "https://issuer.example", resource: "http://www.example.com/mcp"]
    ]

    assert_raise ArgumentError, fn -> AttestoMCP.Server.Plug.init(base ++ [path: "/mcp/../x"]) end
    assert_raise ArgumentError, fn -> AttestoMCP.Server.Plug.init(base ++ [path: "/mcp?x=1"]) end

    assert_raise ArgumentError, ~r/unknown Plug option/, fn ->
      AttestoMCP.Server.Plug.init(base ++ [unknown: true])
    end
  end
end
