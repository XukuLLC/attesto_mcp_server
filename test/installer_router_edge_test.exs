defmodule Mix.Tasks.AttestoMcpServer.InstallRouterEdgeTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  @task Mix.Tasks.AttestoMcpServer.Install
  @install_args [
    "--base-url",
    "https://mcp.example.com",
    "--attesto-config",
    "Sample.Attesto.config/0"
  ]

  test "refuses an existing Phoenix forward/4 at the MCP path" do
    installed =
      four_argument_forward_router_ex()
      |> project()
      |> install(@install_args)

    assert Enum.any?(installed.issues, &String.contains?(&1, "different forwarding options"))
    assert Igniter.Test.diff(installed) == ""
  end

  test "recognizes equivalent forwards that use explicit alias names" do
    installed =
      explicitly_aliased_router_ex()
      |> project()
      |> install(@install_args)

    assert installed.issues == []

    rerun =
      installed
      |> apply_igniter!()
      |> install(@install_args)

    assert rerun.issues == []
    assert_unchanged(rerun)
  end

  test "roots generated forward modules despite conflicting host aliases" do
    installed =
      conflicting_module_alias_router_ex()
      |> project()
      |> install(@install_args)

    assert installed.issues == []

    diff = Igniter.Test.diff(installed)

    assert diff =~ "Elixir.Sample.MCP.MetadataPlug"
    assert diff =~ "Elixir.AttestoMCP.Server.Plug"
    assert diff =~ "server: Elixir.Sample.MCP"
    assert diff =~ "config: &Elixir.Sample.MCP.attesto_config/0"

    rerun =
      installed
      |> apply_igniter!()
      |> install(@install_args)

    assert rerun.issues == []
    assert_unchanged(rerun)
  end

  test "refuses a different callback on an installer-managed server" do
    rerun =
      router_ex()
      |> project()
      |> install(@install_args)
      |> apply_igniter!()
      |> install([
        "--base-url",
        "https://mcp.example.com",
        "--attesto-config",
        "Sample.OtherAttesto.config/0"
      ])

    assert Enum.any?(rerun.issues, fn issue ->
             String.contains?(issue, "different installer-managed Attesto configuration")
           end)

    assert Igniter.Test.diff(rerun) == ""

    refute Enum.any?(rerun.notices, fn notice ->
             String.contains?(notice, "Sample.OtherAttesto.config/0")
           end)
  end

  test "refuses a scoped forward whose effective path matches the requested MCP path" do
    installed =
      scoped_prefix_collision_router_ex()
      |> project()
      |> install(@install_args ++ ["--mcp-path", "/api/mcp"])

    assert Enum.any?(installed.issues, &String.contains?(&1, "scoped forward"))
    assert Igniter.Test.diff(installed) == ""
  end

  test "refuses host routes that would be shadowed by an inserted MCP forward" do
    for router_source <- [
          host_route_router_ex(:get, "/mcp"),
          host_route_router_ex(:get, "/mcp/"),
          host_route_router_ex(:get, "/mcp/admin"),
          host_route_router_ex(:get, "/:section"),
          host_route_router_ex(:match, "/.well-known/oauth-protected-resource/mcp/details"),
          host_route_router_ex(:match, "/*path"),
          host_route_router_ex(:resources, "/mcp"),
          required_phoenix_alias_router_ex(:get),
          required_phoenix_alias_router_ex(:forward),
          parent_forward_router_ex()
        ] do
      installed =
        router_source
        |> project()
        |> install(@install_args)

      assert Enum.any?(installed.issues, &String.contains?(&1, "path overlaps"))
      assert Igniter.Test.diff(installed) == ""
    end
  end

  test "allows host routes outside the MCP forward prefixes" do
    installed =
      host_route_router_ex(:get, "/health")
      |> project()
      |> install(@install_args)

    assert installed.issues == []
    assert Igniter.Test.diff(installed) =~ "Elixir.Phoenix.Router.forward"
  end

  test "ignores aliases declared inside an unrelated scope during top-level comparison" do
    installed =
      nested_alias_router_ex()
      |> project()
      |> install(@install_args)

    assert installed.issues == []

    rerun =
      installed
      |> apply_igniter!()
      |> install(@install_args)

    assert rerun.issues == []
    assert_unchanged(rerun)
  end

  test "refuses multiple or guarded installer-managed callback clauses" do
    for server_source <- [
          multiple_callback_server_ex(),
          guarded_callback_server_ex(),
          qualified_kernel_callback_server_ex(:before),
          qualified_kernel_callback_server_ex(:after),
          aliased_kernel_callback_server_ex(),
          qualified_kernel_callback_kind_server_ex(:defp),
          qualified_kernel_callback_kind_server_ex(:defmacro),
          qualified_kernel_callback_kind_server_ex(:defmacrop),
          qualified_kernel_callback_kind_server_ex(:defguard),
          qualified_kernel_callback_kind_server_ex(:defguardp)
        ] do
      installed =
        router_ex()
        |> project(%{"lib/sample/mcp.ex" => server_source})
        |> install(@install_args)

      assert Enum.any?(installed.issues, fn issue ->
               String.contains?(issue, "different installer-managed Attesto configuration") or
                 String.contains?(issue, "not installer-managed")
             end)

      assert Igniter.Test.diff(installed) == ""
    end
  end

  test "refuses opaque or conditional top-level forms in an installer-managed server" do
    for server_source <- [
          conditional_callback_server_ex(),
          opaque_macro_server_ex(),
          before_compile_server_ex(),
          dynamic_attribute_server_ex()
        ] do
      installed =
        router_ex()
        |> project(%{"lib/sample/mcp.ex" => server_source})
        |> install(@install_args)

      assert installed.issues != []
      assert Igniter.Test.diff(installed) == ""
    end
  end

  test "refuses executable definition tunnels in attributes and nested modules" do
    sources = [
      attribute_definition_tunnel_server_ex("Sample.MCP", "Sample.Attesto.config()"),
      nested_module_definition_tunnel_server_ex("Sample.MCP", "Sample.Attesto.config()")
    ]

    for server_source <- sources do
      installed =
        router_ex()
        |> project(%{"lib/sample/mcp.ex" => server_source})
        |> install(@install_args)

      assert installed.issues != []
      assert Igniter.Test.diff(installed) == ""
    end

    for {label, source_builder} <- [
          {:attribute, &attribute_definition_tunnel_server_ex/2},
          {:nested_module, &nested_module_definition_tunnel_server_ex/2}
        ] do
      module =
        Module.concat([
          __MODULE__,
          "DefinitionTunnel#{label}#{System.unique_integer([:positive])}"
        ])

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        Code.compile_string(source_builder.(inspect(module), ":expected"))
      end)

      on_exit(fn -> :code.purge(module) && :code.delete(module) end)

      assert apply(module, :attesto_config, []) == :hidden
    end
  end

  test "refuses required macros that inject definitions while bodies expand" do
    for server_source <- [
          macro_definition_tunnel_server_ex(
            "Sample.MCP",
            "Sample.AuthInjector",
            "Sample.Attesto.config()"
          ),
          outer_import_definition_tunnel_server_ex(
            "Sample.MCP",
            "Sample.AuthInjector",
            "Sample.Attesto.config()"
          )
        ] do
      installed =
        router_ex()
        |> project(%{"lib/sample/mcp.ex" => server_source})
        |> install(@install_args)

      assert installed.issues != []
      assert Igniter.Test.diff(installed) == ""
    end

    for source_builder <- [
          &macro_definition_tunnel_server_ex/3,
          &outer_import_definition_tunnel_server_ex/3
        ] do
      suffix = System.unique_integer([:positive])
      injector = Module.concat([__MODULE__, "AuthInjector#{suffix}"])
      server = Module.concat([__MODULE__, "MacroDefinitionTunnel#{suffix}"])

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        Code.compile_string(macro_injector_ex(inspect(injector)))
        Code.compile_string(source_builder.(inspect(server), inspect(injector), ":expected"))
      end)

      on_exit(fn ->
        :code.purge(server)
        :code.delete(server)
        :code.purge(injector)
        :code.delete(injector)
      end)

      assert apply(server, :attesto_config, []) == :hidden
    end
  end

  test "refuses after-verify hooks that replace managed modules" do
    installed =
      router_ex()
      |> project(%{
        "lib/sample/mcp.ex" =>
          after_verify_tunnel_server_ex(
            "Sample.MCP",
            "Sample.AfterVerifier",
            "Sample.Attesto.config()"
          )
      })
      |> install(@install_args)

    assert installed.issues != []
    assert Igniter.Test.diff(installed) == ""

    suffix = System.unique_integer([:positive])
    verifier = Module.concat([__MODULE__, "AfterVerifier#{suffix}"])
    server = Module.concat([__MODULE__, "AfterVerifyTunnel#{suffix}"])
    registration = Module.concat([__MODULE__, "AfterVerifyReceiver#{suffix}"])
    Process.register(self(), registration)

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      Code.compile_string(after_verify_callback_ex(inspect(verifier), registration))

      Code.compile_string(
        after_verify_tunnel_server_ex(inspect(server), inspect(verifier), ":expected")
      )

      assert_receive {:after_verify_replaced, ^server}, 1_000
    end)

    on_exit(fn ->
      :code.purge(server)
      :code.delete(server)
      :code.purge(verifier)
      :code.delete(verifier)
    end)

    assert apply(server, :attesto_config, []) == :hidden
  end

  test "accepts an unrelated alias rooted at __MODULE__" do
    installed =
      module_relative_alias_router_ex()
      |> project()
      |> install(@install_args)

    assert installed.issues == []
    assert Igniter.Test.diff(installed) =~ "Elixir.AttestoMCP.Server.Plug"
  end

  test "accepts the approved authorization router use after the primary router use" do
    installed =
      approved_authorization_router_ex()
      |> project()
      |> install(@install_args)

    assert installed.issues == []

    rerun =
      installed
      |> apply_igniter!()
      |> install(@install_args)

    assert rerun.issues == []
    assert_unchanged(rerun)
  end

  test "refuses router uses redirected by enclosing file aliases" do
    for router_source <- [
          outer_primary_router_alias_spoof_ex(
            "SampleWeb.Router",
            "SampleWeb.Spoof"
          ),
          outer_authorization_router_alias_spoof_ex(
            "SampleWeb.Router",
            "SampleWeb.Spoof"
          )
        ] do
      installed =
        router_source
        |> project()
        |> install(@install_args ++ ["--router", "SampleWeb.Router"])

      assert Enum.any?(installed.issues, &String.contains?(&1, "only top-level module"))
      assert Igniter.Test.diff(installed) == ""
    end

    for source_builder <- [
          &outer_primary_router_alias_spoof_ex/2,
          &outer_authorization_router_alias_spoof_ex/2
        ] do
      suffix = System.unique_integer([:positive])
      spoof = Module.concat([__MODULE__, "RouterSpoof#{suffix}"])
      spoof_router = Module.concat([spoof, "Router"])
      router = Module.concat([__MODULE__, "LexicalRouter#{suffix}"])

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        Code.compile_string(router_spoof_ex(inspect(spoof)))
        Code.compile_string(source_builder.(inspect(router), inspect(spoof)))
      end)

      on_exit(fn ->
        :code.purge(router)
        :code.delete(router)
        :code.purge(spoof_router)
        :code.delete(spoof_router)
        :code.purge(spoof)
        :code.delete(spoof)
      end)

      assert apply(router, :spoofed?, [])
    end
  end

  test "requires selected router and managed server modules to be root modules" do
    nested_router =
      nested_absolute_router_ex()
      |> project()
      |> install(@install_args ++ ["--router", "SampleWeb.Router"])

    assert Enum.any?(nested_router.issues, &String.contains?(&1, "only top-level module"))
    assert Igniter.Test.diff(nested_router) == ""

    nested_server =
      router_ex()
      |> project(%{"lib/sample/mcp.ex" => nested_absolute_server_ex()})
      |> install(@install_args)

    assert Enum.any?(nested_server.issues, &String.contains?(&1, "not installer-managed"))
    assert Igniter.Test.diff(nested_server) == ""
  end

  test "refuses a qualified Phoenix.Router.forward collision" do
    installed =
      qualified_forward_router_ex()
      |> project()
      |> install(@install_args)

    assert Enum.any?(installed.issues, &String.contains?(&1, "different forwarding options"))
    assert Igniter.Test.diff(installed) == ""
  end

  test "recognizes an equivalent forward/4 with empty router options" do
    installed =
      empty_router_options_forward_ex()
      |> project()
      |> install(@install_args)

    assert installed.issues == []

    rerun =
      installed
      |> apply_igniter!()
      |> install(@install_args)

    assert rerun.issues == []
    assert_unchanged(rerun)
  end

  test "recognizes equivalent forwards through chained and grouped aliases" do
    installed =
      chained_grouped_alias_router_ex()
      |> project()
      |> install(@install_args)

    assert installed.issues == []

    rerun =
      installed
      |> apply_igniter!()
      |> install(@install_args)

    assert rerun.issues == []
    assert_unchanged(rerun)
  end

  test "does not apply a later alias to an earlier forward" do
    installed =
      forward_before_alias_router_ex()
      |> project()
      |> install(@install_args)

    assert Enum.any?(installed.issues, &String.contains?(&1, "different forwarding options"))
    assert Igniter.Test.diff(installed) == ""
  end

  test "tracks qualified scoped forwards across later router-alias rebinding" do
    installed =
      rebound_router_alias_in_scope_ex()
      |> project()
      |> install(@install_args ++ ["--mcp-path", "/api/mcp"])

    assert Enum.any?(installed.issues, &String.contains?(&1, "scoped forward"))
    assert Igniter.Test.diff(installed) == ""
  end

  test "tracks an MCP plug forward across later plug-alias rebinding" do
    installed =
      rebound_plug_alias_router_ex()
      |> project()
      |> install(@install_args)

    assert Enum.any?(installed.issues, &String.contains?(&1, "reuses an MCP plug"))
    assert Igniter.Test.diff(installed) == ""
  end

  test "allows a scoped forward whose effective path is unrelated" do
    installed =
      unrelated_scoped_forward_router_ex()
      |> project()
      |> install(@install_args)

    assert installed.issues == []

    rerun =
      installed
      |> apply_igniter!()
      |> install(@install_args)

    assert rerun.issues == []
    assert_unchanged(rerun)
  end

  test "recognizes exact qualified Phoenix router forwards" do
    installed =
      exact_qualified_forwards_router_ex()
      |> project()
      |> install(@install_args)

    assert installed.issues == []

    rerun =
      installed
      |> apply_igniter!()
      |> install(@install_args)

    assert rerun.issues == []
    assert_unchanged(rerun)
  end

  test "tracks grouped router aliases with options inside scopes" do
    installed =
      grouped_router_alias_with_options_ex()
      |> project()
      |> install(@install_args ++ ["--mcp-path", "/api/mcp"])

    assert Enum.any?(installed.issues, &String.contains?(&1, "scoped forward"))
    assert Igniter.Test.diff(installed) == ""
  end

  test "refuses a dynamic plug expression before editing" do
    installed =
      dynamic_plug_router_ex()
      |> project()
      |> install(@install_args)

    assert Enum.any?(installed.issues, &String.contains?(&1, "dynamic forward route"))
    assert Igniter.Test.diff(installed) == ""
  end

  test "refuses unqualified router DSL calls whose import provenance is ambiguous" do
    for router_source <- [
          shadowed_scope_router_ex(),
          shadowed_forward_router_ex(),
          opaque_use_router_ex(),
          route_injector_use_router_ex(),
          approved_router_use_before_primary_ex(),
          approved_router_use_with_options_ex(),
          opaque_macro_before_router_use_ex(),
          fake_router_use_before_real_router_ex(),
          pre_router_shadow_import_router_ex(),
          local_forward_macro_router_ex(),
          required_route_macro_after_router_use_ex(),
          aliased_required_route_macro_after_router_use_ex()
        ] do
      installed =
        router_source
        |> project()
        |> install(@install_args)

      assert Enum.any?(installed.issues, &String.contains?(&1, "provenance cannot be proven"))
      assert Igniter.Test.diff(installed) == ""
    end
  end

  test "allows explicit imports that cannot provide router DSL calls" do
    installed =
      irrelevant_import_router_ex()
      |> project()
      |> install(@install_args)

    assert installed.issues == []

    rerun =
      installed
      |> apply_igniter!()
      |> install(@install_args)

    assert rerun.issues == []
    assert_unchanged(rerun)
  end

  test "refuses an exact lookalike router before editing" do
    installed =
      exact_lookalike_router_ex()
      |> project()
      |> install(@install_args ++ ["--router", "SampleWeb.Router"])

    assert Enum.any?(installed.issues, &String.contains?(&1, "not a recognized Phoenix router"))
    assert Igniter.Test.diff(installed) == ""
  end

  test "does not apply a later alias to an earlier callback" do
    installed =
      router_ex()
      |> project(%{"lib/sample/mcp.ex" => callback_before_alias_server_ex()})
      |> install(@install_args)

    assert Enum.any?(installed.issues, fn issue ->
             String.contains?(issue, "different installer-managed Attesto configuration")
           end)

    assert Igniter.Test.diff(installed) == ""
  end

  test "requires one exact top-level public installer ownership marker" do
    invalid_servers = [
      nested_marker_server_ex(),
      guarded_marker_server_ex(),
      private_marker_server_ex(),
      wrong_marker_server_ex(),
      multiple_marker_server_ex(),
      qualified_kernel_marker_server_ex(),
      conditional_marker_server_ex()
    ]

    for server_source <- invalid_servers do
      installed =
        router_ex()
        |> project(%{"lib/sample/mcp.ex" => server_source})
        |> install(@install_args)

      assert Enum.any?(installed.issues, &String.contains?(&1, "not installer-managed"))
      assert Igniter.Test.diff(installed) == ""
    end
  end

  defp install(igniter, args), do: Igniter.compose_task(igniter, @task, args)

  defp project(router_source, extra_files \\ %{}) do
    Igniter.Test.test_project(
      app_name: :sample,
      files:
        Map.merge(
          %{
            "mix.exs" => mix_exs(),
            "lib/sample/application.ex" => application_ex(),
            "lib/sample_web/router.ex" => router_source
          },
          extra_files
        )
    )
  end

  defp mix_exs do
    """
    defmodule Sample.MixProject do
      use Mix.Project

      def project do
        [app: :sample, version: "0.1.0", elixir: "~> 1.18", deps: deps()]
      end

      def application do
        [extra_applications: [:logger], mod: {Sample.Application, []}]
      end

      defp deps do
        [{:attesto_mcp_server, "~> 0.10"}]
      end
    end
    """
  end

  defp application_ex do
    """
    defmodule Sample.Application do
      use Application

      @impl true
      def start(_type, _args) do
        Supervisor.start_link([], strategy: :one_for_one, name: Sample.Supervisor)
      end
    end
    """
  end

  defp router_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router
    end
    """
  end

  defp four_argument_forward_router_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router

      forward "/mcp", SampleWeb.OtherPlug, [], log: false
    end
    """
  end

  defp host_route_router_ex(:get, path) do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router

      get #{inspect(path)}, SampleWeb.PageController, :index
    end
    """
  end

  defp host_route_router_ex(:match, path) do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router

      Phoenix.Router.match :*, #{inspect(path)}, SampleWeb.PageController, :index
    end
    """
  end

  defp host_route_router_ex(:resources, path) do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router

      resources #{inspect(path)}, SampleWeb.PageController
    end
    """
  end

  defp parent_forward_router_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router

      forward "/", SampleWeb.LegacyPlug
    end
    """
  end

  defp required_phoenix_alias_router_ex(:get) do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router

      require Phoenix.Router, as: Routes
      Routes.get "/mcp", SampleWeb.PageController, :index
    end
    """
  end

  defp required_phoenix_alias_router_ex(:forward) do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router

      require Phoenix.Router, as: Routes
      Routes.forward "/mcp/admin", SampleWeb.AdminPlug
    end
    """
  end

  defp explicitly_aliased_router_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router

      alias AttestoMCP.Server.Plug, as: ProtocolPlug
      alias Sample.MCP, as: Server
      alias Sample.MCP.MetadataPlug, as: MetadataPlug

      forward "/.well-known/oauth-protected-resource/mcp", MetadataPlug,
        server: Server,
        path: "/mcp",
        auth: [
          config: &Server.attesto_config/0,
          resource: "/mcp",
          base_url: "https://mcp.example.com"
        ]

      forward "/mcp", ProtocolPlug,
        server: Server,
        path: "/mcp",
        auth: [
          config: &Server.attesto_config/0,
          resource: "/mcp",
          base_url: "https://mcp.example.com"
        ]
    end
    """
  end

  defp conflicting_module_alias_router_ex do
    """
    defmodule SampleWeb.Router do
      alias SampleWeb.Decoy.AttestoMCP
      alias SampleWeb.Decoy.Sample

      use SampleWeb, :router
    end
    """
  end

  defp scoped_prefix_collision_router_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router

      scope "/api" do
        forward "/mcp", SampleWeb.OtherPlug
      end
    end
    """
  end

  defp nested_alias_router_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router

      alias AttestoMCP.Server.Plug, as: ProtocolPlug
      alias Sample.MCP, as: Server
      alias Sample.MCP.MetadataPlug, as: MetadataPlug

      forward "/.well-known/oauth-protected-resource/mcp", MetadataPlug,
        server: Server,
        path: "/mcp",
        auth: [
          config: &Server.attesto_config/0,
          resource: "/mcp",
          base_url: "https://mcp.example.com"
        ]

      forward "/mcp", ProtocolPlug,
        server: Server,
        path: "/mcp",
        auth: [
          config: &Server.attesto_config/0,
          resource: "/mcp",
          base_url: "https://mcp.example.com"
        ]

      scope "/admin" do
        alias SampleWeb.AdminPlug, as: ProtocolPlug
        alias SampleWeb.AdminServer, as: Server
        alias SampleWeb.AdminMetadataPlug, as: MetadataPlug
      end
    end
    """
  end

  defp multiple_callback_server_ex do
    """
    defmodule Sample.MCP do
      def __attesto_mcp_server_installer__, do: :v1

      def attesto_config, do: Sample.Attesto.config()
      def attesto_config, do: Sample.OtherAttesto.config()
    end
    """
  end

  defp guarded_callback_server_ex do
    """
    defmodule Sample.MCP do
      def __attesto_mcp_server_installer__, do: :v1

      def attesto_config() when 1 == 2, do: Sample.Attesto.config()
      def attesto_config, do: Sample.OtherAttesto.config()
    end
    """
  end

  defp qualified_kernel_callback_server_ex(:before) do
    """
    defmodule Sample.MCP do
      def __attesto_mcp_server_installer__, do: :v1

      Elixir.Kernel.defdelegate(attesto_config(), to: Sample.OtherAttesto)
      def attesto_config, do: Sample.Attesto.config()
    end
    """
  end

  defp qualified_kernel_callback_server_ex(:after) do
    """
    defmodule Sample.MCP do
      def __attesto_mcp_server_installer__, do: :v1

      def attesto_config, do: Sample.Attesto.config()
      Kernel.def(attesto_config(), do: Sample.OtherAttesto.config())
    end
    """
  end

  defp aliased_kernel_callback_server_ex do
    """
    defmodule Sample.MCP do
      def __attesto_mcp_server_installer__, do: :v1

      alias Kernel, as: Definitions
      Definitions.def(attesto_config(), do: Sample.OtherAttesto.config())
      alias Sample.Definitions, as: Definitions
      def attesto_config, do: Sample.Attesto.config()
    end
    """
  end

  defp qualified_kernel_callback_kind_server_ex(kind)
       when kind in [:defp, :defmacro, :defmacrop, :defguard, :defguardp] do
    """
    defmodule Sample.MCP do
      def __attesto_mcp_server_installer__, do: :v1

      Kernel.#{kind}(attesto_config(), do: Sample.OtherAttesto.config())
      def attesto_config, do: Sample.Attesto.config()
    end
    """
  end

  defp conditional_callback_server_ex do
    """
    defmodule Sample.MCP do
      def __attesto_mcp_server_installer__, do: :v1

      if true do
        def attesto_config, do: Sample.OtherAttesto.config()
      end

      def attesto_config, do: Sample.Attesto.config()
    end
    """
  end

  defp module_relative_alias_router_ex do
    """
    defmodule SampleWeb.Router do
      alias __MODULE__.Admin, as: AdminRoutes

      use SampleWeb, :router
    end
    """
  end

  defp qualified_forward_router_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router

      Phoenix.Router.forward "/mcp", SampleWeb.OtherPlug
    end
    """
  end

  defp empty_router_options_forward_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router

      forward "/.well-known/oauth-protected-resource/mcp", Elixir.Sample.MCP.MetadataPlug,
        server: Elixir.Sample.MCP,
        path: "/mcp",
        auth: [
          config: &Elixir.Sample.MCP.attesto_config/0,
          resource: "/mcp",
          base_url: "https://mcp.example.com"
        ]

      forward "/mcp", Elixir.AttestoMCP.Server.Plug,
        [
          server: Elixir.Sample.MCP,
          path: "/mcp",
          auth: [
            config: &Elixir.Sample.MCP.attesto_config/0,
            resource: "/mcp",
            base_url: "https://mcp.example.com"
          ]
        ],
        []
    end
    """
  end

  defp chained_grouped_alias_router_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router

      alias Sample.MCP
      alias MCP.MetadataPlug, as: MetadataPlug
      alias AttestoMCP.Server.{Plug, API}

      forward "/.well-known/oauth-protected-resource/mcp", MetadataPlug,
        server: MCP,
        path: "/mcp",
        auth: [
          config: &MCP.attesto_config/0,
          resource: "/mcp",
          base_url: "https://mcp.example.com"
        ]

      forward "/mcp", Plug,
        server: MCP,
        path: "/mcp",
        auth: [
          config: &MCP.attesto_config/0,
          resource: "/mcp",
          base_url: "https://mcp.example.com"
        ]
    end
    """
  end

  defp forward_before_alias_router_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router

      forward "/.well-known/oauth-protected-resource/mcp", Elixir.Sample.MCP.MetadataPlug,
        server: Elixir.Sample.MCP,
        path: "/mcp",
        auth: [
          config: &Elixir.Sample.MCP.attesto_config/0,
          resource: "/mcp",
          base_url: "https://mcp.example.com"
        ]

      forward "/mcp", ProtocolPlug,
        server: Elixir.Sample.MCP,
        path: "/mcp",
        auth: [
          config: &Elixir.Sample.MCP.attesto_config/0,
          resource: "/mcp",
          base_url: "https://mcp.example.com"
        ]

      alias AttestoMCP.Server.Plug, as: ProtocolPlug
    end
    """
  end

  defp rebound_router_alias_in_scope_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router

      alias Phoenix.Router, as: Routes

      scope "/api" do
        Routes.forward "/mcp", SampleWeb.OtherPlug
      end

      alias SampleWeb.OtherRoutes, as: Routes
    end
    """
  end

  defp rebound_plug_alias_router_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router

      alias AttestoMCP.Server.Plug, as: ProtocolPlug
      forward "/other", ProtocolPlug
      alias SampleWeb.OtherPlug, as: ProtocolPlug
    end
    """
  end

  defp unrelated_scoped_forward_router_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router

      scope "/api" do
        forward "/mcp", SampleWeb.OtherPlug
      end
    end
    """
  end

  defp exact_qualified_forwards_router_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router

      Phoenix.Router.forward "/.well-known/oauth-protected-resource/mcp",
                             Elixir.Sample.MCP.MetadataPlug,
        server: Elixir.Sample.MCP,
        path: "/mcp",
        auth: [
          config: &Elixir.Sample.MCP.attesto_config/0,
          resource: "/mcp",
          base_url: "https://mcp.example.com"
        ]

      Phoenix.Router.forward "/mcp", Elixir.AttestoMCP.Server.Plug,
        server: Elixir.Sample.MCP,
        path: "/mcp",
        auth: [
          config: &Elixir.Sample.MCP.attesto_config/0,
          resource: "/mcp",
          base_url: "https://mcp.example.com"
        ]
    end
    """
  end

  defp grouped_router_alias_with_options_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router

      alias Phoenix.{Router, Socket}, warn: false

      scope "/api" do
        Router.forward "/mcp", SampleWeb.OtherPlug
      end
    end
    """
  end

  defp dynamic_plug_router_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router

      @protocol_plug AttestoMCP.Server.Plug
      forward "/other", @protocol_plug
    end
    """
  end

  defp shadowed_scope_router_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router

      import Phoenix.Router, except: [scope: 2]
      import SampleWeb.ScopeDSL, only: [scope: 2]

      scope "/api" do
        Phoenix.Router.forward "/mcp", SampleWeb.OtherPlug
      end
    end
    """
  end

  defp shadowed_forward_router_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router

      import Phoenix.Router, except: [forward: 3]
      import SampleWeb.ForwardDSL, only: [forward: 3]

      forward "/.well-known/oauth-protected-resource/mcp", Elixir.Sample.MCP.MetadataPlug,
        server: Elixir.Sample.MCP

      forward "/mcp", Elixir.AttestoMCP.Server.Plug,
        server: Elixir.Sample.MCP
    end
    """
  end

  defp opaque_use_router_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router
      use SampleWeb.RouteDSL

      forward "/other", SampleWeb.OtherPlug
    end
    """
  end

  defp route_injector_use_router_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router
      use SampleWeb.RouteInjector
    end
    """
  end

  defp approved_router_use_before_primary_ex do
    """
    defmodule SampleWeb.Router do
      use AttestoPhoenix.Router
      use SampleWeb, :router
    end
    """
  end

  defp approved_router_use_with_options_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router
      use AttestoPhoenix.Router, otp_app: :sample
    end
    """
  end

  defp opaque_macro_before_router_use_ex do
    """
    defmodule SampleWeb.Router do
      require SampleWeb.ImportInjector
      SampleWeb.ImportInjector.inject()
      use Phoenix.Router
    end
    """
  end

  defp fake_router_use_before_real_router_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb.FakeRouter, :router

      forward "/mcp", Elixir.AttestoMCP.Server.Plug,
        server: Elixir.Sample.MCP,
        path: "/mcp",
        auth: [
          config: &Elixir.Sample.MCP.attesto_config/0,
          resource: "/mcp",
          base_url: "https://mcp.example.com"
        ]

      use SampleWeb, :router
    end
    """
  end

  defp irrelevant_import_router_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router
      import SampleWeb.RouteNames, only: [route_name: 0]
    end
    """
  end

  defp pre_router_shadow_import_router_ex do
    """
    defmodule SampleWeb.Router do
      import SampleWeb.ForwardDSL, only: [forward: 3]
      use SampleWeb, :router
    end
    """
  end

  defp local_forward_macro_router_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router

      defmacro forward(_path, _plug, _options), do: :ok
    end
    """
  end

  defp required_route_macro_after_router_use_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router

      require SampleWeb.RouteInjector
      SampleWeb.RouteInjector.routes()
    end
    """
  end

  defp aliased_required_route_macro_after_router_use_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router

      require SampleWeb.RouteInjector, as: Injector
      Injector.routes()
    end
    """
  end

  defp exact_lookalike_router_ex do
    """
    defmodule SampleWeb.Router do
      import SampleWeb.FakeRouter

      forward "/.well-known/oauth-protected-resource/mcp", Elixir.Sample.MCP.MetadataPlug,
        server: Elixir.Sample.MCP,
        path: "/mcp",
        auth: [
          config: &Elixir.Sample.MCP.attesto_config/0,
          resource: "/mcp",
          base_url: "https://mcp.example.com"
        ]

      forward "/mcp", Elixir.AttestoMCP.Server.Plug,
        server: Elixir.Sample.MCP,
        path: "/mcp",
        auth: [
          config: &Elixir.Sample.MCP.attesto_config/0,
          resource: "/mcp",
          base_url: "https://mcp.example.com"
        ]
    end
    """
  end

  defp callback_before_alias_server_ex do
    """
    defmodule Sample.MCP do
      def __attesto_mcp_server_installer__, do: :v1
      def attesto_config, do: Verification.config()

      alias Sample.Attesto, as: Verification
    end
    """
  end

  defp approved_authorization_router_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router

      scope "/api", SampleWeb do
      end

      use AttestoPhoenix.Router

      scope "/" do
        attesto_routes Sample.Auth
      end
    end
    """
  end

  defp router_spoof_ex(module_name) do
    """
    defmodule #{module_name}.Router do
      defmacro __using__(_options) do
        quote do
          def spoofed?, do: true
        end
      end
    end
    """
  end

  defp outer_primary_router_alias_spoof_ex(router_name, spoof_name) do
    """
    alias #{spoof_name}, as: Phoenix

    defmodule #{router_name} do
      use Phoenix.Router
    end
    """
  end

  defp outer_authorization_router_alias_spoof_ex(router_name, spoof_name) do
    """
    alias #{spoof_name}, as: AttestoPhoenix

    defmodule #{router_name} do
      use Phoenix.Router
      use AttestoPhoenix.Router
    end
    """
  end

  defp nested_absolute_router_ex do
    """
    defmodule SampleWeb.Wrapper do
      defmodule Elixir.SampleWeb.Router do
        use Phoenix.Router
      end
    end
    """
  end

  defp nested_absolute_server_ex do
    """
    defmodule Sample.Wrapper do
      defmodule Elixir.Sample.MCP do
        def __attesto_mcp_server_installer__, do: :v1
        def attesto_config, do: Sample.Attesto.config()
      end
    end
    """
  end

  defp nested_marker_server_ex do
    invalid_marker_server_ex("""
    defmodule Ownership do
      def __attesto_mcp_server_installer__, do: :v1
    end
    """)
  end

  defp guarded_marker_server_ex do
    invalid_marker_server_ex("def __attesto_mcp_server_installer__() when 1 == 1, do: :v1")
  end

  defp private_marker_server_ex do
    invalid_marker_server_ex("defp __attesto_mcp_server_installer__, do: :v1")
  end

  defp wrong_marker_server_ex do
    invalid_marker_server_ex("def __attesto_mcp_server_installer__, do: :v2")
  end

  defp multiple_marker_server_ex do
    invalid_marker_server_ex("""
    def __attesto_mcp_server_installer__, do: :v1
    def __attesto_mcp_server_installer__, do: :v1
    """)
  end

  defp qualified_kernel_marker_server_ex do
    invalid_marker_server_ex("""
    Kernel.def __attesto_mcp_server_installer__, do: :v1
    def __attesto_mcp_server_installer__, do: :v1
    """)
  end

  defp conditional_marker_server_ex do
    invalid_marker_server_ex("""
    if true do
      def __attesto_mcp_server_installer__, do: :v1
    end

    def __attesto_mcp_server_installer__, do: :v1
    """)
  end

  defp opaque_macro_server_ex do
    """
    defmodule Sample.MCP do
      def __attesto_mcp_server_installer__, do: :v1
      Sample.HiddenDefinitions.inject()
      def attesto_config, do: Sample.Attesto.config()
    end
    """
  end

  defp before_compile_server_ex do
    """
    defmodule Sample.MCP do
      @before_compile Sample.HiddenDefinitions
      def __attesto_mcp_server_installer__, do: :v1
      def attesto_config, do: Sample.Attesto.config()
    end
    """
  end

  defp dynamic_attribute_server_ex do
    """
    defmodule Sample.MCP do
      def __attesto_mcp_server_installer__, do: :v1

      @generated (
                   for name <- [:attesto_config] do
                     def unquote(name)(), do: Sample.OtherAttesto.config()
                   end
                 )

      def attesto_config, do: Sample.Attesto.config()
    end
    """
  end

  defp attribute_definition_tunnel_server_ex(module_name, expected_body) do
    """
    defmodule #{module_name} do
      def __attesto_mcp_server_installer__, do: :v1

      @doc (
             for name <- [:attesto_config] do
               def unquote(name)(), do: :hidden
             end

             "documented"
           )

      def attesto_config, do: #{expected_body}
    end
    """
  end

  defp nested_module_definition_tunnel_server_ex(module_name, expected_body) do
    """
    defmodule #{module_name} do
      def __attesto_mcp_server_installer__, do: :v1

      defmodule Injection do
        Module.eval_quoted(
          #{module_name},
          quote do
            def attesto_config, do: :hidden
          end
        )
      end

      def attesto_config, do: #{expected_body}
    end
    """
  end

  defp macro_injector_ex(module_name) do
    """
    defmodule #{module_name} do
      defmacro inject do
        Module.eval_quoted(
          __CALLER__.module,
          quote do
            def attesto_config, do: :hidden
          end
        )

        quote do: :ok
      end
    end
    """
  end

  defp macro_definition_tunnel_server_ex(module_name, injector_name, expected_body) do
    """
    defmodule #{module_name} do
      require #{injector_name}

      def __attesto_mcp_server_installer__, do: :v1
      def helper, do: #{injector_name}.inject()
      def attesto_config, do: #{expected_body}
    end
    """
  end

  defp outer_import_definition_tunnel_server_ex(module_name, injector_name, expected_body) do
    """
    import #{injector_name}

    defmodule #{module_name} do
      def __attesto_mcp_server_installer__, do: :v1
      def helper, do: inject()
      def attesto_config, do: #{expected_body}
    end
    """
  end

  defp after_verify_callback_ex(module_name, registration) do
    """
    defmodule #{module_name} do
      def replace(module) do
        receiver = Process.whereis(#{inspect(registration)})

        spawn(fn ->
          Module.create(
            module,
            quote do
              def attesto_config, do: :hidden
            end,
            Macro.Env.location(__ENV__)
          )

          send(receiver, {:after_verify_replaced, module})
        end)

        :ok
      end
    end
    """
  end

  defp after_verify_tunnel_server_ex(module_name, verifier_name, expected_body) do
    """
    defmodule #{module_name} do
      @after_verify {#{verifier_name}, :replace}

      def __attesto_mcp_server_installer__, do: :v1
      def attesto_config, do: #{expected_body}
    end
    """
  end

  defp invalid_marker_server_ex(marker) do
    """
    defmodule Sample.MCP do
      #{marker}

      def attesto_config, do: Sample.Attesto.config()
    end
    """
  end
end
