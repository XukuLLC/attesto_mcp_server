if Code.ensure_loaded?(Mix.Ecto) do
  defmodule Mix.Tasks.AttestoMcpServer.Gen.MigrationTest do
    use ExUnit.Case, async: false

    import ExUnit.CaptureIO

    alias Mix.Tasks.AttestoMcpServer.Gen.Migration

    defmodule TestRepo do
      @moduledoc false

      def __adapter__, do: Ecto.Adapters.Postgres
      def config, do: [otp_app: :attesto_mcp_server]
    end

    defmodule OtherRepo do
      @moduledoc false

      def __adapter__, do: Ecto.Adapters.Postgres
      def config, do: [otp_app: :attesto_mcp_server]
    end

    defmodule NonPostgresRepo do
      @moduledoc false

      def __adapter__, do: Ecto.Adapters.SQLite3
      def config, do: [otp_app: :attesto_mcp_server]
    end

    defmodule FirstDefaultPathRepo do
      @moduledoc false

      def __adapter__, do: Ecto.Adapters.Postgres
      def config, do: [otp_app: :attesto_mcp_server, priv: "tmp/attesto-mcp-first-repo"]
    end

    defmodule SecondDefaultPathRepo do
      @moduledoc false

      def __adapter__, do: Ecto.Adapters.SQLite3
      def config, do: [otp_app: :attesto_mcp_server, priv: "tmp/attesto-mcp-second-repo"]
    end

    setup do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "attesto-mcp-server-migration-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      {:ok, tmp_dir: tmp_dir}
    end

    defp migrations_dir(tmp_dir), do: Path.join(tmp_dir, "migrations")

    defp run!(args, tmp_dir) do
      Migration.run([
        "--repo",
        inspect(TestRepo),
        "--migrations-path",
        migrations_dir(tmp_dir)
        | args
      ])
    end

    defp generated_migration(tmp_dir) do
      files =
        Path.wildcard(Path.join(migrations_dir(tmp_dir), "*_create_attesto_mcp_sessions.exs"))

      assert [file] = files
      File.read!(file)
    end

    test "generates the session table and contract columns", %{tmp_dir: tmp_dir} do
      run!([], tmp_dir)
      source = generated_migration(tmp_dir)

      assert source == source |> Code.format_string!() |> IO.iodata_to_binary()

      assert source =~
               "defmodule Mix.Tasks.AttestoMcpServer.Gen.MigrationTest.TestRepo.Migrations.CreateAttestoMcpSessions"

      assert source =~ "use Ecto.Migration"
      assert source =~ "create table(:attesto_mcp_sessions, primary_key: false, prefix: prefix)"
      assert source =~ "add(:namespace, :string, size: 256, primary_key: true, null: false)"
      assert source =~ "add(:session_id, :string, size: 256, primary_key: true, null: false)"
      assert source =~ "add(:record, :map, null: false)"
      assert source =~ "add(:created_at_ms, :bigint, null: false)"
      assert source =~ "add(:last_seen_ms, :bigint, null: false)"
      assert source =~ "add(:absolute_timeout_ms, :bigint, null: false)"
      assert source =~ "add(:idle_timeout_ms, :bigint, null: false)"
      assert source =~ "add(:expires_at_ms, :bigint, null: false)"
      assert source =~ "timestamps(type: :utc_datetime_usec)"

      assert source =~
               "index(:attesto_mcp_sessions, [:namespace, :expires_at_ms, :session_id],"

      assert source =~ "def up do"
      assert source =~ "def down do"
    end

    test "rejects a missing SQL migration layer before parsing or writing", %{
      tmp_dir: tmp_dir
    } do
      for {label, ebin_paths} <- [{"without Ecto", []}, {"with bare Ecto", ecto_ebin_paths()}] do
        migration_path = Path.join(tmp_dir, label |> String.replace(" ", "-"))

        {output, status} = run_task_subprocess!(tmp_dir, ebin_paths, migration_path)

        assert status != 0, "#{label} unexpectedly succeeded:\n#{output}"
        assert output =~ "requires Ecto SQL", output
        refute File.exists?(migration_path)
      end
    end

    test "generates with the complete SQL migration layer without force or clean", %{
      tmp_dir: tmp_dir
    } do
      project_source = """
      defmodule AttestoMcpMigrationComposition.MixProject do
        use Mix.Project

        def project, do: [app: :attesto_mcp_migration_composition, version: "0.1.0"]
      end
      """

      File.write!(Path.join(tmp_dir, "mix.exs"), project_source)
      migration_path = Path.join(tmp_dir, "migrations")

      {output, status} =
        run_task_subprocess!(tmp_dir, ecto_ebin_paths(full: true), migration_path)

      assert status == 0, output

      assert [file] =
               Path.wildcard(Path.join(migration_path, "*_create_attesto_mcp_sessions.exs"))

      assert File.regular?(file)
    end

    test "applies an explicit schema prefix to the table and index", %{tmp_dir: tmp_dir} do
      run!(["--schema-prefix", "mcp_sessions"], tmp_dir)
      source = generated_migration(tmp_dir)

      assert source =~ ~s|prefix = "mcp_sessions"|
      assert source =~ "CREATE SCHEMA IF NOT EXISTS"
      assert source =~ "prefix: prefix"
      refute source =~ "mcp_sessions_attesto_mcp_sessions"
    end

    test "refuses to generate a duplicate migration", %{tmp_dir: tmp_dir} do
      run!([], tmp_dir)

      assert_raise Mix.Error, ~r/migration.*already exists/, fn ->
        run!([], tmp_dir)
      end

      assert length(Path.wildcard(Path.join(migrations_dir(tmp_dir), "*.exs"))) == 1
    end

    test "rejects unsafe schema prefixes", %{tmp_dir: tmp_dir} do
      for prefix <- [
            "",
            "bad-prefix",
            "pg_catalog",
            "information_schema",
            String.duplicate("a", 64)
          ] do
        assert_raise Mix.Error, ~r/invalid --schema-prefix/, fn ->
          run!(["--schema-prefix", prefix], tmp_dir)
        end
      end

      assert Path.wildcard(Path.join(migrations_dir(tmp_dir), "*.exs")) == []
    end

    test "rejects invalid UTF-8 schema prefixes", %{tmp_dir: tmp_dir} do
      assert_raise Mix.Error, ~r/invalid --schema-prefix: expected valid UTF-8/, fn ->
        run!(["--schema-prefix", <<255>>], tmp_dir)
      end

      assert Path.wildcard(Path.join(migrations_dir(tmp_dir), "*.exs")) == []
    end

    test "rejects a repo option whose value is another option", %{tmp_dir: tmp_dir} do
      assert_raise Mix.Error, ~r/invalid --repo: expected a non-empty Ecto repo module/, fn ->
        Migration.run([
          "--repo",
          "--schema-prefix",
          "mcp",
          "--migrations-path",
          migrations_dir(tmp_dir)
        ])
      end

      assert Path.wildcard(Path.join(migrations_dir(tmp_dir), "*.exs")) == []
    end

    test "rejects a non-PostgreSQL Repo before writing a migration", %{tmp_dir: tmp_dir} do
      assert_raise Mix.Error, ~r/support PostgreSQL only/, fn ->
        Migration.run([
          "--repo",
          inspect(NonPostgresRepo),
          "--migrations-path",
          migrations_dir(tmp_dir)
        ])
      end

      assert Path.wildcard(Path.join(migrations_dir(tmp_dir), "*.exs")) == []
    end

    test "rejects duplicate and unknown arguments", %{tmp_dir: tmp_dir} do
      assert_raise Mix.Error, ~r/ambiguous migration-generator arguments/, fn ->
        run!(["--schema-prefix", "mcp", "--schema-prefix", "other"], tmp_dir)
      end

      assert_raise Mix.Error, ~r/invalid migration-generator arguments/, fn ->
        run!(["--unknown"], tmp_dir)
      end

      assert_raise Mix.Error, ~r/invalid migration-generator arguments/, fn ->
        run!(["unexpected"], tmp_dir)
      end
    end

    test "refuses an ambiguous configured repo set", %{tmp_dir: tmp_dir} do
      app = Mix.Project.config()[:app]
      previous = Application.get_env(app, :ecto_repos, :missing)
      Application.put_env(app, :ecto_repos, [TestRepo, OtherRepo])

      on_exit(fn ->
        case previous do
          :missing -> Application.delete_env(app, :ecto_repos)
          value -> Application.put_env(app, :ecto_repos, value)
        end
      end)

      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/ambiguous Ecto repos/, fn ->
          Migration.run(["--migrations-path", migrations_dir(tmp_dir)])
        end
      end)

      assert Path.wildcard(Path.join(migrations_dir(tmp_dir), "*.exs")) == []
    end

    test "rejects one explicit migration path for multiple repos before writing", %{
      tmp_dir: tmp_dir
    } do
      assert_raise Mix.Error, ~r/ambiguous --migrations-path with multiple Ecto repos/, fn ->
        Migration.run([
          "--repo",
          inspect(TestRepo),
          "--repo",
          inspect(OtherRepo),
          "--migrations-path",
          migrations_dir(tmp_dir)
        ])
      end

      assert Path.wildcard(Path.join(migrations_dir(tmp_dir), "*.exs")) == []
    end

    test "preflights every default target before writing any migration" do
      first_path =
        Path.join([File.cwd!(), FirstDefaultPathRepo.config()[:priv], "migrations"])

      second_path =
        Path.join([File.cwd!(), SecondDefaultPathRepo.config()[:priv], "migrations"])

      File.rm_rf!(first_path)
      File.rm_rf!(second_path)

      on_exit(fn ->
        File.rm_rf!(first_path)
        File.rm_rf!(second_path)
      end)

      assert_raise Mix.Error, ~r/support PostgreSQL only/, fn ->
        Migration.run([
          "--repo",
          inspect(FirstDefaultPathRepo),
          "--repo",
          inspect(SecondDefaultPathRepo)
        ])
      end

      refute File.exists?(first_path)
      refute File.exists?(second_path)
    end

    test "uses the child application's private migration path in an umbrella", %{
      tmp_dir: tmp_dir
    } do
      umbrella_root = Path.join(tmp_dir, "umbrella")
      child_root = Path.join([umbrella_root, "apps", "attesto_mcp_umbrella_child"])
      File.mkdir_p!(child_root)
      File.write!(Path.join(umbrella_root, "mix.exs"), umbrella_mix_source())
      File.write!(Path.join(child_root, "mix.exs"), umbrella_child_mix_source())

      run_umbrella_generator!(child_root)

      child_migrations = Path.join(child_root, "priv/repo/migrations")
      umbrella_migrations = Path.join(umbrella_root, "priv/repo/migrations")

      assert [migration] =
               Path.wildcard(Path.join(child_migrations, "*_create_attesto_mcp_sessions.exs"))

      assert File.regular?(migration)
      refute File.exists?(umbrella_migrations)
    end

    test "requires a repo when none is configured", %{tmp_dir: tmp_dir} do
      app = Mix.Project.config()[:app]
      previous = Application.get_env(app, :ecto_repos, :missing)
      Application.delete_env(app, :ecto_repos)

      on_exit(fn ->
        case previous do
          :missing -> Application.delete_env(app, :ecto_repos)
          value -> Application.put_env(app, :ecto_repos, value)
        end
      end)

      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/no Ecto repos available/, fn ->
          Migration.run(["--migrations-path", migrations_dir(tmp_dir)])
        end
      end)
    end

    defp umbrella_mix_source do
      """
      defmodule AttestoMcpUmbrella.MixProject do
        use Mix.Project

        def project, do: [apps_path: "apps"]
      end
      """
    end

    defp umbrella_child_mix_source do
      """
      defmodule AttestoMcpUmbrella.Child.MixProject do
        use Mix.Project

        def project, do: [app: :attesto_mcp_umbrella_child, version: "0.1.0"]
      end
      """
    end

    defp run_umbrella_generator!(child_root) do
      source_root = File.cwd!()
      elixir = System.find_executable("elixir") || raise "elixir executable is required"

      script = """
      source_root = System.fetch_env!("ATTESTO_MCP_SOURCE_ROOT")
      Code.require_file(Path.join(source_root, "lib/mix/tasks/attesto_mcp_server.gen.migration.ex"))

      defmodule UmbrellaChild.Repo do
        def __adapter__, do: Ecto.Adapters.Postgres
        def config, do: [otp_app: :attesto_mcp_umbrella_child]
      end

      Mix.start()

      Mix.Project.in_project(:attesto_mcp_umbrella_child, File.cwd!(), fn _project ->
        Mix.Tasks.AttestoMcpServer.Gen.Migration.run(["--repo", inspect(UmbrellaChild.Repo)])
      end)
      """

      ebin_paths =
        [Mix.Ecto, Mix.EctoSQL]
        |> Enum.map(fn module ->
          module
          |> :code.which()
          |> List.to_string()
          |> Path.dirname()
        end)
        |> Enum.uniq()

      args =
        Enum.flat_map(ebin_paths, fn path -> ["-pa", path] end) ++ ["-e", script]

      {output, status} =
        System.cmd(elixir, args,
          cd: child_root,
          env: [{"ATTESTO_MCP_SOURCE_ROOT", source_root}],
          stderr_to_stdout: true
        )

      assert status == 0, output
    end

    defp ecto_ebin_paths(opts \\ []) do
      apps = if Keyword.get(opts, :full, false), do: [:ecto, :ecto_sql], else: [:ecto]

      Enum.map(apps, &Application.app_dir(&1, "ebin"))
    end

    defp run_task_subprocess!(project_root, ebin_paths, migration_path) do
      source_root = File.cwd!()
      elixir = System.find_executable("elixir") || raise "elixir executable is required"

      script = """
      source_root = System.fetch_env!("ATTESTO_MIGRATION_SOURCE_ROOT")
      Code.require_file(Path.join(source_root, "lib/mix/tasks/attesto_mcp_server.gen.migration.ex"))

      defmodule MigrationCompositionRepo do
        def __adapter__, do: Ecto.Adapters.Postgres
        def config, do: [otp_app: :attesto_mcp_migration_composition]
      end

      Mix.start()
      args = ["--repo", inspect(MigrationCompositionRepo), "--migrations-path", System.fetch_env!("ATTESTO_MIGRATION_PATH")]

      if File.exists?(Path.join(File.cwd!(), "mix.exs")) do
        Mix.Project.in_project(:attesto_mcp_migration_composition, File.cwd!(), fn _project ->
          Mix.Tasks.AttestoMcpServer.Gen.Migration.run(args)
        end)
      else
        Mix.Tasks.AttestoMcpServer.Gen.Migration.run(args)
      end
      """

      args =
        Enum.flat_map(ebin_paths, fn path -> ["-pa", path] end) ++ ["-e", script]

      System.cmd(elixir, args,
        cd: project_root,
        env: [
          {"ATTESTO_MIGRATION_SOURCE_ROOT", source_root},
          {"ATTESTO_MIGRATION_PATH", migration_path},
          {"ERL_LIBS", ""}
        ],
        stderr_to_stdout: true
      )
    end
  end
else
  defmodule Mix.Tasks.AttestoMcpServer.Gen.MigrationTest do
    use ExUnit.Case, async: true

    alias Mix.Tasks.AttestoMcpServer.Gen.Migration

    test "reports that Ecto is required" do
      assert_raise Mix.Error, ~r/requires Ecto/, fn -> Migration.run([]) end
    end
  end
end
