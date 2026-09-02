defmodule AttestoMCP.Server.SessionVisibilityTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server
  alias AttestoMCP.Server.API
  alias AttestoMCP.Server.Session
  alias AttestoMCP.Server.SessionStore.ETS

  defmodule UnpagedStore do
    @moduledoc false
    @behaviour AttestoMCP.Server.SessionStore

    @impl true
    defdelegate save(store, key, record), to: ETS
    @impl true
    defdelegate load(store, key), to: ETS
    @impl true
    defdelegate delete(store, key), to: ETS
    @impl true
    defdelegate list_active(store), to: ETS
    @impl true
    defdelegate update_ttl(store, key, now), to: ETS
    @impl true
    defdelegate update(store, key, fun), to: ETS
    @impl true
    defdelegate cleanup_expired(store), to: ETS
  end

  defmodule MalformedPageStore do
    @moduledoc false
    @behaviour AttestoMCP.Server.SessionStore

    @impl true
    defdelegate save(store, key, record), to: ETS
    @impl true
    defdelegate load(store, key), to: ETS
    @impl true
    defdelegate delete(store, key), to: ETS
    @impl true
    defdelegate list_active(store), to: ETS
    @impl true
    defdelegate update_ttl(store, key, now), to: ETS
    @impl true
    defdelegate update(store, key, fun), to: ETS
    @impl true
    defdelegate cleanup_expired(store), to: ETS

    @impl true
    def list_active_keys(_store, _namespace, _cursor, _limit),
      do: {:ok, %{keys: [{"namespace", "session-id"}], next_cursor: "not-the-last-id"}}
  end

  defmodule InvalidPageStore do
    @moduledoc false
    @behaviour AttestoMCP.Server.SessionStore

    @impl true
    defdelegate save(store, key, record), to: ETS
    @impl true
    defdelegate load(store, key), to: ETS
    @impl true
    defdelegate delete(store, key), to: ETS
    @impl true
    defdelegate list_active(store), to: ETS
    @impl true
    defdelegate update_ttl(store, key, now), to: ETS
    @impl true
    defdelegate update(store, key, fun), to: ETS
    @impl true
    defdelegate cleanup_expired(store), to: ETS

    @impl true
    def list_active_keys(_store, "oversized", _cursor, _limit),
      do:
        {:ok,
         %{
           keys: [{"oversized", "a"}, {"oversized", "b"}],
           next_cursor: "b"
         }}

    @impl true
    def list_active_keys(_store, "no-progress", cursor, _limit),
      do: {:ok, %{keys: [{"no-progress", cursor}], next_cursor: cursor}}
  end

  test "pages active IDs without exposing session records or bindings" do
    store = start_supervised!(ETS)
    server = start_server(session_store: {ETS, store}, session_namespace: "operator-page")

    sessions =
      for principal <- ["principal-c", "principal-a", "principal-b"] do
        {:ok, session} = Server.new_session(server, principal)
        session
      end

    expected_ids = sessions |> Enum.map(& &1.id) |> Enum.sort()

    assert {:ok, %{session_ids: first, next_cursor: cursor}} =
             API.active_session_ids(server, limit: 2)

    assert first == Enum.take(expected_ids, 2)
    assert cursor == List.last(first)

    assert {:ok, %{session_ids: second, next_cursor: nil}} =
             Server.active_session_ids(server, cursor: cursor, limit: 2)

    assert second == Enum.drop(expected_ids, 2)
    refute inspect(first) =~ "principal-"
    refute inspect(second) =~ "principal-"
  end

  test "ETS active key pages exclude expired records" do
    store = start_supervised!(ETS)

    {:ok, active_record} =
      Session.new("active-principal", nil, absolute_timeout: 86_400_000, idle_timeout: 86_400_000)
      |> Map.put(:id, "active-session")
      |> Session.to_record()

    expired_record =
      Map.merge(active_record, %{
        "id" => "expired-session",
        "created_at_ms" => 0,
        "last_seen_ms" => 0,
        "absolute_timeout_ms" => 1,
        "idle_timeout_ms" => 1
      })

    assert :ok = ETS.save(store, {"visibility", "active-session"}, active_record)
    assert :ok = ETS.save(store, {"visibility", "expired-session"}, expired_record)

    assert {:ok, %{keys: [{"visibility", "active-session"}], next_cursor: nil}} =
             ETS.list_active_keys(store, "visibility", nil, 100)
  end

  test "shared stores remain isolated by namespace" do
    store = start_supervised!(ETS)

    first = start_server(session_store: {ETS, store}, session_namespace: "first")
    second = start_server(session_store: {ETS, store}, session_namespace: "second")

    assert {:ok, first_session} = Server.new_session(first, "first-principal")
    assert {:ok, second_session} = Server.new_session(second, "second-principal")

    assert {:ok, %{session_ids: [first_id], next_cursor: nil}} =
             Server.active_session_ids(first)

    assert {:ok, %{session_ids: [second_id], next_cursor: nil}} =
             Server.active_session_ids(second)

    assert first_id == first_session.id
    assert second_id == second_session.id
  end

  test "invalid page options and adapters without key pagination fail explicitly" do
    assert {:error, :invalid_options} = Server.active_session_ids(self(), limit: 0)
    assert {:error, :invalid_options} = Server.active_session_ids(self(), limit: 1_001)
    assert {:error, :invalid_options} = Server.active_session_ids(self(), cursor: <<0>>)
    assert {:error, :invalid_options} = Server.active_session_ids(self(), unknown: true)
    assert {:error, :invalid_options} = Server.active_session_ids(self(), limit: 1, limit: 2)

    store = start_supervised!(ETS)

    server =
      start_server(session_store: {UnpagedStore, store}, session_namespace: "unsupported-page")

    assert {:error, :unsupported} = Server.active_session_ids(server)

    malformed =
      start_server(session_store: {MalformedPageStore, store}, session_namespace: "namespace")

    assert {:error, :session_store_unavailable} = Server.active_session_ids(malformed)

    invalid =
      start_server(session_store: {InvalidPageStore, store}, session_namespace: "oversized")

    assert {:error, :session_store_unavailable} =
             Server.active_session_ids(invalid, limit: 1)

    no_progress =
      start_server(session_store: {InvalidPageStore, store}, session_namespace: "no-progress")

    assert {:error, :session_store_unavailable} =
             Server.active_session_ids(no_progress, cursor: "same", limit: 1)
  end

  defp start_server(opts) do
    start_supervised!(%{
      id: make_ref(),
      start: {Server, :start_link, [opts]}
    })
  end
end
