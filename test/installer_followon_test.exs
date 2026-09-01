defmodule Mix.Tasks.AttestoMcpServer.InstallFollowOnTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  @task Mix.Tasks.AttestoMcpServer.Install
  @args ["--base-url", "https://mcp.example.com"]

  test "leaves CIMD disabled by default and supports explicit opt-in" do
    installed = project() |> install(@args)
    assert installed.issues == []
    refute Igniter.Test.diff(installed) =~ "client_id_metadata"
    refute Igniter.Test.diff(installed) =~ ~s({:req,)
    refute Igniter.Test.diff(installed) =~ ":ets"

    opted_in = project(req_source: ~s({:req, "~> 0.7"})) |> install(@args ++ ["--enable-cimd"])
    assert opted_in.issues == []
    assert Igniter.Test.diff(opted_in) =~ "client_id_metadata: [enabled: true]"

    added_req = project() |> install(@args ++ ["--enable-cimd"])
    assert added_req.issues == []
    assert Igniter.Test.diff(added_req) =~ ~s({:req, ">= 0.6.1 and < 1.0.0"})
    refute Igniter.Test.diff(added_req) =~ ":ets"

    dynamic_req =
      project(req_source: "{:req, helper_requirement()}")
      |> install(@args ++ ["--enable-cimd"])

    assert Enum.any?(dynamic_req.issues, &String.contains?(&1, "req dependency is dynamic"))
    assert Igniter.Test.diff(dynamic_req) == ""
  end

  test "automatically wires the durable Ecto session store for one host Repo" do
    installed =
      project(
        extra_files: %{
          "lib/sample/repo.ex" => ecto_repo_source("Sample.Repo"),
          "lib/sample/application.ex" => application_with_repo_source()
        }
      )
      |> install(@args)

    assert installed.issues == []
    diff = Igniter.Test.diff(installed)
    namespace = generated_session_namespace(:sample, Sample.MCP)

    assert diff =~ "AttestoMCP.Server.SessionStore.Ecto"
    assert diff =~ "repo: Sample.Repo"
    assert diff =~ ~s(namespace: "#{namespace}")
    assert diff =~ "schema_prefix: nil"
    assert diff =~ ~s(session_namespace: "#{namespace}")
    assert diff =~ "children = [Sample.Repo, Sample.MCP]"
    assert Enum.any?(installed.notices, &String.contains?(&1, "attesto_mcp_server.gen.migration"))
    assert Enum.any?(installed.notices, &String.contains?(&1, "mix ecto.migrate"))
  end

  test "resolves an aliased Repo in the application's supervised children" do
    installed =
      project(
        extra_files: %{
          "lib/sample/repo.ex" => ecto_repo_source("Sample.Repo"),
          "lib/sample/application.ex" => """
          defmodule Sample.Application do
            use Application
            alias Sample.Repo

            @impl true
            def start(_type, _args) do
              children = [Repo]
              Supervisor.start_link(children, strategy: :one_for_one, name: Sample.Supervisor)
            end
          end
          """
        }
      )
      |> install(@args)

    assert installed.issues == []
    diff = Igniter.Test.diff(installed)
    assert diff =~ "AttestoMCP.Server.SessionStore.Ecto"
    assert diff =~ "repo: Sample.Repo"
    assert diff =~ "children = [Repo, Sample.MCP]"
  end

  test "ignores test-only Repo modules during automatic session-store selection" do
    installed =
      project(
        extra_files: %{
          "test/repo.ex" => ecto_repo_source("Sample.TestRepo")
        }
      )
      |> install(@args)

    assert installed.issues == []
    diff = Igniter.Test.diff(installed)
    refute diff =~ "AttestoMCP.Server.SessionStore.Ecto"
    refute Enum.any?(installed.notices, &String.contains?(&1, "gen.migration"))
  end

  test "resolves a nested Repo module without evaluating host source" do
    installed =
      project(
        extra_files: %{
          "lib/sample/database.ex" => """
          defmodule Sample do
            defmodule Repo do
              @on_load :raise_if_evaluated
              use Ecto.Repo, otp_app: :sample, adapter: Ecto.Adapters.Postgres

              def raise_if_evaluated, do: raise("host source was evaluated")
            end
          end
          """,
          "lib/sample/application.ex" => application_with_repo_source()
        }
      )
      |> install(@args)

    assert installed.issues == []
    diff = Igniter.Test.diff(installed)
    assert diff =~ "AttestoMCP.Server.SessionStore.Ecto"
    assert diff =~ "repo: Sample.Repo"
    assert Enum.any?(installed.notices, &String.contains?(&1, "gen.migration"))
  end

  test "refuses ambiguous host Repos before editing and accepts an explicit Repo" do
    repo_files = %{
      "lib/sample/repo.ex" => ecto_repo_source("Sample.Repo"),
      "lib/sample/audit_repo.ex" => ecto_repo_source("Sample.AuditRepo"),
      "lib/sample/application.ex" =>
        application_with_children_source(["Sample.Repo", "Sample.AuditRepo"])
    }

    refused = project(extra_files: repo_files) |> install(@args)

    assert Enum.any?(refused.issues, &String.contains?(&1, "multiple Ecto Repos"))
    assert Enum.any?(refused.issues, &String.contains?(&1, "--repo"))
    assert Igniter.Test.diff(refused) == ""

    selected =
      project(extra_files: repo_files)
      |> install(@args ++ ["--repo", "Sample.AuditRepo", "--schema-prefix", "mcp"])

    assert selected.issues == []
    diff = Igniter.Test.diff(selected)
    assert diff =~ "repo: Sample.AuditRepo"
    assert diff =~ "schema_prefix: \"mcp\""
    assert Enum.any?(selected.notices, &String.contains?(&1, "--schema-prefix mcp"))
  end

  test "refuses multiple discovered Repos even when none are supervised" do
    refused =
      project(
        extra_files: %{
          "lib/sample/repo.ex" => ecto_repo_source("Sample.Repo"),
          "lib/sample/audit_repo.ex" => ecto_repo_source("Sample.AuditRepo")
        }
      )
      |> install(@args)

    assert Enum.any?(refused.issues, &String.contains?(&1, "multiple Ecto Repos"))
    assert Enum.any?(refused.issues, &String.contains?(&1, "Sample.Repo"))
    assert Enum.any?(refused.issues, &String.contains?(&1, "Sample.AuditRepo"))
    assert Enum.any?(refused.issues, &String.contains?(&1, "--repo"))
    assert Igniter.Test.diff(refused) == ""
  end

  test "refuses a schema prefix without a host Repo before editing" do
    refused = project() |> install(@args ++ ["--schema-prefix", "mcp"])

    assert Enum.any?(refused.issues, &String.contains?(&1, "--schema-prefix"))
    assert Enum.any?(refused.issues, &String.contains?(&1, "existing Ecto Repo"))
    assert Igniter.Test.diff(refused) == ""
  end

  test "refuses an explicit Repo that is not discovered before editing" do
    refused =
      project() |> install(@args ++ ["--session-store", "ecto", "--repo", "Sample.MissingRepo"])

    assert Enum.any?(refused.issues, &String.contains?(&1, "was not found"))
    assert Igniter.Test.diff(refused) == ""
  end

  test "automatically falls back to private ETS for a known non-PostgreSQL Repo" do
    installed =
      project(
        extra_files: %{
          "lib/sample/repo.ex" => ecto_repo_source("Sample.Repo", "Ecto.Adapters.SQLite3"),
          "lib/sample/application.ex" => application_with_repo_source()
        }
      )
      |> install(@args)

    assert installed.issues == []
    diff = Igniter.Test.diff(installed)
    refute diff =~ "AttestoMCP.Server.SessionStore.Ecto"
    refute diff =~ "session_store:"
    refute Enum.any?(installed.notices, &String.contains?(&1, "gen.migration"))
    assert Enum.any?(installed.notices, &String.contains?(&1, "not configured for PostgreSQL"))

    refused =
      project(
        extra_files: %{
          "lib/sample/repo.ex" => ecto_repo_source("Sample.Repo", "Ecto.Adapters.SQLite3"),
          "lib/sample/application.ex" => application_with_repo_source()
        }
      )
      |> install(@args ++ ["--session-store", "ecto"])

    assert Enum.any?(refused.issues, &String.contains?(&1, "supports PostgreSQL only"))
    assert Igniter.Test.diff(refused) == ""
  end

  test "automatically falls back to private ETS for an unverified sole Repo" do
    installed =
      project(
        extra_files: %{
          "lib/sample/repo.ex" => dynamic_ecto_repo_source("Sample.Repo"),
          "lib/sample/application.ex" => application_with_repo_source()
        }
      )
      |> install(@args)

    assert installed.issues == []
    diff = Igniter.Test.diff(installed)
    refute diff =~ "AttestoMCP.Server.SessionStore.Ecto"
    refute diff =~ "session_store:"
    refute Enum.any?(installed.notices, &String.contains?(&1, "gen.migration"))

    assert Enum.any?(
             installed.notices,
             &String.contains?(&1, "could not be statically confirmed")
           )

    assert Enum.any?(installed.notices, &String.contains?(&1, "private ETS store"))
  end

  test "refuses an explicit Ecto choice for an unverified sole Repo" do
    refused =
      project(
        extra_files: %{
          "lib/sample/repo.ex" => dynamic_ecto_repo_source("Sample.Repo"),
          "lib/sample/application.ex" => application_with_repo_source()
        }
      )
      |> install(@args ++ ["--session-store", "ecto"])

    assert Enum.any?(refused.issues, &String.contains?(&1, "supports PostgreSQL only"))
    assert Igniter.Test.diff(refused) == ""
  end

  test "refuses an explicit Repo selection for an unverified sole Repo" do
    refused =
      project(
        extra_files: %{
          "lib/sample/repo.ex" => dynamic_ecto_repo_source("Sample.Repo"),
          "lib/sample/application.ex" => application_with_repo_source()
        }
      )
      |> install(@args ++ ["--repo", "Sample.Repo"])

    assert Enum.any?(refused.issues, &String.contains?(&1, "supports PostgreSQL only"))
    assert Igniter.Test.diff(refused) == ""
  end

  test "recognizes an AshPostgres Repo without evaluating host code" do
    installed =
      project(
        extra_files: %{
          "lib/sample/repo.ex" => ash_postgres_repo_source("Sample.Repo"),
          "lib/sample/application.ex" => application_with_repo_source()
        }
      )
      |> install(@args)

    assert installed.issues == []
    diff = Igniter.Test.diff(installed)
    assert diff =~ "AttestoMCP.Server.SessionStore.Ecto"
    assert diff =~ "repo: Sample.Repo"
  end

  test "does not auto-select an AshPostgres Repo that disables Ecto integration" do
    for option <- [
          "define_ecto_repo?: false",
          "define_ecto_repo?: System.get_env(\"ENABLE_ECTO_REPO\")"
        ] do
      installed =
        project(
          extra_files: %{
            "lib/sample/repo.ex" => ash_postgres_repo_source("Sample.Repo", option),
            "lib/sample/application.ex" => application_with_repo_source()
          }
        )
        |> install(@args)

      assert installed.issues == []
      diff = Igniter.Test.diff(installed)
      refute diff =~ "AttestoMCP.Server.SessionStore.Ecto"
      refute Enum.any?(installed.notices, &String.contains?(&1, "gen.migration"))
    end
  end

  test "does not auto-select a source-only Repo that the application does not supervise" do
    installed =
      project(
        extra_files: %{
          "lib/sample/repo.ex" => ecto_repo_source("Sample.Repo")
        }
      )
      |> install(@args)

    assert installed.issues == []
    diff = Igniter.Test.diff(installed)
    refute diff =~ "AttestoMCP.Server.SessionStore.Ecto"
    refute Enum.any?(installed.notices, &String.contains?(&1, "gen.migration"))

    assert Enum.any?(
             installed.notices,
             &String.contains?(&1, "could not be statically confirmed as supervised")
           )

    assert Enum.any?(installed.notices, &String.contains?(&1, "literal application child"))
  end

  test "refuses explicit Ecto selection when the Repo is not statically supervised" do
    repo_files = %{"lib/sample/repo.ex" => ecto_repo_source("Sample.Repo")}

    for args <- [
          @args ++ ["--session-store", "ecto"],
          @args ++ ["--session-store", "ecto", "--repo", "Sample.Repo"],
          @args ++ ["--schema-prefix", "mcp"]
        ] do
      refused = project(extra_files: repo_files) |> install(args)

      assert Enum.any?(refused.issues, &String.contains?(&1, "Sample.Repo"))

      assert Enum.any?(
               refused.issues,
               &String.contains?(&1, "literal supervised application child")
             )

      assert Enum.any?(refused.issues, &String.contains?(&1, "--session-store ets"))
      refute Enum.any?(refused.issues, &String.contains?(&1, "pass --repo"))
      assert Igniter.Test.diff(refused) == ""
    end
  end

  test "refuses a bare explicit Repo when it is not statically supervised" do
    refused =
      project(
        extra_files: %{
          "lib/sample/repo.ex" => ecto_repo_source("Sample.Repo")
        }
      )
      |> install(@args ++ ["--repo", "Sample.Repo"])

    assert Enum.any?(refused.issues, &String.contains?(&1, "Sample.Repo"))

    assert Enum.any?(
             refused.issues,
             &String.contains?(&1, "literal supervised application child")
           )

    assert Enum.any?(refused.issues, &String.contains?(&1, "--session-store ets"))
    assert Igniter.Test.diff(refused) == ""
  end

  test "auto-selects a Repo from a literal two-tuple child spec" do
    installed =
      project(
        extra_files: %{
          "lib/sample/repo.ex" => ecto_repo_source("Sample.Repo"),
          "lib/sample/application.ex" => application_with_children_source(["{Sample.Repo, []}"])
        }
      )
      |> install(@args)

    assert installed.issues == []
    diff = Igniter.Test.diff(installed)
    assert diff =~ "AttestoMCP.Server.SessionStore.Ecto"
    assert diff =~ "repo: Sample.Repo"
  end

  test "does not treat a dynamic two-tuple child spec as supervised" do
    installed =
      project(
        extra_files: %{
          "lib/sample/repo.ex" => ecto_repo_source("Sample.Repo"),
          "lib/sample/application.ex" => """
          defmodule Sample.Application do
            use Application

            @impl true
            def start(_type, _args) do
              children = [{Sample.Repo, child_options()}]
              Supervisor.start_link(children, strategy: :one_for_one, name: Sample.Supervisor)
            end

            defp child_options, do: []
          end
          """
        }
      )
      |> install(@args)

    assert installed.issues == []
    diff = Igniter.Test.diff(installed)
    refute diff =~ "AttestoMCP.Server.SessionStore.Ecto"

    assert Enum.any?(
             installed.notices,
             &String.contains?(&1, "could not be statically confirmed as supervised")
           )
  end

  test "does not auto-select a Repo from nested, dead, or overwritten children assignments" do
    application_sources = [
      """
      defmodule Sample.Application do
        use Application

        @impl true
        def start(_type, _args) do
          if true do
            children = [Sample.Repo]
          end

          Supervisor.start_link(children, strategy: :one_for_one, name: Sample.Supervisor)
        end
      end
      """,
      """
      defmodule Sample.Application do
        use Application

        @impl true
        def start(_type, _args) do
          if false do
            children = [Sample.Repo]
          end

          Supervisor.start_link(children, strategy: :one_for_one, name: Sample.Supervisor)
        end
      end
      """,
      """
      defmodule Sample.Application do
        use Application

        @impl true
        def start(_type, _args) do
          children = [Sample.Repo]
          children = []
          Supervisor.start_link(children, strategy: :one_for_one, name: Sample.Supervisor)
        end
      end
      """
    ]

    for application_source <- application_sources do
      installed =
        project(
          extra_files: %{
            "lib/sample/repo.ex" => ecto_repo_source("Sample.Repo"),
            "lib/sample/application.ex" => application_source
          }
        )
        |> install(@args)

      assert installed.issues == []
      diff = Igniter.Test.diff(installed)
      refute diff =~ "AttestoMCP.Server.SessionStore.Ecto"

      assert Enum.any?(
               installed.notices,
               &String.contains?(&1, "could not be statically confirmed as supervised")
             )
    end
  end

  test "recognizes a statically aliased PostgreSQL adapter" do
    installed =
      project(
        extra_files: %{
          "lib/sample/repo.ex" => """
          defmodule Sample.Repo do
            alias Ecto.Adapters.Postgres
            use Ecto.Repo, otp_app: :sample, adapter: Postgres
          end
          """,
          "lib/sample/application.ex" => application_with_repo_source()
        }
      )
      |> install(@args)

    assert installed.issues == []
    diff = Igniter.Test.diff(installed)
    assert diff =~ "AttestoMCP.Server.SessionStore.Ecto"
    assert diff =~ "repo: Sample.Repo"
  end

  test "keeps Ash non-PostgreSQL Repos on private ETS" do
    for repo_module <- ["AshSqlite.Repo", "AshMysql.Repo"] do
      installed =
        project(
          extra_files: %{
            "lib/sample/repo.ex" => """
            defmodule Sample.Repo do
              use #{repo_module}, otp_app: :sample
            end
            """,
            "lib/sample/application.ex" => application_with_repo_source()
          }
        )
        |> install(@args)

      assert installed.issues == []
      diff = Igniter.Test.diff(installed)
      refute diff =~ "AttestoMCP.Server.SessionStore.Ecto"
      refute Enum.any?(installed.notices, &String.contains?(&1, "gen.migration"))
      assert Enum.any?(installed.notices, &String.contains?(&1, "not configured for PostgreSQL"))
    end
  end

  test "explicit ETS opts out of automatic durable session wiring" do
    installed =
      project(
        extra_files: %{
          "lib/sample/repo.ex" => ecto_repo_source("Sample.Repo"),
          "lib/sample/application.ex" => application_with_repo_source()
        }
      )
      |> install(@args ++ ["--session-store", "ets"])

    assert installed.issues == []
    diff = Igniter.Test.diff(installed)
    refute diff =~ "AttestoMCP.Server.SessionStore.Ecto"
    refute diff =~ "session_store:"
    refute Enum.any?(installed.notices, &String.contains?(&1, "gen.migration"))
  end

  test "durable session wiring is idempotent on rerun" do
    installed =
      project(
        extra_files: %{
          "lib/sample/repo.ex" => ecto_repo_source("Sample.Repo"),
          "lib/sample/application.ex" => application_with_repo_source()
        }
      )
      |> install(@args)

    assert installed.issues == []
    namespace = generated_session_namespace(:sample, Sample.MCP)
    assert Igniter.Test.diff(installed) =~ ~s(session_namespace: "#{namespace}")

    rerun = installed |> apply_igniter!() |> install(@args)
    assert rerun.issues == []
    assert_unchanged(rerun)
    assert Enum.any?(rerun.notices, &String.contains?(&1, "attesto_mcp_server.gen.migration"))
  end

  test "preserves an existing custom session store without announcing Ecto" do
    installed =
      project(
        extra_files: %{
          "lib/sample/repo.ex" => ecto_repo_source("Sample.Repo"),
          "config/config.exs" => """
          import Config

          config :sample, Sample.MCP,
            server_options: [session_store: {Sample.CustomStore, :handle}]
          """
        }
      )
      |> install(@args)

    assert installed.issues == []
    refute Igniter.Test.diff(installed) =~ "AttestoMCP.Server.SessionStore.Ecto"
    refute Enum.any?(installed.notices, &String.contains?(&1, "gen.migration"))
  end

  test "warns when auto mode preserves an unvalidated bundled Ecto handle" do
    for session_store <- [
          "{AttestoMCP.Server.SessionStore.Ecto, %{repo: Sample.Repo}}",
          "{AttestoMCP.Server.SessionStore.Ecto, %{namespace: \"sample-mcp\"}}"
        ] do
      installed =
        project(
          extra_files: %{
            "config/config.exs" => """
            import Config

            config :sample, Sample.MCP,
              server_options: [session_store: #{session_store}]
            """
          }
        )
        |> install(@args)

      assert installed.issues == []

      assert Enum.any?(
               installed.notices,
               &String.contains?(&1, "could not be statically validated")
             )

      assert Enum.any?(installed.notices, &String.contains?(&1, "startup may reject"))
      refute Enum.any?(installed.notices, &String.contains?(&1, "gen.migration"))
    end
  end

  test "preserves arbitrary custom adapters without an Ecto validation warning" do
    installed =
      project(
        extra_files: %{
          "config/config.exs" => """
          import Config

          config :sample, Sample.MCP,
            server_options: [session_store: {Sample.CustomStore, %{repo: Sample.Repo}}]
          """
        }
      )
      |> install(@args)

    assert installed.issues == []
    refute Enum.any?(installed.notices, &String.contains?(&1, "startup may reject"))

    refute Enum.any?(
             installed.notices,
             &String.contains?(&1, "could not be statically validated")
           )
  end

  test "refuses a session store hidden inside conditional or runtime config" do
    config_sources = [
      {
        "config/config.exs",
        """
        import Config

        if System.get_env("MCP_CONFIG") do
          config :sample, Sample.MCP,
            server_options: [session_store: {Sample.CustomStore, :handle}]
        end
        """
      },
      {
        "config/runtime.exs",
        """
        import Config

        case System.get_env("MCP_CONFIG") do
          nil -> :ok
          _ -> config :sample, Sample.MCP, server_options: runtime_session_options()
        end
        """
      },
      {
        "config/config.exs",
        """
        import Config

        if System.get_env("MCP_CONFIG") do
          Config.config(:sample, Sample.MCP,
            server_options: [session_store: {Sample.CustomStore, :handle}])
        end
        """
      },
      {
        "config/config.exs",
        """
        import Config

        if System.get_env("MCP_CONFIG") do
          alias Config, as: AppConfig
          alias Sample.MCP, as: MCP

          AppConfig.config(:sample, MCP,
            server_options: [session_store: {Sample.CustomStore, :handle}])
        end
        """
      }
    ]

    for {path, source} <- config_sources do
      refused = project(extra_files: %{path => source}) |> install(@args)

      assert Enum.any?(
               refused.issues,
               &String.contains?(&1, "conditional or runtime config")
             ),
             path

      assert Igniter.Test.diff(refused) == ""
    end
  end

  test "preserves an aliased custom session store without announcing Ecto" do
    installed =
      project(
        extra_files: %{
          "lib/sample/repo.ex" => ecto_repo_source("Sample.Repo"),
          "lib/sample/application.ex" => application_with_repo_source(),
          "config/config.exs" => """
          import Config

          alias Sample.MCP, as: MCP
          alias Sample.CustomStore, as: CustomStore

          config :sample, MCP,
            server_options: [session_store: {CustomStore, :handle}]
          """
        }
      )
      |> install(@args)

    assert installed.issues == []
    refute Igniter.Test.diff(installed) =~ "AttestoMCP.Server.SessionStore.Ecto"
    refute Enum.any?(installed.notices, &String.contains?(&1, "gen.migration"))
  end

  test "preserves an existing nil session store without announcing Ecto" do
    installed =
      project(
        extra_files: %{
          "lib/sample/repo.ex" => ecto_repo_source("Sample.Repo"),
          "config/config.exs" => """
          import Config

          config :sample, Sample.MCP,
            server_options: [session_store: nil]
          """
        }
      )
      |> install(@args)

    assert installed.issues == []
    refute Igniter.Test.diff(installed) =~ "AttestoMCP.Server.SessionStore.Ecto"
    refute Enum.any?(installed.notices, &String.contains?(&1, "gen.migration"))
  end

  test "warns when automatic mode preserves an inconsistent Ecto handle as custom" do
    extra_files = %{
      "lib/sample/repo.ex" => ecto_repo_source("Sample.Repo"),
      "lib/sample/application.ex" => application_with_repo_source(),
      "config/config.exs" => """
      import Config

      config :sample, Sample.MCP,
        server_options: [
          session_store:
            {AttestoMCP.Server.SessionStore.Ecto,
             %{repo: Sample.Repo, namespace: "store-namespace"}},
          session_namespace: "server-namespace"
        ]
      """
    }

    installed = project(extra_files: extra_files) |> install(@args)

    assert installed.issues == []
    assert Enum.any?(installed.notices, &String.contains?(&1, "will reject this configuration"))
    assert Enum.any?(installed.notices, &String.contains?(&1, "store-namespace"))
    assert Enum.any?(installed.notices, &String.contains?(&1, "server-namespace"))
    refute Enum.any?(installed.notices, &String.contains?(&1, "gen.migration"))

    refused = project(extra_files: extra_files) |> install(@args ++ ["--session-store", "ecto"])

    assert Enum.any?(refused.issues, &String.contains?(&1, "custom session store"))
    assert Igniter.Test.diff(refused) == ""
  end

  test "preserves an existing Ecto session store and recognizes an omitted prefix" do
    installed =
      project(
        extra_files: %{
          "lib/sample/repo.ex" => ecto_repo_source("Sample.Repo"),
          "config/config.exs" => """
          import Config

          config :sample, Sample.MCP,
            server_options: [
              session_store:
                {AttestoMCP.Server.SessionStore.Ecto,
                 %{repo: Sample.Repo, namespace: "sample-mcp"}},
              session_namespace: "sample-mcp"
            ]
          """
        }
      )
      |> install(@args ++ ["--session-store", "ecto"])

    assert installed.issues == []
    assert Igniter.Test.diff(installed) =~ "namespace: \"sample-mcp\""
    assert Enum.any?(installed.notices, &String.contains?(&1, "gen.migration"))

    conflicting =
      project(
        extra_files: %{
          "lib/sample/repo.ex" => ecto_repo_source("Sample.Repo"),
          "config/config.exs" => """
          import Config

          config :sample, Sample.MCP,
            server_options: [
              session_store:
                {AttestoMCP.Server.SessionStore.Ecto,
                 %{repo: Sample.Repo, namespace: "sample-mcp"}},
              session_namespace: "sample-mcp"
            ]
          """
        }
      )
      |> install(@args ++ ["--session-store", "ets"])

    assert Enum.any?(conflicting.issues, &String.contains?(&1, "already configures the Ecto"))
    assert Igniter.Test.diff(conflicting) == ""
  end

  test "reruns idempotently with aliased generated Ecto session configuration" do
    installed =
      project(
        extra_files: %{
          "lib/sample/repo.ex" => ecto_repo_source("Sample.Repo"),
          "lib/sample/application.ex" => application_with_repo_source(),
          "config/config.exs" => """
          import Config

          alias AttestoMCP.Server.SessionStore.Ecto, as: SessionStore
          alias Sample.MCP, as: MCP
          alias Sample.Repo, as: Repo

          config :sample, MCP,
            server_options: [
              session_store:
                {SessionStore, %{repo: Repo, namespace: "sample-mcp", schema_prefix: nil}},
              session_namespace: "sample-mcp"
            ]
          """
        }
      )
      |> install(@args ++ ["--session-store", "ecto"])

    assert installed.issues == []
    rerun = installed |> apply_igniter!() |> install(@args ++ ["--session-store", "ecto"])
    assert rerun.issues == []
    assert_unchanged(rerun)
    assert Enum.any?(rerun.notices, &String.contains?(&1, "attesto_mcp_server.gen.migration"))
  end

  test "refuses to preserve a bundled Ecto store after its Repo changes to SQLite" do
    refused =
      project(
        extra_files: %{
          "lib/sample/repo.ex" => ecto_repo_source("Sample.Repo", "Ecto.Adapters.SQLite3"),
          "config/config.exs" => """
          import Config

          config :sample, Sample.MCP,
            server_options: [
              session_store:
                {AttestoMCP.Server.SessionStore.Ecto,
                 %{repo: Sample.Repo, namespace: "sample-mcp", schema_prefix: nil}},
              session_namespace: "sample-mcp"
            ]
          """
        }
      )
      |> install(@args)

    assert Enum.any?(refused.issues, &String.contains?(&1, "not statically configured"))
    assert Igniter.Test.diff(refused) == ""
  end

  test "refuses to preserve a bundled Ecto store when its Repo adapter is dynamic" do
    refused =
      project(
        extra_files: %{
          "lib/sample/repo.ex" => dynamic_ecto_repo_source("Sample.Repo"),
          "config/config.exs" => """
          import Config

          config :sample, Sample.MCP,
            server_options: [
              session_store:
                {AttestoMCP.Server.SessionStore.Ecto,
                 %{repo: Sample.Repo, namespace: "sample-mcp", schema_prefix: nil}},
              session_namespace: "sample-mcp"
            ]
          """
        }
      )
      |> install(@args)

    assert Enum.any?(refused.issues, &String.contains?(&1, "could not be statically confirmed"))
    assert Igniter.Test.diff(refused) == ""
  end

  test "does not preserve an Ecto store without a matching bound namespace" do
    for handle <- [
          "%{repo: Sample.Repo}",
          "%{repo: Sample.Repo, namespace: \"other-mcp\"}"
        ] do
      refused =
        project(
          extra_files: %{
            "config/config.exs" => """
            import Config

            config :sample, Sample.MCP,
              server_options: [
                session_store: {AttestoMCP.Server.SessionStore.Ecto, #{handle}},
                session_namespace: "sample-mcp"
              ]
            """
          }
        )
        |> install(@args ++ ["--session-store", "ecto"])

      assert Enum.any?(refused.issues, &String.contains?(&1, "custom session store"))
      assert Igniter.Test.diff(refused) == ""
    end
  end

  test "uses distinct namespaces and Repo ordering for multiple named servers" do
    initial =
      project(
        extra_files: %{
          "lib/sample/repo.ex" => ecto_repo_source("Sample.Repo"),
          "lib/sample/application.ex" => application_with_repo_source(),
          "lib/sample_web/admin_router.ex" => admin_router_source()
        }
      )
      |> install(@args ++ ["--router", "SampleWeb.Router"])

    assert initial.issues == []
    applied = apply_igniter!(initial)

    second =
      applied
      |> install(
        @args ++
          [
            "--server-module",
            "Sample.AdminMCP",
            "--router",
            "SampleWeb.AdminRouter",
            "--mcp-path",
            "/admin-mcp"
          ]
      )

    assert second.issues == []
    diff = Igniter.Test.diff(second)
    namespace = generated_session_namespace(:sample, Sample.AdminMCP)
    assert diff =~ ~s(session_namespace: "#{namespace}")
    assert diff =~ "children = [Sample.Repo, Sample.MCP, Sample.AdminMCP]"
    assert Enum.any?(second.notices, &String.contains?(&1, "namespace \"#{namespace}\""))
  end

  test "binds generated namespaces to the exact app and server identity" do
    my_app_foo =
      project(
        app_name: :my_app,
        extra_files: %{
          "lib/sample/repo.ex" => ecto_repo_source("MyApp.Repo"),
          "lib/sample/application.ex" => application_with_children_source(["MyApp.Repo"])
        }
      )
      |> install(
        @args ++
          ["--server-module", "MyApp.Foo", "--session-store", "ecto", "--repo", "MyApp.Repo"]
      )

    foo =
      project(
        app_name: :my_app,
        extra_files: %{
          "lib/sample/repo.ex" => ecto_repo_source("MyApp.Repo"),
          "lib/sample/application.ex" => application_with_children_source(["MyApp.Repo"])
        }
      )
      |> install(
        @args ++ ["--server-module", "Foo", "--session-store", "ecto", "--repo", "MyApp.Repo"]
      )

    assert my_app_foo.issues == []
    assert foo.issues == []

    first_namespace = generated_session_namespace(:my_app, MyApp.Foo)
    second_namespace = generated_session_namespace(:my_app, Foo)

    assert first_namespace != second_namespace
    assert first_namespace =~ ~r/^my_app-.*-[A-Za-z0-9_-]{43}$/
    assert second_namespace =~ ~r/^my_app-.*-[A-Za-z0-9_-]{43}$/
    assert Igniter.Test.diff(my_app_foo) =~ ~s(session_namespace: "#{first_namespace}")
    assert Igniter.Test.diff(foo) =~ ~s(session_namespace: "#{second_namespace}")
  end

  test "distinguishes Macro.underscore case and acronym collisions" do
    variants = [
      install(
        project(
          extra_files: %{
            "lib/sample/repo.ex" => ecto_repo_source("Sample.Repo"),
            "lib/sample/application.ex" => application_with_repo_source()
          }
        ),
        @args ++ ["--server-module", "Sample.HTTPFoo"]
      ),
      install(
        project(
          extra_files: %{
            "lib/sample/repo.ex" => ecto_repo_source("Sample.Repo"),
            "lib/sample/application.ex" => application_with_repo_source()
          }
        ),
        @args ++ ["--server-module", "Sample.HttpFoo"]
      )
    ]

    assert Enum.all?(variants, &(&1.issues == []))

    namespaces = [
      generated_session_namespace(:sample, Sample.HTTPFoo),
      generated_session_namespace(:sample, Sample.HttpFoo)
    ]

    assert Enum.uniq(namespaces) == namespaces

    for {installed, namespace} <- Enum.zip(variants, namespaces) do
      assert Igniter.Test.diff(installed) =~ ~s(session_namespace: "#{namespace}")
    end
  end

  test "bounds a generated namespace for long app and server module names" do
    app = String.duplicate("a", 80) |> String.to_atom()
    server_module = "Other." <> String.duplicate("A", 210)

    installed =
      project(
        app_name: app,
        extra_files: %{
          "lib/sample/repo.ex" => ecto_repo_source("Sample.Repo"),
          "lib/sample/application.ex" => application_with_repo_source()
        }
      )
      |> install(@args ++ ["--server-module", server_module])

    assert installed.issues == []
    diff = Igniter.Test.diff(installed)
    assert [_, namespace] = Regex.run(~r/session_namespace: "([^"]+)"/, diff)
    assert byte_size(namespace) <= 256
    assert String.starts_with?(namespace, "mcp-")
    assert namespace == generated_session_namespace(app, server_module)
  end

  test "refuses an explicit Ecto switch when a custom session store is configured" do
    installed =
      project(
        extra_files: %{
          "config/config.exs" => """
          import Config

          config :sample, Sample.MCP,
            server_options: [session_store: {Sample.CustomStore, :handle}]
          """
        }
      )
      |> install(@args ++ ["--session-store", "ecto"])

    assert Enum.any?(installed.issues, &String.contains?(&1, "custom session store"))
    assert Igniter.Test.diff(installed) == ""
  end

  test "explicit CIMD opt-in preserves existing cache, repo, prefix, allowlist, and enabled value" do
    config = """
    import Config

    config :sample, AttestoPhoenix.Config,
      client_id_metadata: [
        enabled: false,
        cache: Sample.CIMDCache,
        repo: Sample.Repo,
        table_prefix: "tenant_a",
        allowed_hosts: ["clients.example"]
      ]
    """

    installed =
      project(
        req_source: ~s({:req, "~> 0.7"}),
        extra_files: %{"config/config.exs" => config}
      )
      |> install(@args ++ ["--enable-cimd"])

    assert installed.issues == []

    content =
      installed
      |> apply_igniter!()
      |> Map.fetch!(:rewrite)
      |> Rewrite.source!("config/config.exs")
      |> Rewrite.Source.get(:content)

    assert content =~ "enabled: false"
    assert content =~ "cache: Sample.CIMDCache"
    assert content =~ "repo: Sample.Repo"
    assert content =~ "table_prefix: \"tenant_a\""
    assert content =~ "allowed_hosts: [\"clients.example\"]"
    refute content =~ "Ecto.Adapters.SQL.Sandbox"
    refute content =~ ":ets"

    rerun = installed |> apply_igniter!() |> install(@args ++ ["--enable-cimd"])

    assert rerun.issues == []
    assert_unchanged(rerun)
  end

  test "requires automatic AttestoPhoenix integration for CIMD opt-in" do
    refused =
      project(attesto_phoenix?: false)
      |> install(@args ++ ["--enable-cimd", "--attesto-config", "Sample.Attesto.config/0"])

    assert Enum.any?(refused.issues, &String.contains?(&1, "requires automatic"))
    assert Igniter.Test.diff(refused) == ""
  end

  test "reuse with an explicit callback refuses with exact MCP wiring" do
    refused =
      project(attesto_phoenix?: false)
      |> install(
        @args ++
          [
            "--attesto-config",
            "Sample.Attesto.config/0",
            "--reuse-metadata-route"
          ]
      )

    assert Enum.any?(refused.issues, &String.contains?(&1, "Exact MCP wiring"))
    assert Igniter.Test.diff(refused) == ""
  end

  test "reuses an exact AttestoPhoenix metadata forward and inserts MCP after it" do
    installed =
      project(
        router_source: """
        defmodule SampleWeb.Router do
          use Phoenix.Router

          # established metadata route must remain byte-stable
          use AttestoPhoenix.Router

          # preserve this invocation and its placement
          attesto_routes(protected_resource_paths: ["/mcp"])

          # the installer adds MCP transport after the established route
        end
        """
      )
      |> install(@args ++ ["--reuse-metadata-route"])

    assert installed.issues == []
    diff = Igniter.Test.diff(installed)
    refute diff =~ "MetadataPlug"

    assert diff =~ ~s(Elixir.Phoenix.Router.forward("/mcp")
    assert byte_offset(diff, "attesto_routes") < byte_offset(diff, "forward(\"/mcp\"")

    applied = installed |> apply_igniter!()

    content =
      applied.rewrite
      |> Rewrite.source!("lib/sample_web/router.ex")
      |> Rewrite.Source.get(:content)

    assert content =~ "# established metadata route must remain byte-stable"
    assert content =~ "# preserve this invocation and its placement"
    assert content =~ "# the installer adds MCP transport after the established route"
    assert byte_offset(content, "attesto_routes") < byte_offset(content, "forward(\"/mcp\"")

    rerun = applied |> install(@args ++ ["--reuse-metadata-route"])
    assert rerun.issues == []
    assert_unchanged(rerun)

    mode_switch = applied |> install(@args)
    assert mode_switch.issues != []
    assert Igniter.Test.diff(mode_switch) == ""
  end

  test "reuse accepts a statically bounded unrelated scope" do
    installed =
      project(
        router_source: """
        defmodule SampleWeb.Router do
          use Phoenix.Router

          scope "/health" do
            get "/status", SampleWeb.HealthController, :show
          end

          use AttestoPhoenix.Router
          attesto_routes(protected_resource_paths: ["/mcp"])
        end
        """
      )
      |> install(@args ++ ["--reuse-metadata-route"])

    assert installed.issues == []
    assert Igniter.Test.diff(installed) =~ ~s(forward("/mcp")
  end

  test "reuse refuses a dynamic unrelated scope without editing" do
    installed =
      project(
        router_source: """
        defmodule SampleWeb.Router do
          use Phoenix.Router
          scope dynamic_prefix() do
            get "/health", SampleWeb.HealthController, :show
          end
          use AttestoPhoenix.Router
          attesto_routes(protected_resource_paths: ["/mcp"])
        end
        """
      )
      |> install(@args ++ ["--reuse-metadata-route"])

    assert installed.issues != []
    assert Igniter.Test.diff(installed) == ""
  end

  test "rejects a mismatched or dynamic metadata path during reuse preflight" do
    for route <- [
          "attesto_routes(protected_resource_paths: [\"/other\"])",
          "metadata_path = \"/mcp\"\n  attesto_routes(protected_resource_paths: [metadata_path])"
        ] do
      installed =
        project(
          router_source: """
          defmodule SampleWeb.Router do
          use Phoenix.Router
            use AttestoPhoenix.Router
            #{route}
          end
          """
        )
        |> install(@args ++ ["--reuse-metadata-route"])

      assert installed.issues != []
      assert Igniter.Test.diff(installed) == ""
    end
  end

  test "reports one ordinary metadata forward specifically during reuse preflight" do
    for {route, message} <- [
          {"/.well-known/oauth-protected-resource/mcp",
           "ordinary metadata forward at the exact canonical path"},
          {"/.well-known/oauth-protected-resource/other",
           "mismatched protected-resource metadata path"}
        ] do
      installed =
        project(
          router_source: """
          defmodule SampleWeb.Router do
            use Phoenix.Router
            use AttestoPhoenix.Router

            forward #{inspect(route)}, Sample.MetadataPlug
          end
          """
        )
        |> install(@args ++ ["--reuse-metadata-route"])

      assert Enum.any?(installed.issues, &String.contains?(&1, message))
      assert Igniter.Test.diff(installed) == ""
    end
  end

  test "default generation refuses any selected or ambiguous Attesto route" do
    router_bodies = [
      "use AttestoPhoenix.Router\n  attesto_routes(protected_resource_paths: [\"/mcp\"])\n  attesto_routes(protected_resource_paths: [\"/other\"])",
      "use AttestoPhoenix.Router\n  attesto_routes(protected_resource_paths: [\"/mcp\"])\n  attesto_routes(protected_resource_paths: [\"/mcp\"])",
      "use AttestoPhoenix.Router\n  options = [protected_resource_paths: [\"/mcp\"]]\n  attesto_routes(options)",
      "use AttestoPhoenix.Router\n  AttestoPhoenix.Router.attesto_routes(protected_resource_paths: [\"/mcp\"])"
    ]

    for body <- router_bodies do
      installed =
        project(
          router_source: """
          defmodule SampleWeb.Router do
          use Phoenix.Router
            #{body}
          end
          """
        )
        |> install(@args)

      assert installed.issues != []
      assert Igniter.Test.diff(installed) == ""
    end
  end

  test "refuses ambiguous, scoped, spoofed, and path-lookalike metadata routes" do
    router_bodies = [
      "attesto_routes(protected_resource_paths: [\"/mcp\"])\n  attesto_routes(protected_resource_paths: [\"/mcp\"])",
      "scope \"/\" do\n    attesto_routes(protected_resource_paths: [\"/mcp\"])\n  end",
      "defmacro attesto_routes(_options), do: quote do: :ok\n  attesto_routes(protected_resource_paths: [\"/mcp\"])",
      "attesto_routes(protected_resource_paths: [\"/mcp\"], extra: true)",
      "forward \"/.well-known/oauth-protected-resource/mcp\", SomeWeb.OtherPlug"
    ]

    for body <- router_bodies do
      installed =
        project(
          router_source: """
          defmodule SampleWeb.Router do
            use SampleWeb, :router
            use AttestoPhoenix.Router
            #{body}
          end
          """
        )
        |> install(@args ++ ["--reuse-metadata-route"])

      assert installed.issues != []
      assert Enum.any?(installed.issues, &String.contains?(&1, "Exact MCP wiring"))
    end
  end

  test "refuses opaque router emitters and compiler hooks during metadata reuse" do
    for body <- [
          "evil_routes(\"/mcp\")\n  attesto_routes(protected_resource_paths: [\"/mcp\"])",
          "DynamicRoutes.install(__MODULE__)\n  attesto_routes(protected_resource_paths: [\"/mcp\"])",
          "@before_compile SampleWeb.RouteInjector\n  attesto_routes(protected_resource_paths: [\"/mcp\"])",
          "@phoenix_routes [{:get, \"/evil\"}]\n  attesto_routes(protected_resource_paths: [\"/mcp\"])",
          "require SampleWeb.RouteInjector\n  attesto_routes(protected_resource_paths: [\"/mcp\"])",
          "require SampleWeb.RouteInjector\n  def helper, do: SampleWeb.RouteInjector.inject(__MODULE__)\n  attesto_routes(protected_resource_paths: [\"/mcp\"])",
          "@route_options Evil.install(__MODULE__)\n  attesto_routes(protected_resource_paths: [\"/mcp\"])"
        ] do
      installed =
        project(
          router_source: """
          defmodule SampleWeb.Router do
            use SampleWeb, :router
            use AttestoPhoenix.Router
            #{body}
          end
          """
        )
        |> install(@args ++ ["--reuse-metadata-route"])

      assert installed.issues != []
      assert Enum.any?(installed.issues, &String.contains?(&1, "Exact MCP wiring"))
      assert Igniter.Test.diff(installed) == ""
    end
  end

  test "wraps a direct endpoint parser with an exact MCP bypass" do
    installed =
      project(
        extra_files: %{
          "lib/sample_web/endpoint.ex" => """
          defmodule SampleWeb.Endpoint do
            use Phoenix.Endpoint, otp_app: :sample
            plug Plug.Parsers, parsers: [:json], json_decoder: Jason
            plug SampleWeb.Router
          end
          """
        }
      )
      |> install(@args)

    assert installed.issues == []
    diff = Igniter.Test.diff(installed)
    assert diff =~ "AttestoMCP.Server.PhoenixParser"
    assert diff =~ ~s(mcp_path: "/mcp")
    assert diff =~ "parsers: [:json]"
    assert diff =~ "json_decoder: Jason"

    applied = installed |> apply_igniter!() |> install(@args)
    assert applied.issues == []
    assert_unchanged(applied)
  end

  test "wraps a standard Phoenix endpoint pipeline without rejecting post-parser plugs" do
    installed =
      project(
        extra_files: %{
          "lib/sample_web/endpoint.ex" => """
          defmodule SampleWeb.Endpoint do
            use Phoenix.Endpoint, otp_app: :sample

            @session_options [
              store: :cookie,
              key: "_sample_key",
              signing_salt: "sample-signing-salt"
            ]

            if code_reloading? do
              plug Phoenix.LiveReloader
              plug Phoenix.CodeReloader
            end

            plug Plug.Static,
              at: "/",
              from: :sample,
              gzip: not code_reloading?(),
              only: SampleWeb.static_paths(),
              raise_on_missing_only: code_reloading?()
            plug Plug.RequestId
            plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
            plug Plug.Parsers,
              parsers: [:urlencoded, :multipart, :json],
              pass: ["*/*"],
              json_decoder: Phoenix.json_library()
            plug Plug.MethodOverride
            plug Plug.Head
            plug Plug.Session, @session_options
            plug SampleWeb.Router
          end
          """
        }
      )
      |> install(@args)

    assert installed.issues == []
    assert Igniter.Test.diff(installed) =~ "AttestoMCP.Server.PhoenixParser"
  end

  test "refuses when endpoint parser provenance is custom" do
    installed =
      project(
        extra_files: %{
          "lib/sample_web/endpoint.ex" => """
          defmodule SampleWeb.Endpoint do
            use Phoenix.Endpoint, otp_app: :sample
            plug SampleWeb.CustomParser
          end
          """
        }
      )
      |> install(@args)

    assert installed.issues != []

    assert Enum.any?(
             installed.issues,
             &String.contains?(&1, "custom or ambiguous endpoint plug")
           )

    assert Igniter.Test.diff(installed) == ""
  end

  test "refuses endpoint compiler hooks before rewriting a parser" do
    installed =
      project(
        extra_files: %{
          "lib/sample_web/endpoint.ex" => """
          defmodule SampleWeb.Endpoint do
            @before_compile SampleWeb.RouteInjector
            use Phoenix.Endpoint, otp_app: :sample
            plug Plug.Parsers, parsers: [:json]
          end
          """
        }
      )
      |> install(@args)

    assert installed.issues != []
    assert Igniter.Test.diff(installed) == ""
  end

  test "refuses a non-isolated endpoint source before editing" do
    installed =
      project(
        extra_files: %{
          "lib/sample_web/endpoint.ex" => """
          defmodule SampleWeb.Endpoint do
            use Phoenix.Endpoint, otp_app: :sample
            plug Plug.Parsers, parsers: [:json]
            plug SampleWeb.Router
          end

          defmodule SampleWeb.EndpointHelper do
          end
          """
        }
      )
      |> install(@args)

    assert installed.issues != []
    assert Enum.any?(installed.issues, &String.contains?(&1, "not an isolated module"))
    assert Igniter.Test.diff(installed) == ""
  end

  test "warns and proceeds for a proven endpoint without a direct parser" do
    installed =
      project(
        extra_files: %{
          "lib/sample_web/endpoint.ex" => """
          defmodule SampleWeb.Endpoint do
            use Phoenix.Endpoint, otp_app: :sample
            plug SampleWeb.Router
          end
          """
        }
      )
      |> install(@args)

    assert installed.issues == []

    assert Enum.any?(
             installed.warnings,
             &String.contains?(&1, "statically proven simple pipeline")
           )

    assert Enum.any?(installed.warnings, &String.contains?(&1, "No endpoint edit is required"))
    assert Igniter.Test.diff(installed) != ""
    refute Igniter.Test.diff(installed) =~ "AttestoMCP.Server.PhoenixParser"
  end

  test "refuses unsafe or ambiguous direct parser declarations before editing" do
    endpoint_sources = [
      "plug Plug.Parsers, parsers: [:json], body_reader: {SampleWeb.Reader, :read, []}",
      "plug Plug.Parsers, parsers: [:json], json_decoder: Evil.install(__MODULE__)",
      "plug Plug.Parsers, parsers: [:json]\n  plug Plug.Session, store: SampleWeb.BodyReadingStore\n  plug SampleWeb.Router",
      "plug Plug.Static, at: \"/\", from: Evil.install(__MODULE__)\n  plug Plug.Parsers, parsers: [:json]\n  plug SampleWeb.Router",
      "plug Plug.Parsers, parsers: [:json]\n  plug SampleWeb.Router, Evil.install(__MODULE__)",
      "plug Plug.Parsers, parsers: [:json]\n  plug Plug.Parsers, parsers: [:json]",
      "plug Plug.Parsers, parsers: [:json]\n  if true do\n    plug SampleWeb.CustomParser\n  end",
      "plug Plug.Parsers, parsers: [:json]\n  plug SampleWeb.CustomBodyReader\n  plug SampleWeb.Router",
      "plug Plug.Parsers, parsers: [:json]\n  case :ok do\n    :ok -> plug SampleWeb.CustomParser\n  end\n  plug SampleWeb.Router",
      "plug Plug.Parsers, parsers: [:json]\n  if true do\n    use SampleWeb.ParserInjector\n  end\n  plug SampleWeb.Router",
      "plug Plug.Parsers, parsers: [:json]\n  if function_exported?(Evil.install(__MODULE__), :ok, 0) do\n    :ok\n  end\n  plug SampleWeb.Router",
      "@plugs {SampleWeb.CustomBodyReader, [], true}\n  plug Plug.Parsers, parsers: [:json]\n  plug SampleWeb.Router",
      "plug Plug.Parsers, parsers: [:json]\n  plug SampleWeb.Router\n  plug SampleWeb.Router",
      "plug Plug.Parsers, parsers: [:json]\n  plug SampleWeb.Router\n  plug Plug.Session, @session_options",
      "@session_options [store: SampleWeb.BodyReadingStore]\n  plug Plug.Parsers, parsers: [:json]\n  plug Plug.Session, @session_options\n  plug SampleWeb.Router",
      "plug AttestoMCP.Server.PhoenixParser, mcp_path: \"/other\", parsers: [:json]"
    ]

    for endpoint_body <- endpoint_sources do
      installed =
        project(
          extra_files: %{
            "lib/sample_web/endpoint.ex" => """
            defmodule SampleWeb.Endpoint do
              use Phoenix.Endpoint, otp_app: :sample
              #{endpoint_body}
            end
            """
          }
        )
        |> install(@args)

      assert installed.issues != [], inspect(endpoint_body)

      assert Enum.any?(
               installed.issues,
               &String.contains?(&1, "parser preflight could not establish")
             )

      assert Igniter.Test.diff(installed) == ""
    end
  end

  defp install(igniter, args), do: Igniter.compose_task(igniter, @task, args)

  defp project(options \\ []) do
    router_source = Keyword.get(options, :router_source, router_source())
    app_name = Keyword.get(options, :app_name, :sample)

    files =
      %{
        "mix.exs" =>
          mix_source(
            Keyword.get(options, :attesto_phoenix?, true),
            Keyword.get(options, :req_source),
            app_name
          ),
        "lib/sample/application.ex" => application_source(),
        "lib/sample_web/router.ex" => router_source
      }
      |> Map.merge(Keyword.get(options, :extra_files, %{}))

    Igniter.Test.test_project(app_name: app_name, files: files)
  end

  defp router_source do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router
    end
    """
  end

  defp application_source do
    """
    defmodule Sample.Application do
      use Application

      @impl true
      def start(_type, _args) do
        children = []
        Supervisor.start_link(children, strategy: :one_for_one, name: Sample.Supervisor)
      end
    end
    """
  end

  defp mix_source(attesto_phoenix?, req_source, app_name) do
    attesto = if attesto_phoenix?, do: "{:attesto_phoenix, \"~> 2.0\"},", else: ""
    req = if is_binary(req_source), do: req_source <> ",", else: ""

    """
    defmodule Sample.MixProject do
      use Mix.Project
      def project, do: [app: #{inspect(app_name)}, version: "0.1.0", deps: deps()]
      def application, do: [extra_applications: [:logger], mod: {Sample.Application, []}]
      defp deps do
        [
          {:attesto_mcp_server, "~> 0.10"},
          #{attesto}
          #{req}
        ]
      end
    end
    """
  end

  defp ecto_repo_source(module, adapter \\ "Ecto.Adapters.Postgres") do
    """
    defmodule #{module} do
      use Ecto.Repo, otp_app: :sample, adapter: #{adapter}
    end
    """
  end

  defp dynamic_ecto_repo_source(module) do
    """
    defmodule #{module} do
      @adapter Ecto.Adapters.Postgres
      use Ecto.Repo, otp_app: :sample, adapter: @adapter
    end
    """
  end

  defp ash_postgres_repo_source(module, options \\ "otp_app: :sample") do
    """
    defmodule #{module} do
      use AshPostgres.Repo, #{options}
    end
    """
  end

  defp application_with_repo_source do
    application_with_children_source(["Sample.Repo"])
  end

  defp application_with_children_source(children) do
    children = Enum.join(children, ", ")

    """
    defmodule Sample.Application do
      use Application

      @impl true
      def start(_type, _args) do
        children = [#{children}]
        Supervisor.start_link(children, strategy: :one_for_one, name: Sample.Supervisor)
      end
    end
    """
  end

  defp admin_router_source do
    """
    defmodule SampleWeb.AdminRouter do
      use SampleWeb, :router
    end
    """
  end

  defp byte_offset(text, pattern) do
    case :binary.match(text, pattern) do
      {offset, _length} -> offset
      :nomatch -> raise "expected #{inspect(pattern)} in #{inspect(text)}"
    end
  end

  defp generated_session_namespace(app, server_module) do
    server_module =
      if is_binary(server_module),
        do: server_module |> String.split(".") |> Module.concat(),
        else: server_module

    module_name = server_module |> Module.split() |> Enum.map_join("-", &Macro.underscore/1)
    module_name = String.replace_prefix(module_name, "#{app}-", "")
    readable_prefix = "#{app}-#{module_name}"
    digest = :crypto.hash(:sha256, :erlang.term_to_binary({app, server_module}))
    digest = Base.url_encode64(digest, padding: false)
    namespace = "#{readable_prefix}-#{digest}"

    if byte_size(namespace) <= 256, do: namespace, else: "mcp-#{digest}"
  end
end
