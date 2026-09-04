defmodule Mix.Tasks.AttestoMcpServer.Gen.Migration do
  @shortdoc "Generates Ecto migrations backing AttestoMCP.Server.SessionStore.Ecto and AttestoMCP.Server.UrlElicitationStore.Ecto"

  @moduledoc """
  Generates the Ecto migrations backing
  `AttestoMCP.Server.SessionStore.Ecto` and
  `AttestoMCP.Server.UrlElicitationStore.Ecto`.

  The generated migrations create two PostgreSQL tables:
  `attesto_mcp_sessions` and `attesto_mcp_url_elicitations`. Rows are keyed by
  the namespace and an identifier so several independently named MCP servers
  can safely share a repository.

  The `attesto_mcp_sessions` table stores complete versioned session records as
  JSONB in `record`; `created_at_ms`, `last_seen_ms`, `absolute_timeout_ms`, and
  `idle_timeout_ms` mirror the record for validation, while `expires_at_ms` is a
  denormalized value used for bounded SQL-side expiry filtering and cleanup.

  The `attesto_mcp_url_elicitations` table stores staged approval records with
  their action, JSONB fields, timestamps, and optional consumed timestamp for
  atomic single-use verification.

  This task only writes migration files. It never invokes `Ecto.Migrator` or
  changes the database. Apply the files from the host application's normal
  migration workflow.

  ## Usage

      mix attesto_mcp_server.gen.migration --repo MyApp.Repo

  ## Options

    * `--repo` - the Ecto repo the migrations are generated for. It may be
      supplied more than once when several repos intentionally share the
      same application package. When omitted, configured Ecto repos are
      discovered using `Mix.Ecto`, and none or an ambiguous set is rejected.
    * `--schema-prefix` - an optional validated PostgreSQL schema used as
      Ecto's `prefix:` for every table and index. The schema is created with
      `CREATE SCHEMA IF NOT EXISTS` by the migration and is left in place on
      rollback. Table names are fixed because the runtime schemas query
      `attesto_mcp_sessions` and `attesto_mcp_url_elicitations`.
    * `--migrations-path` - directory in which migrations are written. It
      defaults to the repo's `priv/<repo>/migrations` directory. An explicit
      path may only be used with one repo so generation cannot partially
      write competing migrations into the same directory.

  Each migration file is skipped when a file with that base name already exists
  in the path. An existing host that reruns the task therefore receives only the
  new file.
  """

  use Mix.Task

  import Mix.Generator

  @sessions_table_name "attesto_mcp_sessions"
  @sessions_base_name "create_attesto_mcp_sessions"
  @url_elicitations_table_name "attesto_mcp_url_elicitations"
  @url_elicitations_base_name "create_attesto_mcp_url_elicitations"
  @max_schema_prefix_bytes 63
  @max_key_bytes 256

  @switches [
    repo: [:keep],
    schema_prefix: :string,
    migrations_path: :string
  ]

  @impl Mix.Task
  def run(args) do
    ensure_ecto!()

    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)
    reject_empty_repo_args!(args)
    reject_invalid_args!(positional, invalid)
    reject_duplicate_options!(args)

    prefix = Keyword.get(opts, :schema_prefix)
    validate_schema_prefix!(prefix)

    repos =
      args
      |> normalize_repo_args()
      |> parse_repos()
      |> resolve_repos!(args)

    reject_shared_explicit_path!(repos, opts)

    # Load and validate every repo before any path is derived from it: the
    # default migrations path reads the repo's configuration, and the repo
    # module of a host application is not loaded until Mix.Ecto ensures it.
    # Validating every target first also means a later invalid repo cannot
    # leave an earlier one with a half-applied generation run.
    Enum.each(repos, &ensure_repo!/1)
    reject_duplicate_target_paths!(repos, opts)

    plans = Enum.flat_map(repos, &prepare_migrations(&1, opts, prefix))
    Enum.each(plans, &write_migration/1)
  end

  defp ensure_repo!(repo) do
    apply(Mix.Ecto, :ensure_repo, [repo, []])
    ensure_postgres_repo!(repo)
  end

  defp resolve_repos!([], _args) do
    Mix.raise("""
    no Ecto repos available.

    Pass one explicitly with --repo, for example:

        mix attesto_mcp_server.gen.migration --repo MyApp.Repo

    or configure :ecto_repos for your application.
    """)
  end

  defp resolve_repos!(repos, args) do
    if explicit_repos?(args) do
      Enum.uniq(repos)
    else
      case Enum.uniq(repos) do
        [repo] ->
          [repo]

        repos ->
          Mix.raise(
            "ambiguous Ecto repos #{inspect(repos)}; pass exactly one " <>
              "explicit --repo to select the migration target"
          )
      end
    end
  end

  defp explicit_repos?(args),
    do:
      Enum.any?(
        args,
        &(&1 == "--repo" or (is_binary(&1) and String.starts_with?(&1, "--repo=")))
      )

  defp reject_shared_explicit_path!(repos, opts) do
    if length(repos) > 1 and Keyword.has_key?(opts, :migrations_path) do
      Mix.raise(
        "ambiguous --migrations-path with multiple Ecto repos; generate each repo " <>
          "separately or let each repo select its own migrations directory"
      )
    end
  end

  defp normalize_repo_args(args) do
    Enum.flat_map(args, fn
      "--repo=" <> repo -> ["--repo", repo]
      arg -> [arg]
    end)
  end

  defp reject_empty_repo_args!(args) do
    args
    |> Enum.with_index()
    |> Enum.any?(fn
      {"--repo=", _index} ->
        true

      {"--repo", index} ->
        case Enum.at(args, index + 1) do
          nil ->
            true

          "" ->
            true

          next when is_binary(next) ->
            String.starts_with?(next, "-")

          _other ->
            false
        end

      _other ->
        false
    end)
    |> case do
      true -> Mix.raise("invalid --repo: expected a non-empty Ecto repo module")
      false -> :ok
    end
  end

  defp reject_invalid_args!([], []), do: :ok

  defp reject_invalid_args!(positional, invalid) do
    Mix.raise(
      "invalid migration-generator arguments; use --repo RepoModule and " <>
        "--schema-prefix schema. Unexpected positional arguments: " <>
        "#{inspect(positional)}; invalid options: #{inspect(invalid)}"
    )
  end

  defp reject_duplicate_options!(args) do
    for option <- ["--schema-prefix", "--migrations-path"] do
      count =
        Enum.count(
          args,
          &(&1 == option or (is_binary(&1) and String.starts_with?(&1, option <> "=")))
        )

      if count > 1 do
        Mix.raise("ambiguous migration-generator arguments: #{option} may be supplied only once")
      end
    end
  end

  defp validate_schema_prefix!(nil), do: :ok

  defp validate_schema_prefix!(prefix) when is_binary(prefix) do
    cond do
      prefix == "" ->
        Mix.raise(
          "invalid --schema-prefix: expected a non-empty lowercase PostgreSQL schema identifier"
        )

      not String.valid?(prefix) ->
        Mix.raise("invalid --schema-prefix: expected valid UTF-8")

      byte_size(prefix) > @max_schema_prefix_bytes ->
        Mix.raise("invalid --schema-prefix: expected at most 63 bytes")

      prefix == "information_schema" or String.starts_with?(prefix, "pg_") ->
        Mix.raise(
          "invalid --schema-prefix: #{inspect(prefix)} is a reserved PostgreSQL " <>
            "system schema; choose an application-owned schema"
        )

      Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, prefix) ->
        :ok

      true ->
        Mix.raise("invalid --schema-prefix: expected a lowercase PostgreSQL schema identifier")
    end
  end

  defp validate_schema_prefix!(_prefix) do
    Mix.raise("invalid --schema-prefix: expected nil or a lowercase PostgreSQL schema identifier")
  end

  defp prepare_migrations(repo, opts, prefix) do
    path = migrations_path(repo, opts)
    validate_migrations_path!(path)
    path = Path.expand(path)

    sessions_exists? = Path.wildcard(Path.join(path, "*_#{@sessions_base_name}.exs")) != []

    url_elicitations_exists? =
      Path.wildcard(Path.join(path, "*_#{@url_elicitations_base_name}.exs")) != []

    items =
      case {sessions_exists?, url_elicitations_exists?} do
        {false, false} ->
          [{:sessions, 0}, {:url_elicitations, 1}]

        {false, true} ->
          [{:sessions, 0}]

        {true, false} ->
          [{:url_elicitations, 0}]

        {true, true} ->
          []
      end

    Enum.map(items, fn
      {:sessions, offset} ->
        file = Path.join(path, "#{timestamp(offset)}_#{@sessions_base_name}.exs")

        assigns = [
          module: migration_module(repo, @sessions_base_name),
          prefix: prefix,
          table_name: @sessions_table_name,
          key_size: @max_key_bytes
        ]

        source =
          assigns
          |> migration_template()
          |> Code.format_string!()
          |> IO.iodata_to_binary()

        %{path: path, file: file, source: source}

      {:url_elicitations, offset} ->
        file = Path.join(path, "#{timestamp(offset)}_#{@url_elicitations_base_name}.exs")

        assigns = [
          module: migration_module(repo, @url_elicitations_base_name),
          prefix: prefix,
          table_name: @url_elicitations_table_name,
          key_size: @max_key_bytes
        ]

        source =
          assigns
          |> url_elicitation_migration_template()
          |> Code.format_string!()
          |> IO.iodata_to_binary()

        %{path: path, file: file, source: source}
    end)
  end

  defp reject_duplicate_target_paths!(repos, opts) do
    duplicate_paths =
      repos
      |> Enum.map(&Path.expand(migrations_path(&1, opts)))
      |> Enum.group_by(& &1)
      |> Enum.filter(fn {_path, repos_for_path} -> length(repos_for_path) > 1 end)
      |> Enum.map(&elem(&1, 0))

    if duplicate_paths != [] do
      Mix.raise(
        "ambiguous migration targets: multiple repos resolve to " <>
          "the same migration directory #{inspect(duplicate_paths)}"
      )
    end
  end

  defp write_migration(%{path: path, file: file, source: source}) do
    create_directory(path)
    create_file(file, source)
  end

  defp ensure_ecto!() do
    sql_modules = [Mix.Ecto, Mix.EctoSQL, Ecto.Migration, Ecto.Adapters.Postgres]

    unless Enum.all?(sql_modules, &Code.ensure_loaded?/1) do
      Mix.raise("""
      The task 'attesto_mcp_server.gen.migration' requires Ecto SQL.

      Add {:ecto_sql, "~> 3.10"} (and a driver such as :postgrex) to the
      host application, run `mix deps.get`, then re-run this task.
      """)
    end
  end

  defp parse_repos(args), do: apply(Mix.Ecto, :parse_repo, [args])

  defp ensure_postgres_repo!(repo) do
    adapter =
      try do
        repo.__adapter__()
      rescue
        _exception -> nil
      catch
        _kind, _reason -> nil
      end

    unless adapter == Ecto.Adapters.Postgres do
      Mix.raise(
        "Ecto Repo #{inspect(repo)} does not use Ecto.Adapters.Postgres; " <>
          "the bundled session store and generated migration support PostgreSQL only"
      )
    end
  end

  defp migrations_path(repo, opts) do
    case Keyword.fetch(opts, :migrations_path) do
      {:ok, path} -> path
      :error -> default_migrations_path(repo)
    end
  end

  defp validate_migrations_path!(path) when is_binary(path) do
    if path == "" or String.contains?(path, <<0>>) do
      Mix.raise("invalid --migrations-path: expected a non-empty path without NUL bytes")
    end
  end

  defp validate_migrations_path!(_path),
    do: Mix.raise("invalid --migrations-path: expected a filesystem path")

  defp default_migrations_path(repo) do
    case Code.ensure_loaded(Mix.EctoSQL) do
      {:module, module} ->
        if function_exported?(module, :source_repo_priv, 1) do
          module
          |> apply(:source_repo_priv, [repo])
          |> Path.join("migrations")
        else
          legacy_default_migrations_path(repo)
        end

      _not_available ->
        legacy_default_migrations_path(repo)
    end
  end

  defp legacy_default_migrations_path(repo) do
    config = repo.config()

    priv =
      config[:priv] || "priv/#{repo |> Module.split() |> List.last() |> Macro.underscore()}"

    root =
      case config[:otp_app] do
        app when is_atom(app) -> Map.get(Mix.Project.deps_paths(), app, File.cwd!())
        _missing_otp_app -> File.cwd!()
      end

    Path.join([root, priv, "migrations"])
  end

  defp migration_module(repo, base_name),
    do: Module.concat([repo, Migrations, Macro.camelize(base_name)])

  defp timestamp(offset_seconds) do
    now =
      :calendar.universal_time()
      |> :calendar.datetime_to_gregorian_seconds()

    {{year, month, day}, {hour, minute, second}} =
      :calendar.gregorian_seconds_to_datetime(now + offset_seconds)

    [year, month, day, hour, minute, second]
    |> Enum.map_join(&pad/1)
  end

  defp pad(value) when value < 10, do: "0" <> Integer.to_string(value)
  defp pad(value), do: Integer.to_string(value)

  embed_template(:migration, """
  defmodule <%= inspect @module %> do
    @moduledoc false

    # Generated by `mix attesto_mcp_server.gen.migration`.
    #
    # Backs AttestoMCP.Server.SessionStore.Ecto. The complete versioned
    # session record lives in JSONB; expiry values are denormalized so list
    # and cleanup queries remain bounded and SQL-side.

    use Ecto.Migration

    def up do
      prefix = <%= inspect @prefix %>

      # A non-default runtime prefix is a PostgreSQL schema. Create it when
      # needed, but leave it in place on rollback because it may be shared by
      # other host-application tables and migrations.
      <%= if @prefix do %>
      execute(~s|CREATE SCHEMA IF NOT EXISTS "\#{prefix}"|)
      <% end %>

      create table(:<%= @table_name %>, primary_key: false, prefix: prefix) do
        # The namespace is part of the key: independent named MCP servers
        # may share this table without colliding on a session id.
        add :namespace, :string, size: <%= @key_size %>, primary_key: true, null: false
        add :session_id, :string, size: <%= @key_size %>, primary_key: true, null: false

        # JSONB (`:map`) holds the complete versioned record, including
        # format_version and any future fields unknown to this release.
        add :record, :map, null: false

        # These values mirror the versioned record's bounded expiry fields.
        # Millisecond timestamps can exceed a 32-bit integer, so use bigint.
        add :created_at_ms, :bigint, null: false
        add :last_seen_ms, :bigint, null: false
        add :absolute_timeout_ms, :bigint, null: false
        add :idle_timeout_ms, :bigint, null: false

        # This value is the record's next expiry, denormalized so active and
        # cleanup queries can use one indexed column. The record remains
        # authoritative.
        add :expires_at_ms, :bigint, null: false

        timestamps(type: :utc_datetime_usec)
      end

      # List and cleanup operations stay inside one store-bound namespace.
      # Keep the namespace and expiration deadline together for those
      # bounded SQL-side scans. The primary key supports session lookup.
      create index(:<%= @table_name %>, [:namespace, :expires_at_ms, :session_id],
               prefix: prefix
             )
    end

    def down do
      prefix = <%= inspect @prefix %>
      drop table(:<%= @table_name %>, prefix: prefix)
    end
  end
  """)

  embed_template(:url_elicitation_migration, """
  defmodule <%= inspect @module %> do
    @moduledoc false

    # Generated by `mix attesto_mcp_server.gen.migration`.
    #
    # Backs AttestoMCP.Server.UrlElicitationStore.Ecto.

    use Ecto.Migration

    def up do
      prefix = <%= inspect @prefix %>

      # A non-default runtime prefix is a PostgreSQL schema. Create it when
      # needed, but leave it in place on rollback because it may be shared by
      # other host-application tables and migrations.
      <%= if @prefix do %>
      execute(~s|CREATE SCHEMA IF NOT EXISTS "\#{prefix}"|)
      <% end %>

      create table(:<%= @table_name %>, primary_key: false, prefix: prefix) do
        add :namespace, :string, size: <%= @key_size %>, primary_key: true, null: false
        add :id, :string, size: <%= @key_size %>, primary_key: true, null: false
        add :subject_hash, :string, size: 64, null: false
        add :action, :string, size: <%= @key_size %>, null: false
        add :fields, :map, null: false
        add :created_at_ms, :bigint, null: false
        add :expires_at_ms, :bigint, null: false
        add :consumed_at_ms, :bigint

        timestamps(type: :utc_datetime_usec)
      end

      create index(:<%= @table_name %>, [:namespace, :expires_at_ms, :consumed_at_ms], prefix: prefix)
    end

    def down do
      prefix = <%= inspect @prefix %>
      drop table(:<%= @table_name %>, prefix: prefix)
    end
  end
  """)
end
