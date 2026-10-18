defmodule Mix.Tasks.AttestoMcpServer.Gen.MigrationDbTest do
  @moduledoc false
  # Applies the generated migrations to PostgreSQL. Runs only with
  # `mix test --include ecto`, like the other store tests.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.AttestoMcpServer.Gen.Migration

  @moduletag :ecto

  defmodule MigrationRepo do
    @moduledoc false

    use Ecto.Repo,
      otp_app: :attesto_mcp_server_migration_test,
      adapter: Ecto.Adapters.Postgres
  end

  setup_all do
    Application.put_env(:attesto_mcp_server_migration_test, MigrationRepo,
      username: System.get_env("POSTGRES_USER", "postgres"),
      password: System.get_env("POSTGRES_PASSWORD", "postgres"),
      hostname: System.get_env("POSTGRES_HOST", "localhost"),
      port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
      database: System.get_env("POSTGRES_DB", "attesto_mcp_server_test"),
      pool_size: 2
    )

    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    _ = MigrationRepo.__adapter__().storage_up(MigrationRepo.config())

    case MigrationRepo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    on_exit(fn ->
      if pid = Process.whereis(MigrationRepo), do: Supervisor.stop(pid, :normal)
      Application.delete_env(:attesto_mcp_server_migration_test, MigrationRepo)
    end)

    :ok
  end

  setup do
    prefix = "mcp_mig_#{System.unique_integer([:positive])}"
    tmp_dir = Path.join(System.tmp_dir!(), "attesto-mcp-server-migration-db-#{prefix}")
    File.mkdir_p!(tmp_dir)
    MigrationRepo.query!(~s(CREATE SCHEMA "#{prefix}"))

    on_exit(fn ->
      File.rm_rf!(tmp_dir)

      if Process.whereis(MigrationRepo),
        do: MigrationRepo.query!(~s(DROP SCHEMA IF EXISTS "#{prefix}" CASCADE))
    end)

    {:ok, prefix: prefix, tmp_dir: tmp_dir}
  end

  defp generate!(tmp_dir, prefix) do
    path = Path.join(tmp_dir, "all")

    capture_io(fn ->
      Migration.run([
        "--repo",
        inspect(MigrationRepo),
        "--migrations-path",
        path,
        "--schema-prefix",
        prefix
      ])
    end)

    path
  end

  defp only_index_dir!(tmp_dir, all_path) do
    dir = Path.join(tmp_dir, "index_only")
    File.mkdir_p!(dir)
    [file] = Path.wildcard(Path.join(all_path, "*_add_attesto_mcp_sessions_principal_index.exs"))
    File.cp!(file, Path.join(dir, Path.basename(file)))
    dir
  end

  defp index_present?(prefix) do
    %{rows: rows} =
      MigrationRepo.query!(
        "SELECT 1 FROM pg_indexes WHERE schemaname = $1 AND indexname = $2",
        [prefix, "attesto_mcp_sessions_namespace_principal_expires_at_ms_index"]
      )

    rows != []
  end

  test "the index migration fails before the sessions table exists and is not recorded",
       %{prefix: prefix, tmp_dir: tmp_dir} do
    all_path = generate!(tmp_dir, prefix)
    index_dir = only_index_dir!(tmp_dir, all_path)

    assert_raise RuntimeError,
                 ~r/does not exist.*create_attesto_mcp_sessions migration before/,
                 fn ->
                   Ecto.Migrator.run(MigrationRepo, index_dir, :up,
                     all: true,
                     prefix: prefix,
                     log: false
                   )
                 end

    assert Ecto.Migrator.migrated_versions(MigrationRepo, prefix: prefix) == []
    refute index_present?(prefix)

    # Once the sessions migration has run, the same index migration applies.
    assert [_, _, _] =
             Ecto.Migrator.run(MigrationRepo, all_path, :up,
               all: true,
               prefix: prefix,
               log: false
             )

    assert length(Ecto.Migrator.migrated_versions(MigrationRepo, prefix: prefix)) == 3
    assert index_present?(prefix)
  end

  test "rerunning the generated migrations is a no-op and rollback removes what they created",
       %{prefix: prefix, tmp_dir: tmp_dir} do
    all_path = generate!(tmp_dir, prefix)

    assert [_, _, _] =
             Ecto.Migrator.run(MigrationRepo, all_path, :up,
               all: true,
               prefix: prefix,
               log: false
             )

    assert [] =
             Ecto.Migrator.run(MigrationRepo, all_path, :up,
               all: true,
               prefix: prefix,
               log: false
             )

    assert index_present?(prefix)

    assert [_, _, _] =
             Ecto.Migrator.run(MigrationRepo, all_path, :down,
               all: true,
               prefix: prefix,
               log: false
             )

    refute index_present?(prefix)

    %{rows: rows} =
      MigrationRepo.query!(
        "SELECT tablename FROM pg_tables WHERE schemaname = $1 AND tablename LIKE 'attesto_mcp_%'",
        [prefix]
      )

    assert rows == []
  end
end
