defmodule AttestoMCP.Server.P11ProtectResourceTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AttestoMCP.Server

  @concurrent_fallback_timeout_ms 30_000

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

  test "public ProtectResource derives an absolute audience from path plus base URL", %{
    server: server
  } do
    state =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [
          issuer: "https://issuer.example",
          resource: "/mcp",
          base_url: "https://mcp.example.com"
        ]
      )

    boundary = state.auth_boundary
    assert get_in(boundary, [:authenticate, :resource_path]) == "/mcp"
    assert get_in(boundary, [:authenticate, :base_url]) == "https://mcp.example.com"
    assert get_in(boundary, [:authenticate, :resource_audience]) == :resource
    refute get_in(boundary, [:authenticate, :allow_dynamic_origin])
  end

  test "public ProtectResource keeps an explicit absolute canonical audience", %{server: server} do
    state =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [
          issuer: "https://issuer.example",
          resource: "https://mcp.example.com/mcp"
        ]
      )

    boundary = state.auth_boundary
    assert get_in(boundary, [:authenticate, :resource_path]) == "/mcp"

    assert get_in(boundary, [:authenticate, :resource_audience]) ==
             "https://mcp.example.com/mcp"
  end

  test "the package-only dynamic-origin opt-in is not forwarded to Attesto", %{server: server} do
    state =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [issuer: "https://issuer.example", resource: "/mcp", allow_dynamic_origin: true]
      )

    boundary = state.auth_boundary
    refute get_in(boundary, [:authenticate, :allow_dynamic_origin])
    assert get_in(boundary, [:authenticate, :resource_audience]) == :resource
  end

  test "a path-only audience without a pinned origin is rejected", %{server: server} do
    assert_raise ArgumentError, ~r/resource_audience must be an absolute URL/, fn ->
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [issuer: "https://issuer.example", resource_audience: "/mcp"]
      )
    end
  end

  test "a relative explicit audience is rejected even with a base URL", %{server: server} do
    assert_raise ArgumentError, ~r/resource_audience must be an absolute URL/, fn ->
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [
          issuer: "https://issuer.example",
          resource: "/mcp",
          resource_audience: "/mcp",
          base_url: "https://mcp.example.com"
        ]
      )
    end
  end

  test "a relative resource must be the configured Plug path", %{server: server} do
    assert_raise ArgumentError, ~r/relative :resource must match/, fn ->
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [
          issuer: "https://issuer.example",
          resource: "/other",
          base_url: "https://mcp.example.com"
        ]
      )
    end
  end

  test "a non-string resource is rejected instead of being ignored", %{server: server} do
    assert_raise ArgumentError, ~r/:resource must be an absolute URL/, fn ->
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [
          issuer: "https://issuer.example",
          resource: :resource,
          base_url: "https://mcp.example.com"
        ]
      )
    end
  end

  test "an absolute canonical resource must use the configured Plug path", %{server: server} do
    assert_raise ArgumentError, ~r/canonical resource path/, fn ->
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [
          issuer: "https://issuer.example",
          resource: "https://mcp.example.com/other"
        ]
      )
    end
  end

  test "conflicting absolute resource and origin are rejected", %{server: server} do
    assert_raise ArgumentError, ~r/canonical resource and base origin/, fn ->
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [
          issuer: "https://issuer.example",
          resource: "https://one.example/mcp",
          base_url: "https://two.example"
        ]
      )
    end
  end

  test "a path plus base URL accepts the absolute-audience token and rejects a path audience", %{
    server: server
  } do
    config = AttestoMCP.Test.Factory.config()
    canonical = "https://mcp.example.com/mcp"

    assert :ok =
             Server.register_tool(server, "audience-check", %{
               input_schema: %{"type" => "object"},
               handler: fn _arguments, _context -> {:ok, "accepted"} end
             })

    plug =
      AttestoMCP.Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: "/mcp", base_url: "https://mcp.example.com"]
      )

    request = fn token ->
      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{
            "_meta" => %{
              "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
              "io.modelcontextprotocol/clientCapabilities" => %{}
            },
            "name" => "audience-check",
            "arguments" => %{}
          }
        })

      conn(:post, "/mcp", body)
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", "2026-07-28")
      |> put_req_header("mcp-method", "tools/call")
      |> put_req_header("mcp-name", "audience-check")
      |> AttestoMCP.Server.Plug.call(plug)
    end

    valid =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [AttestoMCP.Scopes.tools_call()],
        audience: canonical
      )

    invalid =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [AttestoMCP.Scopes.tools_call()],
        audience: "/mcp"
      )

    assert request.(valid).status == 200
    assert request.(invalid).status == 401
  end

  test "request-state fallback secret is stable under concurrent first use" do
    secret_key = {AttestoMCP.Server.RequestState, :secret}
    previous = :persistent_term.get(secret_key, nil)
    :persistent_term.erase(secret_key)

    on_exit(fn ->
      if is_binary(previous),
        do: :persistent_term.put(secret_key, previous),
        else: :persistent_term.erase(secret_key)
    end)

    task_supervisor = start_supervised!(Task.Supervisor)
    parent = self()
    barrier = make_ref()

    tasks =
      for index <- 1..64 do
        Task.Supervisor.async_nolink(task_supervisor, fn ->
          send(parent, {barrier, :ready, self()})

          receive do
            {^barrier, :issue} -> :ok
          end

          token =
            AttestoMCP.Server.RequestState.issue(
              "principal-#{index}",
              "tenant",
              "2026-07-28",
              "tools/call",
              %{"index" => index},
              ttl: @concurrent_fallback_timeout_ms * 2,
              consume: false
            )

          token
        end)
      end

    deadline = deadline(@concurrent_fallback_timeout_ms)
    await_task_barrier!(tasks, barrier, deadline)
    Enum.each(tasks, &send(&1.pid, {barrier, :issue}))
    tokens = await_task_results!(tasks, deadline)
    assert length(tokens) == 64

    for {token, index} <- Enum.zip(tokens, 1..64) do
      assert {:ok, _} =
               AttestoMCP.Server.RequestState.verify(
                 token,
                 "principal-#{index}",
                 "tenant",
                 "2026-07-28",
                 "tools/call",
                 %{"index" => index},
                 consume: false
               )
    end
  end

  test "client request waiters are removed when their handler task dies" do
    {:ok, server} = Server.start_link(client_request_timeout: 5_000)
    {:ok, session} = Server.new_session(server, "waiter", "tenant")

    assert :ok =
             Server.negotiate_session(
               server,
               session.id,
               "waiter",
               "tenant",
               "2025-11-25",
               %{"sampling" => %{}}
             )

    assert :ok = Server.mark_initialized(server, session.id)

    assert {:ok, stream} =
             Server.open_legacy_stream(server, session.id, "waiter", "tenant", self())

    assert :ok =
             Server.register_tool(server, "waiter-tool", %{
               input_schema: %{"type" => "object"},
               handler: fn _arguments, context ->
                 _ = context.client_request.("sampling/createMessage", %{"messages" => []})
                 {:ok, "unreachable"}
               end
             })

    caller =
      spawn(fn ->
        Server.dispatch(
          server,
          %{
            kind: :request,
            id: "waiter-call",
            method: "tools/call",
            params: %{"name" => "waiter-tool", "arguments" => %{}}
          },
          %{principal: "waiter", tenant: "tenant", session_id: session.id},
          version: "2025-11-25"
        )
      end)

    assert_receive {:mcp_legacy_event, ^stream, _event_id,
                    %{"method" => "sampling/createMessage"}},
                   1_000

    Process.exit(caller, :kill)

    assert eventually(fn -> Server.stats(server).client_requests == 0 end)
    assert eventually(fn -> Server.stats(server).active_requests == 0 end)
  end

  test "rate buckets retain each category's own window and stay capped" do
    {:ok, server} =
      Server.start_link(
        rate_limits: %{
          calls: %{burst: 1, window_ms: 2_000},
          completion: false,
          subscriptions: false,
          auth_failures: %{burst: 1, window_ms: 5}
        }
      )

    assert :ok = Server.allow_rate(server, {:principal, "long"}, :calls)
    assert {:error, :rate_limited} = Server.allow_rate(server, {:principal, "long"}, :calls)

    Process.sleep(10)
    assert :ok = Server.allow_rate(server, {:ip, {127, 0, 0, 1}}, :auth_failures)
    assert {:error, :rate_limited} = Server.allow_rate(server, {:principal, "long"}, :calls)

    for index <- 1..10_050 do
      assert :ok = Server.allow_rate(server, {:principal, index}, :calls)
    end

    assert Server.stats(server).rate_buckets <= 10_000
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp await_task_barrier!(tasks, barrier, deadline) do
    pending = MapSet.new(tasks, & &1.pid)

    case await_task_barrier(pending, barrier, deadline) do
      :ok ->
        :ok

      {:timeout, pending} ->
        Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))

        flunk(
          "concurrent fallback workers did not reach the barrier: #{MapSet.size(pending)} pending"
        )
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

  defp await_task_results!(tasks, deadline) do
    results = Task.yield_many(tasks, remaining(deadline))

    if Enum.any?(results, &match?({_task, nil}, &1)) do
      Enum.each(results, fn
        {task, nil} -> Task.shutdown(task, :brutal_kill)
        _completed -> :ok
      end)

      flunk("concurrent fallback workers exceeded the absolute deadline")
    end

    Enum.map(results, fn
      {_task, {:ok, value}} -> value
      {_task, {:exit, reason}} -> flunk("concurrent fallback worker exited: #{inspect(reason)}")
    end)
  end

  defp deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
