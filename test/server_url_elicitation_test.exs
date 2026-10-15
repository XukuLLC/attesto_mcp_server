defmodule AttestoMCP.Server.ServerUrlElicitationTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server
  alias AttestoMCP.Server.API
  alias AttestoMCP.Server.UrlElicitationStore.ETS

  defmodule FailingStore do
    @moduledoc false
    @behaviour AttestoMCP.Server.UrlElicitationStore

    @impl true
    def put(_store, _record), do: :ok

    @impl true
    def fetch(_store, _ns, _id), do: :not_found

    @impl true
    def consume(_store, _ns, _id, _hash, _now), do: :not_found

    @impl true
    def cleanup_expired(_store, _now), do: {:error, :database_offline}
  end

  defmodule IncompleteStore do
    @moduledoc false
    def put(_store, _record), do: :ok
  end

  def telemetry_handler(event, measurements, metadata, parent) do
    send(parent, {:telemetry_event, event, measurements, metadata})
  end

  test "default store is started automatically and cleans up on server tick" do
    events = [
      [:attesto_mcp_server, :url_elicitation_store, :cleanup, :start],
      [:attesto_mcp_server, :url_elicitation_store, :cleanup, :stop]
    ]

    handler_id = {__MODULE__, :cleanup_telemetry, make_ref()}
    :ok = :telemetry.attach_many(handler_id, events, &__MODULE__.telemetry_handler/4, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, server} = Server.start_link([])

    # Check store configuration
    store_info = Server.url_elicitation_store(server)
    assert store_info.module == ETS
    assert is_pid(store_info.store)
    assert Process.alive?(store_info.store)

    # Stage an item with minimum TTL (1_000 ms)
    context = %{principal_binding: "test-principal"}
    action = "temp_action"
    fields = %{"k" => "v"}

    {:ok, %{id: id}} = API.stage_url_elicitation(server, context, action, fields, ttl_ms: 1_000)

    Process.sleep(1_050)

    # Trigger cleanup tick
    send(server, :cleanup_sessions)

    assert_receive {:telemetry_event,
                    [:attesto_mcp_server, :url_elicitation_store, :cleanup, :start],
                    %{system_time: system_time}, _start_metadata},
                   1_000

    assert is_integer(system_time)

    assert_receive {:telemetry_event,
                    [:attesto_mcp_server, :url_elicitation_store, :cleanup, :stop],
                    %{duration: duration, count: swept_count}, %{outcome: :success}},
                   1_000

    assert is_integer(duration) and duration >= 0
    assert swept_count == 1

    # Verify item was swept and is now not found
    assert {:error, :not_found} =
             API.resolve_url_elicitation(server, id, context.principal_binding)
  end

  test "failure in cleanup emits failure telemetry and server stays alive" do
    handler_id = {__MODULE__, :failure_telemetry, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:attesto_mcp_server, :url_elicitation_store, :failure],
        &__MODULE__.telemetry_handler/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, server} =
      Server.start_link(url_elicitation_store: {FailingStore, :dummy_store})

    send(server, :cleanup_sessions)

    assert_receive {:telemetry_event, [:attesto_mcp_server, :url_elicitation_store, :failure],
                    %{count: 1}, %{source: :cleanup_expired, outcome: :unavailable}},
                   1_000

    assert Process.alive?(server)
    assert %{tool: _} = API.snapshot(server)
  end

  test "rejects invalid url_elicitation_store options at startup" do
    Process.flag(:trap_exit, true)

    for invalid_opts <- [
          [url_elicitation_store: "not_a_tuple"],
          [url_elicitation_store: {:not_a_module, :store}],
          [url_elicitation_store: {IncompleteStore, :store}],
          [url_elicitation_max_entries: 0],
          [url_elicitation_max_entries: "10"],
          [url_elicitation_max_bytes: 0],
          [url_elicitation_max_bytes: "1024"]
        ] do
      assert {:error, {%ArgumentError{}, _}} = Server.start_link(invalid_opts)
    end
  end

  test "built-in store limits fail staging closed while external adapters keep their own limits" do
    {:ok, bounded_server} =
      Server.start_link(url_elicitation_max_entries: 1, url_elicitation_max_bytes: 1_000_000)

    context = %{principal_binding: "bounded-principal"}

    assert {:ok, _staged} =
             API.stage_url_elicitation(bounded_server, context, "first", %{"value" => 1})

    assert {:error, :store_unavailable} =
             API.stage_url_elicitation(bounded_server, context, "second", %{"value" => 2})

    {:ok, external_store} = ETS.start_link(max_entries: 2, max_bytes: 1_000_000)

    {:ok, external_server} =
      Server.start_link(
        url_elicitation_store: {ETS, external_store},
        url_elicitation_max_entries: 1,
        url_elicitation_max_bytes: 1
      )

    assert {:ok, _staged} =
             API.stage_url_elicitation(external_server, context, "first", %{"value" => 1})

    assert {:ok, _staged} =
             API.stage_url_elicitation(external_server, context, "second", %{"value" => 2})
  end

  test "default store rejects duplicate keys, including consumed records" do
    {:ok, store} = ETS.start_link(max_entries: 2, max_bytes: 1_000_000)
    record = record("duplicate", System.system_time(:millisecond) + 60_000)

    assert :ok = ETS.put(store, record)

    assert {:ok, consumed} =
             ETS.consume(
               store,
               record["namespace"],
               record["id"],
               record["subject_hash"],
               System.system_time(:millisecond)
             )

    assert is_integer(consumed["consumed_at_ms"])
    assert {:error, :already_exists} = ETS.put(store, record)
    assert {:ok, persisted} = ETS.fetch(store, record["namespace"], record["id"])
    assert persisted["consumed_at_ms"] == consumed["consumed_at_ms"]
  end

  test "default store enforces entry and byte limits without changing live records" do
    first = record("first-id", System.system_time(:millisecond) + 60_000)
    second = record("other-id", System.system_time(:millisecond) + 60_000)

    {:ok, entry_store} = ETS.start_link(max_entries: 1, max_bytes: 1_000_000)
    assert :ok = ETS.put(entry_store, first)
    assert {:error, :capacity} = ETS.put(entry_store, second)
    assert {:ok, ^first} = ETS.fetch(entry_store, first["namespace"], first["id"])
    assert :not_found = ETS.fetch(entry_store, second["namespace"], second["id"])

    {:ok, byte_store} =
      ETS.start_link(max_entries: 2, max_bytes: :erlang.external_size(first))

    assert :ok = ETS.put(byte_store, first)
    assert {:error, :capacity} = ETS.put(byte_store, second)
    assert {:ok, ^first} = ETS.fetch(byte_store, first["namespace"], first["id"])
    assert :not_found = ETS.fetch(byte_store, second["namespace"], second["id"])
  end

  test "default store removes expired records before reporting capacity" do
    {:ok, store} = ETS.start_link(max_entries: 1, max_bytes: 1_000_000)
    expired = record("expired", 0)
    current = record("current", System.system_time(:millisecond) + 60_000)

    assert :ok = ETS.put(store, expired)
    assert :ok = ETS.put(store, current)
    assert :not_found = ETS.fetch(store, expired["namespace"], expired["id"])
    assert {:ok, ^current} = ETS.fetch(store, current["namespace"], current["id"])
  end

  test "capacity admission reclaims more than one periodic cleanup batch when needed" do
    expired = Enum.map(1..1_001, &record("expired-#{&1}", 0))
    expired_bytes = Enum.sum(Enum.map(expired, &:erlang.external_size/1))
    base = record("replacement", System.system_time(:millisecond) + 600_000)
    base_bytes = :erlang.external_size(base)

    replacement =
      put_in(
        base,
        ["fields", "payload"],
        String.duplicate("x", max(expired_bytes - base_bytes - 64, 1))
      )

    replacement_bytes = :erlang.external_size(replacement)
    smallest_expired = expired |> Enum.map(&:erlang.external_size/1) |> Enum.min()

    assert replacement_bytes <= expired_bytes
    assert replacement_bytes + smallest_expired > expired_bytes

    {:ok, store} = ETS.start_link(max_entries: 1_002, max_bytes: expired_bytes)

    Enum.each(expired, fn record ->
      assert :ok = ETS.put(store, record)
    end)

    assert :ok = ETS.put(store, replacement)
    assert {:ok, ^replacement} = ETS.fetch(store, replacement["namespace"], replacement["id"])
    assert {:ok, []} = ETS.cleanup_expired(store, System.system_time(:millisecond))
  end

  @tag capture_log: true
  test "stops gracefully with :url_elicitation_store_unavailable when monitored store crashes" do
    Process.flag(:trap_exit, true)

    {:ok, store_pid} = ETS.start_link(name: :"ets_worker_#{System.unique_integer([:positive])}")

    {:ok, server} =
      Server.start_link(url_elicitation_store: {ETS, store_pid})

    Process.exit(store_pid, :kill)

    assert_receive {:EXIT, ^server, :url_elicitation_store_unavailable}, 1_000
  end

  defp record(id, expires_at_ms) do
    %{
      "id" => id,
      "namespace" => "test-namespace",
      "subject_hash" => "subject-hash",
      "action" => "approve",
      "fields" => %{"id" => id},
      "created_at_ms" => 0,
      "expires_at_ms" => expires_at_ms,
      "consumed_at_ms" => nil
    }
  end
end
