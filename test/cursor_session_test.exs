defmodule AttestoMCP.Server.CursorSessionTest do
  use ExUnit.Case, async: true
  alias AttestoMCP.Server.{Cursor, Session}

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
end
