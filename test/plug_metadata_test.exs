defmodule AttestoMCP.Server.PlugMetadataTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test
  alias AttestoMCP.Server

  defmodule RuntimeAuth do
    @moduledoc false

    def effective(counter) do
      Agent.update(counter, &(&1 + 1))
      [config: %{issuer: "https://runtime-issuer.example"}]
    end

    def custom_scopes(counter) do
      Agent.update(counter, &(&1 + 1))

      [
        config: %{issuer: "https://runtime-issuer.example"},
        scopes_supported: ["workspace.documents.read", "workspace.documents.write"]
      ]
    end

    def unavailable(counter) do
      Agent.update(counter, &(&1 + 1))
      raise "runtime authorization configuration unavailable"
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

  test "each mount advertises only its configured authorization scopes", %{server: server} do
    documents =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/documents",
        scopes_supported: ["documents.read"],
        auth: [issuer: "https://issuer.example", resource: "https://api.example/documents"]
      )

    reports =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/reports",
        auth: [
          issuer: "https://issuer.example",
          resource: "https://api.example/reports",
          scopes_supported: ["reports.read"]
        ]
      )

    documents_response =
      conn(:get, "/.well-known/oauth-protected-resource/documents")
      |> AttestoMCP.Server.Plug.call(documents)
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()

    reports_response =
      conn(:get, "/.well-known/oauth-protected-resource/reports")
      |> AttestoMCP.Server.Plug.call(reports)
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()

    assert documents_response["scopes_supported"] == ["documents.read"]
    assert reports_response["scopes_supported"] == ["reports.read"]
  end

  test "metadata keeps the generic default and rejects conflicting scope declarations", %{
    server: server
  } do
    state =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [issuer: "https://issuer.example", resource: "https://api.example/mcp"]
      )

    response =
      conn(:get, "/.well-known/oauth-protected-resource/mcp")
      |> AttestoMCP.Server.Plug.call(state)
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()

    assert response["scopes_supported"] == AttestoMCP.Scopes.all()

    assert_raise ArgumentError, ~r/conflicting top-level and auth option/, fn ->
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        scopes_supported: ["documents.read"],
        auth: [
          issuer: "https://issuer.example",
          resource: "https://api.example/mcp",
          scopes_supported: ["reports.read"]
        ]
      )
    end
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

  test "metadata uses one effective runtime auth snapshot and the pinned resource", %{
    server: server
  } do
    counter = start_counter()

    state =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: {RuntimeAuth, :effective, [counter]},
        resource: "https://canonical-resource.example/mcp"
      )

    response =
      conn(:get, "/.well-known/oauth-protected-resource/mcp")
      |> AttestoMCP.Server.Plug.call(state)

    assert response.status == 200
    assert Agent.get(counter, & &1) == 1

    assert %{
             "resource" => "https://canonical-resource.example/mcp",
             "authorization_servers" => ["https://runtime-issuer.example"],
             "bearer_methods_supported" => ["header"]
           } = Jason.decode!(response.resp_body)
  end

  test "metadata advertises custom scopes from the effective runtime auth snapshot", %{
    server: server
  } do
    counter = start_counter()

    state =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: {RuntimeAuth, :custom_scopes, [counter]},
        resource: "https://canonical-resource.example/mcp"
      )

    response =
      conn(:get, "/.well-known/oauth-protected-resource/mcp")
      |> AttestoMCP.Server.Plug.call(state)

    assert response.status == 200
    assert Agent.get(counter, & &1) == 1

    assert Jason.decode!(response.resp_body)["scopes_supported"] == [
             "workspace.documents.read",
             "workspace.documents.write"
           ]
  end

  test "runtime auth resolver failure makes metadata generically unavailable", %{server: server} do
    counter = start_counter()

    state =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: {RuntimeAuth, :unavailable, [counter]},
        resource: "https://canonical-resource.example/mcp"
      )

    response =
      conn(:get, "/.well-known/oauth-protected-resource/mcp")
      |> AttestoMCP.Server.Plug.call(state)

    assert response.status == 500
    assert response.resp_body == "internal server error"
    assert Agent.get(counter, & &1) == 1
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

    assert_raise ArgumentError, ~r/bearer_methods.*only :header/, fn ->
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [
          issuer: "https://issuer.example",
          resource: "http://www.example.com/mcp",
          bearer_methods: [:body]
        ]
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

  test "server-state exits are contained as service unavailable" do
    server =
      spawn(fn ->
        receive do
          {:"$gen_call", _from, :options} -> exit(:simulated_server_failure)
        end
      end)

    state =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [issuer: "https://issuer.example", resource: "http://www.example.com/mcp"]
      )

    response = AttestoMCP.Server.Plug.call(conn(:get, "/mcp"), state)
    assert response.status == 503
    assert response.resp_body == "service unavailable"
  end

  test "throws and exits are contained with HTTP exception telemetry", %{server: server} do
    handler_id = {__MODULE__, :http_failure, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:attesto_mcp_server, :http_request, :exception],
        &__MODULE__.http_failure_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    for failure <- [:throw, :exit] do
      config = fn ->
        case failure do
          :throw -> throw(:simulated_auth_config_failure)
          :exit -> exit(:simulated_auth_config_failure)
        end
      end

      state =
        AttestoMCP.Server.Plug.init(
          server: server,
          path: "/mcp",
          auth: [config: config, resource: "http://www.example.com/mcp"]
        )

      response =
        AttestoMCP.Server.Plug.call(
          conn(:get, "/.well-known/oauth-protected-resource/mcp"),
          state
        )

      assert response.status == 500
      assert response.resp_body == "internal server error"

      assert_receive {:http_failure, measurements,
                      %{status: 500, outcome: :exception, transport: :http}}

      assert is_integer(measurements.duration)
      assert measurements.duration >= 0
    end
  end

  test "failure containment preserves an already-sent connection", %{server: server} do
    state =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [
          config: fn -> throw(:simulated_auth_config_failure) end,
          resource: "http://www.example.com/mcp"
        ]
      )

    sent =
      conn(:get, "/.well-known/oauth-protected-resource/mcp")
      |> send_resp(204, "already sent")

    assert AttestoMCP.Server.Plug.call(sent, state) == sent
  end

  test "Plug rejects unsafe paths and unknown options", %{server: server} do
    base = [
      server: server,
      auth: [issuer: "https://issuer.example", resource: "http://www.example.com/mcp"]
    ]

    for path <- [
          "/mcp/../x",
          "/mcp?x=1",
          "/literal\\segment",
          "/encoded%3Asegment",
          "/:tenant/mcp",
          "/mcp/*rest",
          "/café",
          "/mcp{unsafe}"
        ] do
      assert_raise ArgumentError, fn -> AttestoMCP.Server.Plug.init(base ++ [path: path]) end
    end

    assert_raise ArgumentError, ~r/unknown Plug option/, fn ->
      AttestoMCP.Server.Plug.init(base ++ [unknown: true])
    end
  end

  def http_failure_event(_event, measurements, metadata, receiver) do
    send(receiver, {:http_failure, measurements, metadata})
  end

  defp start_counter do
    name = Module.concat(__MODULE__, "Counter#{System.unique_integer([:positive])}")
    {:ok, _counter} = Agent.start_link(fn -> 0 end, name: name)
    name
  end
end
