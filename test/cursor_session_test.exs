defmodule AttestoMCP.Server.CursorSessionTest do
  use ExUnit.Case, async: false
  alias AttestoMCP.Server
  alias AttestoMCP.Server.{Cursor, Session}

  @cursor_secret_key {Cursor, :secret}
  @concurrent_fallback_timeout_ms 30_000

  test "cursors bind principal and era and expire" do
    cursor = Cursor.issue(42, "alice", "2026-07-28", secret: "test-secret", ttl: 10_000)
    assert {:ok, 42} = Cursor.verify(cursor, "alice", "2026-07-28", secret: "test-secret")

    assert {:error, :invalid_cursor} =
             Cursor.verify(cursor, "bob", "2026-07-28", secret: "test-secret")

    assert {:error, :invalid_cursor} =
             Cursor.verify(cursor, "alice", "2025-11-25", secret: "test-secret")
  end

  test "catalog digests bind deterministic definition content but not runtime callbacks" do
    first = %{
      identity: "alpha",
      description: "same",
      handler: fn _, _ -> {:ok, "first"} end,
      authorize: fn _ -> true end
    }

    second =
      [
        authorize: fn _ -> false end,
        handler: fn _, _ -> {:ok, "second"} end,
        description: "same",
        identity: "alpha"
      ]
      |> Map.new()

    assert Cursor.catalog_digest([first]) == Cursor.catalog_digest([second])

    refute Cursor.catalog_digest([first]) ==
             Cursor.catalog_digest([Map.put(second, :description, "changed")])
  end

  test "catalog digest pins deterministic encoding for a wide normalized definition" do
    {:ok, server} = Server.start_link([])

    metadata = Enum.into(1..40, %{}, fn index -> {"metadata_#{index}", index} end)

    assert :ok =
             Server.register_tool(
               server,
               "wide",
               Map.merge(metadata, %{
                 description: "wide definition",
                 handler: fn _, _ -> {:ok, "one"} end
               })
             )

    [normalized] = Server.snapshot(server).tool |> Map.values()
    assert map_size(normalized) > 32

    digestible = Map.drop(normalized, [:handler, :authorize, "handler", "authorize"])
    item_digest = :crypto.hash(:sha256, :erlang.term_to_binary(digestible, [:deterministic]))

    expected =
      :crypto.hash(:sha256, :erlang.term_to_binary([item_digest], [:deterministic]))
      |> Base.url_encode64(padding: false)

    assert Cursor.catalog_digest([normalized]) == expected

    reordered =
      digestible
      |> Map.to_list()
      |> Enum.reverse()
      |> Map.new()
      |> Map.put(:handler, fn _, _ -> {:ok, "two"} end)

    assert Cursor.catalog_digest([reordered]) == expected
  end

  test "sessions bind principal and have bounded lifetime" do
    session = Session.new("alice", "tenant", idle_timeout: 100, absolute_timeout: 1000)
    assert Session.valid?(session)
    assert Session.same_principal?(session, "alice")
    refute Session.same_principal?(session, "bob")
    refute Session.valid?(%{session | last_seen: 0}, 1_000)
  end

  test "nil timeout options use safe defaults" do
    session = Session.new("alice", nil, idle_timeout: nil, absolute_timeout: nil)
    assert Session.valid?(session)
  end

  test "concurrent first use shares one runtime fallback cursor secret" do
    previous_env = Application.fetch_env(:attesto_mcp_server, :cursor_secret)
    previous_persisted = :persistent_term.get(@cursor_secret_key, :missing)

    on_exit(fn ->
      case previous_env do
        {:ok, value} -> Application.put_env(:attesto_mcp_server, :cursor_secret, value)
        :error -> Application.delete_env(:attesto_mcp_server, :cursor_secret)
      end

      case previous_persisted do
        :missing -> :persistent_term.erase(@cursor_secret_key)
        value -> :persistent_term.put(@cursor_secret_key, value)
      end
    end)

    Application.delete_env(:attesto_mcp_server, :cursor_secret)
    :persistent_term.erase(@cursor_secret_key)
    task_supervisor = start_supervised!(Task.Supervisor)
    parent = self()
    barrier = make_ref()

    tasks =
      for position <- 1..128 do
        Task.Supervisor.async_nolink(task_supervisor, fn ->
          send(parent, {barrier, :ready, self()})

          receive do
            {^barrier, :issue_cursor} -> Cursor.issue(position, "principal", "2026-07-28")
          end
        end)
      end

    deadline = deadline(@concurrent_fallback_timeout_ms)
    await_task_barrier!(tasks, barrier, deadline)
    Enum.each(tasks, &send(&1.pid, {barrier, :issue_cursor}))
    cursors = await_task_results!(tasks, deadline)

    Enum.zip(1..128, cursors)
    |> Enum.each(fn {position, cursor} ->
      assert {:ok, ^position} = Cursor.verify(cursor, "principal", "2026-07-28")
    end)
  end

  defp await_task_barrier!(tasks, barrier, deadline) do
    pending = MapSet.new(tasks, & &1.pid)

    case await_task_barrier(pending, barrier, deadline) do
      :ok ->
        :ok

      {:timeout, pending} ->
        Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
        flunk("cursor workers did not reach the barrier: #{MapSet.size(pending)} pending")
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

      flunk("cursor workers exceeded the absolute deadline")
    end

    Enum.map(results, fn
      {_task, {:ok, value}} -> value
      {_task, {:exit, reason}} -> flunk("cursor worker exited: #{inspect(reason)}")
    end)
  end

  defp deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
