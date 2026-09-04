defmodule AttestoMCP.Server.UrlElicitationStore.EctoTestRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :attesto_mcp_server_url_elicitation_ecto_test,
    adapter: Ecto.Adapters.Postgres
end

defmodule AttestoMCP.Server.UrlElicitationStore.EctoTestDirectRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :attesto_mcp_server_url_elicitation_ecto_test_direct,
    adapter: Ecto.Adapters.Postgres
end

defmodule AttestoMCP.Server.UrlElicitationStore.EctoTestMigration do
  @moduledoc false

  use Ecto.Migration

  def change do
    create_if_not_exists table(:attesto_mcp_url_elicitations, primary_key: false) do
      add(:namespace, :string, size: 256, primary_key: true, null: false)
      add(:id, :string, size: 256, primary_key: true, null: false)
      add(:subject_hash, :string, size: 64, null: false)
      add(:action, :string, size: 256, null: false)
      add(:fields, :map, null: false)
      add(:created_at_ms, :bigint, null: false)
      add(:expires_at_ms, :bigint, null: false)
      add(:consumed_at_ms, :bigint)

      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists(
      index(:attesto_mcp_url_elicitations, [:namespace, :expires_at_ms, :consumed_at_ms])
    )
  end
end

defmodule AttestoMCP.Server.UrlElicitationStore.EctoTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias AttestoMCP.Server.API
  alias AttestoMCP.Server.UrlElicitationStore.Ecto, as: Store
  alias AttestoMCP.Server.UrlElicitationStore.EctoTestDirectRepo, as: DirectRepo
  alias AttestoMCP.Server.UrlElicitationStore.EctoTestMigration
  alias AttestoMCP.Server.UrlElicitationStore.EctoTestRepo, as: Repo
  alias Ecto.Adapters.SQL.Sandbox

  @ecto_included? Enum.any?(
                    Keyword.get(ExUnit.configuration(), :include, []),
                    &(&1 == :ecto or match?({:ecto, _}, &1))
                  )

  if @ecto_included? do
    @moduletag :ecto
  else
    @moduletag skip: "Ecto URL elicitation store tests require --include ecto and Postgres"
  end

  setup_all do
    Application.put_env(:attesto_mcp_server_url_elicitation_ecto_test, Repo,
      username: System.get_env("POSTGRES_USER", "postgres"),
      password: System.get_env("POSTGRES_PASSWORD", "postgres"),
      hostname: System.get_env("POSTGRES_HOST", "localhost"),
      database: System.get_env("POSTGRES_DB", "attesto_mcp_server_test"),
      pool: Sandbox,
      pool_size: 10
    )

    Application.put_env(:attesto_mcp_server_url_elicitation_ecto_test_direct, DirectRepo,
      username: System.get_env("POSTGRES_USER", "postgres"),
      password: System.get_env("POSTGRES_PASSWORD", "postgres"),
      hostname: System.get_env("POSTGRES_HOST", "localhost"),
      database: System.get_env("POSTGRES_DB", "attesto_mcp_server_test"),
      pool_size: 20
    )

    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    _ = Repo.__adapter__().storage_up(Repo.config())

    case Repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    case DirectRepo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Version 1 follows the session store test's migration (version 0) so the
    # shared test database never sees an out-of-order migration.
    Ecto.Migrator.run(Repo, [{1, EctoTestMigration}], :up, all: true, log: false)

    Sandbox.mode(Repo, :manual)

    on_exit(fn ->
      stop_repo(DirectRepo)
      stop_repo(Repo)
      Application.delete_env(:attesto_mcp_server_url_elicitation_ecto_test, Repo)
      Application.delete_env(:attesto_mcp_server_url_elicitation_ecto_test_direct, DirectRepo)
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

  defp make_record(overrides \\ %{}) do
    now = System.system_time(:millisecond)
    random_bytes = :crypto.strong_rand_bytes(32)
    id = Base.url_encode64(random_bytes, padding: false)
    subject_hash = :crypto.hash(:sha256, "test-user") |> Base.encode16(case: :lower)

    Map.merge(
      %{
        "namespace" => "default",
        "id" => id,
        "subject_hash" => subject_hash,
        "action" => "transfer",
        "fields" => %{"amount" => 100},
        "created_at_ms" => now,
        "expires_at_ms" => now + 60_000,
        "consumed_at_ms" => nil
      },
      overrides
    )
  end

  test "new/1 validates options strictly" do
    assert {:error, :invalid_repo} = Store.new([])
    assert {:error, :invalid_repo} = Store.new(namespace: "default")
    assert {:error, :invalid_namespace} = Store.new(repo: Repo)
    assert {:error, :invalid_repo} = Store.new(repo: "NotAModule", namespace: "default")
    assert {:error, :invalid_namespace} = Store.new(repo: Repo, namespace: "")
    assert {:error, :invalid_namespace} = Store.new(repo: Repo, namespace: <<0>>)

    assert {:error, :invalid_options} =
             Store.new(repo: Repo, namespace: "default", unknown_option: 123)

    assert {:error, :invalid_options} =
             Store.new([{:repo, Repo}, {:namespace, "default"}, {:namespace, "duplicate"}])

    assert {:error, :invalid_schema_prefix} =
             Store.new(repo: Repo, namespace: "default", schema_prefix: String.duplicate("a", 64))
  end

  test "put, fetch, and consume happy path", %{store: store} do
    record = make_record()
    now = System.system_time(:millisecond)

    assert :ok = Store.put(store, record)

    assert {:ok, fetched} = Store.fetch(store, "default", record["id"])
    assert fetched["id"] == record["id"]
    assert fetched["action"] == "transfer"
    assert fetched["fields"] == %{"amount" => 100}
    assert is_nil(fetched["consumed_at_ms"])

    assert {:ok, consumed} =
             Store.consume(store, "default", record["id"], record["subject_hash"], now)

    assert consumed["id"] == record["id"]
    assert consumed["consumed_at_ms"] == now

    # Second consume returns {:error, :consumed}
    assert {:error, :consumed} =
             Store.consume(store, "default", record["id"], record["subject_hash"], now + 1)
  end

  test "foreign subject takes precedence over consumed and expired state", %{store: store} do
    now = System.system_time(:millisecond)
    foreign_hash = :crypto.hash(:sha256, "attacker") |> Base.encode16(case: :lower)

    # 1. Unconsumed active record
    active = make_record()
    assert :ok = Store.put(store, active)

    assert {:error, :foreign} =
             Store.consume(store, "default", active["id"], foreign_hash, now)

    # 2. Already consumed record
    consumed = make_record()
    assert :ok = Store.put(store, consumed)

    assert {:ok, _} =
             Store.consume(store, "default", consumed["id"], consumed["subject_hash"], now)

    assert {:error, :foreign} =
             Store.consume(store, "default", consumed["id"], foreign_hash, now)

    # 3. Expired record
    expired = make_record(%{"expires_at_ms" => now - 1_000})
    assert :ok = Store.put(store, expired)

    assert {:error, :foreign} =
             Store.consume(store, "default", expired["id"], foreign_hash, now)
  end

  test "expired record returns :expired and is swept by cleanup_expired", %{store: store} do
    now = System.system_time(:millisecond)
    expired = make_record(%{"expires_at_ms" => now - 100})
    assert :ok = Store.put(store, expired)

    assert {:error, :expired} =
             Store.consume(store, "default", expired["id"], expired["subject_hash"], now)

    # Cleanup expired sweeps it
    assert {:ok, swept_ids} = Store.cleanup_expired(store, now)
    assert expired["id"] in swept_ids

    # After cleanup, fetch returns :not_found
    assert :not_found = Store.fetch(store, "default", expired["id"])
  end

  test "nested transaction returns {:error, :nested_transaction_unsupported}", %{store: store} do
    record = make_record()
    now = System.system_time(:millisecond)

    Repo.transaction(fn ->
      assert {:error, :nested_transaction_unsupported} = Store.put(store, record)

      assert {:error, :nested_transaction_unsupported} =
               Store.consume(store, "default", record["id"], record["subject_hash"], now)

      assert {:error, :nested_transaction_unsupported} = Store.cleanup_expired(store, now)
    end)
  end

  test "namespace isolation prevents cross-namespace operations", %{store: store} do
    record = make_record(%{"namespace" => "default"})
    assert :ok = Store.put(store, record)

    assert {:error, :namespace_mismatch} = Store.fetch(store, "other_ns", record["id"])

    assert {:error, :namespace_mismatch} =
             Store.consume(store, "other_ns", record["id"], record["subject_hash"], 0)
  end

  test "not_found returned for nonexistent or malformed elicitation IDs", %{store: store} do
    assert :not_found = Store.fetch(store, "default", "nonexistent-id")

    assert :not_found =
             Store.consume(store, "default", "nonexistent-id", "somehash", 1_000)
  end

  test "consume is single use under 100 concurrent callers using direct repo" do
    {:ok, direct_store} = Store.new(repo: DirectRepo, namespace: "concurrent_test")
    record = make_record(%{"namespace" => "concurrent_test"})
    now = System.system_time(:millisecond)

    assert :ok = Store.put(direct_store, record)

    tasks =
      for _i <- 1..100 do
        Task.async(fn ->
          Store.consume(
            direct_store,
            "concurrent_test",
            record["id"],
            record["subject_hash"],
            now
          )
        end)
      end

    results = Task.await_many(tasks, 15_000)

    successes = Enum.filter(results, &match?({:ok, _}, &1))
    consumed = Enum.filter(results, &match?({:error, :consumed}, &1))

    assert length(successes) == 1
    assert length(consumed) == 99
  end

  test "schema prefix isolates tables and executes properly" do
    prefix = "mcp_elicitation_test_#{System.unique_integer([:positive])}"

    Repo.query!("CREATE SCHEMA \"#{prefix}\"", [])

    Repo.query!(
      """
      CREATE TABLE "#{prefix}"."attesto_mcp_url_elicitations" (
        namespace varchar(256) NOT NULL,
        id varchar(256) NOT NULL,
        subject_hash varchar(64) NOT NULL,
        action varchar(256) NOT NULL,
        fields jsonb NOT NULL,
        created_at_ms bigint NOT NULL,
        expires_at_ms bigint NOT NULL,
        consumed_at_ms bigint,
        inserted_at timestamp(6) without time zone NOT NULL,
        updated_at timestamp(6) without time zone NOT NULL,
        PRIMARY KEY (namespace, id)
      )
      """,
      []
    )

    try do
      {:ok, prefix_store} = Store.new(repo: Repo, namespace: "default", schema_prefix: prefix)
      record = make_record()
      now = System.system_time(:millisecond)

      assert :ok = Store.put(prefix_store, record)
      assert {:ok, fetched} = Store.fetch(prefix_store, "default", record["id"])
      assert fetched["id"] == record["id"]

      assert {:ok, _} =
               Store.consume(prefix_store, "default", record["id"], record["subject_hash"], now)
    after
      Repo.query!("DROP SCHEMA IF EXISTS \"#{prefix}\" CASCADE", [])
    end
  end

  test "full server integration with Ecto store" do
    {:ok, store} = Store.new(repo: Repo, namespace: "default")

    {:ok, server} =
      API.start_link(
        name: :"ecto_server_#{System.unique_integer([:positive])}",
        session_namespace: "default",
        url_elicitation_store: {Store, store}
      )

    context = %{principal_binding: %{account_id: "acc_456"}}
    action = "wire_transfer"
    fields = %{"usd" => 500}

    assert {:ok, %{id: id, expires_at_ms: exp}} =
             API.stage_url_elicitation(server, context, action, fields, ttl_ms: 30_000)

    assert {:ok, resolved} = API.resolve_url_elicitation(server, id, context.principal_binding)
    assert resolved.action == action
    assert resolved.fields == fields
    assert resolved.expires_at_ms == exp

    assert {:ok, consumed} = API.consume_url_elicitation(server, id, context.principal_binding)
    assert consumed.action == action
    assert consumed.fields == fields

    assert {:error, :consumed} =
             API.resolve_url_elicitation(server, id, context.principal_binding)

    assert {:error, :consumed} =
             API.consume_url_elicitation(server, id, context.principal_binding)
  end

  defp stop_repo(repo) do
    case Process.whereis(repo) do
      pid when is_pid(pid) -> stop_repo_pid(pid)
      nil -> :ok
    end
  end

  defp stop_repo_pid(pid) do
    try do
      Supervisor.stop(pid, :normal)
    catch
      :exit, _ -> :ok
    end
  end
end
