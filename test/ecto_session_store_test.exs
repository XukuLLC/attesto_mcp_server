defmodule AttestoMCP.Server.SessionStore.EctoTestRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :attesto_mcp_server_ecto_test,
    adapter: Ecto.Adapters.Postgres
end

defmodule AttestoMCP.Server.SessionStore.EctoTestDirectRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :attesto_mcp_server_ecto_test_direct,
    adapter: Ecto.Adapters.Postgres
end

defmodule AttestoMCP.Server.SessionStore.EctoInvalidTransactionRepo do
  @moduledoc false

  def transaction(_fun), do: :ok
  def one(_query, _opts), do: nil
  def all(_query, _opts), do: []
  def insert(_changeset, _opts), do: {:error, :unsupported}
  def update(_changeset, _opts), do: {:error, :unsupported}
  def delete_all(_query, _opts), do: {0, nil}
  def __adapter__, do: Ecto.Adapters.Postgres
end

defmodule AttestoMCP.Server.SessionStore.EctoReplacingLoadStore do
  @moduledoc false
  @behaviour AttestoMCP.Server.SessionStore

  alias AttestoMCP.Server.SessionStore.Ecto, as: Store

  def save({store, _replacement}, key, record), do: Store.save(store, key, record)

  def load({store, replacement}, key) do
    result = Store.load(store, key)
    if match?({:ok, _record}, result), do: :ok = Store.save(store, key, replacement)
    result
  end

  def delete({store, _replacement}, key), do: Store.delete(store, key)
  def list_active({store, _replacement}), do: Store.list_active(store)
  def count_active({store, _replacement}), do: Store.count_active(store)
  def update_ttl({store, _replacement}, key, now), do: Store.update_ttl(store, key, now)
  def update({store, _replacement}, key, fun), do: Store.update(store, key, fun)
  def cleanup_expired({store, _replacement}), do: Store.cleanup_expired(store)
end

defmodule AttestoMCP.Server.SessionStore.EctoTestMigration do
  @moduledoc false

  use Ecto.Migration

  def change do
    create table(:attesto_mcp_sessions, primary_key: false) do
      add(:namespace, :string, size: 256, primary_key: true, null: false)
      add(:session_id, :string, size: 256, primary_key: true, null: false)
      add(:record, :map, null: false)
      add(:created_at_ms, :bigint, null: false)
      add(:last_seen_ms, :bigint, null: false)
      add(:absolute_timeout_ms, :bigint, null: false)
      add(:idle_timeout_ms, :bigint, null: false)
      add(:expires_at_ms, :bigint, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:attesto_mcp_sessions, [:namespace, :expires_at_ms, :session_id]))
  end
end

