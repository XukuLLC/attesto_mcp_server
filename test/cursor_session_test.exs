defmodule AttestoMCP.Server.CursorSessionTest do
  use ExUnit.Case, async: false
  alias AttestoMCP.Server.{Cursor, Session}

  @cursor_secret_key {Cursor, :secret}

  test "cursors bind principal and era and expire" do
    cursor = Cursor.issue(42, "alice", "2026-07-28", secret: "test-secret", ttl: 10_000)
    assert {:ok, 42} = Cursor.verify(cursor, "alice", "2026-07-28", secret: "test-secret")

    assert {:error, :invalid_cursor} =
             Cursor.verify(cursor, "bob", "2026-07-28", secret: "test-secret")

    assert {:error, :invalid_cursor} =
             Cursor.verify(cursor, "alice", "2025-11-25", secret: "test-secret")
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
    parent = self()

    tasks =
      for position <- 1..128 do
        Task.async(fn ->
          send(parent, {:cursor_ready, self()})

          receive do
            :issue_cursor -> Cursor.issue(position, "principal", "2026-07-28")
          end
        end)
      end

    task_pids = MapSet.new(tasks, & &1.pid)

    for _ <- tasks do
      assert_receive {:cursor_ready, pid}, 1_000
      assert MapSet.member?(task_pids, pid)
    end

    Enum.each(tasks, &send(&1.pid, :issue_cursor))
    cursors = Enum.map(tasks, &Task.await(&1, 5_000))

    Enum.zip(1..128, cursors)
    |> Enum.each(fn {position, cursor} ->
      assert {:ok, ^position} = Cursor.verify(cursor, "principal", "2026-07-28")
    end)
  end
end
