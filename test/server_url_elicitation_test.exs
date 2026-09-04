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
          [url_elicitation_store: {IncompleteStore, :store}]
        ] do
      assert {:error, {%ArgumentError{}, _}} = Server.start_link(invalid_opts)
    end
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
end
