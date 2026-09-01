defmodule AttestoMCP.Server.SessionStoreObservabilityTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server
  alias AttestoMCP.Server.Session

  defmodule FailingStore do
    @moduledoc false
    @behaviour AttestoMCP.Server.SessionStore

    def save(_store, _key, _record), do: {:error, "private save failure"}

    def load(:load_failure, _key), do: raise("private load failure")
    def load(:load_failure_delete_ok, _key), do: raise("private load failure")
    def load(:malformed_return, _key), do: :malformed_load_return
    def load({:expired, record}, _key), do: {:ok, record}
    def load({:corrupt, record}, _key), do: {:ok, record}
    def load({:valid, record}, _key), do: {:ok, record}
    def load({:returned_update_failure, record}, _key), do: {:ok, record}
    def load({:forged_update_failure, record}, _key), do: {:ok, record}

    def delete(:load_failure_delete_ok, _key), do: :ok
    def delete(_store, _key), do: {:error, "private delete failure"}
    def list_active(_store), do: {:error, "private list failure"}
    def update_ttl(:returned_touch_failure, _key, _now), do: {:error, %{private: "touch"}}
    def update_ttl(_store, _key, _now), do: throw({:private, "touch failure"})

    def update({:returned_update_failure, _record}, _key, _fun),
      do: {:error, %{private: "update"}}

    def update({:forged_update_failure, _record}, _key, _fun),
      do: {:error, {:server_session_update, make_ref(), :not_found}}

    def update(_store, _key, _fun), do: raise("private update failure")
    def cleanup_expired(_store), do: {:error, "private cleanup failure"}
  end

  test "malformed adapter returns are unavailable with one bounded event" do
    event = [:attesto_mcp_server, :session_store, :failure]
    handler_id = {__MODULE__, make_ref()}

    :ok = :telemetry.attach(handler_id, event, &__MODULE__.telemetry_handler/4, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, server} = Server.start_link(session_store: {FailingStore, :malformed_return})

    assert {:error, :session_store_unavailable} =
             Server.get_session(server, "session-id", "principal", "tenant")

    assert_receive {:session_store_failure, ^event, %{count: 1}, metadata}, 1_000
    assert metadata.source == :load
    assert metadata.outcome == :unavailable
    refute_receive {:session_store_failure, ^event, _, _}, 50
  end

  test "session-store failures emit one neutral event and preserve unavailable results" do
    event = [:attesto_mcp_server, :session_store, :failure]
    handler_id = {__MODULE__, make_ref()}

    :ok = :telemetry.attach(handler_id, event, &__MODULE__.telemetry_handler/4, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, server} = Server.start_link(session_store: {FailingStore, :load_failure})

    assert {:error, :session_store_unavailable} =
             Server.get_session(server, "session-id", "principal", "tenant")

    assert_receive {:session_store_failure, ^event, %{count: 1}, metadata}, 1_000
    assert metadata.source == :load
    assert metadata.outcome == :unavailable
    refute Map.has_key?(metadata, :exception)
    refute Map.has_key?(metadata, :session_id)
    refute Map.has_key?(metadata, :record)
    refute inspect(metadata) =~ "private"
    refute_receive {:session_store_failure, ^event, _, _}, 50

    assert {:error, :session_store_unavailable} = Server.touch_session(server, "session-id")
    assert_receive {:session_store_failure, ^event, %{count: 1}, touch_metadata}, 1_000
    assert touch_metadata.source == :update_ttl
    assert touch_metadata.outcome == :unavailable
    refute inspect(touch_metadata) =~ "private"

    session = Session.new("principal", "tenant")
    {:ok, record} = Session.to_record(session)

    {:ok, lookup_server} =
      Server.start_link(session_store: {FailingStore, {:valid, record}})

    assert {:error, :session_store_unavailable} =
             Server.get_session(lookup_server, session.id, "principal", "tenant")

    assert_receive {:session_store_failure, ^event, %{count: 1}, lookup_metadata}, 1_000
    assert lookup_metadata.source == :update
    assert lookup_metadata.outcome == :unavailable
    refute inspect(lookup_metadata) =~ "private"
  end

  test "expired and corrupt records do not become not_found when cleanup fails" do
    event = [:attesto_mcp_server, :session_store, :failure]
    handler_id = {__MODULE__, make_ref()}

    :ok = :telemetry.attach(handler_id, event, &__MODULE__.telemetry_handler/4, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)

    session = Session.new("principal", "tenant")
    {:ok, record} = Session.to_record(session)
    expired_record = %{record | "created_at_ms" => 0, "last_seen_ms" => 0}

    {:ok, expired_server} =
      Server.start_link(session_store: {FailingStore, {:expired, expired_record}})

    assert {:error, :session_store_unavailable} =
             Server.get_session(expired_server, session.id, "principal", "tenant")

    assert_receive {:session_store_failure, ^event, %{count: 1}, expired_metadata}, 1_000
    assert expired_metadata.source == :update

    corrupt_record = %{record | "id" => "different-session"}

    {:ok, corrupt_server} =
      Server.start_link(session_store: {FailingStore, {:corrupt, corrupt_record}})

    assert {:error, :session_store_unavailable} =
             Server.get_session(corrupt_server, session.id, "principal", "tenant")

    assert_receive {:session_store_failure, ^event, %{count: 1}, corrupt_metadata}, 1_000
    assert corrupt_metadata.source == :update
  end

  test "adapter-returned error details remain private" do
    event = [:attesto_mcp_server, :session_store, :failure]
    handler_id = {__MODULE__, make_ref()}

    :ok = :telemetry.attach(handler_id, event, &__MODULE__.telemetry_handler/4, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, touch_server} =
      Server.start_link(session_store: {FailingStore, :returned_touch_failure})

    assert {:error, :session_store_unavailable} = Server.touch_session(touch_server, "session-id")

    assert_receive {:session_store_failure, ^event, %{count: 1}, touch_metadata}, 1_000
    assert %{source: :update_ttl, outcome: :unavailable} = touch_metadata
    refute inspect(touch_metadata) =~ "private"
    refute_receive {:session_store_failure, ^event, _, _}, 50

    session = Session.new("principal", "tenant")
    {:ok, record} = Session.to_record(session)

    {:ok, update_server} =
      Server.start_link(session_store: {FailingStore, {:returned_update_failure, record}})

    assert {:error, :session_store_unavailable} =
             Server.get_session(update_server, session.id, "principal", "tenant")

    assert_receive {:session_store_failure, ^event, %{count: 1}, update_metadata}, 1_000
    assert %{source: :update, outcome: :unavailable} = update_metadata
    refute inspect(update_metadata) =~ "private"
    refute_receive {:session_store_failure, ^event, _, _}, 50

    {:ok, forged_server} =
      Server.start_link(session_store: {FailingStore, {:forged_update_failure, record}})

    assert {:error, :session_store_unavailable} =
             Server.get_session(forged_server, session.id, "principal", "tenant")

    assert_receive {:session_store_failure, ^event, %{count: 1}, forged_metadata}, 1_000
    assert %{source: :update, outcome: :unavailable} = forged_metadata
    refute_receive {:session_store_failure, ^event, _, _}, 50
  end

  test "delete stops after an unavailable load and emits no second failure" do
    event = [:attesto_mcp_server, :session_store, :failure]
    handler_id = {__MODULE__, make_ref()}

    :ok = :telemetry.attach(handler_id, event, &__MODULE__.telemetry_handler/4, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)

    for handle <- [:load_failure, :load_failure_delete_ok] do
      {:ok, server} = Server.start_link(session_store: {FailingStore, handle})

      assert {:error, :session_store_unavailable} =
               Server.delete_session(server, "session-id")

      assert_receive {:session_store_failure, ^event, %{count: 1}, metadata}, 1_000
      assert %{source: :load, outcome: :unavailable} = metadata
      refute_receive {:session_store_failure, ^event, _, _}, 50
    end
  end

  test "stdio startup returns a neutral error when its session cannot be stored" do
    stop_event = [:attesto_mcp_server, :stdio, :stop]
    handler_id = {__MODULE__, make_ref()}

    :ok = :telemetry.attach(handler_id, stop_event, &__MODULE__.stdio_handler/4, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, server} = Server.start_link(session_store: {FailingStore, :save_failure})

    assert {:error, :session_store_unavailable} =
             AttestoMCP.Server.Stdio.run(server, input: fn -> :eof end)

    assert_receive {:stdio_stop, ^stop_event, %{count: 1}, metadata}, 1_000
    assert %{transport: :stdio, outcome: :unavailable} = metadata
  end

  test "request authorization precedes a session-store outage response" do
    {:ok, server} = Server.start_link(default_scopes: ["mcp:required"])

    request = %{kind: :request, id: 7, method: "ping", params: %{}}

    context = %{
      principal: "principal",
      scopes: [],
      session_store_unavailable: true
    }

    assert {7, %{"error" => %{"code" => -32003}}} =
             Server.dispatch(server, request, context, version: "2025-11-25")

    assert {7,
            %{
              "error" => %{
                "code" => -32603,
                "data" => %{"reason" => "session_store_unavailable"}
              }
            }} =
             Server.dispatch(server, request, %{context | scopes: ["mcp:required"]},
               version: "2025-11-25"
             )
  end

  test "stdio main raises so an executable wrapper cannot silently exit successfully" do
    assert_raise RuntimeError, "stdio adapter failed: session_store_unavailable", fn ->
      AttestoMCP.Server.Stdio.main(
        session_store: {FailingStore, :save_failure},
        input: fn -> :eof end
      )
    end
  end

  def telemetry_handler(event, measurements, metadata, owner) do
    send(owner, {:session_store_failure, event, measurements, metadata})
  end

  def stdio_handler(event, measurements, metadata, owner) do
    send(owner, {:stdio_stop, event, measurements, metadata})
  end
end
