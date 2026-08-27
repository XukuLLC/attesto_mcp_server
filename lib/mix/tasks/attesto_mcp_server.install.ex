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
    module reuses its validated `Attesto.Config`. Other hosts must supply a
    zero-arity callback with `--attesto-config`.

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
           {:ok, igniter, router} <- router(igniter, options[:router]),
           {:ok, igniter} <-
             routes_available(igniter, router, server_module, path, base_url) do
        igniter = create_server_module(igniter, server_module, app, auth_source)

        if igniter.issues == [] do
          igniter
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
        ~r/\A((?:Elixir\.)?[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*)\.([a-z_][A-Za-z0-9_!?]*)\/0\z/

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

    defp validate_path(path) when is_binary(path) do
      segments = String.split(path, "/")

      if path != "/" and String.starts_with?(path, "/") and
           not String.ends_with?(path, "/") and byte_size(path) <= 512 and
           not String.contains?(path, ["//", "?", "#"]) and ".." not in segments and
           safe_text?(path) do
        {:ok, path}
      else
        {:error,
         "--mcp-path must be an absolute, non-root path without a trailing slash, query, fragment, or traversal"}
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
          if installer_managed_server?(zipper) do
            {:ok, zipper}
          else
            {:error,
             "server module #{inspect(server_module)} already exists and is not installer-managed; choose --server-module"}
          end
        end
      )
    end

    defp routes_available(igniter, nil, _server_module, _path, _base_url),
      do: {:ok, igniter}

    defp routes_available(igniter, router, server_module, path, base_url) do
      case Igniter.Project.Module.find_module(igniter, router) do
        {:ok, {igniter, _source, zipper}} ->
          with {:ok, body} <- Igniter.Code.Common.move_to_do_block(zipper) do
            specs = route_specs(server_module, path, base_url)

            statuses =
              specs
              |> Map.new(fn {route, plug_module, _code} ->
                {route, forward_status(body, route, plug_module, server_module, path, base_url)}
              end)

            conflicts = for {route, :conflict} <- statuses, do: route
            missing? = Enum.any?(statuses, fn {_route, status} -> status == :missing end)
            incompatible_forward? = incompatible_forward?(body, specs)

            cond do
              conflicts != [] ->
                {:error, igniter,
                 "router #{inspect(router)} already uses #{Enum.join(conflicts, ", ")} with different forwarding options"}

              incompatible_forward? ->
                {:error, igniter,
                 "router #{inspect(router)} contains a dynamic forward route or reuses an MCP plug at another path; mount manually or choose another --router"}

              missing? and Igniter.Libs.Phoenix.move_to_router_use(igniter, body) == :error ->
                {:error, igniter,
                 "router #{inspect(router)} is not a recognized Phoenix router; choose --router explicitly"}

              true ->
                {:ok, igniter}
            end
          else
            :error -> {:error, igniter, "could not inspect router #{inspect(router)}"}
          end

        {:error, igniter} ->
          {:error, igniter, "router #{inspect(router)} was not found"}
      end
    end

    defp installer_managed_server?(zipper) do
      Igniter.Code.Function.move_to_def(
        zipper,
        :__attesto_mcp_server_installer__,
        0
      ) != :error
    end

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
          case Igniter.Libs.Phoenix.move_to_router_use(igniter, zipper) do
            {:ok, location} ->
              {:ok, Igniter.Code.Common.add_code(location, missing, placement: :after)}

            :error ->
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
      aliases = alias_map(ast)

      {top_level_forwards, nested_forward_count} = forward_calls(ast, route)

      forwards = Enum.map(top_level_forwards, &canonical_ast(&1, aliases))

      expected =
        route
        |> forward_statement(plug_module, server_module, path, base_url)
        |> Sourceror.parse_string!()
        |> canonical_ast(aliases)

      case {forwards, nested_forward_count} do
        {[], 0} ->
          :missing

        {[^expected], 0} ->
          :present

        _ ->
          :conflict
      end
    end

    defp forward_calls(ast, route) do
      all = collect_forward_calls(ast, route)

      top_level =
        ast
        |> top_level_expressions()
        |> Enum.filter(&forward_call_for_route?(&1, route))

      {top_level, length(all) - length(top_level)}
    end

    defp collect_forward_calls(ast, route) do
      {_ast, calls} =
        Macro.prewalk(ast, [], fn
          {:forward, _meta, args} = call, calls when length(args) in [2, 3] ->
            if literal_string(List.first(args)) == route,
              do: {call, [call | calls]},
              else: {call, calls}

          node, calls ->
            {node, calls}
        end)

      Enum.reverse(calls)
    end

    defp incompatible_forward?(zipper, specs) do
      ast = Sourceror.Zipper.node(zipper)
      aliases = alias_map(ast)
      desired_routes = specs |> Enum.map(&elem(&1, 0)) |> MapSet.new()
      desired_plugs = specs |> Enum.map(&elem(&1, 1)) |> MapSet.new()

      ast
      |> collect_all_forward_calls()
      |> Enum.any?(fn {:forward, _meta, args} ->
        route = args |> List.first() |> literal_string()
        plug_module = args |> Enum.at(1) |> canonical_ast(aliases)

        is_nil(route) or
          (route not in desired_routes and MapSet.member?(desired_plugs, plug_module))
      end)
    end

    defp collect_all_forward_calls(ast) do
      {_ast, calls} =
        Macro.prewalk(ast, [], fn
          {:forward, _meta, args} = call, calls when length(args) in [2, 3] ->
            {call, [call | calls]}

          node, calls ->
            {node, calls}
        end)

      Enum.reverse(calls)
    end

    defp top_level_expressions({:__block__, _meta, expressions}), do: expressions
    defp top_level_expressions(expression), do: [expression]

    defp forward_call_for_route?({:forward, _meta, args}, route) when length(args) in [2, 3],
      do: literal_string(List.first(args)) == route

    defp forward_call_for_route?(_node, _route), do: false

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
      """
      forward #{inspect(route)}, #{inspect(plug_module)},
        server: #{inspect(server_module)},
        path: #{inspect(path)},
        auth: [
          config: &#{inspect(server_module)}.attesto_config/0,
          resource: #{inspect(path)},
          base_url: #{inspect(base_url)}
        ]
      """
      |> String.trim()
    end

    defp literal_string(value) when is_binary(value), do: value
    defp literal_string({:__block__, _meta, [value]}) when is_binary(value), do: value
    defp literal_string(_value), do: nil

    defp alias_map(ast) do
      {_ast, aliases} =
        Macro.prewalk(ast, %{}, fn
          {:alias, _meta, [module_ast | options]} = node, aliases ->
            case alias_entry(module_ast, options) do
              {name, module} ->
                aliases =
                  Map.update(aliases, name, module, fn
                    ^module -> module
                    _different_module -> :ambiguous
                  end)

                {node, aliases}

              nil ->
                {node, aliases}
            end

          node, aliases ->
            {node, aliases}
        end)

      aliases
    end

    defp alias_entry({:__aliases__, _meta, parts}, options) when is_list(parts) do
      module = Module.concat(parts)

      name =
        case Keyword.get(options, :as) do
          {:__aliases__, _as_meta, as_parts} when is_list(as_parts) -> List.last(as_parts)
          nil -> List.last(parts)
          _other -> nil
        end

      if is_atom(name), do: {name, module}, else: nil
    end

    defp alias_entry(_module_ast, _options), do: nil

    defp canonical_ast(ast, aliases) do
      Macro.prewalk(ast, fn
        {:__aliases__, _meta, [head | tail]} ->
          case Map.get(aliases, head) do
            module when is_atom(module) and module not in [nil, :ambiguous] ->
              Module.concat([module | tail])

            _unknown_or_ambiguous ->
              Module.concat([head | tail])
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
            "The generated server reuses the host's validated attesto_phoenix configuration."

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
