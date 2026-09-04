defmodule Mix.Tasks.AttestoMcpServer.Install do
  use Igniter.Mix.Task

  @shortdoc Mix.Tasks.AttestoMcpServer.Install.Docs.short_doc()
  @moduledoc Mix.Tasks.AttestoMcpServer.Install.Docs.long_doc()
  @example Mix.Tasks.AttestoMcpServer.Install.Docs.example()
  @origin_pattern ~r/\A(https?):\/\/(\[[0-9a-f:.]+\]|[a-z0-9.-]+)(?::([0-9]{1,5}))?\/?\z/i
  @attesto_phoenix_requirement ">= 2.14.1 and < 4.0.0"
  @req_requirement ">= 0.6.1 and < 1.0.0"
  @max_version_component 99_999_999_999_999
  @max_session_namespace_bytes 256
  @requirement_atom_pattern ~r/\A\s*(?<operator>~>|>=|<=|>|<|==)?\s*(?<major>[0-9]+)(?:\.(?<minor>[0-9]+))?(?:\.(?<patch>[0-9]+))?(?<suffix>[+-].*)?\s*\z/
  @static_path_pattern ~r/\A\/(?:[A-Za-z0-9._~-]+(?:\/[A-Za-z0-9._~-]+)*)?\z/
  @safe_dependency_options [:override, :runtime, :optional, :app, :hex, :manager, :env]
  @definition_kinds [:def, :defp, :defmacro, :defmacrop, :defdelegate, :defguard, :defguardp]
  @typespec_attributes [
    :spec,
    :type,
    :typep,
    :opaque,
    :callback,
    :macrocallback
  ]
  @unsafe_compile_attributes [
    :before_compile,
    :after_compile,
    :on_definition,
    :compile,
    :on_load,
    :after_verify,
    :derive
  ]
  @unsafe_router_route_attributes [
    :phoenix_routes,
    :phoenix_pipeline,
    :phoenix_scopes,
    :phoenix_router,
    :phoenix_helpers,
    :routes,
    :pipeline,
    :plugs
  ]
  @router_dsl_signatures for name <- [:scope, :forward], arity <- 2..4, do: {name, arity}
  @router_dsl_definition_names [
    :scope,
    :forward,
    :pipeline,
    :pipe_through,
    :plug,
    :socket,
    :live,
    :live_dashboard,
    :live_session,
    :resources,
    :get,
    :post,
    :put,
    :patch,
    :delete,
    :options,
    :connect,
    :trace,
    :head,
    :match
  ]
  @http_route_names [:get, :post, :put, :patch, :delete, :options, :connect, :trace, :head]
  @dependency_source_options [
    :git,
    :github,
    :path,
    :in_umbrella,
    :repo,
    :organization,
    :branch,
    :tag,
    :ref,
    :submodules,
    :sparse,
    :subdir,
    :depth
  ]

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{
      group: :attesto_mcp_server,
      example: @example,
      schema: [
        base_url: :string,
        mcp_path: :string,
        server_module: :string,
        router: :string,
        attesto_config: :string,
        reuse_metadata_route: :boolean,
        enable_cimd: :boolean,
        session_store: :string,
        repo: :string,
        schema_prefix: :string,
        allow_http_loopback: :boolean
      ],
      defaults: [
        mcp_path: "/mcp",
        reuse_metadata_route: false,
        enable_cimd: false,
        allow_http_loopback: false
      ],
      required: [:base_url]
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    options = igniter.args.options
    app = Igniter.Project.Application.app_name(igniter)

    with {:ok, path} <- validate_path(options[:mcp_path]),
         {:ok, base_url} <-
           validate_base_url(options[:base_url], options[:allow_http_loopback]),
         {:ok, server_module} <-
           module_option(options[:server_module], default_server_module(igniter)),
         {:ok, igniter, session_config} <-
           session_store_configuration(igniter, options, app, server_module),
         {:ok, auth_source} <- auth_source(igniter, options[:attesto_config], app),
         :ok <- validate_cimd_source(auth_source, options[:enable_cimd] == true),
         :ok <-
           validate_metadata_reuse_source(
             auth_source,
             options[:reuse_metadata_route] == true,
             server_module,
             path,
             base_url
           ),
         {:ok, auth_dependencies} <-
           authorization_dependencies(igniter, auth_source, options[:enable_cimd] == true),
         {:ok, igniter, router} <-
           router_for_install(
             igniter,
             options[:router],
             options[:reuse_metadata_route] == true,
             server_module,
             path,
             base_url,
             auth_source
           ),
         metadata_mode <-
           if(options[:reuse_metadata_route] == true, do: :reuse, else: :generate),
         {:ok, igniter} <-
           routes_available(
             igniter,
             router,
             server_module,
             path,
             base_url,
             auth_source,
             metadata_mode
           ) do
      igniter =
        create_server_module(
          igniter,
          server_module,
          app,
          auth_source,
          metadata_mode
        )

      if igniter.issues == [] do
        igniter
        |> configure_authorization_server(
          app,
          auth_source,
          auth_dependencies,
          options[:enable_cimd] == true
        )
        |> configure_server(app, server_module, session_config)
        |> add_server_child(server_module, session_config)
        |> add_routes(router, server_module, path, base_url, auth_source, metadata_mode)
        |> create_starter_test(server_module)
        |> add_notices(auth_source, path, base_url, metadata_mode, router, session_config)
      else
        igniter
      end
    else
      {:error, message} -> Igniter.add_issue(igniter, message)
      {:error, failed_igniter, message} -> Igniter.add_issue(failed_igniter, message)
    end
  end

  defp default_server_module(igniter),
    do: Igniter.Project.Module.module_name(igniter, "MCP")

  defp module_option(nil, default), do: {:ok, default}

  defp module_option(value, _default) when is_binary(value) do
    if Regex.match?(~r/\A(?:Elixir\.)?[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*\z/, value) do
      {:ok, value |> String.replace_prefix("Elixir.", "") |> Igniter.Project.Module.parse()}
    else
      {:error, "module options must use a fully qualified Elixir module name"}
    end
  end

  defp module_option(_value, _default),
    do: {:error, "module options must use a fully qualified Elixir module name"}

  # 2025-era session-bound MCP requests default to the private ETS store when
  # no host Repo is available. Phoenix applications with one statically
  # confirmed PostgreSQL Repo get the bundled Ecto adapter automatically;
  # multiple Repos are never guessed because that would make the generated
  # migration instructions disagree with runtime. If the sole Repo cannot be
  # proven to use PostgreSQL, automatic selection stays on private ETS; an
  # explicit Ecto choice remains fail-closed. This also keeps known
  # non-PostgreSQL Repos from breaking the default installer path.
  defp session_store_configuration(igniter, options, app, server_module) do
    with {:ok, requested} <- normalize_session_store(options[:session_store]),
         {:ok, schema_prefix} <- session_schema_prefix(options[:schema_prefix]),
         {:ok, repo_option} <- module_option(options[:repo], nil),
         {:ok, igniter, existing} <- configured_session_store(igniter, app, server_module) do
      case existing do
        :none ->
          case {requested, repo_option, schema_prefix} do
            {:ets, nil, nil} ->
              {:ok, igniter, %{mode: :ets, requested: :ets}}

            {:ets, _repo, _prefix} ->
              {:error,
               "--repo and --schema-prefix require an Ecto session store; remove them or omit --session-store ets"}

            {_mode, repo, prefix} ->
              select_session_repo(igniter, requested, repo, prefix, app, server_module)
          end

        %{mode: :ecto} = existing ->
          existing_ecto_session_config(
            igniter,
            existing,
            requested,
            repo_option,
            schema_prefix,
            app,
            server_module
          )

        %{mode: :ets} = existing ->
          if requested in [:auto, :ets] and is_nil(repo_option) and is_nil(schema_prefix) do
            {:ok, igniter, existing}
          else
            {:error,
             "the host already configures an ETS session store; remove that session_store setting before selecting Ecto"}
          end

        %{mode: :custom} ->
          if requested == :auto and is_nil(repo_option) and is_nil(schema_prefix) do
            {:ok, igniter, existing}
          else
            {:error,
             "the host already configures a custom session store; remove that session_store setting before selecting another backend"}
          end
      end
    end
  end

  defp normalize_session_store(nil), do: {:ok, :auto}
  defp normalize_session_store("auto"), do: {:ok, :auto}
  defp normalize_session_store("ecto"), do: {:ok, :ecto}
  defp normalize_session_store("ets"), do: {:ok, :ets}

  defp normalize_session_store(_value),
    do: {:error, "--session-store must be one of: auto, ecto, ets"}

  defp session_schema_prefix(nil), do: {:ok, nil}

  defp session_schema_prefix(prefix) when is_binary(prefix) do
    cond do
      prefix == "" ->
        {:error,
         "invalid --schema-prefix: expected a non-empty lowercase PostgreSQL schema identifier"}

      not String.valid?(prefix) ->
        {:error, "invalid --schema-prefix: expected valid UTF-8"}

      byte_size(prefix) > 63 ->
        {:error, "invalid --schema-prefix: expected at most 63 bytes"}

      prefix == "information_schema" or String.starts_with?(prefix, "pg_") ->
        {:error,
         "invalid --schema-prefix: #{inspect(prefix)} is a reserved PostgreSQL system schema"}

      Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, prefix) ->
        {:ok, prefix}

      true ->
        {:error, "invalid --schema-prefix: expected a lowercase PostgreSQL schema identifier"}
    end
  end

  defp session_schema_prefix(_value),
    do: {:error, "invalid --schema-prefix: expected a lowercase PostgreSQL schema identifier"}

  defp select_session_repo(igniter, requested, repo, schema_prefix, app, server_module) do
    {igniter, repos} = project_ecto_repos(igniter)
    repos = Enum.sort_by(repos, &inspect/1)
    supervised_repos = supervised_project_repos(igniter, repos)
    selectable_repos = if is_nil(repo), do: supervised_repos, else: repos

    cond do
      not is_nil(repo) and repo in repos and repo not in supervised_repos ->
        unsupervised_repo_result(igniter, requested, schema_prefix, repo)

      not is_nil(repo) and repo in repos ->
        case select_postgres_session_repo(
               igniter,
               repo,
               schema_prefix,
               app,
               server_module,
               requested
             ) do
          {:unverified, failed_igniter, message} ->
            {:error, failed_igniter, message}

          {:unsupported, failed_igniter, message} ->
            {:error, failed_igniter, message}

          result ->
            result
        end

      not is_nil(repo) ->
        {:error,
         "Ecto Repo #{inspect(repo)} was not found; pass --repo for an existing Repo module"}

      is_nil(repo) and length(repos) > 1 ->
        names = Enum.map_join(repos, ", ", &inspect/1)
        {:error, "multiple Ecto Repos were found (#{names}); choose one with --repo"}

      length(repos) == 1 and supervised_repos == [] and
          (requested == :ecto or not is_nil(schema_prefix)) ->
        {:error, unsupervised_repo_message(List.first(repos))}

      requested == :ecto and selectable_repos == [] ->
        {:error, "--session-store ecto requires an existing Ecto Repo; pass --repo RepoModule"}

      requested == :auto and is_nil(schema_prefix) and length(repos) == 1 and
          supervised_repos == [] ->
        {:ok, igniter,
         %{
           mode: :ets,
           requested: :auto,
           fallback: :repo_not_statically_supervised,
           repo: List.first(repos)
         }}

      length(selectable_repos) == 1 ->
        repo = List.first(selectable_repos)

        case select_postgres_session_repo(
               igniter,
               repo,
               schema_prefix,
               app,
               server_module,
               requested
             ) do
          {:unverified, failed_igniter, _message}
          when requested == :auto and is_nil(schema_prefix) ->
            {:ok, failed_igniter,
             %{mode: :ets, requested: :auto, fallback: :unverified_repo, repo: repo}}

          {:unsupported, failed_igniter, _message}
          when requested == :auto and is_nil(schema_prefix) ->
            {:ok, failed_igniter,
             %{mode: :ets, requested: :auto, fallback: :unsupported_repo, repo: repo}}

          {:unverified, failed_igniter, message} ->
            {:error, failed_igniter, message}

          {:unsupported, failed_igniter, message} ->
            {:error, failed_igniter, message}

          result ->
            result
        end

      length(selectable_repos) > 1 ->
        names = Enum.map_join(selectable_repos, ", ", &inspect/1)
        {:error, "multiple Ecto Repos were found (#{names}); choose one with --repo"}

      not is_nil(schema_prefix) ->
        {:error, "--schema-prefix requires an existing Ecto Repo; pass --repo RepoModule"}

      true ->
        {:ok, igniter, %{mode: :ets, requested: :auto}}
    end
  end

  defp unsupervised_repo_result(_igniter, :auto, nil, repo) do
    {:error, unsupervised_repo_message(repo)}
  end

  defp unsupervised_repo_result(_igniter, _requested, _schema_prefix, repo),
    do: {:error, unsupervised_repo_message(repo)}

  defp unsupervised_repo_message(repo) do
    "Ecto Repo #{inspect(repo)} exists but could not be statically confirmed as supervised by the application. Add #{inspect(repo)} as a literal supervised application child or choose `--session-store ets`; the installer will not configure the Ecto session store until the Repo is proven supervised."
  end

  defp select_postgres_session_repo(
         igniter,
         repo,
         schema_prefix,
         app,
         server_module,
         requested
       ) do
    case find_project_module_source(igniter, repo) do
      {:ok, {igniter, _source, module_ast}} ->
        case postgres_repo_status(module_ast) do
          :postgres ->
            {:ok, igniter,
             ecto_session_config(repo, schema_prefix, app, server_module, requested)}

          :unsupported ->
            {:unsupported, igniter,
             "Ecto Repo #{inspect(repo)} is not statically configured with Ecto.Adapters.Postgres; the bundled durable session store supports PostgreSQL only. Select a PostgreSQL Repo or use --session-store ets"}

          :unverified ->
            {:unverified, igniter,
             "Ecto Repo #{inspect(repo)} could not be statically confirmed as PostgreSQL; the bundled durable session store supports PostgreSQL only. Select a statically proven PostgreSQL Repo or use --session-store ets"}
        end

      {:error, igniter} ->
        {:unverified, igniter,
         "Ecto Repo #{inspect(repo)} could not be inspected; select an inspectable PostgreSQL Repo or use --session-store ets"}
    end
  end

  # Repo selection is source-only. `Igniter.Project.Module.find_module/2` may
  # consult a compiled module before searching the project, which is not
  # appropriate for an installer that must never trigger host `@on_load`
  # callbacks merely to inspect an adapter declaration.
  defp find_project_module_source(igniter, module) do
    {igniter, sources} = project_lib_sources(igniter)

    sources
    |> Enum.reduce_while({:error, igniter}, fn source, not_found ->
      result =
        try do
          source
          |> Rewrite.Source.get(:quoted)
          |> find_module_ast(module)
        rescue
          _exception -> :error
        catch
          _kind, _reason -> :error
        end

      case result do
        {:ok, module_ast} -> {:halt, {:ok, {igniter, source, module_ast}}}
        :error -> {:cont, not_found}
      end
    end)
  end

  # Walk source AST directly so a nested declaration such as
  # `defmodule MyApp do; defmodule Repo do ... end; end` is resolved as
  # `MyApp.Repo`. This is deliberately a data-only walk: host modules are
  # never loaded or evaluated while the installer inspects adapter settings.
  defp find_module_ast(ast, module), do: find_module_ast(ast, module, [])

  defp find_module_ast({:defmodule, _meta, [module_ast, options]} = node, module, prefix)
       when is_list(options) do
    current = literal_module_ast(module_ast)
    full_module = nested_module_name(prefix, current)

    cond do
      full_module == module ->
        {:ok, node}

      is_nil(current) ->
        :error

      true ->
        case keyword_value(options, :do) do
          {:ok, body} -> find_module_ast(body, module, full_module)
          :error -> :error
        end
    end
  end

  defp find_module_ast({form, _meta, args}, module, prefix) when is_atom(form) and is_list(args),
    do: find_module_ast(args, module, prefix)

  defp find_module_ast(list, module, prefix) when is_list(list) do
    Enum.find_value(list, :error, fn child -> find_module_ast(child, module, prefix) end)
  end

  defp find_module_ast(_other, _module, _prefix), do: :error

  defp nested_module_name(_prefix, nil), do: nil
  defp nested_module_name([], module), do: module
  defp nested_module_name(prefix, module), do: Module.concat(prefix, module)

  defp application_children({:defmodule, _meta, [_module_ast, options]}) when is_list(options) do
    with {:ok, body} <- keyword_value(options, :do),
         {:ok, {start_body, aliases}} <- application_start_body(body),
         {:ok, children} <- application_supervised_children(start_body, aliases) do
      literal_child_modules(children, aliases)
    else
      _other -> []
    end
  end

  defp application_children(_module_ast), do: []

  defp application_start_body(body) do
    body
    |> top_level_alias_contexts()
    |> Enum.find_value(:error, fn
      {{:def, _meta, [{:start, _head_meta, arguments}, options]}, aliases}
      when is_list(arguments) and length(arguments) == 2 and is_list(options) ->
        case keyword_value(options, :do) do
          {:ok, start_body} -> {:ok, {start_body, aliases}}
          :error -> false
        end

      _other ->
        false
    end)
  end

  defp application_supervised_children(start_body, aliases) do
    calls =
      start_body
      |> top_level_expressions()
      |> Enum.with_index()
      |> Enum.flat_map(fn {expression, index} ->
        case supervisor_start_call_args(expression, aliases) do
          {:ok, arguments} -> [{index, arguments}]
          :error -> []
        end
      end)

    case calls do
      [{call_index, [children | _rest]}] ->
        application_children_argument(start_body, call_index, children)

      _ambiguous_or_missing ->
        :error
    end
  end

  defp supervisor_start_call_args(
         {{:., _dot_meta, [module_ast, function]}, _call_meta, arguments},
         aliases
       )
       when function in [:start_link, :start_supervisor] and is_list(arguments) and
              arguments != [] do
    if canonical_ast(module_ast, aliases) == Supervisor, do: {:ok, arguments}, else: :error
  end

  defp supervisor_start_call_args(_expression, _aliases), do: :error

  defp application_children_argument(start_body, call_index, {name, _meta, nil})
       when is_atom(name) do
    expressions = top_level_expressions(start_body)

    assignments =
      expressions
      |> Enum.with_index()
      |> Enum.flat_map(fn {expression, index} ->
        case direct_variable_assignment(expression, name) do
          {:ok, children} -> [{index, children}]
          :error -> []
        end
      end)

    assignment_count =
      Enum.reduce(expressions, 0, fn expression, count ->
        count + count_variable_assignments(expression, name)
      end)

    case assignments do
      [{assignment_index, children}]
      when assignment_index < call_index and assignment_count == 1 ->
        {:ok, children}

      _ambiguous_or_missing ->
        :error
    end
  end

  defp application_children_argument(_start_body, _call_index, children)
       when is_list(children),
       do: {:ok, children}

  defp application_children_argument(
         _start_body,
         _call_index,
         {:__block__, _meta, [children]} = wrapped
       ) do
    if is_list(children), do: {:ok, wrapped}, else: :error
  end

  defp application_children_argument(_start_body, _call_index, _children), do: :error

  defp direct_variable_assignment({:=, _meta, [{name, _var_meta, nil}, children]}, name),
    do: {:ok, children}

  defp direct_variable_assignment(_expression, _name), do: :error

  defp count_variable_assignments(ast, name) do
    {_ast, count} =
      Macro.prewalk(ast, 0, fn
        {:=, _meta, [{candidate, _var_meta, nil}, _children]} = node, count
        when candidate == name ->
          {node, count + 1}

        node, count ->
          {node, count}
      end)

    count
  end

  defp literal_child_modules(children, aliases) when is_list(children) do
    Enum.flat_map(children, fn
      {:__block__, _meta, [child]} ->
        literal_child_modules(child, aliases)

      {:__aliases__, _meta, _parts} = module_ast ->
        case canonical_ast(module_ast, aliases) do
          module when is_atom(module) -> [module]
          _other -> []
        end

      {:{}, _meta, [module_ast, options]} ->
        literal_child_spec_module(module_ast, options, aliases)

      {module_ast, options} ->
        literal_child_spec_module(module_ast, options, aliases)

      module when is_atom(module) ->
        [module]

      _other ->
        []
    end)
  end

  defp literal_child_modules({:__block__, _meta, [children]}, aliases),
    do: literal_child_modules(children, aliases)

  # Sourceror represents a literal two-tuple directly as `{module_ast,
  # options}`; the regular quoted AST uses a `:{}` node instead.
  defp literal_child_modules({module_ast, options}, aliases),
    do: literal_child_spec_module(module_ast, options, aliases)

  defp literal_child_modules(_children, _aliases), do: []

  defp literal_child_spec_module(module_ast, options, aliases) do
    if literal_list_ast?(options) do
      case canonical_ast(module_ast, aliases) do
        module when is_atom(module) -> [module]
        _other -> []
      end
    else
      []
    end
  end

  # Sourceror wraps list literals in a one-element `__block__` node to retain
  # their source location. A dynamic child-spec options expression is not a
  # literal list and must not prove Repo supervision.
  defp literal_list_ast?(value) when is_list(value), do: true

  defp literal_list_ast?({:__block__, _meta, [value]}) when is_list(value), do: true

  defp literal_list_ast?(_value), do: false

  defp postgres_repo_status(module_ast) do
    case repo_status_ast(module_ast) do
      :none -> :unverified
      status -> status
    end
  end

  # Inspect only runtime modules under lib. Igniter 0.6's generic Ecto helper
  # scans every configured source, including tests and configuration files,
  # through an unbounded module traversal. Apart from unnecessary work, that
  # can make a test-only Repo alter production installer output.
  defp project_ecto_repos(igniter) do
    {igniter, sources} = project_lib_sources(igniter)

    repos = sources |> Enum.flat_map(&repo_modules_in_source/1) |> Enum.uniq()

    {igniter, repos}
  end

  # Automatic persistence is only safe for a Repo that the host application
  # actually starts. A source declaration by itself may belong to a library,
  # a migration-only module, or a disabled deployment. Explicit `--repo`
  # selection is also conservative: the selected Repo must be a literal child
  # in the application's `start/2` list. Automatic mode can fall back to ETS
  # when that proof is unavailable.
  defp supervised_project_repos(igniter, repos) do
    app_module =
      case Igniter.Project.Application.app_module(igniter) do
        module when is_atom(module) -> module
        {module, _options} when is_atom(module) -> module
        _other -> nil
      end

    supervised =
      with module when is_atom(module) <- app_module,
           {:ok, {_igniter, _source, module_ast}} <- find_project_module_source(igniter, module) do
        application_children(module_ast)
      else
        _other -> []
      end

    Enum.filter(repos, &(&1 in supervised))
  end

  defp project_lib_sources(igniter) do
    # Igniter.Test preloads its virtual files, but a real installer invocation
    # starts with only the sources touched by earlier task steps. Load the
    # runtime tree explicitly so Repo discovery and supervision checks behave
    # the same in generated applications as they do in focused unit tests.
    # The shared walker reads regular files only and never follows symlinks.
    igniter = include_project_elixir_tree(igniter, "lib", ".ex")

    sources =
      igniter.rewrite
      |> Rewrite.sources()
      |> Enum.filter(&project_lib_source?/1)

    {igniter, sources}
  end

  defp project_lib_source?(%Rewrite.Source{path: path, filetype: %Rewrite.Source.Ex{}})
       when is_binary(path) do
    relative_path =
      case Path.type(path) do
        :absolute -> Path.relative_to_cwd(path)
        _relative -> path
      end

    case Path.split(relative_path) do
      ["lib" | parts] when parts != [] ->
        ".." not in parts and Path.extname(List.last(parts)) == ".ex"

      _other ->
        false
    end
  end

  defp project_lib_source?(_source), do: false

  defp repo_modules_in_source(source) do
    try do
      source
      |> Rewrite.Source.get(:quoted)
      |> collect_repo_modules([])
    rescue
      _exception -> []
    catch
      _kind, _reason -> []
    end
  end

  defp collect_repo_modules({:defmodule, _meta, [module_ast, options]}, prefix)
       when is_list(options) do
    current = literal_module_ast(module_ast)
    full_module = nested_module_name(prefix, current)

    own_repo =
      if is_nil(full_module) or
           repo_status_ast(options) not in [:postgres, :unsupported, :unverified],
         do: [],
         else: [full_module]

    nested_repos =
      case keyword_value(options, :do) do
        {:ok, body} when not is_nil(current) -> collect_repo_modules(body, full_module)
        _other -> []
      end

    own_repo ++ nested_repos
  end

  defp collect_repo_modules({form, _meta, args}, prefix)
       when is_atom(form) and is_list(args),
       do: collect_repo_modules(args, prefix)

  defp collect_repo_modules(list, prefix) when is_list(list) do
    Enum.flat_map(list, &collect_repo_modules(&1, prefix))
  end

  defp collect_repo_modules(_other, _prefix), do: []

  defp repo_status_ast({:defmodule, _meta, [_module_ast, options]}) when is_list(options),
    do: repo_status_ast(options)

  defp repo_status_ast(options) when is_list(options) do
    case keyword_value(options, :do) do
      {:ok, body} -> body |> top_level_alias_contexts() |> repo_use_status()
      :error -> :unverified
    end
  end

  defp repo_status_ast(_options), do: :unverified

  defp repo_use_status(contexts) do
    statuses = Enum.flat_map(contexts, &repo_use_context_status/1)

    cond do
      :postgres in statuses -> :postgres
      :unsupported in statuses -> :unsupported
      statuses != [] -> :unverified
      true -> :none
    end
  end

  defp repo_use_context_status({{:use, _meta, [module_ast | arguments]}, aliases}) do
    case canonical_ast(module_ast, aliases) do
      AshPostgres.Repo ->
        ash_postgres_repo_status(arguments, aliases)

      module when module in [AshSqlite.Repo, AshMysql.Repo] ->
        [:unsupported]

      Ecto.Repo ->
        [ecto_repo_options_status(arguments, aliases)]

      _other ->
        []
    end
  end

  defp repo_use_context_status(_context), do: []

  defp ash_postgres_repo_status([options], _aliases) when is_list(options) do
    case keyword_value(options, :define_ecto_repo?) do
      :error ->
        [:postgres]

      {:ok, value} ->
        case literal_boolean(value) do
          true -> [:postgres]
          false -> []
          nil -> [:unverified]
        end
    end
  end

  defp ash_postgres_repo_status(_arguments, _aliases), do: [:unverified]

  defp ecto_repo_options_status([options], aliases) when is_list(options) do
    case keyword_value(options, :adapter) do
      {:ok, adapter_ast} ->
        case canonical_ast(adapter_ast, aliases) do
          Ecto.Adapters.Postgres -> :postgres
          adapter when is_atom(adapter) -> :unsupported
          _dynamic -> :unverified
        end

      :error ->
        :unverified
    end
  end

  defp ecto_repo_options_status(_arguments, _aliases), do: :unverified

  defp ecto_session_config(repo, schema_prefix, app, server_module, requested) do
    %{
      mode: :ecto,
      requested: requested,
      repo: repo,
      schema_prefix: schema_prefix,
      namespace: session_namespace(app, server_module)
    }
  end

  defp session_namespace(app, server_module) do
    module_name = server_module |> Module.split() |> Enum.map_join("-", &Macro.underscore/1)
    module_name = String.replace_prefix(module_name, "#{app}-", "")
    readable_prefix = "#{app}-#{module_name}"
    digest = :crypto.hash(:sha256, :erlang.term_to_binary({app, server_module}))
    digest = Base.url_encode64(digest, padding: false)
    namespace = "#{readable_prefix}-#{digest}"

    if byte_size(namespace) <= @max_session_namespace_bytes do
      namespace
    else
      "mcp-#{digest}"
    end
  end

  defp existing_ecto_session_config(
         igniter,
         existing,
         requested,
         repo_option,
         schema_prefix,
         app,
         server_module
       ) do
    cond do
      requested == :ets ->
        {:error,
         "the host already configures the Ecto session store; use its existing backend or remove that session_store setting before selecting ETS"}

      not is_nil(repo_option) and repo_option != existing.repo ->
        {:error,
         "the host already configures Ecto session Repo #{inspect(existing.repo)}; remove that session_store setting before selecting #{inspect(repo_option)}"}

      not is_nil(schema_prefix) and schema_prefix != existing.schema_prefix ->
        {:error,
         "the host already configures Ecto session schema prefix #{inspect(existing.schema_prefix)}; remove that session_store setting before selecting #{inspect(schema_prefix)}"}

      true ->
        namespace = existing.namespace || session_namespace(app, server_module)
        {:ok, igniter, %{existing | requested: :preserve, namespace: namespace}}
    end
  end

  # Config is read as data so installer execution never evaluates host code.
  # A literal session_store identifies a possible prior installer run (or a
  # deliberate ETS opt-out). Bundled Ecto candidates are statically
  # revalidated below; dynamic or custom values remain opaque host
  # configuration and are never announced as newly selected Ecto.
  defp configured_session_store(igniter, app, server_module) do
    config_path = Igniter.Project.Application.config_path(igniter)
    config_dir = Path.dirname(config_path)
    igniter = include_project_elixir_tree(igniter, config_dir, ".exs")
    config_dir_parts = config_dir |> Path.expand() |> Path.split()

    results =
      igniter.rewrite
      |> Rewrite.sources()
      |> Enum.flat_map(fn source ->
        if session_config_source?(source.path, config_dir_parts) do
          configured_session_store_in_source(source.content, app, server_module)
        else
          []
        end
      end)

    case results do
      [] ->
        {:ok, igniter, :none}

      [%{mode: :ambiguous, message: message}] ->
        {:error, igniter, message}

      [entry] ->
        case validate_preserved_session_store(igniter, entry) do
          :ok ->
            {:ok, igniter, entry}

          {:error, message} ->
            {:error, igniter, message}
        end

      _entries ->
        {:error,
         "multiple #{inspect(server_module)} session_store configurations were found; keep one literal backend before installation"}
    end
  end

  # A literal Ecto handle is emitted by this installer, so reruns must
  # revalidate the referenced Repo from source before treating it as an
  # idempotent prior installation. The check is deliberately source-only:
  # loading a compiled host module could execute arbitrary application code
  # during installation. Opaque custom stores remain untouched.
  defp validate_preserved_session_store(_igniter, %{mode: mode}) when mode in [:ets, :custom],
    do: :ok

  defp validate_preserved_session_store(igniter, %{mode: :ecto, repo: repo}) do
    case find_project_module_source(igniter, repo) do
      {:ok, {_igniter, _source, module_ast}} ->
        case postgres_repo_status(module_ast) do
          :postgres ->
            :ok

          :unsupported ->
            {:error,
             "the existing AttestoMCP.Server.SessionStore.Ecto handle references Repo #{inspect(repo)}, which is not statically configured with Ecto.Adapters.Postgres; remove or correct that session_store setting before installation"}

          :unverified ->
            {:error,
             "the existing AttestoMCP.Server.SessionStore.Ecto handle references Repo #{inspect(repo)}, which could not be statically confirmed as PostgreSQL; remove or correct that session_store setting before installation"}
        end

      {:error, _igniter} ->
        {:error,
         "the existing AttestoMCP.Server.SessionStore.Ecto handle references Repo #{inspect(repo)}, but its source could not be inspected; remove or correct that session_store setting before installation"}
    end
  end

  defp validate_preserved_session_store(_igniter, _entry), do: :ok

  defp session_config_source?(path, config_dir_parts) do
    source_path = Path.expand(path)

    Path.extname(path) == ".exs" and
      Enum.take(Path.split(source_path), length(config_dir_parts)) == config_dir_parts
  end

  # Igniter's older glob reader may traverse far beyond the intended project
  # subtree for recursive patterns. Enumerate regular files ourselves and add
  # each explicit path instead. Symlinked directories are deliberately skipped
  # so installer discovery cannot escape the selected runtime/config tree.
  # Igniter.Test already carries its virtual files in Rewrite, so touching the
  # caller's real filesystem in test mode would be both unnecessary and wrong.
  defp include_project_elixir_tree(igniter, root, extension) do
    if igniter.assigns[:test_mode?] do
      igniter
    else
      root
      |> regular_project_files(extension)
      |> Enum.reduce(igniter, fn path, current ->
        Igniter.include_existing_file(current, path, required?: false)
      end)
    end
  end

  defp regular_project_files(root, extension) do
    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory}} ->
        walk_project_directory(root, extension)

      _other ->
        []
    end
  end

  defp walk_project_directory(directory, extension) do
    case File.ls(directory) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.flat_map(fn entry ->
          path = Path.join(directory, entry)

          case File.lstat(path) do
            {:ok, %File.Stat{type: :directory}} ->
              walk_project_directory(path, extension)

            {:ok, %File.Stat{type: :regular}} ->
              if Path.extname(path) == extension, do: [path], else: []

            _symlink_or_unreadable ->
              []
          end
        end)

      _unreadable ->
        []
    end
  end

  defp configured_session_store_in_source(content, app, server_module)
       when is_binary(content) do
    case Code.string_to_quoted(content, emit_warnings: false) do
      {:ok, ast} -> configured_session_store_ast(ast, app, server_module)
      {:error, _error} -> []
    end
  end

  defp configured_session_store_ast(ast, app, server_module) do
    contexts = top_level_alias_contexts(ast)

    entries =
      Enum.flat_map(contexts, fn {expression, aliases} ->
        case config_call_args(expression, aliases) do
          {:ok, [configured_app, module_ast, options]} when configured_app == app ->
            if canonical_ast(module_ast, aliases) == server_module do
              case configured_session_store_config(options, aliases) do
                :not_found -> []
                entry -> [entry]
              end
            else
              []
            end

          _other ->
            []
        end
      end)

    if Enum.any?(contexts, fn {expression, aliases} ->
         nested_session_store_config?(expression, app, server_module, aliases)
       end) do
      [
        %{
          mode: :ambiguous,
          message:
            "could not safely inspect #{inspect(server_module)} session_store configuration inside a conditional or runtime config; move it to a literal top-level config before installation"
        }
        | entries
      ]
    else
      entries
    end
  end

  defp nested_session_store_config?(expression, app, server_module, aliases) do
    {found?, _aliases} =
      nested_session_store_walk(expression, aliases, true, app, server_module)

    found?
  end

  defp nested_session_store_walk(
         {:quote, _meta, _arguments},
         aliases,
         _root?,
         _app,
         _server_module
       ),
       do: {false, aliases}

  defp nested_session_store_walk(
         {:alias, _meta, _arguments} = expression,
         aliases,
         _root?,
         _app,
         _server_module
       ),
       do: {false, aliases_after_expression(expression, aliases)}

  defp nested_session_store_walk(expression, aliases, root?, app, server_module) do
    case config_call_args(expression, aliases) do
      {:ok, [configured_app, module_ast, options]} ->
        found? =
          not root? and configured_app == app and
            canonical_ast(module_ast, aliases) == server_module and
            session_store_config_possible?(options, aliases)

        if found? do
          {true, aliases}
        else
          nested_session_store_children(expression, aliases, app, server_module)
        end

      :error ->
        nested_session_store_children(expression, aliases, app, server_module)
    end
  end

  defp nested_session_store_children(
         {:__block__, _meta, expressions},
         aliases,
         app,
         server_module
       )
       when is_list(expressions),
       do: nested_session_store_sequence(expressions, aliases, app, server_module)

  defp nested_session_store_children({form, _meta, arguments}, aliases, app, server_module)
       when is_atom(form) and is_list(arguments),
       do: nested_session_store_sequence(arguments, aliases, app, server_module)

  defp nested_session_store_children({key, value}, aliases, app, server_module)
       when is_atom(key),
       do: nested_session_store_walk(value, aliases, false, app, server_module)

  defp nested_session_store_children(expressions, aliases, app, server_module)
       when is_list(expressions),
       do: nested_session_store_sequence(expressions, aliases, app, server_module)

  defp nested_session_store_children(_expression, aliases, _app, _server_module),
    do: {false, aliases}

  defp nested_session_store_sequence(expressions, aliases, app, server_module) do
    Enum.reduce_while(expressions, {false, aliases}, fn expression, {false, aliases} ->
      {found?, aliases} =
        nested_session_store_walk(expression, aliases, false, app, server_module)

      if found?, do: {:halt, {true, aliases}}, else: {:cont, {false, aliases}}
    end)
  end

  defp config_call_args({:config, _meta, arguments}, _aliases)
       when is_list(arguments) and length(arguments) == 3,
       do: {:ok, arguments}

  defp config_call_args(
         {{:., _dot_meta, [module_ast, :config]}, _call_meta, arguments},
         aliases
       )
       when is_list(arguments) and length(arguments) == 3 do
    if canonical_ast(module_ast, aliases) == Config, do: {:ok, arguments}, else: :error
  end

  defp config_call_args(_expression, _aliases), do: :error

  defp session_store_config_possible?(options, aliases) when is_list(options) do
    case config_option(options, :server_options) do
      :not_found ->
        false

      {:found, server_options} ->
        nested_server_options_include_session_store?(server_options, aliases)
    end
  end

  defp session_store_config_possible?(_options, _aliases), do: true

  defp nested_server_options_include_session_store?(options, _aliases) when is_list(options) do
    config_option(options, :session_store) != :not_found
  end

  defp nested_server_options_include_session_store?(_options, _aliases), do: true

  defp configured_session_store_config(options, aliases) when is_list(options) do
    case config_option(options, :server_options) do
      :not_found -> :not_found
      {:found, server_options} -> configured_session_store_options(server_options, aliases)
    end
  end

  defp configured_session_store_config(_options, _aliases),
    do: %{mode: :custom, requested: :preserve}

  defp configured_session_store_options(options, aliases) when is_list(options) do
    case config_option(options, :session_store) do
      :not_found -> :not_found
      {:found, value} -> configured_session_store_value(value, options, aliases)
    end
  end

  defp configured_session_store_options(_options, _aliases),
    do: %{mode: :custom, requested: :preserve}

  defp configured_session_store_value(nil, _options, _aliases),
    do: %{mode: :ets, requested: :preserve}

  defp configured_session_store_value(value, options, aliases) do
    case configured_ecto_session_store(value, aliases) do
      {:ok, repo, schema_prefix, store_namespace} ->
        case configured_session_namespace(options) do
          {:ok, namespace} when store_namespace == namespace ->
            %{
              mode: :ecto,
              requested: :preserve,
              existing?: true,
              repo: repo,
              schema_prefix: schema_prefix,
              namespace: namespace
            }

          {:ok, namespace} ->
            %{
              mode: :custom,
              requested: :preserve,
              consistency_warning:
                "Preserved the existing Ecto session store as custom configuration, but its handle namespace #{inspect(store_namespace)} does not match session_namespace #{inspect(namespace)}. The server will reject this configuration at startup; align the two values or remove the session_store setting before rerunning the installer."
            }

          _uninspectable_namespace ->
            unvalidated_ecto_session_config()
        end

      :error ->
        if bundled_ecto_session_store?(value, aliases) do
          unvalidated_ecto_session_config()
        else
          %{mode: :custom, requested: :preserve}
        end
    end
  end

  defp bundled_ecto_session_store?({module_ast, _handle_ast}, aliases) do
    canonical_ast(module_ast, aliases) == AttestoMCP.Server.SessionStore.Ecto
  end

  defp bundled_ecto_session_store?(_value, _aliases), do: false

  defp unvalidated_ecto_session_config do
    %{
      mode: :custom,
      requested: :preserve,
      consistency_warning:
        "Preserved the existing bundled Ecto session store as custom configuration, but its handle could not be statically validated; startup may reject this configuration. Verify the Ecto handle and session_namespace before deploying."
    }
  end

  defp configured_session_namespace(options) do
    case config_option(options, :session_namespace) do
      :not_found ->
        :error

      {:found, value} ->
        configured_namespace_value(value)
    end
  end

  defp configured_ecto_session_store({module_ast, handle_ast}, aliases) do
    if canonical_ast(module_ast, aliases) == AttestoMCP.Server.SessionStore.Ecto do
      configured_ecto_session_handle(handle_ast, aliases)
    else
      :error
    end
  end

  defp configured_ecto_session_store(_value, _aliases), do: :error

  defp configured_ecto_session_handle({:%{}, _meta, pairs}, aliases) when is_list(pairs) do
    with {:found, repo_ast} <- config_option(pairs, :repo),
         repo when is_atom(repo) <- canonical_ast(repo_ast, aliases),
         {:found, namespace_ast} <- config_option(pairs, :namespace),
         {:ok, namespace} <- configured_namespace_value(namespace_ast),
         {:ok, schema_prefix} <- configured_ecto_schema_prefix(pairs) do
      {:ok, repo, schema_prefix, namespace}
    else
      _ -> :error
    end
  end

  defp configured_ecto_session_handle(_value, _aliases), do: :error

  defp configured_namespace_value(value) do
    case literal_string(value) do
      namespace when is_binary(namespace) ->
        if namespace != "" and byte_size(namespace) <= @max_session_namespace_bytes and
             String.valid?(namespace) and :binary.match(namespace, <<0>>) == :nomatch do
          {:ok, namespace}
        else
          :error
        end

      _invalid ->
        :error
    end
  end

  defp configured_ecto_schema_prefix(pairs) do
    case config_option(pairs, :schema_prefix) do
      :not_found ->
        {:ok, nil}

      {:found, prefix_ast} ->
        prefix = literal_string_or_nil(prefix_ast)

        case session_schema_prefix(prefix) do
          {:ok, validated} -> {:ok, validated}
          {:error, _message} -> :error
        end
    end
  end

  defp config_option(options, key) when is_list(options) do
    case Enum.find(options, fn
           {option, _value} when option == key -> true
           _other -> false
         end) do
      nil -> :not_found
      {_option, value} -> {:found, value}
    end
  end

  defp config_option(_options, _key), do: :not_found

  defp literal_module_ast({:__aliases__, _meta, parts}) when is_list(parts),
    do: Module.concat(parts)

  defp literal_module_ast(value) when is_atom(value), do: value
  defp literal_module_ast(_value), do: nil

  defp literal_string_or_nil(value) do
    case value do
      nil -> nil
      {:__block__, _meta, [nil]} -> nil
      {:__block__, _meta, [value]} when is_binary(value) -> value
      value when is_binary(value) -> value
      _ -> :invalid
    end
  end

  defp auth_source(igniter, nil, app) do
    if Igniter.Project.Deps.has_dep?(igniter, :attesto_phoenix),
      do: {:ok, {:attesto_phoenix, app}},
      else:
        {:error,
         "--attesto-config Module.function/0 is required when attesto_phoenix is not installed"}
  end

  defp auth_source(_igniter, value, _app) when is_binary(value) do
    callback_pattern =
      ~r/\A((?:Elixir\.)?[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*)\.([a-z_][A-Za-z0-9_]*(?:[!?])?)\/0\z/

    case Regex.run(callback_pattern, value) do
      [_, module, function] ->
        module =
          module
          |> String.replace_prefix("Elixir.", "")
          |> Igniter.Project.Module.parse()

        {:ok, {:callback, module, function}}

      _ ->
        {:error, "--attesto-config must be a fully qualified zero-arity callback"}
    end
  end

  defp auth_source(_igniter, _value, _app),
    do: {:error, "--attesto-config must be a fully qualified zero-arity callback"}

  defp validate_cimd_source({:callback, _module, _function}, true),
    do:
      {:error,
       "--enable-cimd requires automatic attesto_phoenix integration; remove it when using --attesto-config"}

  defp validate_cimd_source(_auth_source, _enable_cimd?), do: :ok

  defp validate_metadata_reuse_source(
         auth_source = {:callback, _module, _function},
         true,
         server_module,
         path,
         base_url
       ),
       do:
         {:error,
          manual_mcp_wiring_message(
            "--reuse-metadata-route requires automatic attesto_phoenix integration; an explicit callback cannot prove the existing metadata route equivalence",
            server_module,
            path,
            base_url,
            auth_source
          )}

  defp validate_metadata_reuse_source(_auth_source, _reuse?, _server_module, _path, _base_url),
    do: :ok

  defp authorization_dependencies(_igniter, {:callback, _module, _function}, _enable_cimd?),
    do: {:ok, []}

  defp authorization_dependencies(igniter, {:attesto_phoenix, _app}, enable_cimd?) do
    with :ok <- validate_dependency_catalog(igniter, enable_cimd?),
         {:ok, attesto_phoenix} <-
           constrained_dependency(
             igniter,
             :attesto_phoenix,
             @attesto_phoenix_requirement
           ),
         {:ok, dependencies} <-
           authorization_dependency_list(igniter, attesto_phoenix, enable_cimd?) do
      {:ok, dependencies}
    end
  end

  defp authorization_dependency_list(_igniter, attesto_phoenix, false),
    do: {:ok, [attesto_phoenix]}

  defp authorization_dependency_list(igniter, attesto_phoenix, true) do
    with {:ok, req} <- constrained_dependency(igniter, :req, @req_requirement) do
      {:ok, [attesto_phoenix, req]}
    end
  end

  defp validate_dependency_catalog(igniter, require_req?) do
    with {:ok, entries} <- literal_dependency_entries(igniter) do
      names = Enum.map(entries, &dependency_entry_name/1)

      cond do
        Enum.any?(names, &match?({:error, :unknown_dependency_name}, &1)) ->
          {:error,
           "deps/0 contains a dependency entry whose package name cannot be verified; " <>
             "declare dependencies as explicit tuples before installation"}

        duplicate = duplicate_required_dependency(names, require_req?) ->
          {:error,
           "deps/0 declares #{inspect(duplicate)} more than once; keep one explicit " <>
             "compatible dependency before installation"}

        true ->
          :ok
      end
    end
  end

  defp literal_dependency_entries(igniter) do
    zipper =
      igniter
      |> Igniter.include_existing_file("mix.exs")
      |> Map.fetch!(:rewrite)
      |> Rewrite.source!("mix.exs")
      |> Rewrite.Source.get(:quoted)
      |> Sourceror.Zipper.zip()

    with {:ok, module_zipper} <- Igniter.Code.Module.move_to_module_using(zipper, Mix.Project),
         :ok <- validate_single_deps_clause(module_zipper),
         {:ok, zipper} <- Igniter.Code.Function.move_to_defp(module_zipper, :deps, 0) do
      zipper = Igniter.Code.Common.maybe_move_to_single_child_block(zipper)

      if Igniter.Code.List.list?(zipper) do
        {:ok, Sourceror.Zipper.node(zipper)}
      else
        {:error,
         "deps/0 must return a literal dependency list so required runtime dependencies " <>
           "can be verified before installation"}
      end
    else
      _not_found ->
        {:error,
         "could not inspect deps/0; declare required runtime dependencies explicitly before " <>
           "installation"}
    end
  end

  defp validate_single_deps_clause(module_zipper) do
    clauses =
      module_zipper
      |> Sourceror.Zipper.node()
      |> top_level_expressions()
      |> Enum.map(&unwrap_single_block/1)
      |> Enum.filter(&deps_clause?/1)

    case clauses do
      [{:defp, _meta, [{:deps, _call_meta, args}, _body]}]
      when args in [nil, []] ->
        :ok

      _other ->
        {:error,
         "mix.exs must define exactly one unguarded private deps/0 clause so required " <>
           "runtime dependencies can be verified before installation"}
    end
  end

  defp unwrap_single_block({:__block__, _meta, [expression]}), do: expression
  defp unwrap_single_block(expression), do: expression

  defp deps_clause?({:defp, _meta, [{:deps, _call_meta, args}, _body]})
       when args in [nil, []],
       do: true

  defp deps_clause?(
         {:defp, _meta, [{:when, _when_meta, [{:deps, _call_meta, args}, _guard]}, _body]}
       )
       when args in [nil, []],
       do: true

  defp deps_clause?(_expression), do: false

  defp dependency_entry_name(entry) do
    with {:ok, quoted} <- entry |> Sourceror.to_string() |> Code.string_to_quoted() do
      case quoted do
        {name, _value} when is_atom(name) -> name
        {:{}, _meta, [name | _rest]} when is_atom(name) -> name
        _unknown -> {:error, :unknown_dependency_name}
      end
    else
      _parse_error -> {:error, :unknown_dependency_name}
    end
  end

  defp duplicate_required_dependency(names, require_req?) do
    required = if require_req?, do: [:attesto_phoenix, :req], else: [:attesto_phoenix]
    Enum.find(required, fn name -> Enum.count(names, &(&1 == name)) > 1 end)
  end

  defp constrained_dependency(igniter, name, required_requirement) do
    case Igniter.Project.Deps.get_dep(igniter, name) do
      {:ok, nil} ->
        {:ok, {name, required_requirement}}

      {:ok, declaration} when is_binary(declaration) ->
        constrain_existing_dependency(name, declaration, required_requirement)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp constrain_existing_dependency(name, declaration, required_requirement) do
    with {:ok, dependency} <- evaluate_dependency(name, declaration),
         {:ok, existing_requirement, options} <- dependency_parts(name, dependency),
         :ok <- validate_dependency_options(name, options),
         {:ok, desired_requirement} <-
           intersect_requirements(name, existing_requirement, required_requirement) do
      desired =
        if options == [],
          do: {name, desired_requirement},
          else: {name, desired_requirement, options}

      {:ok, desired}
    end
  end

  defp evaluate_dependency(name, declaration) do
    with {:ok, quoted} <- Code.string_to_quoted(declaration),
         true <- Macro.quoted_literal?(quoted) do
      {dependency, _binding} = Code.eval_quoted(quoted, [], __ENV__)
      {:ok, dependency}
    else
      _not_a_literal ->
        {:error,
         "the existing #{inspect(name)} dependency is dynamic and cannot be validated; " <>
           "replace it with an explicit compatible version requirement before installation"}
    end
  end

  defp dependency_parts(name, {name, requirement}) when is_binary(requirement),
    do: {:ok, requirement, []}

  defp dependency_parts(name, {name, requirement, options})
       when is_binary(requirement) and is_list(options),
       do: {:ok, requirement, options}

  defp dependency_parts(name, _dependency) do
    {:error,
     "the existing #{inspect(name)} dependency must declare an explicit compatible Hex version " <>
       "requirement before installation"}
  end

  defp validate_dependency_options(name, options) do
    cond do
      not Keyword.keyword?(options) ->
        {:error,
         "the existing #{inspect(name)} dependency options must be a literal keyword list"}

      length(Keyword.keys(options)) != length(Enum.uniq(Keyword.keys(options))) ->
        {:error, "the existing #{inspect(name)} dependency has duplicate options"}

      Keyword.has_key?(options, :only) ->
        {:error,
         "the existing #{inspect(name)} dependency is environment-restricted; it must be " <>
           "available in every environment before installation"}

      Keyword.has_key?(options, :targets) ->
        {:error,
         "the existing #{inspect(name)} dependency is target-restricted; it must be " <>
           "available for every target before installation"}

      Enum.any?(@dependency_source_options, &Keyword.has_key?(options, &1)) ->
        {:error,
         "the existing #{inspect(name)} dependency must use the public Hex package without " <>
           "a custom repository, organization, Git selector, path, or umbrella source"}

      Keyword.has_key?(options, :system_env) ->
        {:error,
         "the existing #{inspect(name)} dependency must not override its system environment"}

      Keyword.has_key?(options, :compile) ->
        {:error,
         "the existing #{inspect(name)} dependency must use its default Hex package compiler"}

      unsupported = unsupported_dependency_option(options) ->
        {:error,
         "the existing #{inspect(name)} dependency uses unsupported option " <>
           "#{inspect(unsupported)}"}

      not valid_hex_package_option?(name, options) ->
        {:error,
         "the existing #{inspect(name)} dependency renames a different Hex package; use the " <>
           "#{name} package before installation"}

      not valid_manager_option?(options) ->
        {:error, "the existing #{inspect(name)} dependency must use the Mix build manager"}

      not valid_override_option?(options) ->
        {:error, "the existing #{inspect(name)} dependency override option must be boolean"}

      Keyword.get(options, :env, :prod) != :prod ->
        {:error,
         "the existing #{inspect(name)} dependency must compile in the production environment"}

      Keyword.get(options, :runtime, true) != true ->
        {:error,
         "the existing #{inspect(name)} dependency must use runtime: true; it must be available " <>
           "at runtime before installation"}

      Keyword.get(options, :optional, false) != false ->
        {:error,
         "the existing #{inspect(name)} dependency must use optional: false; it must be a direct runtime " <>
           "dependency before installation"}

      Keyword.get(options, :app, true) != true ->
        {:error,
         "the existing #{inspect(name)} dependency must use app: true so its application is " <>
           "available at runtime"}

      true ->
        :ok
    end
  end

  defp valid_hex_package_option?(name, options) do
    case Keyword.fetch(options, :hex) do
      :error -> true
      {:ok, ^name} -> true
      {:ok, value} -> value == Atom.to_string(name)
    end
  end

  defp valid_manager_option?(options) do
    case Keyword.fetch(options, :manager) do
      :error -> true
      {:ok, :mix} -> true
      {:ok, _other} -> false
    end
  end

  defp valid_override_option?(options) do
    case Keyword.fetch(options, :override) do
      :error -> true
      {:ok, value} -> is_boolean(value)
    end
  end

  defp unsupported_dependency_option(options) do
    Enum.find(Keyword.keys(options), &(&1 not in @safe_dependency_options))
  end

  defp intersect_requirements(name, existing_source, required_source) do
    with :ok <- reject_unsupported_requirement_syntax(name, existing_source),
         {:ok, _existing} <- Version.parse_requirement(existing_source),
         {:ok, _required} <- Version.parse_requirement(required_source),
         {:ok, existing_interval, existing_atom_count} <-
           requirement_interval(name, existing_source),
         {:ok, required_interval, _required_atom_count} <-
           requirement_interval(name, required_source) do
      intersection = intersect_intervals(existing_interval, required_interval)

      if interval_nonempty?(intersection) do
        emit_intersection(
          name,
          existing_source,
          existing_interval,
          existing_atom_count,
          required_source,
          required_interval,
          intersection
        )
      else
        {:error,
         "the existing #{inspect(name)} requirement #{inspect(existing_source)} does not " <>
           "overlap supported versions #{inspect(required_source)}"}
      end
    else
      {:error, message} ->
        {:error, message}

      :error ->
        {:error,
         "the existing #{inspect(name)} dependency has an invalid version requirement " <>
           "#{inspect(existing_source)}"}
    end
  end

  defp reject_unsupported_requirement_syntax(name, source) do
    cond do
      String.contains?(source, "!=") ->
        {:error,
         "the existing #{inspect(name)} requirement #{inspect(source)} excludes individual " <>
           "versions and cannot be safely narrowed automatically; replace it with a " <>
           "continuous range before installation"}

      Regex.match?(~r/(?:\A|\s)or(?:\s|\z)/, source) ->
        {:error,
         "the existing #{inspect(name)} requirement #{inspect(source)} uses alternatives " <>
           "that cannot be safely narrowed automatically; replace it with a single range " <>
           "before installation"}

      true ->
        :ok
    end
  end

  defp requirement_interval(name, source) do
    with {:ok, atoms} <- requirement_atoms(source),
         {:ok, interval} <- atoms_to_interval(atoms) do
      {:ok, interval, length(atoms)}
    else
      :error ->
        {:error,
         "the existing #{inspect(name)} requirement #{inspect(source)} cannot be safely " <>
           "normalized; replace it with a stable continuous range before installation"}

      {:error, :alternatives} ->
        {:error,
         "the existing #{inspect(name)} requirement #{inspect(source)} uses alternatives " <>
           "that cannot be safely narrowed automatically; replace it with a single range " <>
           "before installation"}

      {:error, :prerelease} ->
        {:error,
         "the existing #{inspect(name)} requirement #{inspect(source)} contains a pre-release " <>
           "version; use a stable compatible requirement before installation"}

      {:error, :unsupported} ->
        {:error,
         "the existing #{inspect(name)} requirement #{inspect(source)} uses unsupported " <>
           "constraints; replace it with a stable continuous range before installation"}
    end
  end

  defp requirement_atoms(source) do
    source
    |> String.split(~r/\s+and\s+/, trim: true)
    |> Enum.reduce_while({:ok, []}, fn atom_source, {:ok, atoms} ->
      case requirement_atom(atom_source) do
        {:ok, atom} -> {:cont, {:ok, [atom | atoms]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, atoms} -> {:ok, Enum.reverse(atoms)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp requirement_atom(source) do
    case Regex.named_captures(@requirement_atom_pattern, source) do
      %{
        "operator" => operator,
        "major" => major,
        "minor" => minor,
        "patch" => patch,
        "suffix" => suffix
      } ->
        with {:ok, operator} <- requirement_operator(operator),
             {:ok, key, precision} <- requirement_version_key(major, minor, patch),
             :ok <- validate_requirement_precision(operator, precision),
             :ok <- validate_requirement_suffix(suffix) do
          {:ok, {operator, key, precision}}
        end

      _no_match ->
        {:error, :unsupported}
    end
  end

  defp requirement_operator(""), do: {:ok, :==}
  defp requirement_operator("=="), do: {:ok, :==}
  defp requirement_operator("~>"), do: {:ok, :~>}
  defp requirement_operator(">="), do: {:ok, :>=}
  defp requirement_operator("<="), do: {:ok, :<=}
  defp requirement_operator(">"), do: {:ok, :>}
  defp requirement_operator("<"), do: {:ok, :<}
  defp requirement_operator(_operator), do: {:error, :unsupported}

  defp requirement_version_key(major, "", ""),
    do: {:ok, {String.to_integer(major), 0, 0}, 1}

  defp requirement_version_key(major, minor, ""),
    do: {:ok, {String.to_integer(major), String.to_integer(minor), 0}, 2}

  defp requirement_version_key(major, minor, patch) do
    {:ok, {String.to_integer(major), String.to_integer(minor), String.to_integer(patch)}, 3}
  end

  defp validate_requirement_precision(:~>, precision) when precision in [2, 3], do: :ok
  defp validate_requirement_precision(operator, 3) when operator != :~>, do: :ok
  defp validate_requirement_precision(_operator, _precision), do: {:error, :unsupported}

  defp validate_requirement_suffix("-" <> _prerelease), do: {:error, :prerelease}
  defp validate_requirement_suffix(_suffix), do: :ok

  defp atoms_to_interval(atoms) do
    Enum.reduce_while(atoms, {:ok, unbounded_interval()}, fn atom, {:ok, interval} ->
      case atom_interval(atom) do
        {:ok, atom_interval} ->
          {:cont, {:ok, intersect_intervals(interval, atom_interval)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp atom_interval({:==, key, 3}),
    do: {:ok, %{lower: {key, true}, upper: {key, true}}}

  defp atom_interval({operator, key, 3}) when operator in [:>, :>=, :<, :<=] do
    case operator do
      :> -> {:ok, %{lower: {key, false}, upper: nil}}
      :>= -> {:ok, %{lower: {key, true}, upper: nil}}
      :< -> {:ok, %{lower: nil, upper: {key, false}}}
      :<= -> {:ok, %{lower: nil, upper: {key, true}}}
    end
  end

  defp atom_interval({:~>, {major, minor, _patch} = lower, precision})
       when precision in [2, 3] do
    upper =
      if precision == 2,
        do: increment_version_key({major, 0, 0}, :major),
        else: increment_version_key({major, minor, 0}, :minor)

    case upper do
      {:ok, upper} -> {:ok, %{lower: {lower, true}, upper: {upper, false}}}
      :error -> {:error, :unsupported}
    end
  end

  defp atom_interval(_atom), do: {:error, :unsupported}

  defp unbounded_interval, do: %{lower: nil, upper: nil}

  defp intersect_intervals(left, right) do
    %{
      lower: stronger_lower(left.lower, right.lower),
      upper: stronger_upper(left.upper, right.upper)
    }
  end

  defp stronger_lower(nil, bound), do: bound
  defp stronger_lower(bound, nil), do: bound

  defp stronger_lower({left, left_inclusive}, {right, right_inclusive}) do
    case compare_version_keys(left, right) do
      :gt -> {left, left_inclusive}
      :lt -> {right, right_inclusive}
      :eq -> {left, left_inclusive and right_inclusive}
    end
  end

  defp stronger_upper(nil, bound), do: bound
  defp stronger_upper(bound, nil), do: bound

  defp stronger_upper({left, left_inclusive}, {right, right_inclusive}) do
    case compare_version_keys(left, right) do
      :lt -> {left, left_inclusive}
      :gt -> {right, right_inclusive}
      :eq -> {left, left_inclusive and right_inclusive}
    end
  end

  defp interval_nonempty?(%{lower: lower, upper: upper}) do
    with {:ok, first} <- first_version_in_interval(lower) do
      case upper do
        nil ->
          true

        {last, inclusive} ->
          compare_version_keys(first, last) == :lt or
            (inclusive and compare_version_keys(first, last) == :eq)
      end
    else
      :error -> false
    end
  end

  defp first_version_in_interval(nil), do: {:ok, {0, 0, 0}}
  defp first_version_in_interval({version, true}), do: {:ok, version}
  defp first_version_in_interval({version, false}), do: stable_successor(version)

  defp stable_successor({major, minor, patch}) when patch < @max_version_component,
    do: {:ok, {major, minor, patch + 1}}

  defp stable_successor({major, minor, @max_version_component})
       when minor < @max_version_component,
       do: {:ok, {major, minor + 1, 0}}

  defp stable_successor({major, @max_version_component, @max_version_component})
       when major < @max_version_component,
       do: {:ok, {major + 1, 0, 0}}

  defp stable_successor(_version), do: :error

  defp increment_version_key({major, _minor, _patch}, :major)
       when major < @max_version_component,
       do: {:ok, {major + 1, 0, 0}}

  defp increment_version_key({major, minor, _patch}, :minor)
       when minor < @max_version_component,
       do: {:ok, {major, minor + 1, 0}}

  defp increment_version_key(_version, _component), do: :error

  defp compare_version_keys(left, right) when left < right, do: :lt
  defp compare_version_keys(left, right) when left > right, do: :gt
  defp compare_version_keys(_left, _right), do: :eq

  defp emit_intersection(
         name,
         existing_source,
         existing_interval,
         existing_atom_count,
         required_source,
         required_interval,
         intersection
       ) do
    source =
      cond do
        intersection == existing_interval and existing_atom_count <= 2 -> existing_source
        intersection == required_interval -> required_source
        true -> interval_to_requirement(intersection)
      end

    with source when is_binary(source) <- source,
         {:ok, _parsed} <- Version.parse_requirement(source),
         {:ok, normalized, atom_count} <- requirement_interval(name, source),
         true <- normalized == intersection and atom_count <= 2 do
      {:ok, source}
    else
      _invalid ->
        {:error,
         "the existing #{inspect(name)} requirement #{inspect(existing_source)} could not " <>
           "be narrowed to a Hex-compatible range inside #{inspect(required_source)}"}
    end
  end

  defp interval_to_requirement(%{lower: {version, true}, upper: {version, true}}),
    do: "== " <> version_key_to_string(version)

  defp interval_to_requirement(%{lower: lower, upper: upper}) do
    [lower_requirement(lower), upper_requirement(upper)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" and ")
  end

  defp lower_requirement(nil), do: nil

  defp lower_requirement({version, inclusive}),
    do: if(inclusive, do: ">= ", else: "> ") <> version_key_to_string(version)

  defp upper_requirement(nil), do: nil

  defp upper_requirement({version, inclusive}),
    do: if(inclusive, do: "<= ", else: "< ") <> version_key_to_string(version)

  defp version_key_to_string({major, minor, patch}), do: "#{major}.#{minor}.#{patch}"

  defp validate_path(path) when is_binary(path) do
    segments = String.split(path, "/")

    if path != "/" and String.starts_with?(path, "/") and
         not String.ends_with?(path, "/") and byte_size(path) <= 512 and
         Regex.match?(@static_path_pattern, path) and
         not Enum.any?(segments, &(&1 in [".", ".."])) and
         safe_text?(path) do
      {:ok, path}
    else
      {:error,
       "--mcp-path must be an absolute, static, non-root ASCII path using only unreserved URI characters and slash separators"}
    end
  end

  defp validate_path(_path),
    do: {:error, "--mcp-path must be an absolute path"}

  defp validate_base_url(value, allow_http_loopback?) when is_binary(value) do
    case Regex.run(@origin_pattern, value) do
      [_, raw_scheme, raw_host | port_match] ->
        scheme = String.downcase(raw_scheme)
        host = raw_host |> String.trim_leading("[") |> String.trim_trailing("]")
        port_text = List.first(port_match)

        with true <- valid_host?(host),
             {:ok, port} <- validate_port(port_text, scheme) do
          loopback? = String.downcase(host) in ["127.0.0.1", "::1", "localhost"]

          cond do
            scheme == "https" ->
              {:ok, normalize_origin(scheme, host, port)}

            loopback? and allow_http_loopback? == true ->
              {:ok, normalize_origin(scheme, host, port)}

            loopback? ->
              {:error, "HTTP loopback origins require --allow-http-loopback"}

            true ->
              {:error,
               "--base-url must use HTTPS; HTTP is limited to explicitly allowed loopback development"}
          end
        else
          _ -> invalid_origin()
        end

      _ ->
        invalid_origin()
    end
  end

  defp validate_base_url(_value, _allow_http_loopback?),
    do: {:error, "--base-url is required"}

  defp invalid_origin do
    {:error,
     "--base-url must be an absolute origin with a valid DNS/IP host and port, without credentials, path, query, or fragment"}
  end

  defp validate_port(nil, "https"), do: {:ok, 443}
  defp validate_port(nil, "http"), do: {:ok, 80}

  defp validate_port(value, _scheme) do
    case Integer.parse(value) do
      {port, ""} when port in 1..65_535 -> {:ok, port}
      _ -> :error
    end
  end

  defp valid_host?(host) do
    cond do
      byte_size(host) == 0 or byte_size(host) > 253 ->
        false

      String.contains?(host, ":") ->
        match?(
          {:ok, address} when tuple_size(address) == 8,
          :inet.parse_address(to_charlist(host))
        )

      Regex.match?(~r/\A[0-9.]+\z/, host) ->
        match?(
          {:ok, address} when tuple_size(address) == 4,
          :inet.parse_address(to_charlist(host))
        )

      true ->
        host
        |> String.split(".")
        |> Enum.all?(&valid_dns_label?/1)
    end
  end

  defp valid_dns_label?(label) do
    byte_size(label) in 1..63 and Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/i, label)
  end

  defp normalize_origin(scheme, host, port) do
    host = String.downcase(host)
    authority = if String.contains?(host, ":"), do: "[#{host}]", else: host
    default_port = if scheme == "https", do: 443, else: 80
    port_suffix = if port == default_port, do: "", else: ":#{port}"

    "#{scheme}://#{authority}#{port_suffix}"
  end

  defp safe_text?(value) do
    String.valid?(value) and
      Enum.all?(:binary.bin_to_list(value), &(&1 >= 0x21 and &1 != 0x7F and &1 != ?"))
  end

  defp router(igniter, nil) do
    case Igniter.Libs.Phoenix.list_routers(igniter) do
      {igniter, []} ->
        {:ok, igniter, nil}

      {igniter, [router]} ->
        {:ok, igniter, router}

      {igniter, routers} ->
        names = routers |> Enum.map(&inspect/1) |> Enum.sort() |> Enum.join(", ")

        {:error, igniter,
         "multiple Phoenix routers were found (#{names}); choose one with --router"}
    end
  end

  defp router(igniter, value) do
    with {:ok, router} <- module_option(value, nil),
         {true, igniter} <- Igniter.Project.Module.module_exists(igniter, router) do
      {:ok, igniter, router}
    else
      {:error, message} ->
        {:error, igniter, message}

      {false, igniter} ->
        {:error, igniter, "router module #{value} was not found"}
    end
  end

  defp router_for_install(
         igniter,
         value,
         true,
         server_module,
         path,
         base_url,
         auth_source
       ) do
    case router(igniter, value) do
      {:error, igniter, message} ->
        {:error, igniter,
         manual_mcp_wiring_message(message, server_module, path, base_url, auth_source)}

      result ->
        result
    end
  end

  defp router_for_install(
         igniter,
         value,
         false,
         _server_module,
         _path,
         _base_url,
         _auth_source
       ),
       do: router(igniter, value)

  defp create_server_module(igniter, server_module, app, auth_source, metadata_mode) do
    Igniter.Project.Module.find_and_update_or_create_module(
      igniter,
      server_module,
      server_module_contents(app, auth_source, metadata_mode),
      fn zipper ->
        cond do
          not installer_managed_server?(zipper) ->
            {:error,
             "server module #{inspect(server_module)} already exists and is not installer-managed; choose --server-module"}

          installer_managed_auth_source?(zipper, auth_source) ->
            {:ok, zipper}

          true ->
            {:error,
             "server module #{inspect(server_module)} has a different installer-managed Attesto configuration; use its original authorization source or choose --server-module"}
        end
      end
    )
  end

  defp move_to_trusted_router_use(igniter, body, router) do
    modules = trusted_router_modules(igniter, router)

    with {:ok, target} <- trusted_router_use_ast(Sourceror.Zipper.node(body), modules) do
      Igniter.Code.Common.move_to(body, fn candidate ->
        Sourceror.Zipper.node(candidate) == target
      end)
    end
  end

  defp trusted_router_use_ast(ast, modules) do
    matches =
      ast
      |> top_level_alias_contexts()
      |> Enum.filter(fn {expression, aliases} ->
        trusted_router_use_expression?(expression, aliases, modules)
      end)
      |> Enum.map(&elem(&1, 0))

    case matches do
      [expression] -> {:ok, expression}
      _none_or_ambiguous -> :error
    end
  end

  defp trusted_router_use_expression?(
         {:use, _meta, [module_ast | arguments]},
         aliases,
         modules
       ) do
    module = canonical_ast(module_ast, aliases)

    module == Phoenix.Router or
      (module in modules and length(arguments) == 1 and
         literal_atom(List.first(arguments)) == :router)
  end

  defp trusted_router_use_expression?(_expression, _aliases, _modules), do: false

  defp trusted_router_modules(igniter, router) do
    [Igniter.Libs.Phoenix.web_module(igniter), inferred_router_web_module(router)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp inferred_router_web_module(router) do
    parts = Module.split(router)

    case Enum.find_index(parts, &String.ends_with?(&1, "Web")) do
      nil -> nil
      index -> parts |> Enum.take(index + 1) |> Module.concat()
    end
  end

  defp routes_available(
         igniter,
         nil,
         _server_module,
         _path,
         _base_url,
         _auth_source,
         :generate
       ),
       do: {:ok, igniter}

  defp routes_available(
         igniter,
         nil,
         server_module,
         path,
         base_url,
         auth_source,
         :reuse
       ),
       do:
         reuse_issue(
           igniter,
           "--reuse-metadata-route requires a selected Phoenix router so the exact metadata path can be proven",
           server_module,
           path,
           base_url,
           auth_source
         )

  defp routes_available(
         igniter,
         router,
         server_module,
         path,
         base_url,
         auth_source,
         metadata_mode
       ) do
    case Igniter.Project.Module.find_module(igniter, router) do
      {:ok, {igniter, _source, zipper}} ->
        with true <- isolated_module_source?(zipper),
             {:ok, body} <- Igniter.Code.Common.move_to_do_block(zipper) do
          specs = route_specs(server_module, path, base_url, auth_source, metadata_mode)

          endpoint_status = endpoint_parser_preflight(igniter, router, path)

          igniter =
            case endpoint_status do
              {:warning, message} -> Igniter.add_warning(igniter, message)
              _other -> igniter
            end

          trusted_router_use = move_to_trusted_router_use(igniter, body, router)
          router_recognized? = match?({:ok, _location}, trusted_router_use)

          dsl_provenance_safe? =
            case trusted_router_use do
              {:ok, location} ->
                router_dsl_provenance_safe?(
                  Sourceror.Zipper.node(body),
                  Sourceror.Zipper.node(location),
                  metadata_mode == :reuse
                )

              :error ->
                false
            end

          statuses =
            specs
            |> Map.new(fn {route, plug_module, _code} ->
              {route,
               forward_status(
                 body,
                 route,
                 plug_module,
                 server_module,
                 path,
                 base_url,
                 auth_source
               )}
            end)

          conflicts = for {route, :conflict} <- statuses, do: route
          scoped_forward_conflict? = scoped_forward_conflict?(body, specs)
          incompatible_forward? = incompatible_forward?(body, specs)
          route_overlap? = route_overlap?(body, specs)

          metadata_status =
            metadata_route_status(
              Sourceror.Zipper.node(body),
              path,
              server_module,
              metadata_mode
            )

          cond do
            match?({:error, _message}, metadata_status) ->
              reuse_issue(
                igniter,
                elem(metadata_status, 1),
                server_module,
                path,
                base_url,
                auth_source
              )

            not router_recognized? ->
              reuse_issue(
                igniter,
                "router #{inspect(router)} is not a recognized Phoenix router; choose --router explicitly",
                server_module,
                path,
                base_url,
                auth_source
              )

            not dsl_provenance_safe? ->
              reuse_issue(
                igniter,
                "router #{inspect(router)} contains an unqualified scope or forward whose Phoenix.Router provenance cannot be proven; mount manually or qualify the router calls",
                server_module,
                path,
                base_url,
                auth_source
              )

            match?({:error, _message}, endpoint_status) ->
              reuse_issue(
                igniter,
                elem(endpoint_status, 1),
                server_module,
                path,
                base_url,
                auth_source
              )

            conflicts != [] ->
              reuse_issue(
                igniter,
                "router #{inspect(router)} already uses #{Enum.join(conflicts, ", ")} with different forwarding options",
                server_module,
                path,
                base_url,
                auth_source
              )

            scoped_forward_conflict? ->
              reuse_issue(
                igniter,
                "router #{inspect(router)} contains a scoped forward route that collides with or cannot be distinguished from the requested MCP routes; mount manually or choose another --router",
                server_module,
                path,
                base_url,
                auth_source
              )

            incompatible_forward? ->
              reuse_issue(
                igniter,
                "router #{inspect(router)} contains a dynamic forward route or plug, an ambiguous nested forward, or reuses an MCP plug at another path; mount manually or choose another --router",
                server_module,
                path,
                base_url,
                auth_source
              )

            route_overlap? ->
              reuse_issue(
                igniter,
                "router #{inspect(router)} contains a route whose path overlaps a requested MCP route; mount manually or choose another --router",
                server_module,
                path,
                base_url,
                auth_source
              )

            true ->
              {:ok, igniter}
          end
        else
          false ->
            route_preflight_failure(
              igniter,
              metadata_mode,
              "router #{inspect(router)} must be the only top-level module in its source file so compiler provenance can be verified",
              server_module,
              path,
              base_url,
              auth_source
            )

          :error ->
            route_preflight_failure(
              igniter,
              metadata_mode,
              "could not inspect router #{inspect(router)}",
              server_module,
              path,
              base_url,
              auth_source
            )
        end

      {:error, igniter} ->
        route_preflight_failure(
          igniter,
          metadata_mode,
          "router #{inspect(router)} was not found",
          server_module,
          path,
          base_url,
          auth_source
        )
    end
  end

  defp route_preflight_failure(
         igniter,
         :reuse,
         message,
         server_module,
         path,
         base_url,
         auth_source
       ),
       do: reuse_issue(igniter, message, server_module, path, base_url, auth_source)

  defp route_preflight_failure(
         igniter,
         :generate,
         message,
         _server_module,
         _path,
         _base_url,
         _auth_source
       ),
       do: {:error, igniter, message}

  defp installer_managed_server?(zipper) do
    with true <- isolated_module_source?(zipper),
         {:ok, module_body} <- module_body_ast(Sourceror.Zipper.node(zipper)),
         true <- installer_managed_module_body?(module_body),
         [definition] <- definitions_named(module_body, :__attesto_mcp_server_installer__),
         {:ok, actual} <-
           plain_zero_arity_definition_body(
             definition,
             :__attesto_mcp_server_installer__
           ),
         {:ok, aliases} <- aliases_before_expression(module_body, definition) do
      canonical_ast(actual, aliases) == :v1
    else
      _other -> false
    end
  end

  defp installer_managed_auth_source?(zipper, auth_source) do
    expected =
      auth_source
      |> attesto_config_code()
      |> Sourceror.parse_string!()
      |> canonical_ast(%{})

    with true <- isolated_module_source?(zipper),
         {:ok, module_body} <- module_body_ast(Sourceror.Zipper.node(zipper)),
         true <- installer_managed_module_body?(module_body),
         [definition] <- attesto_config_definitions(module_body),
         {:ok, actual} <- plain_attesto_config_body(definition),
         {:ok, aliases} <- aliases_before_expression(module_body, definition) do
      canonical_ast(actual, aliases) == expected
    else
      _other -> false
    end
  end

  defp isolated_module_source?(zipper) do
    target = Sourceror.Zipper.node(zipper)

    ancestors =
      Stream.unfold(zipper, fn current ->
        case Sourceror.Zipper.up(current) do
          nil -> nil
          parent -> {Sourceror.Zipper.node(parent), parent}
        end
      end)
      |> Enum.to_list()

    case Sourceror.Zipper.topmost_root(zipper) |> top_level_expressions() do
      [{:defmodule, _meta, [_module, options]} = module] when is_list(options) ->
        target == module or direct_root_module_body?(target, ancestors, module)

      _not_one_dedicated_module ->
        false
    end
  end

  defp direct_root_module_body?(target, [{key, value}, options, ancestor], module)
       when is_list(options),
       do:
         not match?({:defmodule, _meta, _arguments}, target) and value == target and
           ancestor == module and literal_atom(key) == :do

  defp direct_root_module_body?(_target, _ancestors, _module), do: false

  defp module_body_ast({:defmodule, _meta, [_module, options]}) when is_list(options),
    do: keyword_value(options, :do)

  defp module_body_ast(ast), do: {:ok, ast}

  defp attesto_config_definitions(ast) do
    definitions_named(ast, :attesto_config)
  end

  defp definitions_named(ast, name) do
    ast
    |> collect_definition_contexts(%{})
    |> Enum.filter(fn {definition, _aliases} ->
      definition_name(definition_head(definition)) == name
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp installer_managed_module_body?(ast) do
    not custom_macro_surface?(ast) and
      ast
      |> top_level_alias_contexts()
      |> Enum.all?(fn {expression, aliases} ->
        installer_managed_top_level_expression?(expression, aliases)
      end)
  end

  defp custom_macro_surface?({form, meta, arguments})
       when form in [:import, :require, :use] and is_list(meta) and is_list(arguments),
       do: true

  defp custom_macro_surface?({kind, meta, _arguments})
       when kind in [:defmacro, :defmacrop, :defguard, :defguardp] and is_list(meta),
       do: true

  defp custom_macro_surface?({{:., _dot_meta, [_module_ast, kind]}, call_meta, _arguments})
       when kind in [:defmacro, :defmacrop, :defguard, :defguardp] and is_list(call_meta),
       do: true

  defp custom_macro_surface?(node) when is_tuple(node) do
    node
    |> Tuple.to_list()
    |> Enum.any?(&custom_macro_surface?/1)
  end

  defp custom_macro_surface?(node) when is_list(node),
    do: Enum.any?(node, &custom_macro_surface?/1)

  defp custom_macro_surface?(_literal), do: false

  defp installer_managed_top_level_expression?(
         {:defmodule, _meta, [module_ast, options]},
         aliases
       )
       when is_list(options) do
    with {:ok, _module} <- resolve_alias_module(module_ast, aliases),
         {:ok, nested_body} <- keyword_value(options, :do) do
      installer_managed_module_body?(nested_body)
    else
      _invalid_or_dynamic_module -> false
    end
  end

  defp installer_managed_top_level_expression?({:alias, _meta, arguments}, _aliases)
       when is_list(arguments),
       do: Enum.all?(arguments, &quoted_literal_ast?/1)

  defp installer_managed_top_level_expression?({:@, _meta, _arguments} = attribute, _aliases),
    do: safe_installer_module_attribute?(attribute)

  defp installer_managed_top_level_expression?({kind, _meta, [head | _rest]}, _aliases)
       when kind in @definition_kinds,
       do: definition_name(head) != nil

  defp installer_managed_top_level_expression?(
         {{:., _dot_meta, [module_ast, kind]}, _call_meta, [head | _rest]},
         aliases
       )
       when kind in @definition_kinds,
       do: canonical_ast(module_ast, aliases) == Kernel and definition_name(head) != nil

  defp installer_managed_top_level_expression?(_expression, _aliases), do: false

  defp safe_installer_module_attribute?({:@, _meta, [{name, _attribute_meta, arguments}]})
       when is_atom(name) and is_list(arguments) do
    cond do
      name in @unsafe_compile_attributes ->
        false

      name in @typespec_attributes and match?([_value], arguments) ->
        arguments |> List.first() |> safe_typespec_ast?()

      match?([_value], arguments) ->
        arguments |> List.first() |> quoted_literal_ast?()

      true ->
        false
    end
  end

  defp safe_installer_module_attribute?(_attribute), do: false

  defp quoted_literal_ast?(value),
    do: value |> canonical_ast(%{}) |> Macro.quoted_literal?()

  defp safe_typespec_ast?({:__block__, _meta, [value]}), do: safe_typespec_ast?(value)

  defp safe_typespec_ast?({form, _meta, _arguments})
       when form in [
              :for,
              :with,
              :case,
              :cond,
              :if,
              :unless,
              :receive,
              :try,
              :fn,
              :quote,
              :unquote,
              :unquote_splicing,
              :alias,
              :import,
              :require,
              :use,
              :defmodule,
              :defprotocol,
              :defimpl,
              :@,
              :__block__
            ],
       do: false

  defp safe_typespec_ast?({form, _meta, _arguments}) when form in @definition_kinds,
    do: false

  defp safe_typespec_ast?(node) when is_tuple(node) do
    node
    |> Tuple.to_list()
    |> Enum.all?(&safe_typespec_ast?/1)
  end

  defp safe_typespec_ast?(node) when is_list(node),
    do: Enum.all?(node, &safe_typespec_ast?/1)

  defp safe_typespec_ast?(_literal), do: true

  defp collect_definition_contexts({:__block__, _meta, expressions}, aliases) do
    {contexts, _aliases} =
      Enum.map_reduce(expressions, aliases, fn expression, current_aliases ->
        {collect_definition_contexts(expression, current_aliases),
         aliases_after_expression(expression, current_aliases)}
      end)

    List.flatten(contexts)
  end

  defp collect_definition_contexts(
         {container, _meta, _arguments},
         _aliases
       )
       when container in [:defmodule, :defprotocol, :defimpl, :quote],
       do: []

  defp collect_definition_contexts(node, aliases) do
    case definition_head(node) do
      nil -> collect_definition_context_children(node, aliases)
      _head -> [{node, aliases}]
    end
  end

  defp collect_definition_context_children(node, aliases) when is_tuple(node) do
    node
    |> Tuple.to_list()
    |> Enum.flat_map(&collect_definition_contexts(&1, aliases))
  end

  defp collect_definition_context_children(node, aliases) when is_list(node),
    do: Enum.flat_map(node, &collect_definition_contexts(&1, aliases))

  defp collect_definition_context_children(_node, _aliases), do: []

  defp definition_head({kind, _meta, [head | _rest]})
       when kind in @definition_kinds,
       do: head

  defp definition_head({{:., _dot_meta, [_module_ast, kind]}, _call_meta, [head | _rest]})
       when kind in @definition_kinds,
       do: head

  defp definition_head(_expression), do: nil

  defp definition_name({:when, _meta, [head | _guards]}), do: definition_name(head)
  defp definition_name({name, _meta, _arguments}) when is_atom(name), do: name
  defp definition_name(_head), do: nil

  defp plain_attesto_config_body(definition),
    do: plain_zero_arity_definition_body(definition, :attesto_config)

  defp plain_zero_arity_definition_body(
         {:def, _meta, [{name, _call_meta, arguments}, options]},
         expected_name
       )
       when name == expected_name and arguments in [nil, []] and is_list(options),
       do: keyword_value(options, :do)

  defp plain_zero_arity_definition_body(_definition, _expected_name), do: :error

  defp server_module_contents(app, auth_source, metadata_mode) do
    metadata_plug =
      if metadata_mode == :generate do
        """
        defmodule MetadataPlug do
          @moduledoc false
          @behaviour Plug

          @impl Plug
          defdelegate init(options), to: AttestoMCP.Server.Plug

          @impl Plug
          defdelegate call(conn, options), to: AttestoMCP.Server.Plug
        end
        """
      else
        ""
      end

    """
    @moduledoc "Application-owned MCP registrations and Attesto integration."

    alias AttestoMCP.Server.API

    @otp_app #{inspect(app)}

    @doc false
    def __attesto_mcp_server_installer__, do: :v1

    #{metadata_plug}

    @spec child_spec(keyword()) :: Supervisor.child_spec()
    def child_spec(options) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [options]},
        type: :worker
      }
    end

    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(options \\\\ []) do
      configured =
        @otp_app
        |> Application.get_env(__MODULE__, [])
        |> Keyword.get(:server_options, [])

      options =
        configured
        |> Keyword.merge(options)
        |> Keyword.put_new(:name, __MODULE__)
        |> Keyword.put_new(:server_name, "#{app}-mcp")
        |> Keyword.put_new_lazy(:server_version, &application_version/0)

      case API.start_link(options) do
        {:ok, server} ->
          case register(server) do
            :ok ->
              {:ok, server}

            {:error, reason} ->
              GenServer.stop(server)
              {:error, {:registration_failed, reason}}
          end

        other ->
          other
      end
    end

    @spec register(API.server()) :: :ok | {:error, term()}
    def register(server) do
      API.register_tool(server, "server_status", %{
        description: "Return the MCP server status",
        input_schema: %{
          "type" => "object",
          "properties" => %{},
          "additionalProperties" => false
        },
        handler: fn %{}, _context -> {:ok, "ok"} end
      })
    end

    @spec attesto_config() :: term()
    def attesto_config do
      #{attesto_config_code(auth_source)}
    end

    defp application_version do
      case Application.spec(@otp_app, :vsn) do
        nil -> "0.0.0"
        version -> to_string(version)
      end
    end
    """
  end

  defp attesto_config_code({:attesto_phoenix, app}) do
    "AttestoMCP.Server.Phoenix.attesto_config(#{inspect(app)})"
  end

  defp attesto_config_code({:callback, module, function}) do
    "#{inspect(module)}.#{function}()"
  end

  defp configure_server(igniter, app, server_module, session_config) do
    server_options = [server_name: "#{app}-mcp"]

    igniter =
      Igniter.Project.Config.configure_new(
        igniter,
        "config.exs",
        app,
        [server_module, :server_options],
        server_options
      )

    case session_config do
      %{mode: :ecto, existing?: true} ->
        igniter

      %{mode: :ecto, repo: repo, schema_prefix: schema_prefix, namespace: namespace} ->
        igniter
        |> Igniter.Project.Config.configure_new(
          "config.exs",
          app,
          [server_module, :server_options, :session_store],
          {:code,
           quote do
             {AttestoMCP.Server.SessionStore.Ecto,
              %{
                repo: unquote(repo),
                namespace: unquote(namespace),
                schema_prefix: unquote(schema_prefix)
              }}
           end}
        )
        |> Igniter.Project.Config.configure_new(
          "config.exs",
          app,
          [server_module, :server_options, :session_namespace],
          namespace
        )

      %{mode: :ets, requested: :ets} ->
        # ETS is the server default. Keep an explicit opt-out source-neutral so
        # it does not add a misleading `session_store: nil` to host config.
        igniter

      _other ->
        igniter
    end
  end

  defp add_server_child(igniter, server_module, %{mode: :ecto, repo: repo}) do
    Igniter.Project.Application.add_new_child(igniter, server_module, after: [repo])
  end

  defp add_server_child(igniter, server_module, _session_config) do
    Igniter.Project.Application.add_new_child(igniter, server_module)
  end

  defp configure_authorization_server(
         igniter,
         app,
         {:attesto_phoenix, _app},
         dependencies,
         enable_cimd?
       ) do
    igniter =
      Enum.reduce(dependencies, igniter, fn dependency, acc ->
        Igniter.Project.Deps.add_dep(acc, dependency, yes?: true)
      end)

    if enable_cimd? do
      igniter
      |> Igniter.Project.Config.configure_new(
        "config.exs",
        app,
        [AttestoPhoenix.Config, :client_id_metadata, :enabled],
        true
      )
      |> configure_native_loopback(app)
    else
      configure_native_loopback(igniter, app)
    end
  end

  defp configure_authorization_server(
         igniter,
         _app,
         {:callback, _module, _function},
         _dependencies,
         _enable_cimd?
       ),
       do: igniter

  defp configure_native_loopback(igniter, app) do
    Igniter.Project.Config.configure_new(
      igniter,
      "config.exs",
      app,
      [AttestoPhoenix.Config, :native_apps, :loopback_include_localhost],
      true
    )
  end

  defp add_routes(
         igniter,
         nil,
         server_module,
         path,
         base_url,
         auth_source,
         metadata_mode
       ) do
    Igniter.add_warning(
      igniter,
      Igniter.Util.Warning.formatted_warning(
        "No Phoenix router was found. Add these forwards manually without a browser session or CSRF pipeline.",
        forward_code(server_module, path, base_url, auth_source, metadata_mode)
      )
    )
  end

  defp add_routes(igniter, router, server_module, path, base_url, auth_source, metadata_mode) do
    igniter = update_endpoint_parser(igniter, router, path)

    Igniter.Project.Module.find_and_update_module!(igniter, router, fn zipper ->
      zipper =
        if metadata_mode == :generate do
          upgrade_legacy_phoenix_forwards(
            zipper,
            server_module,
            path,
            base_url,
            auth_source
          )
        else
          zipper
        end

      missing =
        server_module
        |> route_specs(path, base_url, auth_source, metadata_mode)
        |> Enum.reject(fn {route, plug_module, _code} ->
          forward_present?(
            zipper,
            route,
            plug_module,
            server_module,
            path,
            base_url,
            auth_source
          )
        end)
        |> Enum.map_join("\n\n", &elem(&1, 2))

      if missing == "" do
        {:ok, zipper}
      else
        location =
          if metadata_mode == :reuse do
            move_to_metadata_route(zipper, metadata_path(path))
          else
            move_to_trusted_router_use(igniter, zipper, router)
          end

        with {:ok, location} <- location do
          {:ok, Igniter.Code.Common.add_code(location, missing, placement: :after)}
        else
          _not_found ->
            {:warning,
             Igniter.Util.Warning.formatted_warning(
               "Could not locate the Phoenix router use statement. Add these forwards manually.",
               missing
             )}
        end
      end
    end)
  end

  defp forward_present?(
         zipper,
         route,
         plug_module,
         server_module,
         path,
         base_url,
         auth_source
       ) do
    forward_status(
      zipper,
      route,
      plug_module,
      server_module,
      path,
      base_url,
      auth_source
    ) == :present
  end

  defp move_to_metadata_route(zipper, route) do
    ast =
      case Sourceror.Zipper.node(zipper) do
        {:defmodule, _meta, [_module, options]} when is_list(options) ->
          case keyword_value(options, :do) do
            {:ok, body} -> body
            :error -> Sourceror.Zipper.node(zipper)
          end

        node ->
          node
      end

    target =
      attesto_route_contexts(ast)
      |> Enum.find_value(fn context ->
        if context.metadata_path == route and context.scope_prefix == [] and
             context.router_use_before?,
           do: context.call
      end)

    if target do
      Igniter.Code.Common.move_to(zipper, fn candidate ->
        Sourceror.Zipper.node(candidate) == target
      end)
    end
  end

  defp update_endpoint_parser(igniter, router, path) do
    case endpoint_parser_preflight(igniter, router, path) do
      {:ok, :replace} ->
        endpoint = inferred_endpoint_module(router)

        igniter =
          Igniter.Project.Module.find_and_update_module!(igniter, endpoint, fn body ->
            with parser_body = Sourceror.Zipper.node(body),
                 {:ok, parser} <-
                   endpoint_parser_expression(parser_body),
                 {:ok, location} <-
                   Igniter.Code.Common.move_to(body, fn candidate ->
                     Sourceror.Zipper.node(candidate) == parser
                   end) do
              {:ok,
               Igniter.Code.Common.replace_code(
                 location,
                 wrapped_parser_code(parser, path)
               )}
            else
              _not_found -> {:ok, body}
            end
          end)

        Igniter.add_notice(igniter, endpoint_parser_wrapped_notice(endpoint, path))

      {:warning, _message} ->
        igniter

      {:error, message} ->
        Igniter.add_issue(igniter, message)

      {:ok, :present} ->
        igniter
    end
  end

  defp inferred_endpoint_module(router) do
    case inferred_router_web_module(router) do
      nil -> nil
      web_module -> Module.concat(web_module, Endpoint)
    end
  end

  defp endpoint_parser_preflight(igniter, router, path) do
    endpoint = inferred_endpoint_module(router)

    case endpoint do
      nil ->
        {:warning,
         "Phoenix endpoint could not be inferred from router #{inspect(router)}; " <>
           "installation will continue without an endpoint edit. Verify the selected host " <>
           "endpoint manually; a direct standard `Plug.Parsers` declaration must be wrapped " <>
           "with `plug Elixir.AttestoMCP.Server.PhoenixParser, mcp_path: #{inspect(path)}, ...` " <>
           "while preserving its options. Ordinary routes below the configured MCP prefix " <>
           "#{inspect(path)} also bypass host body parsing, must not overlap the MCP forward, " <>
           "and must be reviewed if added later."}

      endpoint ->
        endpoint_parser_preflight(igniter, router, path, endpoint)
    end
  end

  defp endpoint_parser_preflight(igniter, router, path, endpoint) do
    case Igniter.Project.Module.find_module(igniter, endpoint) do
      {:ok, {_igniter, _source, zipper}} ->
        with true <- isolated_module_source?(zipper),
             {:ok, body} <- Igniter.Code.Common.move_to_do_block(zipper) do
          endpoint_parser_status(Sourceror.Zipper.node(body), path, endpoint, router)
        else
          false ->
            {:error,
             endpoint_parser_warning(
               endpoint,
               path,
               "the endpoint source is not an isolated module"
             )}

          :error ->
            {:error,
             endpoint_parser_warning(endpoint, path, "the endpoint body could not be inspected")}
        end

      _not_found ->
        {:warning,
         endpoint_parser_warning(
           endpoint,
           path,
           "no endpoint source was found"
         )}
    end
  end

  defp endpoint_parser_status(body, path, endpoint, router) do
    parser_calls = endpoint_parser_contexts(body)
    nested_plug_calls = nested_endpoint_plug_calls(body)

    cond do
      parser_calls == [] and endpoint_no_parser_pipeline_safe?(body, router) ->
        {:warning, endpoint_no_parser_warning(endpoint, path)}

      parser_calls == [] ->
        {:error,
         endpoint_parser_warning(
           endpoint,
           path,
           "a custom or ambiguous endpoint plug can read the request body before MCP authentication"
         )}

      not Enum.all?(nested_plug_calls, &endpoint_nested_plug_allowed?/1) or
          not endpoint_plug_provenance_safe?(body, router) ->
        {:error,
         endpoint_parser_warning(
           endpoint,
           path,
           "a nested parser call or local/imported plug macro makes parser provenance ambiguous"
         )}

      true ->
        calls = parser_calls
        wrapped = Enum.filter(calls, &(&1.kind == :wrapped))
        direct = Enum.filter(calls, &(&1.kind == :direct))
        invalid = Enum.filter(calls, &(&1.kind == :invalid))

        cond do
          invalid != [] ->
            {:error,
             endpoint_parser_warning(
               endpoint,
               path,
               "one or more Plug.Parsers declarations use unsupported, duplicate, dynamic, or custom options"
             )}

          length(wrapped) == 1 and direct == [] and
            wrapped |> List.first() |> Map.get(:path) == path and
              endpoint_plug_pipeline_safe?(body, router) ->
            {:ok, :present}

          length(wrapped) == 1 and direct == [] ->
            {:error,
             endpoint_parser_warning(
               endpoint,
               path,
               "an existing AttestoMCP parser bypass targets a different path or is followed by an unproven plug"
             )}

          length(direct) == 1 and wrapped == [] and
              endpoint_plug_pipeline_safe?(body, router) ->
            {:ok, :replace}

          length(direct) == 1 and wrapped == [] ->
            {:error,
             endpoint_parser_warning(
               endpoint,
               path,
               "a plug after the parser is not a proven standard plug or the selected Phoenix router"
             )}

          true ->
            {:error,
             endpoint_parser_warning(
               endpoint,
               path,
               "the parser declarations are ambiguous or use a custom wrapper"
             )}
        end
    end
  end

  defp endpoint_no_parser_pipeline_safe?(body, router) do
    direct_contexts = direct_endpoint_plug_calls(body)

    Enum.all?(direct_contexts, fn {expression, aliases} ->
      endpoint_no_parser_plug_allowed?(expression, aliases, router)
    end) and
      Enum.all?(nested_endpoint_plug_calls(body), &endpoint_nested_plug_allowed?/1) and
      endpoint_terminal_router?(Enum.with_index(direct_contexts), router) and
      endpoint_session_options_provenance_safe?(body) and
      endpoint_opaque_calls(body) == [] and
      definitions_named(body, :plug) == [] and
      not contains_import?(body) and
      not contains_require?(body) and
      not contains_unsafe_router_compile_attribute?(body) and
      not contains_unsafe_endpoint_attribute?(body) and
      body |> top_level_alias_contexts() |> Enum.all?(&endpoint_use_provenance_safe?/1)
  end

  defp endpoint_no_parser_plug_allowed?(expression, aliases, router) do
    endpoint_plug_module_allowed?(expression, aliases) or
      endpoint_post_parser_plug_allowed?(expression, aliases, router)
  end

  defp endpoint_parser_contexts(body) do
    body
    |> top_level_alias_contexts()
    |> Enum.flat_map(fn {expression, aliases} ->
      case endpoint_parser_call(expression, aliases) do
        {:ok, kind, parser_path} ->
          [%{call: expression, kind: kind, path: parser_path}]

        :error ->
          if endpoint_parser_module_call?(expression, aliases),
            do: [%{call: expression, kind: :invalid, path: nil}],
            else: []
      end
    end)
  end

  defp endpoint_parser_module_call?({:plug, _meta, [module_ast | _arguments]}, aliases) do
    canonical_ast(module_ast, aliases) in [Plug.Parsers, AttestoMCP.Server.PhoenixParser]
  end

  defp endpoint_parser_module_call?(_expression, _aliases), do: false

  defp direct_endpoint_plug_calls(body) do
    body
    |> top_level_alias_contexts()
    |> Enum.filter(fn {expression, _aliases} ->
      match?({:plug, _meta, _arguments}, expression)
    end)
  end

  defp nested_endpoint_plug_calls(body) do
    body
    |> top_level_alias_contexts()
    |> Enum.flat_map(fn {expression, aliases} ->
      if match?({:plug, _meta, _arguments}, expression) do
        []
      else
        expression
        |> nested_plug_nodes()
        |> Enum.map(&{&1, aliases})
      end
    end)
  end

  defp nested_plug_nodes(expression) do
    {_expression, plugs} =
      Macro.prewalk(expression, [], fn
        {:plug, _meta, _arguments} = node, plugs -> {node, [node | plugs]}
        node, plugs -> {node, plugs}
      end)

    plugs
  end

  defp endpoint_nested_plug_allowed?({{:plug, _meta, [module_ast | arguments]}, aliases}) do
    canonical_ast(module_ast, aliases) in [
      Plug.Static,
      Plug.RequestId,
      Plug.MethodOverride,
      Plug.Head,
      Plug.Logger,
      Plug.Telemetry,
      Plug.Session,
      Phoenix.Ecto.CheckRepoStatus,
      Phoenix.LiveDashboard.RequestLogger,
      Phoenix.LiveReloader,
      Phoenix.CodeReloader
    ] and endpoint_allowed_plug_options_safe?(arguments, canonical_ast(module_ast, aliases))
  end

  defp endpoint_nested_plug_allowed?(_call), do: false

  defp endpoint_plug_provenance_safe?(body, router) do
    definitions_named(body, :plug) == [] and
      not contains_import?(body) and
      not contains_require?(body) and
      not contains_unsafe_router_compile_attribute?(body) and
      not contains_unsafe_endpoint_attribute?(body) and
      endpoint_session_options_provenance_safe?(body) and
      body |> top_level_alias_contexts() |> Enum.all?(&endpoint_use_provenance_safe?/1) and
      endpoint_opaque_calls(body) == [] and
      endpoint_plug_pipeline_safe?(body, router)
  end

  defp endpoint_opaque_calls(body) do
    body
    |> top_level_alias_contexts()
    |> Enum.flat_map(fn {expression, aliases} ->
      if match?({:use, _meta, _arguments}, expression) do
        []
      else
        endpoint_opaque_runtime_nodes(expression, aliases)
      end
    end)
  end

  defp contains_unsafe_endpoint_attribute?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {:@, _meta, [{name, _attribute_meta, _values}]} = node, _found?
        when name in [:plugs, :before_compile, :after_compile, :on_definition] ->
          {node, true}

        {:@, _meta, [{_name, _attribute_meta, [value]}]} = node, _found? ->
          {node, not endpoint_static_value_safe?(value)}

        {:@, _meta, [{_name, _attribute_meta, nil}]} = node, found? ->
          {node, found?}

        node, found? ->
          {node, found?}
      end)

    found?
  end

  defp endpoint_opaque_runtime_nodes({:__block__, _meta, expressions}, aliases),
    do: Enum.flat_map(expressions, &endpoint_opaque_runtime_nodes(&1, aliases))

  defp endpoint_opaque_runtime_nodes({:if, _meta, arguments}, aliases),
    do:
      endpoint_condition_nodes(arguments, aliases) ++
        endpoint_control_body_nodes(arguments, aliases)

  defp endpoint_opaque_runtime_nodes({:unless, _meta, arguments}, aliases),
    do:
      endpoint_condition_nodes(arguments, aliases) ++
        endpoint_control_body_nodes(arguments, aliases)

  defp endpoint_opaque_runtime_nodes({:plug, _meta, _arguments}, _aliases), do: []

  defp endpoint_opaque_runtime_nodes({:socket, _meta, arguments} = node, _aliases) do
    if endpoint_static_values_safe?(arguments), do: [], else: [node]
  end

  defp endpoint_opaque_runtime_nodes({:use, _meta, _arguments} = node, _aliases), do: [node]
  defp endpoint_opaque_runtime_nodes({:@, _meta, _arguments}, _aliases), do: []

  defp endpoint_opaque_runtime_nodes({form, _meta, _arguments}, _aliases)
       when form in @definition_kinds,
       do: []

  defp endpoint_opaque_runtime_nodes({:alias, _meta, arguments} = node, _aliases) do
    if endpoint_static_values_safe?(arguments), do: [], else: [node]
  end

  defp endpoint_opaque_runtime_nodes({:import, _meta, _arguments}, _aliases), do: []
  defp endpoint_opaque_runtime_nodes({:require, _meta, _arguments}, _aliases), do: []

  defp endpoint_opaque_runtime_nodes(
         {{:., _dot_meta, [_module_ast, _name]}, _call_meta, _arguments} = node,
         _aliases
       ),
       do: [node]

  defp endpoint_opaque_runtime_nodes({name, _meta, _arguments} = node, _aliases)
       when name in [:case, :cond, :try, :with],
       do: [node]

  defp endpoint_opaque_runtime_nodes({name, _meta, _arguments} = node, _aliases)
       when is_atom(name),
       do: [node]

  defp endpoint_opaque_runtime_nodes(_node, _aliases), do: []

  defp endpoint_control_body_nodes(arguments, aliases) when is_list(arguments) do
    case List.last(arguments) do
      options when is_list(options) ->
        options
        |> Enum.flat_map(fn {key_ast, body} ->
          if literal_atom(key_ast) in [:do, :else],
            do: endpoint_opaque_runtime_nodes(body, aliases),
            else: []
        end)

      _other ->
        []
    end
  end

  defp endpoint_control_body_nodes(_arguments, _aliases), do: []

  defp endpoint_condition_nodes([condition | _rest], aliases) do
    case condition do
      {:__block__, _meta, [inner]} ->
        endpoint_condition_nodes([inner], aliases)

      {:code_reloading?, _meta, arguments} when arguments in [nil, []] ->
        []

      {:function_exported?, _meta, [module_ast, name_ast, arity_ast]} ->
        if match?({:__aliases__, _module_meta, _parts}, module_ast) and
             is_atom(canonical_ast(module_ast, aliases)) and
             is_atom(literal_atom(name_ast)) and is_integer(literal_integer(arity_ast)) do
          []
        else
          endpoint_opaque_runtime_nodes(condition, aliases)
        end

      _other ->
        endpoint_opaque_runtime_nodes(condition, aliases)
    end
  end

  defp endpoint_condition_nodes(_arguments, _aliases), do: []

  defp endpoint_use_provenance_safe?({expression, aliases}) do
    case expression do
      {:use, _meta, [module_ast | arguments]} ->
        canonical_ast(module_ast, aliases) == Phoenix.Endpoint and
          endpoint_module_ast_literal?(module_ast) and
          endpoint_plug_options_safe?(arguments)

      _other ->
        true
    end
  end

  defp endpoint_plug_pipeline_safe?(body, router) do
    contexts = direct_endpoint_plug_calls(body)

    case Enum.find_index(contexts, fn {expression, aliases} ->
           match?({:ok, _kind, _path}, endpoint_parser_call(expression, aliases))
         end) do
      nil ->
        false

      parser_index ->
        indexed_contexts = Enum.with_index(contexts)

        pipeline_safe? =
          Enum.all?(indexed_contexts, fn {{expression, aliases}, index} ->
            if index <= parser_index do
              endpoint_plug_module_allowed?(expression, aliases)
            else
              endpoint_post_parser_plug_allowed?(expression, aliases, router)
            end
          end)

        post_parser = Enum.drop(indexed_contexts, parser_index + 1)
        terminal_router? = endpoint_terminal_router?(post_parser, router)

        pipeline_safe? and terminal_router?
    end
  end

  defp endpoint_terminal_router?(indexed_contexts, router) when is_atom(router) do
    router_indices =
      indexed_contexts
      |> Enum.filter(fn {{expression, aliases}, _index} ->
        endpoint_router_plug?(expression, aliases, router)
      end)
      |> Enum.map(&elem(&1, 1))

    length(router_indices) == 1 and
      List.last(router_indices) == elem(List.last(indexed_contexts), 1)
  end

  defp endpoint_router_plug?({:plug, _meta, [module_ast | arguments]}, aliases, router),
    do:
      canonical_ast(module_ast, aliases) == router and
        endpoint_allowed_plug_options_safe?(arguments, router)

  defp endpoint_router_plug?(_expression, _aliases, _router), do: false

  defp endpoint_post_parser_plug_allowed?(
         {:plug, _meta, [module_ast | arguments]},
         aliases,
         router
       ) do
    module = canonical_ast(module_ast, aliases)

    (module in [
       Plug.RequestId,
       Plug.MethodOverride,
       Plug.Head,
       Plug.Logger,
       Plug.Telemetry,
       Plug.Session,
       Phoenix.Ecto.CheckRepoStatus,
       Phoenix.LiveDashboard.RequestLogger
     ] or module == router) and
      endpoint_allowed_plug_options_safe?(arguments, module)
  end

  defp endpoint_post_parser_plug_allowed?(_expression, _aliases, _router), do: false

  defp endpoint_plug_module_allowed?({:plug, _meta, [module_ast | arguments]}, aliases) do
    module = canonical_ast(module_ast, aliases)

    parser? = module in [Plug.Parsers, AttestoMCP.Server.PhoenixParser]

    if parser? do
      match?(
        {:ok, _kind, _path},
        endpoint_parser_call({:plug, [], [module_ast | arguments]}, aliases)
      )
    else
      endpoint_allowed_plug_options_safe?(arguments, module) and
        module in [
          Plug.Static,
          Plug.RequestId,
          Plug.MethodOverride,
          Plug.Head,
          Plug.Logger,
          Plug.Telemetry,
          Plug.Session,
          Phoenix.Ecto.CheckRepoStatus,
          Phoenix.LiveDashboard.RequestLogger,
          Phoenix.LiveReloader
        ]
    end
  end

  defp endpoint_plug_module_allowed?(_expression, _aliases), do: false

  defp endpoint_plug_options_safe?(arguments) when is_list(arguments) do
    length(arguments) <= 1 and Enum.all?(arguments, &endpoint_static_value_safe?/1)
  end

  defp endpoint_plug_options_safe?(_arguments), do: false

  defp endpoint_allowed_plug_options_safe?(arguments, Plug.Session),
    do: endpoint_session_options_safe?(arguments)

  defp endpoint_allowed_plug_options_safe?(arguments, _module),
    do: endpoint_plug_options_safe?(arguments)

  defp endpoint_session_options_safe?([options]) when is_list(options) do
    endpoint_plug_options_safe?([options]) and
      case quoted_keyword_values(options, :store) do
        [] -> true
        [store] -> literal_atom(store) == :cookie
        _duplicate -> false
      end
  end

  defp endpoint_session_options_safe?([{:@, _meta, [{_name, _attribute_meta, nil}]}]),
    do: true

  defp endpoint_session_options_safe?(arguments),
    do: endpoint_plug_options_safe?(arguments)

  defp endpoint_session_options_provenance_safe?(body) do
    attributes = endpoint_session_attribute_values(body)

    (direct_endpoint_plug_calls(body) ++ nested_endpoint_plug_calls(body))
    |> Enum.all?(fn
      {{:plug, _meta, [module_ast | arguments]}, aliases} ->
        if canonical_ast(module_ast, aliases) == Plug.Session do
          case arguments do
            [{:@, _attribute_meta, [{name, _name_meta, nil}]}] ->
              case Map.get(attributes, name) do
                [value] -> endpoint_session_attribute_value_safe?(value)
                _ambiguous_or_missing -> false
              end

            _literal_or_invalid ->
              true
          end
        else
          true
        end

      _other ->
        true
    end)
  end

  defp endpoint_session_attribute_values(body) do
    {_body, attributes} =
      Macro.prewalk(body, %{}, fn
        {:@, _meta, [{name, _attribute_meta, [value]}]} = node, attributes
        when is_atom(name) ->
          {node, Map.update(attributes, name, [value], &[value | &1])}

        node, attributes ->
          {node, attributes}
      end)

    attributes
  end

  defp endpoint_session_attribute_value_safe?(value) when is_list(value) do
    endpoint_static_value_safe?(value) and
      case quoted_keyword_values(value, :store) do
        [store] -> literal_atom(store) == :cookie
        _missing_or_duplicate -> false
      end
  end

  defp endpoint_session_attribute_value_safe?({:__block__, _meta, [value]}),
    do: endpoint_session_attribute_value_safe?(value)

  defp endpoint_session_attribute_value_safe?(_value), do: false

  defp endpoint_static_values_safe?(arguments) when is_list(arguments),
    do: Enum.all?(arguments, &endpoint_static_value_safe?/1)

  defp endpoint_static_values_safe?(_arguments), do: false

  defp endpoint_static_value_safe?(value) when is_atom(value) or is_binary(value), do: true
  defp endpoint_static_value_safe?(value) when is_integer(value) or is_float(value), do: true

  defp endpoint_static_value_safe?({:__block__, _meta, [value]}),
    do: endpoint_static_value_safe?(value)

  defp endpoint_static_value_safe?({:__aliases__, _meta, parts}) when is_list(parts),
    do: Enum.all?(parts, &is_atom/1)

  defp endpoint_static_value_safe?(values) when is_list(values),
    do: Enum.all?(values, &endpoint_static_value_safe?/1)

  defp endpoint_static_value_safe?({key, value}) do
    case literal_atom(key) do
      nil -> false
      _atom -> endpoint_static_value_safe?(value)
    end
  end

  defp endpoint_static_value_safe?({:{}, _meta, values}) when is_list(values),
    do: Enum.all?(values, &endpoint_static_value_safe?/1)

  defp endpoint_static_value_safe?({:%{}, _meta, values}) when is_list(values),
    do: Enum.all?(values, &endpoint_static_map_entry_safe?/1)

  defp endpoint_static_value_safe?({:not, _not_meta, [{:code_reloading?, _call_meta, arguments}]})
       when arguments in [nil, []],
       do: true

  defp endpoint_static_value_safe?({:code_reloading?, _call_meta, arguments})
       when arguments in [nil, []],
       do: true

  defp endpoint_static_value_safe?(
         {{:., _dot_meta, [{:__aliases__, _module_meta, parts}, :static_paths]}, _call_meta, []}
       ) do
    case List.last(parts) do
      module when is_atom(module) -> String.ends_with?(Atom.to_string(module), "Web")
      _other -> false
    end
  end

  defp endpoint_static_value_safe?(_value), do: false

  defp endpoint_static_map_entry_safe?({key, value}),
    do: endpoint_static_value_safe?(key) and endpoint_static_value_safe?(value)

  defp endpoint_static_map_entry_safe?(_entry), do: false

  defp endpoint_module_ast_literal?({:__aliases__, _meta, [:Phoenix, :Endpoint]}), do: true
  defp endpoint_module_ast_literal?(_module_ast), do: false

  defp endpoint_parser_expression(body) do
    case endpoint_parser_contexts(body) |> Enum.filter(&(&1.kind == :direct)) do
      [%{call: expression}] -> {:ok, expression}
      _other -> :error
    end
  end

  defp endpoint_parser_call({:plug, _meta, [module_ast | arguments]}, aliases)
       when length(arguments) in 0..1 do
    module = canonical_ast(module_ast, aliases)

    cond do
      module == AttestoMCP.Server.PhoenixParser ->
        if wrapped_parser_options_safe?(arguments),
          do: {:ok, :wrapped, parser_path(arguments)},
          else: :error

      module == Plug.Parsers and
          (arguments == [] or
             (length(arguments) == 1 and
                quoted_keyword_list?(List.first(arguments)) and
                not quoted_keyword_has_key?(List.first(arguments), :mcp_path) and
                endpoint_parser_options_safe?(List.first(arguments)))) ->
        {:ok, :direct, nil}

      true ->
        :error
    end
  end

  defp endpoint_parser_call(_expression, _aliases), do: :error

  defp endpoint_parser_options_safe?(options) when is_list(options) do
    body_reader? = quoted_keyword_has_key?(options, :body_reader)

    parser_values = quoted_keyword_values(options, :parsers)

    not body_reader? and
      length(parser_values) <= 1 and
      Enum.all?(parser_values, &standard_parser_list?/1) and
      Enum.all?(options, fn
        {_key, value} -> parser_option_value_safe?(value)
        _other -> false
      end)
  end

  defp endpoint_parser_options_safe?(_options), do: false

  defp wrapped_parser_options_safe?(arguments) do
    case arguments do
      [options] when is_list(options) ->
        quoted_keyword_list?(options) and
          length(Enum.filter(options, fn {key, _} -> literal_atom(key) == :mcp_path end)) ==
            1 and
          endpoint_parser_options_safe?(options)

      _other ->
        false
    end
  end

  defp parser_option_value_safe?(value) when is_atom(value) or is_binary(value), do: true
  defp parser_option_value_safe?(value) when is_integer(value) or is_float(value), do: true

  defp parser_option_value_safe?({:__block__, _meta, [value]}),
    do: parser_option_value_safe?(value)

  defp parser_option_value_safe?({:__aliases__, _meta, parts}) when is_list(parts),
    do: Enum.all?(parts, &is_atom/1)

  defp parser_option_value_safe?(values) when is_list(values),
    do: Enum.all?(values, &parser_option_value_safe?/1)

  defp parser_option_value_safe?({:{}, _meta, values}) when is_list(values),
    do: Enum.all?(values, &parser_option_value_safe?/1)

  defp parser_option_value_safe?({{:., _dot_meta, [module_ast, :json_library]}, _call_meta, []}) do
    canonical_ast(module_ast, %{}) == Phoenix
  end

  defp parser_option_value_safe?(_value), do: false

  defp standard_parser_list?(value) do
    case literal_atom_list(value) do
      {:ok, parsers} -> Enum.all?(parsers, &(&1 in [:json, :urlencoded, :multipart, :text]))
      :error -> false
    end
  end

  defp literal_atom_list({:__block__, _meta, [value]}), do: literal_atom_list(value)

  defp literal_atom_list(values) when is_list(values) do
    atoms = Enum.map(values, &literal_atom/1)

    if Enum.all?(atoms, &is_atom/1), do: {:ok, atoms}, else: :error
  end

  defp literal_atom_list(_value), do: :error

  defp parser_path([]), do: nil

  defp parser_path([options]) when is_list(options) do
    entries =
      Enum.filter(options, fn
        {key, _value} -> literal_atom(key) == :mcp_path
        _other -> false
      end)

    with true <- quoted_keyword_list?(options),
         [{_key, value}] <- entries,
         path when is_binary(path) <- literal_string(value),
         {:ok, ^path} <- validate_path(path) do
      path
    else
      _invalid -> nil
    end
  end

  defp parser_path(_arguments), do: nil

  defp wrapped_parser_code({:plug, _meta, [_module_ast | arguments]}, path) do
    options =
      case arguments do
        [] ->
          [{:mcp_path, path}]

        [existing] when is_list(existing) ->
          [{:mcp_path, path} | existing]
      end

    "plug Elixir.AttestoMCP.Server.PhoenixParser, " <>
      Sourceror.to_string(options)
  end

  defp endpoint_parser_warning(endpoint, path, reason) do
    endpoint_name = inspect(endpoint)

    "Phoenix parser preflight could not establish authentication-before-body-decoding for " <>
      "the forwarded MCP subtree rooted at #{inspect(path)} in #{endpoint_name}: #{reason}. For a direct " <>
      "standard `Plug.Parsers` declaration, use `plug " <>
      "Elixir.AttestoMCP.Server.PhoenixParser, mcp_path: #{inspect(path)}, ...` while " <>
      "preserving its options. A custom body reader/parser must itself skip the complete MCP " <>
      "forward subtree or be reordered/removed; do not assume a wrapper makes custom behavior safe. " <>
      "Then test malformed and oversized unauthenticated MCP bodies are refused by " <>
      "authentication before JSON decoding; metadata and unrelated routes must remain parsed. " <>
      "Ordinary routes below the configured MCP prefix #{inspect(path)} also bypass host body " <>
      "parsing, must not overlap the MCP forward, and must be reviewed if added later."
  end

  defp endpoint_no_parser_warning(endpoint, path) do
    "Phoenix endpoint #{inspect(endpoint)} has a statically proven simple pipeline with no " <>
      "direct `Plug.Parsers` declaration for the MCP forward rooted at #{inspect(path)}. No endpoint " <>
      "edit is required; the MCP Plug remains responsible for bounded body decoding. If a " <>
      "host parser is added later, it must skip the complete MCP forward subtree and use a body-length limit " <>
      "at least as strict as the MCP Plug's `:max_body_bytes`. Ordinary routes below the configured " <>
      "MCP prefix #{inspect(path)} also bypass host body parsing, must not overlap the MCP forward, " <>
      "and must be reviewed if added later."
  end

  defp endpoint_parser_wrapped_notice(endpoint, path) do
    "Wrapped #{inspect(endpoint)}'s standard Plug.Parsers with " <>
      "Elixir.AttestoMCP.Server.PhoenixParser for the MCP forward rooted at #{inspect(path)}. " <>
      "Ordinary routes below the configured MCP prefix #{inspect(path)} also bypass host body " <>
      "parsing, must not overlap the MCP forward, and must be reviewed if added later."
  end

  defp forward_status(
         zipper,
         route,
         plug_module,
         server_module,
         path,
         base_url,
         auth_source
       ) do
    ast = Sourceror.Zipper.node(zipper)

    forwards =
      ast
      |> forward_contexts()
      |> Enum.filter(&(&1.top_level? and &1.route == route))
      |> Enum.map(fn context ->
        canonical_forward_ast(context.call, context.aliases)
      end)

    expected =
      route
      |> forward_statement(plug_module, server_module, path, base_url, auth_source)
      |> Sourceror.parse_string!()
      |> canonical_forward_ast(%{})

    legacy =
      route
      |> legacy_phoenix_forward_statement(
        plug_module,
        server_module,
        path,
        base_url,
        auth_source
      )
      |> maybe_canonical_forward()

    case forwards do
      [] ->
        :missing

      [^expected] ->
        :present

      [^legacy] when not is_nil(legacy) ->
        :legacy

      _ ->
        :conflict
    end
  end

  defp maybe_canonical_forward(nil), do: nil

  defp maybe_canonical_forward(statement) do
    statement
    |> Sourceror.parse_string!()
    |> canonical_forward_ast(%{})
  end

  defp upgrade_legacy_phoenix_forwards(
         zipper,
         _server_module,
         _path,
         _base_url,
         {:callback, _module, _function}
       ),
       do: zipper

  defp upgrade_legacy_phoenix_forwards(
         zipper,
         server_module,
         path,
         base_url,
         {:attesto_phoenix, _app} = auth_source
       ) do
    specs = route_specs(server_module, path, base_url, auth_source)

    case Sourceror.Zipper.node(zipper) do
      {:__block__, _meta, _expressions} ->
        case Sourceror.Zipper.down(zipper) do
          nil ->
            zipper

          first_expression ->
            upgrade_direct_legacy_forwards(
              first_expression,
              %{},
              specs,
              server_module,
              path,
              base_url,
              auth_source
            )
        end

      _single_expression ->
        zipper
    end
  end

  # Walk only the router module body's direct expressions. A structurally
  # identical forward inside a scope, function, or quoted form must never be
  # rewritten as a side effect of migrating an installer-owned top-level
  # route.
  defp upgrade_direct_legacy_forwards(
         candidate,
         aliases,
         specs,
         server_module,
         path,
         base_url,
         auth_source
       ) do
    expression = Sourceror.Zipper.node(candidate)

    replacement =
      Enum.find_value(specs, fn {route, plug_module, code} ->
        legacy =
          route
          |> legacy_phoenix_forward_statement(
            plug_module,
            server_module,
            path,
            base_url,
            auth_source
          )
          |> maybe_canonical_forward()

        if direct_legacy_forward?(expression, aliases, route, legacy), do: code
      end)

    aliases = aliases_after_expression(expression, aliases)

    candidate =
      if replacement,
        do: Igniter.Code.Common.replace_code(candidate, replacement),
        else: candidate

    case Sourceror.Zipper.right(candidate) do
      nil ->
        Sourceror.Zipper.up(candidate)

      next ->
        upgrade_direct_legacy_forwards(
          next,
          aliases,
          specs,
          server_module,
          path,
          base_url,
          auth_source
        )
    end
  end

  defp direct_legacy_forward?(expression, aliases, route, legacy) when not is_nil(legacy) do
    with {:ok, arguments} <- forward_call_args(expression, aliases),
         ^route <- literal_string(List.first(arguments)) do
      canonical_forward_ast(expression, aliases) == legacy
    else
      _not_exact_legacy_forward -> false
    end
  end

  defp direct_legacy_forward?(_expression, _aliases, _route, _legacy), do: false

  defp scoped_forward_conflict?(zipper, specs) do
    ast = Sourceror.Zipper.node(zipper)
    desired_routes = specs |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    ast
    |> forward_contexts()
    |> Enum.any?(fn context ->
      context.scoped? and
        (context.route == :unknown or MapSet.member?(desired_routes, context.route))
    end)
  end

  defp router_dsl_provenance_safe?(ast, trusted_router_use, strict?) do
    if strict? and not direct_phoenix_router_use?(trusted_router_use) do
      false
    else
      if strict? and
           (contains_unsafe_router_compile_attribute?(ast) or
              contains_unsafe_router_module_attribute?(ast) or contains_require?(ast) or
              contains_router_dsl_definitions?(ast) or
              contains_custom_router_macro_definitions?(ast)) do
        false
      else
        if strict? and contains_unsafe_router_route_attribute?(ast) do
          false
        else
          unsafe_signatures =
            @router_dsl_signatures
            |> Enum.filter(fn {name, _arity} -> definitions_named(ast, name) != [] end)
            |> MapSet.new()

          environment = %{
            aliases: %{},
            available: MapSet.new(),
            insertion_safe?: nil,
            opaque_use_seen?: false,
            required_modules: MapSet.new(),
            strict?: strict?,
            unsafe: unsafe_signatures,
            router_use_seen?: false,
            trusted_router_use: trusted_router_use
          }

          case validate_router_dsl_node(ast, environment) do
            {:ok, %{insertion_safe?: true, opaque_use_seen?: false, router_use_seen?: true}} ->
              true

            _error_or_unsafe_insertion ->
              false
          end
        end
      end
    end
  end

  defp direct_phoenix_router_use?({:use, _meta, [module_ast]}),
    do: match?({:__aliases__, _module_meta, [:Phoenix, :Router]}, module_ast)

  defp direct_phoenix_router_use?(_expression), do: false

  defp contains_unsafe_router_compile_attribute?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {:@, _meta, [{name, _attribute_meta, _values}]} = node, _found?
        when name in @unsafe_compile_attributes ->
          {node, true}

        node, found? ->
          {node, found?}
      end)

    found?
  end

  defp contains_unsafe_router_route_attribute?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {:@, _meta, [{name, _attribute_meta, _values}]} = node, _found?
        when name in @unsafe_router_route_attributes ->
          {node, true}

        node, found? ->
          {node, found?}
      end)

    found?
  end

  defp contains_unsafe_router_module_attribute?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {:@, _meta, [{_name, _attribute_meta, [value]}]} = node, _found? ->
          {node, not Macro.quoted_literal?(value)}

        node, found? ->
          {node, found?}
      end)

    found?
  end

  defp contains_require?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {:require, _meta, _arguments} = node, _found? -> {node, true}
        node, found? -> {node, found?}
      end)

    found?
  end

  defp contains_router_dsl_definitions?(ast),
    do: Enum.any?(@router_dsl_definition_names, &(definitions_named(ast, &1) != []))

  defp contains_custom_router_macro_definitions?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {kind, _meta, _arguments} = node, _found?
        when kind in [:defmacro, :defmacrop] ->
          {node, true}

        node, found? ->
          {node, found?}
      end)

    found?
  end

  defp validate_router_dsl_node({:__block__, _meta, expressions}, environment) do
    Enum.reduce_while(expressions, {:ok, environment}, fn expression, {:ok, current} ->
      if opaque_before_trusted_router_use?(expression, current) do
        {:halt, :error}
      else
        case validate_router_dsl_node(expression, current) do
          {:ok, updated} -> {:cont, {:ok, updated}}
          :error -> {:halt, :error}
        end
      end
    end)
  end

  defp validate_router_dsl_node({:alias, _meta, _arguments} = expression, environment) do
    {:ok, %{environment | aliases: aliases_after_expression(expression, environment.aliases)}}
  end

  defp validate_router_dsl_node({:import, _meta, arguments}, environment)
       when is_list(arguments),
       do: {:ok, update_router_import(environment, arguments)}

  defp validate_router_dsl_node({:use, _meta, arguments} = expression, environment)
       when is_list(arguments),
       do:
         if(environment.strict? and not router_static_values_safe?(arguments),
           do: :error,
           else: {:ok, update_router_use(environment, expression)}
         )

  defp validate_router_dsl_node({:require, _meta, arguments} = expression, environment)
       when is_list(arguments) do
    case arguments do
      [module_ast | _options] ->
        case canonical_ast(module_ast, environment.aliases) do
          module when is_atom(module) ->
            {:ok,
             %{
               environment
               | aliases: aliases_after_expression(expression, environment.aliases),
                 required_modules: MapSet.put(environment.required_modules, module)
             }}

          _dynamic_module ->
            :error
        end

      _invalid_require ->
        :error
    end
  end

  defp validate_router_dsl_node({form, _meta, _arguments}, environment)
       when form in [:defmodule, :defprotocol, :defimpl, :quote],
       do: {:ok, environment}

  defp validate_router_dsl_node({:@, _meta, _arguments}, environment),
    do: {:ok, environment}

  defp validate_router_dsl_node(node, environment) do
    if definition_head(node) != nil do
      {:ok, environment}
    else
      validate_router_dsl_call(node, environment)
    end
  end

  defp opaque_before_trusted_router_use?(_expression, %{router_use_seen?: true}), do: false

  defp opaque_before_trusted_router_use?(expression, environment) do
    not pre_router_use_expression_safe?(expression, environment)
  end

  defp pre_router_use_expression_safe?(expression, environment)
       when expression == environment.trusted_router_use,
       do: true

  defp pre_router_use_expression_safe?({form, _meta, _arguments}, _environment)
       when form in [
              :alias,
              :import,
              :require,
              :use,
              :defmodule,
              :defprotocol,
              :defimpl,
              :quote
            ],
       do: true

  defp pre_router_use_expression_safe?({:@, _meta, _arguments} = attribute, _environment),
    do: safe_router_module_attribute?(attribute)

  defp pre_router_use_expression_safe?(expression, _environment),
    do: definition_head(expression) != nil

  defp safe_router_module_attribute?({:@, _meta, [{name, _attribute_meta, [value]}]})
       when name not in [:before_compile, :on_definition, :compile],
       do: Macro.quoted_literal?(value)

  defp safe_router_module_attribute?(_attribute), do: false

  defp router_static_values_safe?(values) when is_list(values),
    do: Enum.all?(values, &router_static_value_safe?/1)

  defp router_static_value_safe?(value) when is_atom(value) or is_binary(value), do: true
  defp router_static_value_safe?(value) when is_integer(value) or is_float(value), do: true

  defp router_static_value_safe?({:__block__, _meta, [value]}),
    do: router_static_value_safe?(value)

  defp router_static_value_safe?({:__aliases__, _meta, parts}) when is_list(parts),
    do: Enum.all?(parts, &is_atom/1)

  defp router_static_value_safe?(values) when is_list(values),
    do: Enum.all?(values, &router_static_value_safe?/1)

  defp router_static_value_safe?({key, value}) do
    case literal_atom(key) do
      nil -> false
      _atom -> router_static_value_safe?(value)
    end
  end

  defp router_static_value_safe?({:{}, _meta, values}) when is_list(values),
    do: Enum.all?(values, &router_static_value_safe?/1)

  defp router_static_value_safe?({:%{}, _meta, values}) when is_list(values),
    do: Enum.all?(values, &router_static_map_entry_safe?/1)

  defp router_static_value_safe?(_value), do: false

  defp router_static_map_entry_safe?({key, value}),
    do: router_static_value_safe?(key) and router_static_value_safe?(value)

  defp router_static_map_entry_safe?(_entry), do: false

  defp validate_router_dsl_call(node, environment) do
    case router_dsl_call(node, environment.aliases) do
      {:ok, provenance, :scope, arity, arguments} ->
        signature = {:scope, arity}

        if trusted_router_dsl_call?(provenance, signature, environment) do
          case scope_arguments_and_body(arguments) do
            {:ok, non_body_arguments, body} ->
              if environment.strict? and not router_static_values_safe?(non_body_arguments) do
                :error
              else
                case validate_router_dsl_node(body, environment) do
                  {:ok, _nested_environment} -> {:ok, environment}
                  :error -> :error
                end
              end

            :error ->
              validate_router_dsl_children(node, environment)
          end
        else
          :error
        end

      {:ok, provenance, :forward, arity, arguments} ->
        if trusted_router_dsl_call?(provenance, {:forward, arity}, environment) and
             (not environment.strict? or router_static_values_safe?(arguments)),
           do: {:ok, environment},
           else: :error

      :error ->
        cond do
          call_to_required_module?(node, environment) ->
            :error

          environment.strict? and
              router_config_plug_call?(node, environment) ->
            if router_static_call_safe?(node), do: {:ok, environment}, else: :error

          environment.strict? and opaque_router_call?(node, environment) ->
            :error

          environment.strict? and known_router_call?(node) ->
            validate_known_router_call(node, environment)

          environment.strict? ->
            :error

          true ->
            validate_router_dsl_children(node, environment)
        end
    end
  end

  defp router_config_plug_call?(
         {{:., _dot_meta, [module_ast, :plug]}, _meta, _arguments},
         environment
       ) do
    canonical_ast(module_ast, environment.aliases) == AttestoPhoenix.Plug
  end

  defp router_config_plug_call?(_node, _environment), do: false

  defp router_static_call_safe?({_name, _meta, arguments}) when is_list(arguments),
    do: router_static_values_safe?(arguments)

  defp router_static_call_safe?(_node), do: false

  defp validate_known_router_call(name_and_meta_and_arguments, environment)
       when is_tuple(name_and_meta_and_arguments) and
              tuple_size(name_and_meta_and_arguments) == 3,
       do: validate_known_router_call_parts(name_and_meta_and_arguments, environment)

  defp validate_known_router_call_parts({name, _meta, arguments}, environment)
       when is_list(arguments) do
    case arguments do
      [module_ast | plug_arguments] when name == :plug ->
        if canonical_ast(module_ast, environment.aliases) == AttestoPhoenix.Plug.PutConfig and
             router_static_values_safe?(plug_arguments) do
          {:ok, environment}
        else
          :error
        end

      [_pipeline | _rest] when name in [:live, :live_dashboard, :live_session] ->
        :error

      [pipeline] when name == :pipe_through ->
        if literal_atom(pipeline) == :attesto_config,
          do: {:ok, environment},
          else: :error

      _other ->
        validate_known_router_call_arguments(arguments, environment)
    end
  end

  defp validate_known_router_call_arguments(arguments, environment) do
    case router_call_body(arguments) do
      {:ok, non_body_arguments, body} ->
        if router_static_values_safe?(non_body_arguments) do
          validate_router_dsl_node(body, environment)
        else
          :error
        end

      :none ->
        if router_static_values_safe?(arguments), do: {:ok, environment}, else: :error
    end
  end

  defp router_call_body(arguments) do
    case List.last(arguments) do
      options when is_list(options) ->
        case keyword_value(options, :do) do
          {:ok, body} -> {:ok, Enum.drop(arguments, -1), body}
          :error -> :none
        end

      _other ->
        :none
    end
  end

  defp call_to_required_module?(
         {{:., _dot_meta, [module_ast, _name]}, call_meta, arguments},
         environment
       )
       when is_list(call_meta) and is_list(arguments) do
    module = canonical_ast(module_ast, environment.aliases)

    module != Phoenix.Router and
      MapSet.member?(environment.required_modules, module)
  end

  defp call_to_required_module?(_node, _environment), do: false

  defp opaque_router_call?(
         {{:., _dot_meta, [module_ast, _name]}, _call_meta, _arguments},
         environment
       ) do
    canonical_ast(module_ast, environment.aliases) != Phoenix.Router
  end

  defp opaque_router_call?(_node, _environment), do: false

  defp known_router_call?({name, _meta, _arguments}) when is_atom(name) do
    name in [
      :attesto_routes,
      :case,
      :cond,
      :if,
      :live,
      :live_dashboard,
      :live_session,
      :pipe_through,
      :pipeline,
      :plug,
      :resources,
      :socket,
      :unless,
      :with
    ] or name in @http_route_names
  end

  defp known_router_call?({{:., _dot_meta, [_module_ast, name]}, _meta, _arguments})
       when is_atom(name) do
    name in [
      :attesto_routes,
      :live,
      :live_dashboard,
      :live_session,
      :pipe_through,
      :pipeline,
      :plug,
      :resources,
      :scope,
      :socket
    ] or name in @http_route_names
  end

  defp known_router_call?(_node), do: false

  defp validate_router_dsl_children(node, environment) when is_tuple(node) do
    node
    |> Tuple.to_list()
    |> validate_router_dsl_child_list(environment)
  end

  defp validate_router_dsl_children(node, environment) when is_list(node),
    do: validate_router_dsl_child_list(node, environment)

  defp validate_router_dsl_children(_node, environment), do: {:ok, environment}

  defp validate_router_dsl_child_list(children, environment) do
    Enum.reduce_while(children, {:ok, environment}, fn child, {:ok, _current} ->
      case validate_router_dsl_node(child, environment) do
        {:ok, _child_environment} -> {:cont, {:ok, environment}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp router_dsl_call({name, meta, arguments}, _aliases)
       when name in [:scope, :forward] and is_list(meta) and is_list(arguments) and
              length(arguments) in 2..4,
       do: {:ok, :unqualified, name, length(arguments), arguments}

  defp router_dsl_call(
         {{:., _dot_meta, [module_ast, name]}, meta, arguments},
         aliases
       )
       when name in [:scope, :forward] and is_list(meta) and is_list(arguments) and
              length(arguments) in 2..4 do
    if canonical_ast(module_ast, aliases) == Phoenix.Router,
      do: {:ok, :qualified, name, length(arguments), arguments},
      else: :error
  end

  defp router_dsl_call(_node, _aliases), do: :error

  defp trusted_router_dsl_call?(:qualified, _signature, _environment), do: true

  defp trusted_router_dsl_call?(:unqualified, signature, environment) do
    MapSet.member?(environment.available, signature) and
      not MapSet.member?(environment.unsafe, signature)
  end

  defp update_router_import(environment, [module_ast | remaining]) do
    options =
      case remaining do
        [] -> {:ok, []}
        [value] when is_list(value) -> {:ok, value}
        _other -> :error
      end

    if canonical_ast(module_ast, environment.aliases) == Phoenix.Router do
      available =
        case options do
          {:ok, value} -> imported_router_signatures(value, :phoenix)
          :error -> MapSet.new()
        end

      %{environment | available: available}
    else
      possible =
        case options do
          {:ok, value} -> imported_router_signatures(value, :unknown)
          :error -> MapSet.new(@router_dsl_signatures)
        end

      %{environment | unsafe: MapSet.union(environment.unsafe, possible)}
    end
  end

  defp update_router_import(environment, _arguments),
    do: taint_router_dsl(environment)

  defp update_router_use(environment, expression) do
    cond do
      expression == environment.trusted_router_use ->
        updated = %{
          environment
          | available: MapSet.new(@router_dsl_signatures),
            router_use_seen?: true
        }

        if environment.insertion_safe? == nil do
          %{
            updated
            | insertion_safe?: trusted_router_dsl_call?(:unqualified, {:forward, 3}, updated)
          }
        else
          updated
        end

      approved_attesto_phoenix_router_use?(expression, environment) ->
        environment

      true ->
        environment
        |> taint_router_dsl()
        |> Map.put(:opaque_use_seen?, true)
    end
  end

  defp approved_attesto_phoenix_router_use?(
         {:use, _meta, [module_ast]},
         %{router_use_seen?: true, aliases: aliases}
       ),
       do: canonical_ast(module_ast, aliases) == AttestoPhoenix.Router

  defp approved_attesto_phoenix_router_use?(_expression, _environment), do: false

  defp taint_router_dsl(environment) do
    %{
      environment
      | unsafe: MapSet.union(environment.unsafe, MapSet.new(@router_dsl_signatures))
    }
  end

  defp imported_router_signatures(options, source) do
    only = keyword_value(options, :only)
    except = keyword_value(options, :except)
    all = router_dsl_signature_set()

    case {only, except} do
      {{:ok, value}, :error} ->
        imported_only_signatures(value, source, all)

      {:error, {:ok, value}} ->
        case listed_router_signatures(value) do
          {:ok, excluded} ->
            all
            |> Enum.reject(&MapSet.member?(excluded, &1))
            |> MapSet.new()

          :error ->
            conservative_import_signatures(source, all)
        end

      {:error, :error} ->
        all

      _both_or_invalid ->
        conservative_import_signatures(source, all)
    end
  end

  defp imported_only_signatures(value, source, all) when is_list(value) do
    case listed_router_signatures(value) do
      {:ok, signatures} -> signatures
      :error -> conservative_import_signatures(source, all)
    end
  end

  defp imported_only_signatures(value, source, all) do
    case literal_atom(value) do
      :macros -> all
      :functions -> conservative_import_signatures(source, all)
      _other -> conservative_import_signatures(source, all)
    end
  end

  defp conservative_import_signatures(:phoenix, _all), do: MapSet.new()
  defp conservative_import_signatures(:unknown, all), do: all

  @spec router_dsl_signature_set() :: MapSet.t({atom(), non_neg_integer()})
  defp router_dsl_signature_set, do: MapSet.new(@router_dsl_signatures)

  @spec listed_router_signatures(term()) ::
          {:ok, MapSet.t({atom(), non_neg_integer()})} | :error
  defp listed_router_signatures(entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, MapSet.new()}, fn
      {name_ast, arity_ast}, {:ok, signatures} ->
        signature = {literal_atom(name_ast), literal_integer(arity_ast)}

        if elem(signature, 1) == nil do
          {:halt, :error}
        else
          updated =
            if signature in @router_dsl_signatures,
              do: MapSet.put(signatures, signature),
              else: signatures

          {:cont, {:ok, updated}}
        end

      _unsupported, _result ->
        {:halt, :error}
    end)
  end

  defp listed_router_signatures(_entries), do: :error

  defp forward_contexts(ast) do
    collect_forward_contexts(ast, {:known, []}, false, %{}, true)
  end

  defp collect_forward_contexts(
         {:__block__, _meta, expressions},
         prefix,
         in_scope?,
         aliases,
         top_level?
       ) do
    {contexts, _aliases} =
      Enum.map_reduce(expressions, aliases, fn expression, current_aliases ->
        contexts =
          collect_forward_contexts(
            expression,
            prefix,
            in_scope?,
            current_aliases,
            top_level?
          )

        {contexts, aliases_after_expression(expression, current_aliases)}
      end)

    List.flatten(contexts)
  end

  defp collect_forward_contexts(
         {container, _meta, _arguments},
         _prefix,
         _in_scope?,
         _aliases,
         _top_level?
       )
       when container in [
              :def,
              :defp,
              :defmacro,
              :defmacrop,
              :defdelegate,
              :defguard,
              :defguardp,
              :defmodule,
              :defprotocol,
              :defimpl,
              :quote
            ],
       do: []

  defp collect_forward_contexts(node, prefix, in_scope?, aliases, top_level?) do
    case scope_call(node, aliases) do
      {:ok, arguments, body} ->
        nested_prefix = scoped_prefix(prefix, arguments)
        collect_forward_contexts(body, nested_prefix, true, aliases, false)

      :error ->
        case forward_call_args(node, aliases) do
          {:ok, args} ->
            route =
              if in_scope?,
                do: effective_scoped_route(prefix, List.first(args)),
                else: literal_string(List.first(args)) || :unknown

            [
              %{
                aliases: aliases,
                call: node,
                route: route,
                scoped?: in_scope?,
                top_level?: top_level? and not in_scope?
              }
            ]

          :error ->
            collect_forward_context_children(node, prefix, in_scope?, aliases)
        end
    end
  end

  defp collect_forward_context_children(node, prefix, in_scope?, aliases)
       when is_tuple(node) do
    node
    |> Tuple.to_list()
    |> Enum.flat_map(&collect_forward_contexts(&1, prefix, in_scope?, aliases, false))
  end

  defp collect_forward_context_children(node, prefix, in_scope?, aliases)
       when is_list(node) do
    Enum.flat_map(node, &collect_forward_contexts(&1, prefix, in_scope?, aliases, false))
  end

  defp collect_forward_context_children(_node, _prefix, _in_scope?, _aliases), do: []

  defp scope_call({:scope, _meta, args}, _aliases) when length(args) in 2..4,
    do: scope_arguments_and_body(args)

  defp scope_call(
         {{:., _dot_meta, [module_ast, :scope]}, _call_meta, args},
         aliases
       )
       when length(args) in 2..4 do
    if canonical_ast(module_ast, aliases) == Phoenix.Router,
      do: scope_arguments_and_body(args),
      else: :error
  end

  defp scope_call(_node, _aliases), do: :error

  defp scope_arguments_and_body(args) do
    case List.pop_at(args, -1) do
      {options, arguments} when is_list(options) ->
        case keyword_value(options, :do) do
          {:ok, body} -> {:ok, arguments, body}
          :error -> :error
        end

      _other ->
        :error
    end
  end

  defp scoped_prefix(:unknown, _arguments), do: :unknown

  defp scoped_prefix({:known, prefix}, arguments) do
    case scope_path_segments(arguments) do
      {:ok, segments} -> {:known, prefix ++ segments}
      :error -> :unknown
    end
  end

  defp scope_path_segments([]), do: {:ok, []}

  defp scope_path_segments([options | _rest]) when is_list(options) do
    case keyword_value(options, :path) do
      {:ok, path_ast} -> literal_path_segments(path_ast)
      :error -> {:ok, []}
    end
  end

  defp scope_path_segments([path_ast | _rest]), do: literal_path_segments(path_ast)

  defp literal_path_segments(path_ast) do
    case literal_string(path_ast) do
      path when is_binary(path) -> {:ok, String.split(path, "/", trim: true)}
      nil -> :error
    end
  end

  defp effective_scoped_route(:unknown, _route_ast), do: :unknown

  defp effective_scoped_route({:known, prefix}, route_ast) do
    case literal_string(route_ast) do
      route when is_binary(route) ->
        "/" <> Enum.join(prefix ++ String.split(route, "/", trim: true), "/")

      nil ->
        :unknown
    end
  end

  defp incompatible_forward?(zipper, specs) do
    ast = Sourceror.Zipper.node(zipper)
    desired_routes = specs |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    desired_plugs = specs |> Enum.map(&elem(&1, 1)) |> MapSet.new()

    ast
    |> forward_contexts()
    |> Enum.any?(fn context ->
      {:ok, args} = forward_call_args(context.call, context.aliases)
      plug_module = args |> Enum.at(1) |> canonical_ast(context.aliases)

      context.route == :unknown or not is_atom(plug_module) or
        (not context.top_level? and not context.scoped?) or
        (context.route not in desired_routes and
           MapSet.member?(desired_plugs, plug_module))
    end)
  end

  defp route_overlap?(zipper, specs) do
    ast = Sourceror.Zipper.node(zipper)
    desired_routes = specs |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    forward_overlap? =
      ast
      |> forward_contexts()
      |> Enum.any?(fn context ->
        is_binary(context.route) and context.route not in desired_routes and
          Enum.any?(desired_routes, &prefix_patterns_overlap?(context.route, &1))
      end)

    http_overlap? =
      ast
      |> http_route_contexts()
      |> Enum.any?(fn
        {_kind, :unknown} ->
          true

        {:route, route} ->
          Enum.any?(desired_routes, &ordinary_route_overlaps_forward?(route, &1))

        {:resources, route} ->
          Enum.any?(desired_routes, &prefix_patterns_overlap?(route, &1))
      end)

    forward_overlap? or http_overlap?
  end

  defp http_route_contexts(ast) do
    collect_http_route_contexts(ast, {:known, []}, %{})
  end

  defp collect_http_route_contexts({:__block__, _meta, expressions}, prefix, aliases) do
    {contexts, _aliases} =
      Enum.map_reduce(expressions, aliases, fn expression, current_aliases ->
        contexts = collect_http_route_contexts(expression, prefix, current_aliases)
        {contexts, aliases_after_expression(expression, current_aliases)}
      end)

    List.flatten(contexts)
  end

  defp collect_http_route_contexts({container, _meta, _arguments}, _prefix, _aliases)
       when container in [
              :def,
              :defp,
              :defmacro,
              :defmacrop,
              :defmodule,
              :defprotocol,
              :defimpl,
              :quote
            ],
       do: []

  defp collect_http_route_contexts(node, prefix, aliases) do
    case scope_call(node, aliases) do
      {:ok, arguments, body} ->
        collect_http_route_contexts(body, scoped_prefix(prefix, arguments), aliases)

      :error ->
        case http_route_path(node, aliases) do
          {:ok, kind, path_ast} ->
            [{kind, effective_scoped_route(prefix, path_ast)}]

          :error ->
            collect_http_route_context_children(node, prefix, aliases)
        end
    end
  end

  defp collect_http_route_context_children(node, prefix, aliases) when is_tuple(node) do
    node
    |> Tuple.to_list()
    |> Enum.flat_map(&collect_http_route_contexts(&1, prefix, aliases))
  end

  defp collect_http_route_context_children(node, prefix, aliases) when is_list(node),
    do: Enum.flat_map(node, &collect_http_route_contexts(&1, prefix, aliases))

  defp collect_http_route_context_children(_node, _prefix, _aliases), do: []

  defp http_route_path({name, meta, arguments}, _aliases)
       when name in @http_route_names and is_list(meta) and is_list(arguments) and
              length(arguments) in 3..4,
       do: {:ok, :route, List.first(arguments)}

  defp http_route_path({:match, meta, arguments}, _aliases)
       when is_list(meta) and is_list(arguments) and length(arguments) in 4..5,
       do: {:ok, :route, Enum.at(arguments, 1)}

  defp http_route_path({:resources, meta, arguments}, _aliases)
       when is_list(meta) and is_list(arguments) and length(arguments) in 2..4,
       do: {:ok, :resources, List.first(arguments)}

  defp http_route_path(
         {{:., _dot_meta, [module_ast, name]}, meta, arguments},
         aliases
       )
       when name in @http_route_names and is_list(meta) and is_list(arguments) and
              length(arguments) in 3..4 do
    if canonical_ast(module_ast, aliases) == Phoenix.Router,
      do: {:ok, :route, List.first(arguments)},
      else: :error
  end

  defp http_route_path(
         {{:., _dot_meta, [module_ast, :match]}, meta, arguments},
         aliases
       )
       when is_list(meta) and is_list(arguments) and length(arguments) in 4..5 do
    if canonical_ast(module_ast, aliases) == Phoenix.Router,
      do: {:ok, :route, Enum.at(arguments, 1)},
      else: :error
  end

  defp http_route_path(
         {{:., _dot_meta, [module_ast, :resources]}, meta, arguments},
         aliases
       )
       when is_list(meta) and is_list(arguments) and length(arguments) in 2..4 do
    if canonical_ast(module_ast, aliases) == Phoenix.Router,
      do: {:ok, :resources, List.first(arguments)},
      else: :error
  end

  defp http_route_path(_node, _aliases), do: :error

  defp ordinary_route_overlaps_forward?(route, forward) do
    route
    |> route_segments()
    |> ordinary_segments_overlap?(route_segments(forward))
  end

  defp ordinary_segments_overlap?([], []), do: true
  defp ordinary_segments_overlap?([], [_forward | _rest]), do: false
  defp ordinary_segments_overlap?([_route | _rest], []), do: true

  defp ordinary_segments_overlap?([route | routes], [forward | forwards]) do
    cond do
      String.contains?(route, "*") -> true
      route_segment_compatible?(route, forward) -> ordinary_segments_overlap?(routes, forwards)
      true -> false
    end
  end

  defp prefix_patterns_overlap?(left, right) do
    prefix_segments_overlap?(route_segments(left), route_segments(right))
  end

  defp prefix_segments_overlap?([], _right), do: true
  defp prefix_segments_overlap?(_left, []), do: true

  defp prefix_segments_overlap?([left | lefts], [right | rights]) do
    cond do
      String.contains?(left, "*") or String.contains?(right, "*") -> true
      route_segment_compatible?(left, right) -> prefix_segments_overlap?(lefts, rights)
      true -> false
    end
  end

  defp route_segment_compatible?(left, right) do
    left == right or String.contains?(left, [":", "*"]) or
      String.contains?(right, [":", "*"])
  end

  defp route_segments(route), do: String.split(route, "/", trim: true)

  defp top_level_expressions({:__block__, _meta, expressions}), do: expressions
  defp top_level_expressions(expression), do: [expression]

  defp forward_call_args({:forward, _meta, args}, _aliases) when length(args) in 2..4,
    do: {:ok, args}

  defp forward_call_args(
         {{:., _dot_meta, [module_ast, :forward]}, _call_meta, args},
         aliases
       )
       when length(args) in 2..4 do
    if canonical_ast(module_ast, aliases) == Phoenix.Router,
      do: {:ok, args},
      else: :error
  end

  defp forward_call_args(_node, _aliases), do: :error

  defp canonical_forward_ast(
         {{:., _dot_meta, [module_ast, :forward]}, call_meta, args} = call,
         aliases
       )
       when length(args) in 2..4 do
    if canonical_ast(module_ast, aliases) == Phoenix.Router,
      do: canonical_forward_ast({:forward, call_meta, args}, aliases),
      else: canonical_ast(call, aliases)
  end

  defp canonical_forward_ast({:forward, meta, [first, second, third, fourth]}, aliases) do
    call =
      if literal_empty_list?(fourth),
        do: {:forward, meta, [first, second, third]},
        else: {:forward, meta, [first, second, third, fourth]}

    canonical_ast(call, aliases)
  end

  defp canonical_forward_ast(call, aliases), do: canonical_ast(call, aliases)

  defp forward_code(server_module, path, base_url, auth_source, metadata_mode) do
    server_module
    |> route_specs(path, base_url, auth_source, metadata_mode)
    |> Enum.map(&elem(&1, 2))
    |> Enum.join("\n\n")
  end

  defp route_specs(server_module, path, base_url, auth_source, :reuse) do
    [
      {path, AttestoMCP.Server.Plug,
       forward_statement(
         path,
         AttestoMCP.Server.Plug,
         server_module,
         path,
         base_url,
         auth_source
       )}
    ]
  end

  defp route_specs(server_module, path, base_url, auth_source, :generate) do
    metadata_path = metadata_path(path)
    metadata_plug = Module.concat(server_module, MetadataPlug)

    [
      {metadata_path, metadata_plug,
       forward_statement(
         metadata_path,
         metadata_plug,
         server_module,
         path,
         base_url,
         auth_source
       )},
      {path, AttestoMCP.Server.Plug,
       forward_statement(
         path,
         AttestoMCP.Server.Plug,
         server_module,
         path,
         base_url,
         auth_source
       )}
    ]
  end

  defp route_specs(server_module, path, base_url, auth_source),
    do: route_specs(server_module, path, base_url, auth_source, :generate)

  defp reuse_issue(igniter, message, server_module, path, base_url, auth_source) do
    {:error, igniter,
     manual_mcp_wiring_message(message, server_module, path, base_url, auth_source)}
  end

  defp metadata_route_status(body, path, _server_module, :generate) do
    metadata_path = metadata_path(path)

    routes = attesto_route_contexts(body)

    if Enum.any?(routes, fn context ->
         context.metadata_path == metadata_path or context.metadata_path == :unknown
       end) do
      {:error,
       "an AttestoPhoenix protected-resource metadata route may already cover the selected path; prove it explicitly with --reuse-metadata-route or remove the ambiguous route before installation"}
    else
      :ok
    end
  end

  defp metadata_route_status(body, path, _server_module, :reuse) do
    metadata_path = metadata_path(path)

    forward_contexts = forward_contexts(body)

    metadata_forwards =
      Enum.filter(forward_contexts, fn context ->
        is_binary(context.route) and
          String.starts_with?(context.route, "/.well-known/oauth-protected-resource")
      end)

    attesto_routes = attesto_route_contexts(body)

    exact =
      Enum.filter(attesto_routes, fn context ->
        context.metadata_path == metadata_path and
          context.scope_prefix == [] and
          not context.scoped? and
          context.router_use_before?
      end)

    invalid_attesto_routes =
      Enum.filter(attesto_routes, fn context ->
        context.metadata_path == :unknown or context.scope_prefix != [] or
          context.scoped? or
          not context.router_use_before?
      end)

    router_use_count = attesto_router_use_count(body)

    ordinary_metadata? =
      body
      |> http_route_contexts()
      |> Enum.any?(fn
        {_kind, route} when is_binary(route) ->
          String.starts_with?(route, "/.well-known/oauth-protected-resource")

        _other ->
          false
      end)

    cond do
      not attesto_routes_provenance_safe?(body) or router_use_count != 1 ->
        {:error,
         "--reuse-metadata-route cannot prove one published `use AttestoPhoenix.Router` plus the official `attesto_routes/1` macro; duplicate uses, local definitions, or imports require manual wiring"}

      length(exact) == 1 and length(attesto_routes) == 1 and metadata_forwards == [] and
        not ordinary_metadata? and invalid_attesto_routes == [] ->
        :ok

      length(exact) > 1 or length(attesto_routes) > 1 or length(metadata_forwards) > 1 or
        (exact != [] and metadata_forwards != []) or ordinary_metadata? ->
        {:error,
         "--reuse-metadata-route found duplicate or ambiguous protected-resource metadata routes for #{inspect(metadata_path)}; remove the ambiguity or wire the routes manually"}

      invalid_attesto_routes != [] or
          Enum.any?(forward_contexts, &(&1.route == :unknown)) ->
        {:error,
         "--reuse-metadata-route cannot prove the supported literal `attesto_routes(protected_resource_paths: [#{inspect(path)}])` invocation; dynamic, scoped, mismatched, or locally defined router macros require manual wiring"}

      Enum.any?(metadata_forwards, &(&1.route == metadata_path)) ->
        {:error,
         "--reuse-metadata-route found an ordinary metadata forward at the exact canonical path #{inspect(metadata_path)}; reuse requires the supported literal `attesto_routes(protected_resource_paths: [#{inspect(path)}])` invocation, otherwise wire the routes manually"}

      metadata_forwards != [] ->
        {:error,
         "--reuse-metadata-route found a mismatched protected-resource metadata path; use the exact canonical path #{inspect(metadata_path)} or wire the routes manually"}

      true ->
        {:error,
         "--reuse-metadata-route could not prove exactly one supported `use AttestoPhoenix.Router` plus `attesto_routes(protected_resource_paths: [#{inspect(path)}])` route; add that route or wire the routes manually"}
    end
  end

  defp manual_mcp_wiring_message(reason, server_module, path, base_url, auth_source) do
    reason <>
      "\n\nExact MCP wiring to add manually after resolving the metadata route:\n" <>
      forward_code(server_module, path, base_url, auth_source, :reuse)
  end

  # The public AttestoPhoenix router integration emits this macro. A
  # metadata route is reusable only when the source itself proves the exact
  # literal path and the official router `use` precedes it.
  defp attesto_route_contexts(body) do
    {_aliases, _seen?, contexts} = collect_attesto_routes(body, %{}, [], false, false, [])
    Enum.reverse(contexts)
  end

  defp attesto_routes_provenance_safe?(body) do
    definitions_named(body, :attesto_routes) == [] and
      not contains_import?(body) and
      Enum.all?(top_level_alias_contexts(body), &attesto_use_provenance_safe?/1)
  end

  defp attesto_use_provenance_safe?({{:use, _meta, [module_ast]}, aliases}) do
    canonical_ast(module_ast, aliases) in [Phoenix.Router, AttestoPhoenix.Router] and
      literal_module_ast?(module_ast, aliases)
  end

  defp attesto_use_provenance_safe?(_context), do: true

  defp literal_module_ast?({:__aliases__, _meta, _parts}, _aliases), do: true
  defp literal_module_ast?(_module_ast, _aliases), do: false

  defp contains_import?(body) do
    {_body, found?} =
      Macro.prewalk(body, false, fn
        {:import, _meta, _arguments} = node, _found? -> {node, true}
        node, found? -> {node, found?}
      end)

    found?
  end

  defp attesto_router_use_count(body) do
    {_body, count} =
      Macro.prewalk(body, 0, fn
        {:use, _meta, [module_ast]} = node, count ->
          {node, if(official_attesto_router_module?(module_ast), do: count + 1, else: count)}

        node, count ->
          {node, count}
      end)

    count
  end

  defp collect_attesto_routes(
         {:__block__, _meta, expressions},
         aliases,
         prefix,
         scoped?,
         seen?,
         acc
       ) do
    Enum.reduce(expressions, {aliases, seen?, acc}, fn expression,
                                                       {current_aliases, current_seen?,
                                                        current_acc} ->
      collect_attesto_routes(
        expression,
        current_aliases,
        prefix,
        scoped?,
        current_seen?,
        current_acc
      )
    end)
  end

  defp collect_attesto_routes(
         {:alias, _meta, _arguments} = expression,
         aliases,
         _prefix,
         _scoped?,
         seen?,
         acc
       ) do
    {aliases_after_expression(expression, aliases), seen?, acc}
  end

  defp collect_attesto_routes(
         {:use, _meta, [module_ast]} = expression,
         aliases,
         _prefix,
         _scoped?,
         seen?,
         acc
       ) do
    {aliases_after_expression(expression, aliases),
     seen? or official_attesto_router_module?(module_ast), acc}
  end

  defp collect_attesto_routes({:scope, _meta, arguments}, aliases, prefix, _scoped?, seen?, acc)
       when is_list(arguments) do
    case arguments do
      [scope_ast, options] when is_list(options) ->
        case literal_string(scope_ast) do
          scope when is_binary(scope) ->
            case keyword_value(options, :do) do
              {:ok, scope_body} ->
                collect_attesto_routes(
                  scope_body,
                  aliases,
                  prefix ++ route_segments(scope),
                  true,
                  seen?,
                  acc
                )

              :error ->
                collect_attesto_route_children(arguments, aliases, prefix, true, seen?, acc)
            end

          _dynamic ->
            collect_attesto_route_children(arguments, aliases, prefix, true, seen?, acc)
        end

      _other ->
        collect_attesto_route_children(arguments, aliases, prefix, true, seen?, acc)
    end
  end

  defp collect_attesto_routes(expression, aliases, prefix, scoped?, seen?, acc) do
    case attesto_routes_call(expression, aliases) do
      {:ok, options} ->
        context = %{
          call: expression,
          aliases: aliases,
          protected_resource_paths: protected_resource_paths(options),
          metadata_path: attesto_metadata_path(prefix, options),
          scope_prefix: prefix,
          scoped?: scoped?,
          router_use_before?: seen?
        }

        {aliases, seen?, [context | acc]}

      {:legacy, _options} ->
        # Older AttestoPhoenix releases accepted a module argument rather
        # than the published protected_resource_paths keyword. It is not a
        # proof of a reusable metadata route, but retain the generate-mode
        # compatibility path for that established syntax.
        context = %{
          call: expression,
          aliases: aliases,
          protected_resource_paths: :not_applicable,
          metadata_path: :not_applicable,
          scope_prefix: prefix,
          scoped?: scoped?,
          router_use_before?: seen?,
          legacy?: true
        }

        {aliases, seen?, [context | acc]}

      :invalid ->
        {aliases, seen?,
         [
           %{
             protected_resource_paths:
               if(attesto_routes_option_syntax?(expression), do: :error, else: :not_applicable),
             metadata_path: :unknown,
             scope_prefix: prefix,
             scoped?: scoped?,
             router_use_before?: seen?
           }
           | acc
         ]}

      :not_attesto_routes ->
        collect_attesto_route_children(expression, aliases, prefix, scoped?, seen?, acc)
    end
  end

  defp collect_attesto_route_children(
         {container, _meta, _arguments},
         aliases,
         _prefix,
         _scoped?,
         seen?,
         acc
       )
       when container in [
              :def,
              :defp,
              :defmacro,
              :defmacrop,
              :defmodule,
              :defprotocol,
              :defimpl,
              :quote
            ],
       do: {aliases, seen?, acc}

  defp collect_attesto_route_children(node, aliases, prefix, scoped?, seen?, acc)
       when is_tuple(node) do
    if contains_attesto_routes_syntax?(node) do
      {aliases, seen?,
       [
         %{
           protected_resource_paths: :not_applicable,
           metadata_path: :unknown,
           scope_prefix: prefix,
           scoped?: scoped?,
           router_use_before?: seen?
         }
         | acc
       ]}
    else
      {aliases, seen?, acc}
    end
  end

  defp collect_attesto_route_children(node, aliases, prefix, scoped?, seen?, acc)
       when is_list(node) do
    if contains_attesto_routes_syntax?(node) do
      {aliases, seen?,
       [
         %{
           protected_resource_paths: :not_applicable,
           metadata_path: :unknown,
           scope_prefix: prefix,
           scoped?: scoped?,
           router_use_before?: seen?
         }
         | acc
       ]}
    else
      {aliases, seen?, acc}
    end
  end

  defp collect_attesto_route_children(_node, aliases, _prefix, _scoped?, seen?, acc),
    do: {aliases, seen?, acc}

  defp attesto_routes_call({:attesto_routes, _meta, [options]}, _aliases)
       when is_list(options) do
    case options do
      [{:__aliases__, _meta, _parts}] -> {:legacy, options}
      _other -> {:ok, options}
    end
  end

  defp attesto_routes_call({:attesto_routes, _meta, [module_ast]}, aliases) do
    if literal_module_ast?(module_ast, aliases), do: {:legacy, [module_ast]}, else: :invalid
  end

  defp attesto_routes_call({:attesto_routes, _meta, _arguments}, _aliases), do: :invalid

  defp attesto_routes_call(_expression, _aliases), do: :not_attesto_routes

  defp attesto_routes_option_syntax?({:attesto_routes, _meta, [argument]}) do
    not literal_module_ast?(argument, %{})
  end

  defp attesto_routes_option_syntax?(_expression), do: false

  defp attesto_routes_syntax?({:attesto_routes, _meta, _arguments}, _aliases), do: true

  defp attesto_routes_syntax?(
         {{:., _dot_meta, [_module_ast, :attesto_routes]}, _meta, _arguments},
         _aliases
       ),
       do: true

  defp attesto_routes_syntax?(_expression, _aliases), do: false

  defp contains_attesto_routes_syntax?(node) do
    {_node, found?} =
      Macro.prewalk(node, false, fn current, found? ->
        if attesto_routes_syntax?(current, %{}), do: {current, true}, else: {current, found?}
      end)

    found?
  end

  defp protected_resource_paths(options) when is_list(options) do
    case options do
      [{key, paths_ast}] ->
        if literal_atom(key) == :protected_resource_paths do
          with {:ok, [path]} <- literal_list(paths_ast),
               {:ok, path} <- validate_path(path) do
            {:ok, [path]}
          else
            _invalid -> :error
          end
        else
          :error
        end

      _duplicate_extra_or_dynamic ->
        :error
    end
  end

  defp protected_resource_paths(_options), do: :error

  defp official_attesto_router_module?({:__aliases__, _meta, [:AttestoPhoenix, :Router]}),
    do: true

  defp official_attesto_router_module?(_module_ast), do: false

  defp attesto_metadata_path([], options) do
    case protected_resource_paths(options) do
      {:ok, [path]} -> metadata_path(path)
      _other -> :unknown
    end
  end

  defp attesto_metadata_path(_prefix, _options), do: :unknown

  defp forward_statement(
         route,
         plug_module,
         server_module,
         path,
         base_url,
         {:callback, _module, _function}
       ) do
    plug_module = absolute_module_name(plug_module)
    server_module = absolute_module_name(server_module)

    """
    Elixir.Phoenix.Router.forward #{inspect(route)}, #{plug_module},
      server: #{server_module},
      path: #{inspect(path)},
      auth: [
        config: &#{server_module}.attesto_config/0,
        resource: #{inspect(path)},
        base_url: #{inspect(base_url)}
      ]
    """
    |> String.trim()
  end

  defp forward_statement(
         route,
         plug_module,
         server_module,
         path,
         base_url,
         {:attesto_phoenix, app}
       ) do
    plug_module = absolute_module_name(plug_module)
    server_module = absolute_module_name(server_module)

    """
    Elixir.Phoenix.Router.forward #{inspect(route)}, #{plug_module},
      server: #{server_module},
      path: #{inspect(path)},
      auth: {Elixir.AttestoMCP.Server.Phoenix, :protected_resource_options, [#{inspect(app)}]},
      resource: #{inspect(path)},
      base_url: #{inspect(base_url)}
    """
    |> String.trim()
  end

  defp legacy_phoenix_forward_statement(
         _route,
         _plug_module,
         _server_module,
         _path,
         _base_url,
         {:callback, _module, _function}
       ),
       do: nil

  defp legacy_phoenix_forward_statement(
         route,
         plug_module,
         server_module,
         path,
         base_url,
         {:attesto_phoenix, _app}
       ) do
    plug_module = absolute_module_name(plug_module)
    server_module = absolute_module_name(server_module)

    """
    Elixir.Phoenix.Router.forward #{inspect(route)}, #{plug_module},
      server: #{server_module},
      path: #{inspect(path)},
      auth: [
        config: &#{server_module}.attesto_config/0,
        resource: #{inspect(path)},
        base_url: #{inspect(base_url)}
      ]
    """
    |> String.trim()
  end

  defp absolute_module_name(module), do: Atom.to_string(module)

  defp literal_string(value) when is_binary(value), do: value
  defp literal_string({:__block__, _meta, [value]}) when is_binary(value), do: value
  defp literal_string(_value), do: nil

  defp literal_list({:__block__, _meta, [value]}), do: literal_list(value)

  defp literal_list(values) when is_list(values) do
    values = Enum.map(values, &literal_string/1)

    if Enum.all?(values, &is_binary/1), do: {:ok, values}, else: :error
  end

  defp literal_list(_value), do: :error

  defp literal_empty_list?([]), do: true
  defp literal_empty_list?({:__block__, _meta, [value]}), do: literal_empty_list?(value)
  defp literal_empty_list?(_value), do: false

  defp keyword_value(options, key) when is_list(options) do
    Enum.reduce_while(options, :error, fn
      {option_key, value}, _result ->
        if literal_atom(option_key) == key,
          do: {:halt, {:ok, value}},
          else: {:cont, :error}

      _other, _result ->
        {:cont, :error}
    end)
  end

  defp quoted_keyword_list?(options) when is_list(options) do
    Enum.all?(options, fn
      {key, _value} -> is_atom(literal_atom(key))
      _other -> false
    end)
  end

  defp quoted_keyword_list?(_options), do: false

  defp quoted_keyword_has_key?(options, key) when is_list(options) do
    Enum.any?(options, fn
      {option_key, _value} -> literal_atom(option_key) == key
      _other -> false
    end)
  end

  defp quoted_keyword_has_key?(_options, _key), do: false

  defp quoted_keyword_values(options, key) when is_list(options) do
    Enum.flat_map(options, fn
      {option_key, value} -> if(literal_atom(option_key) == key, do: [value], else: [])
      _other -> []
    end)
  end

  defp top_level_alias_contexts(ast) do
    {contexts, _aliases} =
      ast
      |> top_level_expressions()
      |> Enum.map_reduce(%{}, fn expression, aliases ->
        {{expression, aliases}, aliases_after_expression(expression, aliases)}
      end)

    contexts
  end

  defp aliases_before_expression(ast, target) do
    ast
    |> top_level_alias_contexts()
    |> Enum.find_value(:error, fn {expression, aliases} ->
      if expression == target, do: {:ok, aliases}, else: false
    end)
  end

  defp aliases_after_expression({:alias, _meta, arguments}, aliases) do
    arguments
    |> alias_call_entries(aliases)
    |> Enum.reduce(aliases, &put_alias/2)
  end

  defp aliases_after_expression({:require, _meta, [module_ast, options]}, aliases)
       when is_list(options) do
    case keyword_value(options, :as) do
      {:ok, _as} ->
        [module_ast, options]
        |> alias_call_entries(aliases)
        |> Enum.reduce(aliases, &put_alias/2)

      :error ->
        aliases
    end
  end

  defp aliases_after_expression(_expression, aliases), do: aliases

  defp alias_call_entries([module_ast], aliases) do
    case grouped_alias_entries(module_ast, aliases) do
      {:ok, entries} -> entries
      :error -> List.wrap(alias_entry(module_ast, [], aliases))
    end
  end

  defp alias_call_entries([module_ast, options], aliases) when is_list(options) do
    case grouped_alias_entries(module_ast, aliases) do
      {:ok, entries} ->
        if Enum.any?(options, fn
             {key, _value} -> literal_atom(key) == :as
             _other -> false
           end),
           do: [],
           else: entries

      :error ->
        List.wrap(alias_entry(module_ast, options, aliases))
    end
  end

  defp alias_call_entries(_arguments, _aliases), do: []

  defp alias_entry({:__aliases__, _meta, parts} = module_ast, options, aliases)
       when is_list(parts) do
    with {:ok, module} <- resolve_alias_module(module_ast, aliases),
         {:ok, name} <- alias_name(parts, options) do
      {name, module}
    else
      _unresolved -> nil
    end
  end

  defp alias_entry(_module_ast, _options, _aliases), do: nil

  defp alias_name(parts, options) do
    case Enum.find(options, fn
           {key, _value} -> literal_atom(key) == :as
           _other -> false
         end) do
      {_key, {:__aliases__, _as_meta, as_parts}} ->
        if as_parts != [] and Enum.all?(as_parts, &is_atom/1),
          do: {:ok, List.last(as_parts)},
          else: :error

      nil ->
        if parts != [] and Enum.all?(parts, &is_atom/1),
          do: {:ok, List.last(parts)},
          else: :error

      _invalid_as_option ->
        :error
    end
  end

  defp grouped_alias_entries(
         {{:., _dot_meta, [prefix_ast, :{}]}, _call_meta, members},
         aliases
       )
       when is_list(members) do
    with {:ok, prefix} <- resolve_alias_module(prefix_ast, aliases) do
      entries =
        Enum.map(members, fn
          {:__aliases__, _meta, parts} when parts != [] ->
            if Enum.all?(parts, &is_atom/1),
              do: {List.last(parts), Module.concat([prefix | parts])},
              else: nil

          _unsupported_member ->
            nil
        end)

      if Enum.all?(entries, &match?({name, module} when is_atom(name) and is_atom(module), &1)),
        do: {:ok, entries},
        else: :error
    end
  end

  defp grouped_alias_entries(_module_ast, _aliases), do: :error

  defp put_alias({name, module}, aliases), do: Map.put(aliases, name, module)

  defp resolve_alias_module({:__aliases__, _meta, parts}, aliases),
    do: resolve_alias_parts(parts, aliases)

  defp resolve_alias_module(_module_ast, _aliases), do: :error

  defp resolve_alias_parts([head | tail] = parts, aliases) when is_atom(head) do
    if Enum.all?(tail, &is_atom/1) do
      case Map.fetch(aliases, head) do
        {:ok, module} when is_atom(module) ->
          {:ok, Module.concat([module | tail])}

        :error ->
          {:ok, Module.concat(parts)}
      end
    else
      :error
    end
  end

  defp resolve_alias_parts(_parts, _aliases), do: :error

  defp literal_atom(value) when is_atom(value), do: value
  defp literal_atom({:__block__, _meta, [value]}) when is_atom(value), do: value
  defp literal_atom(_value), do: nil

  defp literal_boolean(value) when is_boolean(value), do: value
  defp literal_boolean({:__block__, _meta, [value]}) when is_boolean(value), do: value
  defp literal_boolean(_value), do: nil

  defp literal_integer(value) when is_integer(value), do: value
  defp literal_integer({:__block__, _meta, [value]}) when is_integer(value), do: value
  defp literal_integer(_value), do: nil

  defp canonical_ast(ast, aliases) do
    Macro.prewalk(ast, fn
      {:__block__, _meta, [value]} ->
        value

      {:__aliases__, _meta, parts} = alias_ast ->
        case resolve_alias_parts(parts, aliases) do
          {:ok, module} -> module
          :error -> alias_ast
        end

      {form, meta, args} when is_list(meta) ->
        {form, [], args}

      node ->
        node
    end)
  end

  defp metadata_path(path), do: "/.well-known/oauth-protected-resource" <> path

  defp create_starter_test(igniter, server_module) do
    test_module = Module.concat(server_module, InstallerTest)

    Igniter.Project.Module.find_and_update_or_create_module(
      igniter,
      test_module,
      starter_test_contents(server_module),
      &{:ok, &1},
      location: :test
    )
  end

  defp starter_test_contents(server_module) do
    """
    use ExUnit.Case, async: true

    alias AttestoMCP.Server.API

    test "registers the starter status tool" do
      {:ok, server} = API.start_link([])

      assert :ok = #{inspect(server_module)}.register(server)
      assert %{tool: tools} = API.snapshot(server)
      assert Enum.any?(tools, fn {_id, definition} -> definition.name == "server_status" end)
    end
    """
  end

  defp add_notices(igniter, auth_source, path, base_url, metadata_mode, _router, session_config) do
    auth_notice =
      case auth_source do
        {:attesto_phoenix, _app} ->
          "The generated routes reuse the host's validated attesto_phoenix verifier, revocation/principal policy, and sender-constraint callbacks. The installer does not enable or overwrite CIMD settings by default; pass --enable-cimd only after confirming the host's cache storage. Ephemeral localhost callback ports retain the existing installer compatibility default."

        {:callback, module, function} ->
          "The generated server uses #{inspect(module)}.#{function}/0 for Attesto verification."
      end

    metadata_notice =
      case metadata_mode do
        :reuse ->
          "The existing exact AttestoPhoenix protected-resource metadata route was reused; only the protected MCP forward was generated."

        :generate ->
          "The generated metadata route is public; keep it and the protected MCP forward outside browser session and CSRF pipelines."
      end

    session_notice = session_store_notice(session_config)

    igniter
    |> Igniter.add_notice("Configured protected MCP for #{base_url}#{path}.")
    |> Igniter.add_notice(auth_notice)
    |> Igniter.add_notice(metadata_notice)
    |> then(fn igniter ->
      if session_notice, do: Igniter.add_notice(igniter, session_notice), else: igniter
    end)
    |> Igniter.add_notice(
      "Review the generated server_status tool, replace it with application tools, and keep the MCP forward outside browser session and CSRF pipelines."
    )
  end

  defp session_store_notice(%{
         mode: :ecto,
         existing?: true,
         repo: repo,
         schema_prefix: schema_prefix,
         namespace: namespace
       }) do
    migration_command = session_migration_command(repo, schema_prefix)

    """
    Preserved the existing bundled Ecto session store with #{inspect(repo)} and namespace #{inspect(namespace)}. Ensure its tables have already been migrated. If no migration has been generated, run:

        #{migration_command}

    Then run `mix ecto.migrate` in the host application. The installer does not run either command.
    """
  end

  defp session_store_notice(%{
         mode: :ecto,
         repo: repo,
         schema_prefix: schema_prefix,
         namespace: namespace
       }) do
    migration_command = session_migration_command(repo, schema_prefix)

    """
    2025-era session-bound MCP requests use the bundled Ecto store with #{inspect(repo)} and namespace #{inspect(namespace)}. This keeps sessions across application restarts. Generate its tables with:

        #{migration_command}

    Then run `mix ecto.migrate` in the host application. The installer does not run either command. The Ecto store fails closed when the database is unavailable; current session-free requests do not depend on persisted session rows.
    """
  end

  defp session_store_notice(%{mode: :ets, requested: :ets}) do
    "2025-era session-bound MCP requests use the private ETS store because `--session-store ets` was selected; sessions are lost when the application restarts."
  end

  defp session_store_notice(%{mode: :custom, consistency_warning: warning}), do: warning

  defp session_store_notice(%{
         mode: :ets,
         requested: :auto,
         fallback: :repo_not_statically_supervised,
         repo: repo
       }) do
    "Automatic session-store selection kept the private ETS store because Ecto Repo #{inspect(repo)} was found in the host source but could not be statically confirmed as supervised by the application. No Ecto session configuration or migration was added. Add the Repo as a literal application child, select a statically supervised PostgreSQL Repo with `--session-store ecto` and/or `--repo`, or choose `--session-store ets` explicitly; sessions are lost when the application restarts."
  end

  defp session_store_notice(%{
         mode: :ets,
         requested: :auto,
         fallback: :unverified_repo,
         repo: repo
       }) do
    "Automatic session-store selection kept the private ETS store because Ecto Repo #{inspect(repo)} could not be statically confirmed as PostgreSQL. No Ecto session configuration or migration was added. Select a statically proven PostgreSQL Repo with `--session-store ecto` and/or `--repo`, or choose `--session-store ets` explicitly; sessions are lost when the application restarts."
  end

  defp session_store_notice(%{
         mode: :ets,
         requested: :auto,
         fallback: :unsupported_repo,
         repo: repo
       }) do
    "Automatic session-store selection kept the private ETS store because Ecto Repo #{inspect(repo)} is not configured for PostgreSQL. No Ecto session configuration or migration was added. Select a statically proven PostgreSQL Repo with `--session-store ecto` and/or `--repo`, or choose `--session-store ets` explicitly; sessions are lost when the application restarts."
  end

  defp session_store_notice(_session_config), do: nil

  defp session_migration_command(repo, nil),
    do: "mix attesto_mcp_server.gen.migration --repo #{inspect(repo)}"

  defp session_migration_command(repo, prefix),
    do: "mix attesto_mcp_server.gen.migration --repo #{inspect(repo)} --schema-prefix #{prefix}"
end
