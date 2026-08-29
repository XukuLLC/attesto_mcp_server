defmodule AttestoMCP.Server.SessionStoreClusterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AttestoMCP.Server
  alias AttestoMCP.Server.Session
  alias AttestoMCP.Server.SessionStore.ETS
  alias AttestoMCP.Server.Subscriptions

  @legacy "2025-11-25"

  defmodule FailingUpdates do
    @moduledoc false
    @behaviour AttestoMCP.Server.SessionStore

    defdelegate save(store, key, record), to: ETS
    defdelegate load(store, key), to: ETS
    defdelegate list_active(store), to: ETS
    defdelegate cleanup_expired(store), to: ETS

    def delete(_store, _key), do: {:error, :write_failed}
    def update_ttl(_store, _key, _now), do: {:error, :write_failed}
    def update(_store, _key, _fun), do: {:error, :write_failed}
  end

  defmodule ToggleLoads do
    @moduledoc false
    @behaviour AttestoMCP.Server.SessionStore

    def save({store, _gate}, key, record), do: ETS.save(store, key, record)

    def load({store, gate}, key) do
      if Agent.get(gate, & &1), do: {:error, :temporary}, else: ETS.load(store, key)
    end

    def delete({store, _gate}, key), do: ETS.delete(store, key)
    def list_active({store, _gate}), do: ETS.list_active(store)
    def update_ttl({store, _gate}, key, now), do: ETS.update_ttl(store, key, now)
    def update({store, _gate}, key, fun), do: ETS.update(store, key, fun)
    def cleanup_expired({store, _gate}), do: ETS.cleanup_expired(store)
  end

  test "session records round-trip, preserve extensions on update, and fail closed" do
    principal = %{
      "sub" => "alice",
      "profile" => %URI{scheme: "https", host: "example.com", path: "/alice"}
    }

    session =
      Session.new(principal, "tenant-a")
      |> Map.put(:version, @legacy)
      |> Map.put(:initialized, true)
      |> Map.put(:client_capabilities, %{"sampling" => %{}})
      |> Map.put(:resource_subscriptions, %{"urn:item" => true})

    assert {:ok, record} = Session.to_record(session)
    refute Map.has_key?(record, "streams")
    assert {:ok, restored} = Session.from_record(Map.put(record, "future_extension", 42))
    assert restored.id == session.id
    assert restored.principal == session.principal
    assert restored.tenant == session.tenant
    assert restored.streams == %{}

    assert {:error, :unknown_record_version} =
             Session.from_record(Map.put(record, "format_version", 99))

    assert {:error, :invalid_record} = Session.from_record(Map.delete(record, "id"))
    assert {:error, :nonportable_binding} = Session.to_record(%{session | principal: self()})

    compressed_principal =
      %{"sub" => String.duplicate("a", 2_000)}
      |> :erlang.term_to_binary(compressed: 9)
      |> Base.url_encode64(padding: false)

    assert {:error, :invalid_binding} =
             Session.from_record(Map.put(record, "principal", compressed_principal))

    assert {:error, :invalid_record} =
             Session.from_record(
               Map.put(record, "resource_subscriptions", %{"urn:item" => false})
             )

    {:ok, store} = start_supervised(ETS)
    namespace = unique_namespace()

    {:ok, server} =
      start_supervised({Server, session_store: {ETS, store}, session_namespace: namespace})

    assert :ok = ETS.save(store, {namespace, session.id}, Map.put(record, "future_extension", 42))
    assert :ok = Server.touch_session(server, session.id)
    assert {:ok, updated} = ETS.load(store, {namespace, session.id})
    assert updated["future_extension"] == 42
  end

  test "shared store survives a server restart and rejects binding changes" do
    {:ok, store} = start_supervised(ETS)
    namespace = unique_namespace()
    opts = [session_store: {ETS, store}, session_namespace: namespace]

    {:ok, first} = Server.start_link(opts)
    assert {:ok, session} = Server.new_session(first, %{"sub" => "alice"}, "tenant-a")

    assert :ok =
             Server.negotiate_session(
               first,
               session.id,
               %{"sub" => "alice"},
               "tenant-a",
               @legacy,
               %{"sampling" => %{}}
             )

    assert :ok = Server.mark_initialized(first, session.id)
    assert :ok = GenServer.stop(first)

    {:ok, second} = start_supervised(Server.child_spec(opts))

    assert {:ok, restored} =
             Server.get_session(second, session.id, %{"sub" => "alice"}, "tenant-a")

    assert restored.initialized
    assert restored.version == @legacy
    assert restored.client_capabilities == %{"sampling" => %{}}
    assert {:error, :not_found} = Server.get_session(second, session.id, "mallory", "tenant-a")

    assert {:error, :not_found} =
             Server.get_session(second, session.id, %{"sub" => "alice"}, "other")
  end

  test "session refresh and initialization fail closed on backend write failure" do
    {:ok, store} = start_supervised(ETS)

    {:ok, server} =
      start_supervised(
        {Server, session_store: {FailingUpdates, store}, session_namespace: unique_namespace()}
      )

    assert {:ok, session} = Server.new_session(server, "alice", "tenant-a")
    assert {:error, :not_found} = Server.get_session(server, session.id, "alice", "tenant-a")
    assert {:error, :write_failed} = Server.touch_session(server, session.id)
    assert {:error, :write_failed} = Server.mark_initialized(server, session.id)
    assert {:error, :write_failed} = Server.delete_session(server, session.id)
    assert {:ok, _record} = ETS.load(store, {server_namespace(server), session.id})
  end

  test "atomic TTL refresh cannot renew an expired record" do
    {:ok, store} = start_supervised(ETS)
    session = Session.new("alice", "tenant-a")
    assert {:ok, record} = Session.to_record(session)

    expired =
      record
      |> Map.put("created_at_ms", 0)
      |> Map.put("last_seen_ms", 0)
      |> Map.put("absolute_timeout_ms", 1)
      |> Map.put("idle_timeout_ms", 1)

    key = {unique_namespace(), session.id}
    assert :ok = ETS.save(store, key, expired)
    assert {:ok, []} = ETS.list_active(store)
    assert :not_found = ETS.load(store, key)

    assert :ok = ETS.save(store, key, expired)
    assert :not_found = ETS.update_ttl(store, key, 10)
    assert :not_found = ETS.load(store, key)
  end

  test "explicit deletion removes cleanup bookkeeping and permits safe key reuse" do
    {:ok, store} = start_supervised(ETS)
    session = Session.new("alice", "tenant-a")
    assert {:ok, record} = Session.to_record(session)

    for index <- 1..256 do
      key = {"delete-churn", Integer.to_string(index)}
      assert :ok = ETS.save(store, key, Map.put(record, "id", elem(key, 1)))
      assert :ok = ETS.delete(store, key)
    end

    assert %{records: records, cleanup_queue: queue, queued: queued} = :sys.get_state(store)
    assert records == %{}
    assert :queue.len(queue) == 0
    assert MapSet.size(queued) == 0

    key = {"delete-churn", "reused"}
    assert :ok = ETS.save(store, key, Map.put(record, "id", "reused"))
    assert :ok = ETS.delete(store, key)
    assert :ok = ETS.save(store, key, Map.put(record, "id", "reused"))
    assert {:ok, _record} = ETS.load(store, key)
    assert :queue.len(:sys.get_state(store).cleanup_queue) == 1
  end

  test "invalid session bindings are distinct from store outages" do
    {:ok, server} = start_supervised(%{Server.child_spec([]) | id: make_ref()})
    assert {:error, :nonportable_binding} = Server.new_session(server, self(), nil)
    assert Process.alive?(server)
  end

  test "transient store load failures preserve live legacy streams" do
    {:ok, store} = start_supervised(ETS)
    {:ok, gate} = start_supervised({Agent, fn -> false end})

    {:ok, server} =
      start_supervised(
        {Server,
         session_store: {ToggleLoads, {store, gate}}, session_namespace: unique_namespace()}
      )

    assert {:ok, session} = Server.new_session(server, "alice", "tenant-a")
    assert :ok = Server.negotiate_session(server, session.id, "alice", "tenant-a", @legacy, %{})
    assert :ok = Server.mark_initialized(server, session.id)

    assert {:ok, stream} =
             Server.open_legacy_stream(server, session.id, "alice", "tenant-a", self())

    Agent.update(gate, fn _ -> true end)
    assert :ok = Server.publish(server, %{"type" => "toolsListChanged"})
    refute_receive {:mcp_legacy_close, ^stream, _reason}, 50

    Agent.update(gate, fn _ -> false end)
    assert :ok = Server.publish(server, %{"type" => "toolsListChanged"})
    assert_receive {:mcp_legacy_event, ^stream, 1, _event}, 500
  end

  test "updates evict corrupt durable records" do
    {:ok, store} = start_supervised(ETS)
    namespace = unique_namespace()

    {:ok, server} =
      start_supervised({Server, session_store: {ETS, store}, session_namespace: namespace})

    key = {namespace, "corrupt"}

    assert :ok = ETS.save(store, key, %{"format_version" => 999})
    assert :ok = Server.mark_initialized(server, "corrupt")
    assert :not_found = ETS.load(store, key)
  end

  test "unnamed servers use the documented default namespace and preserve missing-session init" do
    {:ok, server} = start_supervised(%{Server.child_spec([]) | id: make_ref()})
    assert :sys.get_state(server).session_namespace == "default"
    assert :ok = Server.mark_initialized(server, "missing-session")
  end

  test "cluster peers share sessions and receive modern, legacy, and catalog events once" do
    {:ok, store} = start_supervised(ETS)
    namespace = unique_namespace()

    opts = [
      session_store: {ETS, store},
      session_namespace: namespace,
      session_clustered: true
    ]

    {:ok, first} = start_supervised(%{Server.child_spec(opts) | id: make_ref()})
    {:ok, second} = start_supervised(%{Server.child_spec(opts) | id: make_ref()})

    assert {:ok, session} = Server.new_session(first, "alice", "tenant-a")
    assert :ok = Server.negotiate_session(first, session.id, "alice", "tenant-a", @legacy, %{})
    assert :ok = Server.mark_initialized(first, session.id)
    assert {:ok, restored} = Server.get_session(second, session.id, "alice", "tenant-a")
    assert restored.initialized

    assert {:ok, legacy_stream} =
             Server.open_legacy_stream(second, session.id, "alice", "tenant-a", self())

    subscriptions = GenServer.call(second, :subscriptions)

    assert {:ok, "modern"} =
             Subscriptions.open(
               subscriptions,
               "alice",
               "tenant-a",
               "modern",
               %{"toolsListChanged" => true},
               self(),
               :peer,
               nil
             )

    assert_receive {:mcp_subscription, :peer, "modern",
                    %{"method" => "notifications/subscriptions/acknowledged"}}

    assert :ok = Server.publish(first, %{"type" => "toolsListChanged"})

    assert_receive {:mcp_subscription, :peer, "modern", modern_event}, 1_000
    assert modern_event["method"] == "notifications/tools/list_changed"

    assert_receive {:mcp_legacy_event, ^legacy_stream, 1, legacy_event}, 1_000
    assert legacy_event["method"] == "notifications/tools/list_changed"
    refute_receive {:mcp_subscription, :peer, "modern", _duplicate}, 50
    refute_receive {:mcp_legacy_event, ^legacy_stream, _, _duplicate}, 50

    Server.ack_subscription(second, "modern", self())
    Server.ack_legacy_stream(second, legacy_stream)

    assert :ok =
             Server.register_tool(first, "clustered", %{
               handler: fn _arguments, _context -> {:ok, "ok"} end
             })

    assert_receive {:mcp_subscription, :peer, "modern", catalog_event}, 1_000
    assert catalog_event["method"] == "notifications/tools/list_changed"
    assert_receive {:mcp_legacy_event, ^legacy_stream, 2, _catalog_event}, 1_000
  end

  test "cluster mode requires an explicit shared adapter and namespace" do
    assert_invalid_start(session_clustered: true)

    {:ok, store} = start_supervised(ETS)
    assert_invalid_start(session_clustered: true, session_store: {ETS, store})
  end

  test "loss of a session store stops the server instead of falling back" do
    {:ok, store} = ETS.start_link([])

    {:ok, server} =
      Server.start_link(
        session_store: {ETS, store},
        session_namespace: unique_namespace()
      )

    Process.unlink(server)
    monitor = Process.monitor(server)

    capture_log(fn ->
      GenServer.stop(store)
      assert_receive {:DOWN, ^monitor, :process, ^server, :session_store_unavailable}, 1_000
    end)
  end

  defp unique_namespace,
    do: "test-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

  defp server_namespace(server) do
    server
    |> Server.options()
    |> Keyword.fetch!(:session_namespace)
  end

  defp assert_invalid_start(opts) do
    {_pid, monitor} = spawn_monitor(fn -> Server.start_link(opts) end)
    assert_receive {:DOWN, ^monitor, :process, _pid, reason}, 1_000
    assert inspect(reason) =~ "requires an explicit shared"
  end
end
