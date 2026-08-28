defmodule Mix.Tasks.AttestoMcpServer.Install.Docs do
  @moduledoc false

  @spec short_doc() :: String.t()
  def short_doc, do: "Installs an Attesto-protected MCP server into a Phoenix host"

  @spec example() :: String.t()
  def example do
    "mix attesto_mcp_server.install --base-url https://mcp.example.com " <>
      "--attesto-config MyApp.Attesto.config/0"
  end

  @spec long_doc() :: String.t()
  def long_doc do
    """
    #{short_doc()}.

    The task creates an application-owned supervised MCP module and starter
    test, adds protected MCP and RFC 9728 metadata forwards to a Phoenix
    router, and adds conservative server configuration. It is idempotent and
    does not invent credentials, authorization policy, or a public origin.

    When `attesto_phoenix` is already a direct dependency, the generated MCP
    module reuses its validated `Attesto.Config`. The installer enables URL
    client metadata and ephemeral `localhost` callback ports when those host
    keys are absent, and adds the Req dependency used by the default metadata
    fetcher. Other hosts must supply a zero-arity callback with
    `--attesto-config`.

    ## Example

        #{example()}

    ## Options

      * `--base-url` - required canonical public origin. HTTPS is required
      * `--mcp-path` - MCP route path; defaults to `/mcp`
      * `--server-module` - supervised host module; defaults to `<App>.MCP`
      * `--router` - Phoenix router module; selected automatically when unique
      * `--attesto-config` - zero-arity callback such as
        `MyApp.Attesto.config/0`; unnecessary with `attesto_phoenix`
      * `--allow-http-loopback` - allow an explicit HTTP loopback origin for
        local development only

    Igniter's global `--dry-run`, `--yes`, and related options remain
    available. Umbrella roots are not supported; run the task inside the
    Phoenix child application.
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AttestoMcpServer.Install do
    use Igniter.Mix.Task

    @shortdoc Mix.Tasks.AttestoMcpServer.Install.Docs.short_doc()
    @moduledoc Mix.Tasks.AttestoMcpServer.Install.Docs.long_doc()
    @example Mix.Tasks.AttestoMcpServer.Install.Docs.example()
    @origin_pattern ~r/\A(https?):\/\/(\[[0-9a-f:.]+\]|[a-z0-9.-]+)(?::([0-9]{1,5}))?\/?\z/i
    @attesto_phoenix_requirement ">= 2.14.0 and < 3.0.0"
    @req_requirement ">= 0.6.1 and < 1.0.0"
    @max_version_component 99_999_999_999_999
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
    @router_dsl_signatures for name <- [:scope, :forward], arity <- 2..4, do: {name, arity}
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
          allow_http_loopback: :boolean
        ],
        defaults: [mcp_path: "/mcp", allow_http_loopback: false],
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
           {:ok, auth_source} <- auth_source(igniter, options[:attesto_config], app),
           {:ok, auth_dependencies} <- authorization_dependencies(igniter, auth_source),
           {:ok, igniter, router} <- router(igniter, options[:router]),
           {:ok, igniter} <-
             routes_available(igniter, router, server_module, path, base_url) do
        igniter = create_server_module(igniter, server_module, app, auth_source)

        if igniter.issues == [] do
          igniter
          |> configure_authorization_server(app, auth_source, auth_dependencies)
          |> configure_server(app, server_module)
          |> Igniter.Project.Application.add_new_child(server_module)
          |> add_routes(router, server_module, path, base_url)
          |> create_starter_test(server_module)
          |> add_notices(auth_source, path, base_url)
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

    defp authorization_dependencies(_igniter, {:callback, _module, _function}), do: {:ok, []}

    defp authorization_dependencies(igniter, {:attesto_phoenix, _app}) do
      with :ok <- validate_dependency_catalog(igniter),
           {:ok, attesto_phoenix} <-
             constrained_dependency(
               igniter,
               :attesto_phoenix,
               @attesto_phoenix_requirement
             ),
           {:ok, req} <-
             constrained_dependency(
               igniter,
               :req,
               @req_requirement
             ) do
        {:ok, [attesto_phoenix, req]}
      end
    end

    defp validate_dependency_catalog(igniter) do
      with {:ok, entries} <- literal_dependency_entries(igniter) do
        names = Enum.map(entries, &dependency_entry_name/1)

        cond do
          Enum.any?(names, &match?({:error, :unknown_dependency_name}, &1)) ->
            {:error,
             "deps/0 contains a dependency entry whose package name cannot be verified; " <>
               "declare dependencies as explicit tuples before installation"}

          duplicate = duplicate_required_dependency(names) ->
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

    defp duplicate_required_dependency(names) do
      Enum.find([:attesto_phoenix, :req], fn name -> Enum.count(names, &(&1 == name)) > 1 end)
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

    defp create_server_module(igniter, server_module, app, auth_source) do
      Igniter.Project.Module.find_and_update_or_create_module(
        igniter,
        server_module,
        server_module_contents(app, auth_source),
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

    defp routes_available(igniter, nil, _server_module, _path, _base_url),
      do: {:ok, igniter}

    defp routes_available(igniter, router, server_module, path, base_url) do
      case Igniter.Project.Module.find_module(igniter, router) do
        {:ok, {igniter, _source, zipper}} ->
          with true <- isolated_module_source?(zipper),
               {:ok, body} <- Igniter.Code.Common.move_to_do_block(zipper) do
            specs = route_specs(server_module, path, base_url)

            trusted_router_use = move_to_trusted_router_use(igniter, body, router)
            router_recognized? = match?({:ok, _location}, trusted_router_use)

            dsl_provenance_safe? =
              case trusted_router_use do
                {:ok, location} ->
                  router_dsl_provenance_safe?(
                    Sourceror.Zipper.node(body),
                    Sourceror.Zipper.node(location)
                  )

                :error ->
                  false
              end

            statuses =
              specs
              |> Map.new(fn {route, plug_module, _code} ->
                {route, forward_status(body, route, plug_module, server_module, path, base_url)}
              end)

            conflicts = for {route, :conflict} <- statuses, do: route
            scoped_forward_conflict? = scoped_forward_conflict?(body, specs)
            incompatible_forward? = incompatible_forward?(body, specs)
            route_overlap? = route_overlap?(body, specs)

            cond do
              not router_recognized? ->
                {:error, igniter,
                 "router #{inspect(router)} is not a recognized Phoenix router; choose --router explicitly"}

              not dsl_provenance_safe? ->
                {:error, igniter,
                 "router #{inspect(router)} contains an unqualified scope or forward whose Phoenix.Router provenance cannot be proven; mount manually or qualify the router calls"}

              conflicts != [] ->
                {:error, igniter,
                 "router #{inspect(router)} already uses #{Enum.join(conflicts, ", ")} with different forwarding options"}

              scoped_forward_conflict? ->
                {:error, igniter,
                 "router #{inspect(router)} contains a scoped forward route that collides with or cannot be distinguished from the requested MCP routes; mount manually or choose another --router"}

              incompatible_forward? ->
                {:error, igniter,
                 "router #{inspect(router)} contains a dynamic forward route or plug, an ambiguous nested forward, or reuses an MCP plug at another path; mount manually or choose another --router"}

              route_overlap? ->
                {:error, igniter,
                 "router #{inspect(router)} contains a route whose path overlaps a requested MCP route; mount manually or choose another --router"}

              true ->
                {:ok, igniter}
            end
          else
            false ->
              {:error, igniter,
               "router #{inspect(router)} must be the only top-level module in its source file so compiler provenance can be verified"}

            :error ->
              {:error, igniter, "could not inspect router #{inspect(router)}"}
          end

        {:error, igniter} ->
          {:error, igniter, "router #{inspect(router)} was not found"}
      end
    end

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

    defp server_module_contents(app, auth_source) do
      """
      @moduledoc "Application-owned MCP registrations and Attesto integration."

      alias AttestoMCP.Server.API

      @otp_app #{inspect(app)}

      @doc false
      def __attesto_mcp_server_installer__, do: :v1

      defmodule MetadataPlug do
        @moduledoc false
        @behaviour Plug

        @impl Plug
        defdelegate init(options), to: AttestoMCP.Server.Plug

        @impl Plug
        defdelegate call(conn, options), to: AttestoMCP.Server.Plug
      end

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

    defp configure_server(igniter, app, server_module) do
      server_options = [server_name: "#{app}-mcp"]

      Igniter.Project.Config.configure_new(
        igniter,
        "config.exs",
        app,
        [server_module, :server_options],
        server_options
      )
    end

    defp configure_authorization_server(
           igniter,
           app,
           {:attesto_phoenix, _app},
           dependencies
         ) do
      igniter =
        Enum.reduce(dependencies, igniter, fn dependency, acc ->
          Igniter.Project.Deps.add_dep(acc, dependency, yes?: true)
        end)

      igniter
      |> Igniter.Project.Config.configure_new(
        "config.exs",
        app,
        [AttestoPhoenix.Config, :client_id_metadata, :enabled],
        true
      )
      |> Igniter.Project.Config.configure_new(
        "config.exs",
        app,
        [AttestoPhoenix.Config, :native_apps, :loopback_include_localhost],
        true
      )
    end

    defp configure_authorization_server(
           igniter,
           _app,
           {:callback, _module, _function},
           _dependencies
         ),
         do: igniter

    defp add_routes(igniter, nil, server_module, path, base_url) do
      Igniter.add_warning(
        igniter,
        Igniter.Util.Warning.formatted_warning(
          "No Phoenix router was found. Add these forwards manually without a browser session or CSRF pipeline.",
          forward_code(server_module, path, base_url)
        )
      )
    end

    defp add_routes(igniter, router, server_module, path, base_url) do
      Igniter.Project.Module.find_and_update_module!(igniter, router, fn zipper ->
        missing =
          server_module
          |> route_specs(path, base_url)
          |> Enum.reject(fn {route, plug_module, _code} ->
            forward_present?(zipper, route, plug_module, server_module, path, base_url)
          end)
          |> Enum.map_join("\n\n", &elem(&1, 2))

        if missing == "" do
          {:ok, zipper}
        else
          with {:ok, location} <- move_to_trusted_router_use(igniter, zipper, router) do
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

    defp forward_present?(zipper, route, plug_module, server_module, path, base_url) do
      forward_status(zipper, route, plug_module, server_module, path, base_url) == :present
    end

    defp forward_status(zipper, route, plug_module, server_module, path, base_url) do
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
        |> forward_statement(plug_module, server_module, path, base_url)
        |> Sourceror.parse_string!()
        |> canonical_forward_ast(%{})

      case forwards do
        [] ->
          :missing

        [^expected] ->
          :present

        _ ->
          :conflict
      end
    end

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

    defp router_dsl_provenance_safe?(ast, trusted_router_use) do
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
         do: {:ok, update_router_use(environment, expression)}

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

    defp validate_router_dsl_call(node, environment) do
      case router_dsl_call(node, environment.aliases) do
        {:ok, provenance, :scope, arity, arguments} ->
          signature = {:scope, arity}

          if trusted_router_dsl_call?(provenance, signature, environment) do
            case scope_arguments_and_body(arguments) do
              {:ok, _arguments, body} ->
                case validate_router_dsl_node(body, environment) do
                  {:ok, _nested_environment} -> {:ok, environment}
                  :error -> :error
                end

              :error ->
                validate_router_dsl_children(node, environment)
            end
          else
            :error
          end

        {:ok, provenance, :forward, arity, _arguments} ->
          if trusted_router_dsl_call?(provenance, {:forward, arity}, environment),
            do: {:ok, environment},
            else: :error

        :error ->
          if call_to_required_module?(node, environment) do
            :error
          else
            validate_router_dsl_children(node, environment)
          end
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

    defp forward_code(server_module, path, base_url) do
      server_module
      |> route_specs(path, base_url)
      |> Enum.map(&elem(&1, 2))
      |> Enum.join("\n\n")
    end

    defp route_specs(server_module, path, base_url) do
      metadata_path = metadata_path(path)
      metadata_plug = Module.concat(server_module, MetadataPlug)

      [
        {metadata_path, metadata_plug,
         forward_statement(metadata_path, metadata_plug, server_module, path, base_url)},
        {path, AttestoMCP.Server.Plug,
         forward_statement(path, AttestoMCP.Server.Plug, server_module, path, base_url)}
      ]
    end

    defp forward_statement(route, plug_module, server_module, path, base_url) do
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

    defp add_notices(igniter, auth_source, path, base_url) do
      auth_notice =
        case auth_source do
          {:attesto_phoenix, _app} ->
            "The generated server reuses the host's validated attesto_phoenix configuration, enables URL client metadata, and accepts ephemeral localhost callback ports for native clients."

          {:callback, module, function} ->
            "The generated server uses #{inspect(module)}.#{function}/0 for Attesto verification."
        end

      igniter
      |> Igniter.add_notice(
        "Configured protected MCP for #{base_url}#{path} and its RFC 9728 metadata route."
      )
      |> Igniter.add_notice(auth_notice)
      |> Igniter.add_notice(
        "Review the generated server_status tool, replace it with application tools, and keep the MCP forwards outside browser session and CSRF pipelines."
      )
    end
  end
else
  defmodule Mix.Tasks.AttestoMcpServer.Install do
    use Mix.Task

    @shortdoc Mix.Tasks.AttestoMcpServer.Install.Docs.short_doc()
    @moduledoc Mix.Tasks.AttestoMcpServer.Install.Docs.long_doc()

    @impl Mix.Task
    def run(_argv) do
      Mix.raise("""
      The task 'attesto_mcp_server.install' requires Igniter. Add the optional
      development dependency and try again:

          {:igniter, "~> 0.6", only: [:dev, :test], runtime: false}

      Or run `mix igniter.install attesto_mcp_server` from the host project.
      """)
    end
  end
end