defmodule AttestoMCP.Server.SessionStore.EctoTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias AttestoMCP.Server
  alias AttestoMCP.Server.SessionStore.Ecto, as: Store
  alias AttestoMCP.Server.SessionStore.EctoTestDirectRepo
  alias AttestoMCP.Server.SessionStore.EctoTestMigration
  alias AttestoMCP.Server.SessionStore.EctoTestRepo, as: Repo
  alias Ecto.Adapters.SQL.Sandbox
  alias Mix.Tasks.AttestoMcpServer.Gen.Migration

  import Ecto.Query, only: [from: 2]

  @ecto_included? Enum.any?(
                    Keyword.get(ExUnit.configuration(), :include, []),
                    &(&1 == :ecto or match?({:ecto, _}, &1))
                  )

  if @ecto_included? do
    @moduletag :ecto
  else
    @moduletag skip: "Ecto session-store tests require --include ecto and Postgres"
  end

  setup_all do
    Application.put_env(:attesto_mcp_server_ecto_test, Repo,
      username: System.get_env("POSTGRES_USER", "postgres"),
      password: System.get_env("POSTGRES_PASSWORD", "postgres"),
      hostname: System.get_env("POSTGRES_HOST", "localhost"),
      database: System.get_env("POSTGRES_DB", "attesto_mcp_server_test"),
      pool: Sandbox,
      pool_size: 10
    )

    Application.put_env(:attesto_mcp_server_ecto_test_direct, EctoTestDirectRepo,
      username: System.get_env("POSTGRES_USER", "postgres"),
      password: System.get_env("POSTGRES_PASSWORD", "postgres"),
      hostname: System.get_env("POSTGRES_HOST", "localhost"),
      database: System.get_env("POSTGRES_DB", "attesto_mcp_server_test"),
      pool_size: 10
    )

    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    _ = Repo.__adapter__().storage_up(Repo.config())

    case Repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    case EctoTestDirectRepo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    Ecto.Migrator.run(Repo, [{0, EctoTestMigration}], :up, all: true, log: false)
    Sandbox.mode(Repo, :manual)

    on_exit(fn ->
      stop_repo(EctoTestDirectRepo)
      stop_repo(Repo)
      Application.delete_env(:attesto_mcp_server_ecto_test, Repo)
      Application.delete_env(:attesto_mcp_server_ecto_test_direct, EctoTestDirectRepo)
    end)

    :ok
  end

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})
    {:ok, store} = Store.new(repo: Repo, namespace: "default")

    on_exit(fn -> Sandbox.checkin(Repo) end)
    {:ok, store: store}
  end

  test "persists records with namespace/session composite isolation" do
    record = record()
    key_a = {"server-a", "same-session"}
    key_b = {"server-b", "same-session"}

    {:ok, store_a} = Store.new(repo: Repo, namespace: "server-a")
    {:ok, store_b} = Store.new(repo: Repo, namespace: "server-b")

    assert :ok = Store.save(store_a, key_a, Map.put(record, "owner", "a"))
    assert :ok = Store.save(store_b, key_b, Map.put(record, "owner", "b"))
    assert {:ok, %{"owner" => "a"}} = Store.load(store_a, key_a)
    assert {:ok, %{"owner" => "b"}} = Store.load(store_b, key_b)

    assert {:error, :namespace_mismatch} = Store.load(store_a, key_b)
    assert {:error, :namespace_mismatch} = Store.delete(store_b, key_a)
  end

  test "round-trips unknown JSON fields", %{store: store} do
    key = {"default", unique_id()}

    record =
      record()
      |> Map.put("future_field", %{"nested" => [1, true, nil, "value"]})

    assert :ok = Store.save(store, key, record)
    assert {:ok, ^record} = Store.load(store, key)
  end

  test "future-version rows survive every Ecto read, update, and expiry path", %{store: store} do
    active_key = {"default", unique_id()}
    expired_key = {"default", unique_id()}
    active = Map.put(record(%{"id" => elem(active_key, 1)}), "format_version", 99)

    expired =
      record(%{"id" => elem(expired_key, 1), "created_at_ms" => 1, "last_seen_ms" => 1})
      |> Map.put("format_version", 99)

    assert :ok = Store.save(store, active_key, active)
    assert :ok = Store.save(store, expired_key, expired)

    assert {:ok, ^active} = Store.load(store, active_key)
    assert {:ok, ^active} = Store.update(store, active_key, fn current -> {:ok, current} end)
    assert {:ok, ^active} = Store.load(store, active_key)

    assert {:ok, ^active} =
             Store.update_ttl(store, active_key, System.system_time(:millisecond))

    assert {:ok, ^active} = Store.load(store, active_key)

    assert {:ok, [{^active_key, ^active}]} = Store.list_active(store)
    assert {:ok, []} = Store.cleanup_expired(store)
    assert {:ok, ^active} = Store.load(store, active_key)
    assert {:ok, ^expired} = Store.load(store, expired_key)
  end

  test "only integer future versions bypass Ecto corruption cleanup", %{store: store} do
    invalid_values = [nil, "1", true, 1.0, 0, -1, 1]

    invalid_keys =
      Enum.map(invalid_values, fn version ->
        key = {"default", unique_id()}

        record(%{"id" => elem(key, 1), "created_at_ms" => 1, "last_seen_ms" => 1})
        |> then(fn record ->
          if is_nil(version),
            do: Map.put(record, "format_version", nil),
            else: Map.put(record, "format_version", version)
        end)
        |> then(fn record ->
          assert :ok = Store.save(store, key, record)
          key
        end)
      end)

    missing_key = {"default", unique_id()}
    missing = record(%{"id" => elem(missing_key, 1), "created_at_ms" => 1, "last_seen_ms" => 1})
    assert :ok = Store.save(store, missing_key, Map.delete(missing, "format_version"))

    future_key = {"default", unique_id()}

    future =
      Map.put(
        record(%{"id" => elem(future_key, 1), "created_at_ms" => 1, "last_seen_ms" => 1}),
        "format_version",
        2
      )

    assert :ok = Store.save(store, future_key, future)

    assert {:ok, cleaned} = Store.cleanup_expired(store)
    assert MapSet.new(cleaned) == MapSet.new(invalid_keys ++ [missing_key])
    assert :not_found = Store.load(store, hd(invalid_keys))
    assert {:ok, ^future} = Store.load(store, future_key)
  end

  test "invalid version markers are removed by locked Ecto updates", %{store: store} do
    for version <- [nil, "1", true, 1.0, 0, -1] do
      key = {"default", unique_id()}

      invalid =
        record(%{"id" => elem(key, 1), "created_at_ms" => 1, "last_seen_ms" => 1})
        |> Map.put("format_version", version)

      assert :ok = Store.save(store, key, invalid)
      assert :not_found = Store.update_ttl(store, key, System.system_time(:millisecond))
      assert :not_found = Store.load(store, key)

      key = {"default", unique_id()}
      invalid = Map.put(invalid, "id", elem(key, 1))
      assert :ok = Store.save(store, key, invalid)
      assert :not_found = Store.update(store, key, fn current -> {:ok, current} end)
      assert :not_found = Store.load(store, key)
    end
  end

  test "direct load and active listing discard invalid version markers under lock", %{
    store: store
  } do
    direct_load_key = {"default", unique_id()}

    direct_load_record =
      record(%{"id" => elem(direct_load_key, 1)})
      |> Map.put("format_version", 0)

    assert :ok = Store.save(store, direct_load_key, direct_load_record)
    assert :not_found = Store.load(store, direct_load_key)

    assert nil ==
             Repo.one(
               from(s in Store.Session,
                 where: s.namespace == "default" and s.session_id == ^elem(direct_load_key, 1)
               )
             )

    listed_key = {"default", unique_id()}

    listed_record =
      record(%{"id" => elem(listed_key, 1)})
      |> Map.put("format_version", "1")

    assert :ok = Store.save(store, listed_key, listed_record)
    assert {:ok, listed} = Store.list_active(store)
    refute Enum.any?(listed, fn {key, _record} -> key == listed_key end)

    assert nil ==
             Repo.one(
               from(s in Store.Session,
                 where: s.namespace == "default" and s.session_id == ^elem(listed_key, 1)
               )
             )
  end

  test "Ecto accepts only the common positive timeout range", %{store: store} do
    max = AttestoMCP.Server.Session.max_timeout_ms()

    for value <- [0, -1, max + 1, 1.0, "1000"] do
      key = {"default", unique_id()}

      invalid =
        Map.merge(record(%{"id" => elem(key, 1), "created_at_ms" => 0, "last_seen_ms" => 0}), %{
          "absolute_timeout_ms" => value,
          "idle_timeout_ms" => value
        })

      assert {:error, :invalid_record} = Store.save(store, key, invalid)
    end

    key = {"default", unique_id()}

    valid =
      Map.merge(record(%{"id" => elem(key, 1), "created_at_ms" => 0, "last_seen_ms" => 0}), %{
        "absolute_timeout_ms" => max,
        "idle_timeout_ms" => max
      })

    assert :ok = Store.save(store, key, valid)
    assert {:ok, ^valid} = Store.load(store, key)
  end

  test "corrupt-load locked recheck preserves a future-version replacement" do
    {:ok, direct_store} =
      Store.new(repo: EctoTestDirectRepo, namespace: "corrupt-load-race-#{unique_id()}")

    key = {direct_store.namespace, unique_id()}
    {namespace, session_id} = key
    saved = record(%{"id" => elem(key, 1)})
    future = Map.put(saved, "format_version", 99)

    future_expires_at =
      min(
        future["created_at_ms"] + future["absolute_timeout_ms"],
        future["last_seen_ms"] + future["idle_timeout_ms"]
      )

    assert :ok = Store.save(direct_store, key, saved)

    EctoTestDirectRepo.query!(
      "UPDATE attesto_mcp_sessions SET expires_at_ms = expires_at_ms + 1 " <>
        "WHERE namespace = $1 AND session_id = $2",
      Tuple.to_list(key),
      log: false,
      telemetry_event: nil
    )

    parent = self()

    blocker =
      Task.async(fn ->
        EctoTestDirectRepo.transaction(
          fn ->
            EctoTestDirectRepo.one!(
              from(s in Store.Session,
                where: s.namespace == ^namespace and s.session_id == ^session_id,
                lock: "FOR UPDATE"
              ),
              log: false,
              telemetry_event: nil
            )

            send(parent, {:corrupt_row_locked, self()})

            receive do
              :replace ->
                assert {1, nil} =
                         EctoTestDirectRepo.update_all(
                           from(s in Store.Session,
                             where: s.namespace == ^namespace and s.session_id == ^session_id,
                             update: [
                               set: [
                                 record: ^future,
                                 created_at_ms: ^future["created_at_ms"],
                                 last_seen_ms: ^future["last_seen_ms"],
                                 absolute_timeout_ms: ^future["absolute_timeout_ms"],
                                 idle_timeout_ms: ^future["idle_timeout_ms"],
                                 expires_at_ms: ^future_expires_at
                               ]
                             ]
                           ),
                           [],
                           log: false,
                           telemetry_event: nil
                         )

                send(parent, :future_row_written)

                receive do
                  :release -> :ok
                end
            end
          end,
          log: false,
          telemetry_event: nil
        )
      end)

    blocker_pid = blocker.pid
    assert_receive {:corrupt_row_locked, ^blocker_pid}, 10_000

    loader = Task.async(fn -> Store.load(direct_store, key) end)
    assert wait_for_row_lock(EctoTestDirectRepo)

    send(blocker.pid, :replace)
    assert_receive :future_row_written, 10_000
    send(blocker.pid, :release)

    assert {:ok, ^future} = Task.await(loader, 10_000)
    assert {:ok, :ok} = Task.await(blocker, 10_000)
    assert {:ok, ^future} = Store.load(direct_store, key)
  end

  test "server invalid lookup preserves a valid or future row replaced before discard", %{
    store: store
  } do
    session = AttestoMCP.Server.Session.new("principal", "tenant")
    assert {:ok, record} = AttestoMCP.Server.Session.to_record(session)
    invalid = Map.delete(record, "principal")

    for replacement <- [record, Map.put(record, "format_version", 99)] do
      key = {"default", unique_id()}
      replacement = Map.put(replacement, "id", elem(key, 1))
      assert :ok = Store.save(store, key, invalid)

      {:ok, server} =
        start_supervised(%{
          Server.child_spec(
            session_store: {
              AttestoMCP.Server.SessionStore.EctoReplacingLoadStore,
              {store, replacement}
            },
            session_namespace: "default"
          )
          | id: make_ref()
        })

      assert {:error, :not_found} =
               Server.peek_session(server, elem(key, 1), "principal", "tenant")

      assert {:ok, ^replacement} = Store.load(store, key)
    end
  end

  test "rejects non-JSON records and invalid keys", %{store: store} do
    key = {"default", unique_id()}

    assert {:error, :invalid_record} = Store.save(store, key, Map.put(record(), "pid", self()))
    assert {:error, :invalid_record} = Store.save(store, key, Map.put(record(), "atom", :value))
    assert {:error, :invalid_record} = Store.save(store, key, Map.put(record(), :atom, "value"))
    assert {:error, :invalid_record} = Store.save(store, key, Map.put(record(), "tuple", {1, 2}))

    collision = %{"status" => "string", :status => "atom"}

    assert {:error, :invalid_record} =
             Store.save(store, key, Map.put(record(), "collision", collision))

    assert {:error, :invalid_key} = Store.save(store, {"default", :session}, record())
    assert :not_found = Store.load(store, {"other", ""})
    assert :not_found = Store.update(store, {"default", <<255>>}, fn record -> {:ok, record} end)
    assert :not_found = Store.update_ttl(store, {"default", String.duplicate("x", 257)}, 0)
    assert :ok = Store.delete(store, {"default", String.duplicate("x", 257)})
  end

  test "fails closed when denormalized expiry columns disagree with the JSON record", %{
    store: store
  } do
    load_key = {"default", unique_id()}
    update_key = {"default", unique_id()}
    ttl_key = {"default", unique_id()}

    for key <- [load_key, update_key, ttl_key] do
      assert :ok = Store.save(store, key, record())

      Repo.query!(
        "UPDATE attesto_mcp_sessions SET expires_at_ms = expires_at_ms + 1 " <>
          "WHERE namespace = $1 AND session_id = $2",
        Tuple.to_list(key)
      )
    end

    assert :not_found = Store.load(store, load_key)

    assert {:error, :store_corrupt} =
             Store.update(store, update_key, fn current -> {:ok, current} end)

    assert {:error, :store_corrupt} =
             Store.update_ttl(store, ttl_key, System.system_time(:millisecond))

    assert {:ok, []} = Store.list_active(store)
    assert :not_found = Store.load(store, update_key)
    assert :not_found = Store.load(store, ttl_key)
  end

  test "list and cleanup discard corrupt rows without wedging later work", %{store: store} do
    active_key = {"default", unique_id()}
    expired_key = {"default", unique_id()}
    valid_expired_key = {"default", unique_id()}

    for _ <- 1..8 do
      assert :ok =
               Store.save(
                 store,
                 {"default", unique_id()},
                 record(%{"absolute_timeout_ms" => 60_000, "idle_timeout_ms" => 60_000})
               )
    end

    assert :ok =
             Store.save(
               store,
               active_key,
               record(%{"absolute_timeout_ms" => 120_000, "idle_timeout_ms" => 120_000})
             )

    assert :ok =
             Store.save(
               store,
               expired_key,
               record(%{"created_at_ms" => 1, "last_seen_ms" => 1})
             )

    assert :ok =
             Store.save(
               store,
               valid_expired_key,
               record(%{"created_at_ms" => 1, "last_seen_ms" => 1})
             )

    Repo.query!(
      "UPDATE attesto_mcp_sessions SET expires_at_ms = expires_at_ms + 1 " <>
        "WHERE namespace = $1 AND session_id = $2",
      Tuple.to_list(active_key)
    )

    Repo.query!(
      "UPDATE attesto_mcp_sessions SET absolute_timeout_ms = absolute_timeout_ms + 1 " <>
        "WHERE namespace = $1 AND session_id = $2",
      Tuple.to_list(expired_key)
    )

    event = [:attesto_mcp_server, :session_store, :failure]
    handler = "ecto-corrupt-row-#{System.unique_integer([:positive])}"
    owner = self()

    :ok =
      :telemetry.attach(
        handler,
        event,
        fn event, measurements, metadata, _config ->
          send(owner, {:store_event, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, listed} = Store.list_active(store)
    assert length(listed) == 8
    refute Enum.any?(listed, fn {key, _record} -> key == active_key end)
    refute_receive {:store_event, ^event, _, _}, 50
    assert {:ok, 9} = Store.count_active(store)

    assert :not_found = Store.load(store, active_key)

    assert_receive {:store_event, ^event, %{count: 1}, load_metadata}, 1_000
    assert load_metadata.source == :load
    assert load_metadata.outcome == :corrupt_discarded
    assert {:ok, 8} = Store.count_active(store)

    assert {:ok, expired} = Store.cleanup_expired(store)
    assert MapSet.new(expired) == MapSet.new([expired_key, valid_expired_key])
    refute_receive {:store_event, ^event, _, _}, 50

    assert {:ok, []} = Store.cleanup_expired(store)
    assert :not_found = Store.load(store, active_key)
    assert :not_found = Store.load(store, expired_key)
    assert :not_found = Store.load(store, valid_expired_key)
  end

  test "rejects PostgreSQL JSONB-incompatible NUL bytes in record keys and values", %{
    store: store
  } do
    key = {"default", unique_id()}
    nul = <<0>>

    assert {:error, :invalid_record} =
             Store.save(store, key, Map.put(record(), "bad#{nul}key", "value"))

    assert {:error, :invalid_record} =
             Store.save(store, key, Map.put(record(), "nested", ["ok", "bad#{nul}value"]))

    assert {:error, :invalid_record} =
             Store.save(store, key, Map.put(record(), "nested", %{"bad" => "#{nul}"}))

    atom_key = String.to_atom("bad" <> nul <> "key")

    assert {:error, :invalid_record} =
             Store.save(store, key, Map.put(record(), atom_key, "value"))
  end

  test "update_ttl sets the supplied timestamp and does not revive expiry", %{store: store} do
    key = {"default", unique_id()}
    saved = record(%{"idle_timeout_ms" => 10_000})

    assert :ok = Store.save(store, key, saved)
    now = saved["last_seen_ms"] + 100
    assert {:ok, updated} = Store.update_ttl(store, key, now)
    assert updated["last_seen_ms"] == now
    assert {:ok, ^updated} = Store.load(store, key)

    expired = record(%{"created_at_ms" => 1, "last_seen_ms" => 1})
    assert :ok = Store.save(store, key, expired)
    assert :not_found = Store.update_ttl(store, key, System.system_time(:millisecond))
    assert :not_found = Store.load(store, key)
  end

  test "update_ttl never rewinds a newer activity timestamp", %{store: store} do
    key = {"default", unique_id()}
    saved = record(%{"idle_timeout_ms" => 10_000})
    assert :ok = Store.save(store, key, saved)

    newer = saved["last_seen_ms"] + 1_000
    stale = newer - 500

    assert {:ok, %{"last_seen_ms" => ^newer}} = Store.update_ttl(store, key, newer)
    assert {:ok, %{"last_seen_ms" => ^newer}} = Store.update_ttl(store, key, stale)
    assert {:ok, %{"last_seen_ms" => ^newer}} = Store.load(store, key)
  end

  test "keeps a record active at its exact deadline and expires it after", %{store: store} do
    key = {"default", unique_id()}
    now = System.system_time(:millisecond)
    deadline = now + 1_000

    saved =
      record(%{
        "created_at_ms" => now,
        "last_seen_ms" => now,
        "absolute_timeout_ms" => 1_000,
        "idle_timeout_ms" => 1_000
      })

    assert :ok = Store.save(store, key, saved)
    assert {:ok, at_deadline} = Store.update_ttl(store, key, deadline)
    assert at_deadline["last_seen_ms"] == deadline
    assert {:ok, ^at_deadline} = Store.load(store, key)

    assert :not_found = Store.update_ttl(store, key, deadline + 1)
    assert :not_found = Store.load(store, key)
  end

  test "update_ttl rechecks expiry after waiting for the row lock" do
    {:ok, direct_store} =
      Store.new(repo: EctoTestDirectRepo, namespace: "ttl-lock-#{unique_id()}")

    key = {direct_store.namespace, unique_id()}
    now = System.system_time(:millisecond)

    assert :ok =
             Store.save(
               direct_store,
               key,
               record(%{
                 "created_at_ms" => now,
                 "last_seen_ms" => now,
                 "absolute_timeout_ms" => 100,
                 "idle_timeout_ms" => 100
               })
             )

    parent = self()
    blocker = lock_row(EctoTestDirectRepo, key, parent)
    blocker_pid = blocker.pid
    assert_receive {:row_locked, ^blocker_pid}, 10_000

    refresh =
      Task.async(fn ->
        send(parent, :refresh_started)
        Store.update_ttl(direct_store, key, now)
      end)

    assert_receive :refresh_started, 10_000
    refute_receive {:task_finished, _pid}, 150
    send(blocker.pid, :release)

    assert :not_found = Task.await(refresh, 10_000)
    assert {:ok, :ok} = Task.await(blocker, 10_000)
    assert :not_found = Store.load(direct_store, key)
  end

  test "a row-lock waiter cannot rewind a newer committed TTL touch" do
    {:ok, direct_store} =
      Store.new(repo: EctoTestDirectRepo, namespace: "ttl-monotonic-#{unique_id()}")

    key = {direct_store.namespace, unique_id()}
    {namespace, session_id} = key
    saved = record(%{"id" => elem(key, 1), "idle_timeout_ms" => 10_000})
    assert :ok = Store.save(direct_store, key, saved)

    newer = saved["last_seen_ms"] + 1_000
    stale = newer - 500
    newer_record = Map.put(saved, "last_seen_ms", newer)
    newer_expiry = min(saved["created_at_ms"] + saved["absolute_timeout_ms"], newer + 10_000)
    parent = self()

    blocker =
      Task.async(fn ->
        EctoTestDirectRepo.transaction(
          fn ->
            EctoTestDirectRepo.one!(
              from(s in Store.Session,
                where: s.namespace == ^namespace and s.session_id == ^session_id,
                lock: "FOR UPDATE"
              ),
              log: false,
              telemetry_event: nil
            )

            send(parent, {:row_locked, self()})

            receive do
              :write_newer ->
                assert {1, nil} =
                         EctoTestDirectRepo.update_all(
                           from(s in Store.Session,
                             where: s.namespace == ^namespace and s.session_id == ^session_id,
                             update: [
                               set: [
                                 record: ^newer_record,
                                 last_seen_ms: ^newer,
                                 expires_at_ms: ^newer_expiry
                               ]
                             ]
                           ),
                           [],
                           log: false,
                           telemetry_event: nil
                         )

                send(parent, :newer_written)

                receive do
                  :release -> :ok
                end
            end
          end,
          log: false,
          telemetry_event: nil
        )
      end)

    blocker_pid = blocker.pid
    assert_receive {:row_locked, ^blocker_pid}, 10_000

    stale_refresh =
      Task.async(fn ->
        send(parent, :stale_refresh_started)
        result = Store.update_ttl(direct_store, key, stale)
        send(parent, {:stale_refresh_done, result})
        result
      end)

    assert_receive :stale_refresh_started, 10_000
    refute_receive {:stale_refresh_done, _result}, 150

    send(blocker.pid, :write_newer)
    assert_receive :newer_written, 10_000
    refute_receive {:stale_refresh_done, _result}, 150

    send(blocker.pid, :release)
    assert {:ok, %{"last_seen_ms" => ^newer}} = Task.await(stale_refresh, 10_000)
    assert {:ok, :ok} = Task.await(blocker, 10_000)
    assert {:ok, %{"last_seen_ms" => ^newer}} = Store.load(direct_store, key)
  end

  test "update rechecks expiry after waiting for the row lock" do
    {:ok, direct_store} =
      Store.new(repo: EctoTestDirectRepo, namespace: "update-lock-#{unique_id()}")

    key = {direct_store.namespace, unique_id()}
    now = System.system_time(:millisecond)

    assert :ok =
             Store.save(
               direct_store,
               key,
               record(%{
                 "created_at_ms" => now,
                 "last_seen_ms" => now,
                 "absolute_timeout_ms" => 100,
                 "idle_timeout_ms" => 100
               })
             )

    parent = self()
    blocker = lock_row(EctoTestDirectRepo, key, parent)
    blocker_pid = blocker.pid
    assert_receive {:row_locked, ^blocker_pid}, 10_000

    update =
      Task.async(fn ->
        send(parent, :update_started)

        result =
          Store.update(direct_store, key, fn current ->
            send(parent, :update_callback_called)
            {:ok, Map.put(current, "updated", true)}
          end)

        send(parent, {:task_finished, self()})
        result
      end)

    assert_receive :update_started, 10_000
    refute_receive {:task_finished, _pid}, 150
    send(blocker.pid, :release)

    assert :not_found = Task.await(update, 10_000)
    assert {:ok, :ok} = Task.await(blocker, 10_000)
    refute_received :update_callback_called
    assert :not_found = Store.load(direct_store, key)
  end

  test "row-lock waits fail closed before the server call budget is exhausted" do
    {:ok, direct_store} =
      Store.new(repo: EctoTestDirectRepo, namespace: "lock-timeout-#{unique_id()}")

    key = {direct_store.namespace, unique_id()}
    assert :ok = Store.save(direct_store, key, record())

    parent = self()
    blocker = lock_row(EctoTestDirectRepo, key, parent)
    blocker_pid = blocker.pid
    assert_receive {:row_locked, ^blocker_pid}, 10_000

    started = System.monotonic_time(:millisecond)

    assert {:error, :store_unavailable} =
             Store.update(direct_store, key, fn current -> {:ok, current} end)

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < 2_500

    send(blocker.pid, :release)
    assert {:ok, :ok} = Task.await(blocker, 10_000)
    assert {:ok, _record} = Store.load(direct_store, key)
    assert :ok = Store.delete(direct_store, key)
  end

  test "nested adapter transactions fail closed without changing the caller timeout" do
    namespace = "nested-transaction-#{unique_id()}"
    {:ok, direct_store} = Store.new(repo: EctoTestDirectRepo, namespace: namespace)
    key = {namespace, unique_id()}
    nested_record = record(%{"id" => elem(key, 1)})

    assert {:ok, :committed} =
             EctoTestDirectRepo.transaction(
               fn ->
                 EctoTestDirectRepo.query!("SET LOCAL lock_timeout = '321ms'", [],
                   log: false,
                   telemetry_event: nil
                 )

                 assert %{rows: [["321ms"]]} =
                          EctoTestDirectRepo.query!("SHOW lock_timeout", [],
                            log: false,
                            telemetry_event: nil
                          )

                 assert {:error, :nested_transaction_unsupported} =
                          Store.update(direct_store, key, fn current -> {:ok, current} end)

                 assert %{rows: [["321ms"]]} =
                          EctoTestDirectRepo.query!("SHOW lock_timeout", [],
                            log: false,
                            telemetry_event: nil
                          )

                 EctoTestDirectRepo.query!(
                   "INSERT INTO attesto_mcp_sessions " <>
                     "(namespace, session_id, record, created_at_ms, last_seen_ms, " <>
                     "absolute_timeout_ms, idle_timeout_ms, expires_at_ms, inserted_at, updated_at) " <>
                     "VALUES ($1, $2, $3::jsonb, $4, $5, $6, $7, $8, NOW(), NOW())",
                   [
                     namespace,
                     elem(key, 1),
                     nested_record,
                     nested_record["created_at_ms"],
                     nested_record["last_seen_ms"],
                     nested_record["absolute_timeout_ms"],
                     nested_record["idle_timeout_ms"],
                     min(
                       nested_record["created_at_ms"] + nested_record["absolute_timeout_ms"],
                       nested_record["last_seen_ms"] + nested_record["idle_timeout_ms"]
                     )
                   ],
                   log: false,
                   telemetry_event: nil
                 )

                 :committed
               end,
               log: false,
               telemetry_event: nil
             )

    assert {:ok, ^nested_record} = Store.load(direct_store, key)
  end

  test "update is atomic under concurrent read-modify-write callbacks" do
    {:ok, direct_store} =
      Store.new(
        repo: EctoTestDirectRepo,
        namespace: "concurrency-#{unique_id()}"
      )

    key = {direct_store.namespace, unique_id()}
    assert :ok = Store.save(direct_store, key, record(%{"count" => 0}))
    parent = self()

    tasks =
      for _ <- 1..8 do
        Task.async(fn ->
          pid = backend_pid(EctoTestDirectRepo)
          send(parent, {:backend_pid, self(), pid})

          receive do
            :go -> :ok
          end

          Store.update(direct_store, key, fn current ->
            {:ok, Map.update!(current, "count", &(&1 + 1))}
          end)
        end)
      end

    pids =
      for _ <- tasks do
        assert_receive {:backend_pid, _task, pid}, 10_000
        pid
      end

    assert length(Enum.uniq(pids)) > 1
    Enum.each(tasks, &send(&1.pid, :go))

    results = Task.await_many(tasks, 10_000)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert {:ok, %{"count" => 8}} = Store.load(direct_store, key)
    assert :ok = Store.delete(direct_store, key)
  end

  test "concurrent cleanup calls claim disjoint batches on independent connections" do
    {:ok, direct_store} =
      Store.new(repo: EctoTestDirectRepo, namespace: "cleanup-race-#{unique_id()}")

    keys = for _ <- 1..20, do: {direct_store.namespace, unique_id()}
    expired = record(%{"created_at_ms" => 1, "last_seen_ms" => 1})

    Enum.each(keys, fn key ->
      assert :ok = Store.save(direct_store, key, expired)
    end)

    {results, pids} =
      run_independent_pair([
        {:cleanup_a, fn -> Store.cleanup_expired(direct_store) end},
        {:cleanup_b, fn -> Store.cleanup_expired(direct_store) end}
      ])

    assert length(Enum.uniq(pids)) == 2
    assert {:ok, keys_a} = results.cleanup_a
    assert {:ok, keys_b} = results.cleanup_b
    assert MapSet.disjoint?(MapSet.new(keys_a), MapSet.new(keys_b))
    assert MapSet.size(MapSet.new(keys_a ++ keys_b)) == length(keys)
  end

  test "cleanup and update cannot race an expired row back into existence" do
    {:ok, direct_store} =
      Store.new(repo: EctoTestDirectRepo, namespace: "cleanup-update-#{unique_id()}")

    key = {direct_store.namespace, unique_id()}

    assert :ok =
             Store.save(direct_store, key, record(%{"created_at_ms" => 1, "last_seen_ms" => 1}))

    {results, pids} =
      run_independent_pair([
        {:cleanup, fn -> Store.cleanup_expired(direct_store) end},
        {:update, fn -> Store.update(direct_store, key, fn current -> {:ok, current} end) end}
      ])

    assert length(Enum.uniq(pids)) == 2
    assert results.cleanup in [{:ok, [key]}, {:ok, []}]
    assert results.update == :not_found
    assert :not_found = Store.load(direct_store, key)
  end

  test "cleanup and ttl refresh cannot race an expired row back into existence" do
    {:ok, direct_store} =
      Store.new(repo: EctoTestDirectRepo, namespace: "cleanup-ttl-#{unique_id()}")

    key = {direct_store.namespace, unique_id()}

    assert :ok =
             Store.save(direct_store, key, record(%{"created_at_ms" => 1, "last_seen_ms" => 1}))

    {results, pids} =
      run_independent_pair([
        {:cleanup, fn -> Store.cleanup_expired(direct_store) end},
        {:refresh,
         fn -> Store.update_ttl(direct_store, key, System.system_time(:millisecond)) end}
      ])

    assert length(Enum.uniq(pids)) == 2
    assert results.cleanup in [{:ok, [key]}, {:ok, []}]
    assert results.refresh == :not_found
    assert :not_found = Store.load(direct_store, key)
  end

  test "ttl refresh and ordinary update serialize without losing either change" do
    {:ok, direct_store} =
      Store.new(repo: EctoTestDirectRepo, namespace: "ttl-update-#{unique_id()}")

    key = {direct_store.namespace, unique_id()}
    saved = record(%{"count" => 0})
    assert :ok = Store.save(direct_store, key, saved)
    refresh_time = saved["last_seen_ms"] + 10

    {results, pids} =
      run_independent_pair([
        {:refresh, fn -> Store.update_ttl(direct_store, key, refresh_time) end},
        {:update,
         fn ->
           Store.update(direct_store, key, fn current ->
             {:ok, Map.update!(current, "count", &(&1 + 1))}
           end)
         end}
      ])

    assert length(Enum.uniq(pids)) == 2
    assert {:ok, _} = results.refresh
    assert {:ok, _} = results.update

    assert {:ok, %{"count" => 1, "last_seen_ms" => ^refresh_time}} =
             Store.load(direct_store, key)
  end

  test "update callback errors and deletion are transactional", %{store: store} do
    key = {"default", unique_id()}
    assert :ok = Store.save(store, key, record())
    assert {:error, :nope} = Store.update(store, key, fn _ -> {:error, :nope} end)
    assert {:ok, _} = Store.load(store, key)
    assert :not_found = Store.update(store, key, fn _ -> :delete end)
    assert :not_found = Store.load(store, key)
  end

  test "a server session survives a process restart with binding and negotiated state", %{
    store: _store
  } do
    namespace = "restart-#{unique_id()}"
    {:ok, restart_store} = Store.new(repo: Repo, namespace: namespace)
    opts = [session_store: {Store, restart_store}, session_namespace: namespace]

    {:ok, first} = Server.start_link(opts)
    assert {:ok, session} = Server.new_session(first, %{"sub" => "alice"}, "tenant-a")
    assert Server.stats(first).sessions == 1

    assert :ok =
             Server.negotiate_session(
               first,
               session.id,
               %{"sub" => "alice"},
               "tenant-a",
               "2025-11-25",
               %{"sampling" => %{}}
             )

    assert :ok = Server.mark_initialized(first, session.id)
    assert :ok = GenServer.stop(first)

    {:ok, second} = Server.start_link(opts)
    assert Server.stats(second).sessions == 1

    on_exit(fn ->
      if Process.alive?(second) do
        try do
          GenServer.stop(second)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    assert {:ok, restored} =
             Server.get_session(second, session.id, %{"sub" => "alice"}, "tenant-a")

    assert restored.id == session.id
    assert restored.principal == %{"sub" => "alice"}
    assert restored.tenant == "tenant-a"
    assert restored.version == "2025-11-25"
    assert restored.initialized
    assert restored.client_capabilities == %{"sampling" => %{}}

    assert {:error, :not_found} =
             Server.get_session(second, session.id, %{"sub" => "mallory"}, "tenant-a")

    assert {:error, :not_found} =
             Server.get_session(second, session.id, %{"sub" => "alice"}, "tenant-b")
  end

  test "list and cleanup return bounded, active/expired records", %{store: store} do
    live = {"default", unique_id()}
    assert :ok = Store.save(store, live, record())

    for _ <- 1..1_001 do
      assert :ok =
               Store.save(
                 store,
                 {"default", unique_id()},
                 record(%{"created_at_ms" => 1, "last_seen_ms" => 1})
               )
    end

    assert {:ok, active} = Store.list_active(store)
    assert Enum.any?(active, fn {key, _record} -> key == live end)
    assert length(active) <= 8
    assert {:ok, 1} = Store.count_active(store)

    assert {:ok, expired} = Store.cleanup_expired(store)
    assert length(expired) <= 1_000
    assert {:ok, _remaining} = Store.cleanup_expired(store)
  end

  test "record-bearing listings retain a small aggregate memory bound", %{store: store} do
    payload = String.duplicate("x", 800_000)

    for _ <- 1..9 do
      assert :ok = Store.save(store, {"default", unique_id()}, record(%{"payload" => payload}))
    end

    assert {:ok, 9} = Store.count_active(store)
    assert {:ok, listed} = Store.list_active(store)
    assert length(listed) == 8
    assert Enum.all?(listed, fn {_key, stored} -> stored["payload"] == payload end)
  end

  test "list and cleanup stay within the store namespace", %{store: _store} do
    {:ok, store_a} = Store.new(repo: Repo, namespace: "cleanup-a")
    {:ok, store_b} = Store.new(repo: Repo, namespace: "cleanup-b")
    active_a = {"cleanup-a", unique_id()}
    active_b = {"cleanup-b", unique_id()}
    expired_a = {"cleanup-a", unique_id()}
    expired_b = {"cleanup-b", unique_id()}

    assert :ok = Store.save(store_a, active_a, record())
    assert :ok = Store.save(store_b, active_b, record())

    expired_record = record(%{"created_at_ms" => 1, "last_seen_ms" => 1})
    assert :ok = Store.save(store_a, expired_a, expired_record)
    assert :ok = Store.save(store_b, expired_b, expired_record)

    assert {:ok, active} = Store.list_active(store_a)
    assert Enum.any?(active, fn {key, _record} -> key == active_a end)
    refute Enum.any?(active, fn {key, _record} -> key == active_b end)

    assert {:ok, [^expired_a]} = Store.cleanup_expired(store_a)
    assert {:ok, [^expired_b]} = Store.cleanup_expired(store_b)
  end

  test "schema prefix selects a real prefixed session table", %{store: _store} do
    prefix = "mcp_#{System.unique_integer([:positive])}"
    create_prefixed_table(prefix)

    try do
      assert {:ok, prefixed} =
               Store.new(repo: Repo, namespace: "prefixed", schema_prefix: prefix)

      assert prefixed.schema_prefix == prefix

      key = {"prefixed", unique_id()}
      record = record()
      assert :ok = Store.save(prefixed, key, record)
      assert {:ok, ^record} = Store.load(prefixed, key)
      assert {:ok, [{^key, ^record}]} = Store.list_active(prefixed)
      assert :ok = Store.delete(prefixed, key)
      assert :not_found = Store.load(prefixed, key)

      for invalid <- ["", "Bad", "bad-prefix", "pg_catalog", "information_schema"] do
        assert {:error, :invalid_schema_prefix} =
                 Store.new(repo: Repo, namespace: "prefixed", schema_prefix: invalid)
      end

      assert {:error, :invalid_options} =
               Store.new(repo: Repo, namespace: "prefixed", schema_prefx: prefix)

      assert {:error, :invalid_options} =
               Store.new(
                 repo: Repo,
                 namespace: "prefixed",
                 schema_prefix: prefix,
                 schema_prefix: prefix
               )
    after
      Repo.query!(~s|DROP SCHEMA "#{prefix}" CASCADE|)
    end
  end

  test "requires a valid namespace in the store handle" do
    assert {:error, :invalid_namespace} = Store.new(repo: Repo)
    assert {:error, :invalid_namespace} = Store.new(repo: Repo, namespace: "")
    assert {:error, :invalid_namespace} = Store.new(repo: Repo, namespace: <<0>>)
  end

  test "rejects an Ecto handle whose namespace differs from the server namespace" do
    {:ok, store} = Store.new(repo: Repo, namespace: "store-namespace")

    {_pid, monitor} =
      spawn_monitor(fn ->
        Server.start_link(
          session_store: {Store, store},
          session_namespace: "server-namespace"
        )
      end)

    assert_receive {:DOWN, ^monitor, :process, _pid, {%ArgumentError{} = error, _stack}}, 1_000
    assert Exception.message(error) =~ "valid Ecto handle"

    {_pid, invalid_monitor} =
      spawn_monitor(fn ->
        Server.start_link(
          session_store:
            {Store,
             %{
               repo: AttestoMCP.Server.SessionStore.EctoInvalidTransactionRepo,
               namespace: "default",
               schema_prefix: nil
             }},
          session_namespace: "default"
        )
      end)

    assert_receive {:DOWN, ^invalid_monitor, :process, _pid,
                    {%ArgumentError{} = invalid_error, _stack}},
                   1_000

    assert Exception.message(invalid_error) =~ "valid Ecto handle"
  end

  test "requires the Repo transaction/2 API" do
    assert {:error, :invalid_repo} =
             Store.new(
               repo: AttestoMCP.Server.SessionStore.EctoInvalidTransactionRepo,
               namespace: "default"
             )
  end

  test "the generated prefixed migration applies and backs the runtime adapter" do
    prefix = "generated_#{System.unique_integer([:positive])}"

    migration_path =
      Path.join(
        System.tmp_dir!(),
        "attesto-mcp-generated-migration-#{System.unique_integer([:positive])}"
      )

    version = System.unique_integer([:positive, :monotonic]) + 10_000

    on_exit(fn ->
      EctoTestDirectRepo.query!(~s|DROP SCHEMA IF EXISTS "#{prefix}" CASCADE|, [],
        log: false,
        telemetry_event: nil
      )

      File.rm_rf!(migration_path)
    end)

    Migration.run([
      "--repo",
      inspect(EctoTestDirectRepo),
      "--schema-prefix",
      prefix,
      "--migrations-path",
      migration_path
    ])

    assert [file] =
             Path.wildcard(Path.join(migration_path, "*_create_attesto_mcp_sessions.exs"))

    assert [{migration_module, _bytecode}] = Code.compile_file(file)

    assert :ok =
             Ecto.Migrator.up(EctoTestDirectRepo, version, migration_module, log: false)

    {:ok, generated_store} =
      Store.new(
        repo: EctoTestDirectRepo,
        namespace: "generated",
        schema_prefix: prefix
      )

    key = {"generated", unique_id()}
    saved = record()
    assert :ok = Store.save(generated_store, key, saved)
    assert {:ok, ^saved} = Store.load(generated_store, key)

    assert %{rows: [[index_definition]]} =
             EctoTestDirectRepo.query!(
               "SELECT indexdef FROM pg_indexes " <>
                 "WHERE schemaname = $1 AND tablename = 'attesto_mcp_sessions' " <>
                 "AND indexname LIKE '%namespace_expires_at_ms_session_id_index'",
               [prefix],
               log: false,
               telemetry_event: nil
             )

    assert index_definition =~ "(namespace, expires_at_ms, session_id)"

    assert :ok =
             Ecto.Migrator.down(EctoTestDirectRepo, version, migration_module, log: false)
  end

  defp create_prefixed_table(prefix) do
    Repo.query!(~s|CREATE SCHEMA "#{prefix}"|)

    Repo.query!("""
    CREATE TABLE "#{prefix}"."attesto_mcp_sessions" (
      namespace varchar(256) NOT NULL,
      session_id varchar(256) NOT NULL,
      record jsonb NOT NULL,
      created_at_ms bigint NOT NULL,
      last_seen_ms bigint NOT NULL,
      absolute_timeout_ms bigint NOT NULL,
      idle_timeout_ms bigint NOT NULL,
      expires_at_ms bigint NOT NULL,
      inserted_at timestamp(6) without time zone NOT NULL,
      updated_at timestamp(6) without time zone NOT NULL,
      PRIMARY KEY (namespace, session_id)
    )
    """)

    Repo.query!(
      ~s|CREATE INDEX "#{prefix}_attesto_mcp_sessions_namespace_expires_at_ms_session_id_index" ON "#{prefix}"."attesto_mcp_sessions" (namespace, expires_at_ms, session_id)|
    )
  end

  defp backend_pid(repo) do
    %{rows: [[pid]]} =
      repo.query!("SELECT pg_backend_pid()", [], log: false, telemetry_event: nil)

    pid
  end

  defp wait_for_row_lock(repo, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_for_row_lock_until(repo, deadline)
  end

  defp wait_for_row_lock_until(repo, deadline) do
    %{rows: [[waiting]]} =
      repo.query!(
        "SELECT count(*) FROM pg_stat_activity " <>
          "WHERE wait_event_type = 'Lock' AND query LIKE '%FOR UPDATE%'",
        [],
        log: false,
        telemetry_event: nil
      )

    if waiting > 0 do
      true
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(5)
        wait_for_row_lock_until(repo, deadline)
      else
        flunk("timed out waiting for the corrupt-row cleanup lock")
      end
    end
  end

  defp lock_row(repo, {namespace, session_id}, parent) do
    Task.async(fn ->
      repo.transaction(
        fn ->
          repo.one!(
            from(s in Store.Session,
              where: s.namespace == ^namespace and s.session_id == ^session_id,
              lock: "FOR UPDATE"
            ),
            log: false,
            telemetry_event: nil
          )

          send(parent, {:row_locked, self()})

          receive do
            :release -> :ok
          end
        end,
        log: false,
        telemetry_event: nil
      )
    end)
  end

  defp run_independent_pair(operations) do
    parent = self()

    tasks =
      Enum.map(operations, fn {tag, operation} ->
        Task.async(fn ->
          backend = backend_pid(EctoTestDirectRepo)
          send(parent, {:pair_ready, tag, self(), backend})

          receive do
            :go -> :ok
          end

          result = operation.()
          send(parent, {:pair_done, tag, self(), result})
          result
        end)
      end)

    ready =
      Enum.map(operations, fn {tag, _operation} ->
        receive do
          {:pair_ready, ^tag, pid, backend} -> {tag, pid, backend}
        after
          10_000 -> flunk("timed out waiting for #{tag} connection")
        end
      end)

    send_all(tasks, :go)

    done =
      Enum.map(1..length(operations), fn _index ->
        receive do
          {:pair_done, tag, _pid, result} ->
            {tag, result}
        after
          10_000 -> flunk("timed out waiting for concurrent store operation")
        end
      end)

    _ = Task.await_many(tasks, 10_000)
    {Map.new(done), Enum.map(ready, &elem(&1, 2))}
  end

  defp send_all(tasks, message), do: Enum.each(tasks, &send(&1.pid, message))

  defp stop_repo(repo) do
    case Process.whereis(repo) do
      pid when is_pid(pid) -> Supervisor.stop(pid, :normal)
      nil -> :ok
    end
  end

  defp record(overrides \\ %{}) do
    now = System.system_time(:millisecond)

    Map.merge(
      %{
        "format_version" => 1,
        "id" => unique_id(),
        "principal" => "principal",
        "tenant" => "tenant",
        "protocol_version" => "2025-11-25",
        "initialized" => true,
        "created_at_ms" => now,
        "last_seen_ms" => now,
        "absolute_timeout_ms" => 86_400_000,
        "idle_timeout_ms" => 1_800_000,
        "client_capabilities" => %{},
        "resource_subscriptions" => %{},
        "logging_level" => nil
      },
      overrides
    )
  end

  defp unique_id, do: "session-#{System.unique_integer([:positive])}"
end
