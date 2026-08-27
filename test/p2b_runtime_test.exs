defmodule AttestoMCP.Server.P2BRuntimeTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server
  alias AttestoMCP.Server.Subscriptions

  @modern "2026-07-28"

  defp modern(params) do
    Map.put_new(params, "_meta", %{
      "io.modelcontextprotocol/protocolVersion" => @modern,
      "io.modelcontextprotocol/clientCapabilities" => %{}
    })
  end

  defp wait_until(fun, attempts \\ 50)

  defp wait_until(_fun, 0), do: flunk("condition did not become true")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  @tag :g06
  @tag :t40
  test "registry restart restores definitions and sibling supervisors recover" do
    {:ok, server} = Server.start_link(max_concurrency: 4)

    assert :ok =
             Server.register_tool(server, "persistent", %{
               handler: fn _, _ -> {:ok, "still here"} end
             })

    old_registry = :sys.get_state(server).registry
    Process.exit(old_registry, :kill)

    wait_until(fn ->
      state = :sys.get_state(server)
      state.registry != old_registry and Process.alive?(state.registry)
    end)

    assert Enum.any?(Server.snapshot(server).tool, fn {_id, item} -> item.name == "persistent" end)

    old_subscriptions = :sys.get_state(server).subscriptions

    assert {:ok, "runtime-sub"} =
             Subscriptions.open(
               old_subscriptions,
               "principal",
               "tenant",
               "runtime-sub",
               %{"toolsListChanged" => true},
               self(),
               :runtime_sub,
               nil
             )

    assert_receive {:mcp_subscription, :runtime_sub, "runtime-sub", _ack}
    Process.exit(old_subscriptions, :kill)

    wait_until(fn ->
      state = :sys.get_state(server)
      state.subscriptions != old_subscriptions and Process.alive?(state.subscriptions)
    end)

    assert %{subscriptions: 0, subscription_queue: 0} = Server.stats(server)

    old_tasks = :sys.get_state(server).tasks
    Process.exit(old_tasks, :kill)

    wait_until(fn ->
      state = :sys.get_state(server)
      state.tasks != old_tasks and Process.alive?(state.tasks)
    end)

    request = %{
      kind: :request,
      id: 1,
      method: "tools/call",
      params: modern(%{"name" => "persistent", "arguments" => %{}})
    }

    assert {1, %{"result" => %{"isError" => false}}} =
             Server.dispatch(server, request, %{principal: "principal"}, version: @modern)
  end

  @tag :g06
  @tag :t40
  test "concurrent bounded work returns counters to zero" do
    {:ok, server} = Server.start_link(max_concurrency: 8, per_principal_concurrency: 2)

    assert :ok =
             Server.register_tool(server, "slow", %{
               handler: fn _, _ ->
                 Process.sleep(8)
                 {:ok, "ok"}
               end
             })

    request = fn id ->
      %{
        kind: :request,
        id: id,
        method: "tools/call",
        params: modern(%{"name" => "slow", "arguments" => %{}})
      }
    end

    jobs =
      for id <- 1..120 do
        Task.async(fn ->
          Server.dispatch(
            server,
            request.(id),
            %{principal: "principal-#{rem(id, 12)}"},
            version: @modern
          )
        end)
      end

    results = Task.await_many(jobs, 10_000)
    assert length(results) == 120
    assert Enum.all?(results, &match?({_, %{}}, &1))

    wait_until(fn ->
      stats = Server.stats(server)
      stats.active == 0 and stats.active_requests == 0
    end)

    assert %{active: 0, active_requests: 0, subscriptions: 0, subscription_queue: 0} =
             Server.stats(server)
  end
end
