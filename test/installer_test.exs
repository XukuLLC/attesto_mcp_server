defmodule Mix.Tasks.AttestoMcpServer.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  @task Mix.Tasks.AttestoMcpServer.Install

  test "installs a supervised server, public metadata, and protected MCP routes" do
    installed =
      true
      |> project()
      |> install(["--base-url", "https://mcp.example.com"])

    assert installed.issues == []

    diff = Igniter.Test.diff(installed)

    assert diff =~ "defmodule Sample.MCP do"
    assert diff =~ "def __attesto_mcp_server_installer__, do: :v1"
    assert diff =~ "defmodule MetadataPlug do"
    assert diff =~ "AttestoMCP.Server.Phoenix.attesto_config(:sample)"
    assert diff =~ "Keyword.put_new_lazy(:server_version, &application_version/0)"
    refute diff =~ "server_version: \"0.10.0\""
    assert diff =~ "Sample.MCP"
    assert diff =~ "server_status"

    metadata = ~s(forward("/.well-known/oauth-protected-resource/mcp")
    endpoint = ~s(forward("/mcp")

    assert diff =~ metadata
    assert diff =~ endpoint
    assert diff =~ "Sample.MCP.MetadataPlug"
    assert diff =~ "config: &Sample.MCP.attesto_config/0"
    assert diff =~ ~s(base_url: "https://mcp.example.com")
    assert byte_offset(diff, metadata) < byte_offset(diff, endpoint)
  end

  test "requires and installs an Attesto callback without attesto_phoenix" do
    installed =
      false
      |> project()
      |> install([
        "--base-url",
        "https://mcp.example.com",
        "--attesto-config",
        "Sample.Attesto.config/0"
      ])

    assert installed.issues == []
    assert Igniter.Test.diff(installed) =~ "Sample.Attesto.config()"
  end

  test "refuses to invent authorization configuration" do
    installed =
      false
      |> project()
      |> install(["--base-url", "https://mcp.example.com"])

    assert Enum.any?(installed.issues, &String.contains?(&1, "--attesto-config"))
    assert Igniter.Test.diff(installed) == ""
  end

  test "requires HTTPS unless loopback HTTP is explicitly allowed" do
    refused =
      false
      |> project()
      |> install([
        "--base-url",
        "http://localhost:4000",
        "--attesto-config",
        "Sample.Attesto.config/0"
      ])

    assert Enum.any?(refused.issues, &String.contains?(&1, "--allow-http-loopback"))

    accepted =
      false
      |> project()
      |> install([
        "--base-url",
        "http://127.0.0.1:4000",
        "--allow-http-loopback",
        "--attesto-config",
        "Sample.Attesto.config/0"
      ])

    assert accepted.issues == []
    assert Igniter.Test.diff(accepted) =~ ~s(base_url: "http://127.0.0.1:4000")
  end

  test "canonicalizes valid HTTPS DNS and IPv6 origins" do
    dns =
      false
      |> project()
      |> install([
        "--base-url",
        "HTTPS://MCP.EXAMPLE.COM:443/",
        "--attesto-config",
        "Sample.Attesto.config/0"
      ])

    assert dns.issues == []
    assert Igniter.Test.diff(dns) =~ ~s(base_url: "https://mcp.example.com")

    ipv6 =
      false
      |> project()
      |> install([
        "--base-url",
        "https://[2001:db8::1]:8443",
        "--attesto-config",
        "Sample.Attesto.config/0"
      ])

    assert ipv6.issues == []
    assert Igniter.Test.diff(ipv6) =~ ~s(base_url: "https://[2001:db8::1]:8443")
  end

  test "rejects unsafe route and origin inputs before editing" do
    for args <- [
          [
            "--base-url",
            "https://mcp.example.com/path",
            "--attesto-config",
            "Sample.Attesto.config/0"
          ],
          [
            "--base-url",
            "https://mcp.example.com",
            "--mcp-path",
            "/mcp/../admin",
            "--attesto-config",
            "Sample.Attesto.config/0"
          ],
          [
            "--base-url",
            "https://mcp.example.com",
            "--mcp-path",
            "/",
            "--attesto-config",
            "Sample.Attesto.config/0"
          ],
          [
            "--base-url",
            "https://mcp.example.com:bad",
            "--attesto-config",
            "Sample.Attesto.config/0"
          ],
          [
            "--base-url",
            "https://mcp.example.com:99999",
            "--attesto-config",
            "Sample.Attesto.config/0"
          ],
          [
            "--base-url",
            "https://mcp.example.com\\evil",
            "--attesto-config",
            "Sample.Attesto.config/0"
          ],
          [
            "--base-url",
            "https://user@mcp.example.com",
            "--attesto-config",
            "Sample.Attesto.config/0"
          ]
        ] do
      installed = false |> project() |> install(args)

      refute installed.issues == []
      assert Igniter.Test.diff(installed) == ""
    end
  end

  test "second installation is idempotent" do
    installed =
      true
      |> project()
      |> install(["--base-url", "https://mcp.example.com"])
      |> apply_igniter!()
      |> install(["--base-url", "https://mcp.example.com"])

    assert installed.issues == []
    assert_unchanged(installed)
  end

  test "supports an explicit router and warns when no router exists" do
    explicit =
      true
      |> project()
      |> install([
        "--base-url",
        "https://mcp.example.com",
        "--router",
        "SampleWeb.Router"
      ])

    assert explicit.issues == []
    assert Igniter.Test.diff(explicit) =~ ~s(forward("/mcp")

    no_router =
      true
      |> project(router?: false)
      |> install(["--base-url", "https://mcp.example.com"])

    assert no_router.issues == []
    assert Enum.any?(no_router.warnings, &String.contains?(&1, "Add these forwards manually"))
    assert Enum.any?(no_router.warnings, &String.contains?(&1, "AttestoMCP.Server.Plug"))
    assert Enum.any?(no_router.warnings, &String.contains?(&1, "Sample.MCP.MetadataPlug"))
  end

  test "refuses ambiguous router selection before editing" do
    project =
      true
      |> project()
      |> Igniter.create_new_file("lib/sample_web/admin_router.ex", admin_router_ex())
      |> apply_igniter!()

    installed = install(project, ["--base-url", "https://mcp.example.com"])

    assert Enum.any?(installed.issues, &String.contains?(&1, "multiple Phoenix routers"))
    assert Enum.any?(installed.issues, &String.contains?(&1, "--router"))
    assert Igniter.Test.diff(installed) == ""
  end

  test "an unknown explicit router cannot leave partial edits" do
    installed =
      true
      |> project()
      |> install([
        "--base-url",
        "https://mcp.example.com",
        "--router",
        "SampleWeb.MissingRouter"
      ])

    assert Enum.any?(installed.issues, &String.contains?(&1, "router module"))
    assert Igniter.Test.diff(installed) == ""
  end

  test "does not overwrite an application-owned module collision" do
    project =
      true
      |> project()
      |> Igniter.create_new_file(
        "lib/sample/mcp.ex",
        "defmodule Sample.MCP do\n  def application_owned, do: true\nend\n"
      )
      |> apply_igniter!()

    installed = install(project, ["--base-url", "https://mcp.example.com"])

    assert Enum.any?(installed.issues, &String.contains?(&1, "not installer-managed"))
    assert Igniter.Test.diff(installed) == ""
  end

  test "does not override an existing forward owned by another Plug" do
    installed =
      true
      |> project(router_source: conflicting_router_ex())
      |> install(["--base-url", "https://mcp.example.com"])

    assert Enum.any?(installed.issues, &String.contains?(&1, "different forwarding options"))
    assert Igniter.Test.diff(installed) == ""
  end

  test "refuses a dynamic forward route before editing" do
    installed =
      true
      |> project(router_source: dynamic_forward_router_ex())
      |> install(["--base-url", "https://mcp.example.com"])

    assert Enum.any?(installed.issues, &String.contains?(&1, "dynamic forward route"))
    assert Igniter.Test.diff(installed) == ""
  end

  test "refuses the Phoenix 1.7 protocol plug at another path" do
    installed =
      true
      |> project(router_source: other_path_attesto_router_ex())
      |> install(["--base-url", "https://mcp.example.com"])

    assert Enum.any?(installed.issues, &String.contains?(&1, "reuses an MCP plug"))
    assert Igniter.Test.diff(installed) == ""
  end

  test "finds a conflicting forward nested in a Phoenix scope" do
    installed =
      true
      |> project(router_source: nested_conflicting_router_ex())
      |> install(["--base-url", "https://mcp.example.com"])

    assert Enum.any?(installed.issues, &String.contains?(&1, "different forwarding options"))
    assert Igniter.Test.diff(installed) == ""
  end

  test "does not accept an exact forward nested inside a scope" do
    installed =
      true
      |> project(router_source: nested_exact_router_ex())
      |> install(["--base-url", "https://mcp.example.com"])

    assert Enum.any?(installed.issues, &String.contains?(&1, "different forwarding options"))
    assert Igniter.Test.diff(installed) == ""
  end

  test "recognizes equivalent forwards that use router aliases" do
    installed =
      true
      |> project(router_source: aliased_installed_router_ex())
      |> install(["--base-url", "https://mcp.example.com"])

    assert installed.issues == []

    rerun =
      installed
      |> apply_igniter!()
      |> install(["--base-url", "https://mcp.example.com"])

    assert rerun.issues == []
    assert_unchanged(rerun)
  end

  test "does not accept an existing Attesto forward with different options" do
    installed =
      true
      |> project(router_source: mismatched_attesto_router_ex())
      |> install(["--base-url", "https://mcp.example.com"])

    assert Enum.any?(installed.issues, &String.contains?(&1, "different forwarding options"))
    assert Igniter.Test.diff(installed) == ""
  end

  test "an explicit non-Phoenix module cannot leave partial edits" do
    installed =
      true
      |> project(router_source: plain_module_ex())
      |> install([
        "--base-url",
        "https://mcp.example.com",
        "--router",
        "SampleWeb.Router"
      ])

    assert Enum.any?(installed.issues, &String.contains?(&1, "not a recognized Phoenix router"))
    assert Igniter.Test.diff(installed) == ""
  end

  test "generated distinct metadata and MCP plugs compile on Phoenix 1.7" do
    suffix = System.unique_integer([:positive])
    root = "InstallerPhoenixCompile#{suffix}"

    source = """
    defmodule #{root}.Server do
      def attesto_config, do: :configured

      defmodule MetadataPlug do
        @behaviour Plug
        @impl Plug
        defdelegate init(options), to: AttestoMCP.Server.Plug
        @impl Plug
        defdelegate call(conn, options), to: AttestoMCP.Server.Plug
      end
    end

    defmodule #{root}.Router do
      use Phoenix.Router

      forward "/.well-known/oauth-protected-resource/mcp", #{root}.Server.MetadataPlug,
        server: #{root}.Server,
        path: "/mcp",
        auth: [
          config: &#{root}.Server.attesto_config/0,
          resource: "/mcp",
          base_url: "https://mcp.example.com"
        ]

      forward "/mcp", AttestoMCP.Server.Plug,
        server: #{root}.Server,
        path: "/mcp",
        auth: [
          config: &#{root}.Server.attesto_config/0,
          resource: "/mcp",
          base_url: "https://mcp.example.com"
        ]
    end
    """

    compiled = Code.compile_string(source)

    assert Enum.any?(compiled, fn {module, _bytecode} ->
             module == Module.concat([root, "Router"])
           end)
  end

  defp install(igniter, args), do: Igniter.compose_task(igniter, @task, args)

  defp project(attesto_phoenix?, options \\ []) do
    router_source =
      if Keyword.get(options, :router?, true),
        do: Keyword.get(options, :router_source, router_ex())

    files =
      %{
        "mix.exs" => mix_exs(attesto_phoenix?),
        "lib/sample/application.ex" => application_ex()
      }
      |> maybe_put_router(router_source)

    Igniter.Test.test_project(app_name: :sample, files: files)
  end

  defp maybe_put_router(files, source) when is_binary(source),
    do: Map.put(files, "lib/sample_web/router.ex", source)

  defp maybe_put_router(files, nil), do: files

  defp mix_exs(attesto_phoenix?) do
    phoenix_dependency =
      if attesto_phoenix?,
        do: ~s({:attesto_phoenix, "~> 2.0"}),
        else: ""

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
        [
          {:attesto_mcp_server, "~> 0.10"},
          #{phoenix_dependency}
        ]
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
        children = []
        Supervisor.start_link(children, strategy: :one_for_one, name: Sample.Supervisor)
      end
    end
    """
  end

  defp router_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router

      pipeline :browser do
        plug :fetch_session
        plug :protect_from_forgery
      end

      scope "/", SampleWeb do
        pipe_through :browser
      end
    end
    """
  end

  defp conflicting_router_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router

      forward "/mcp", SampleWeb.OtherPlug
    end
    """
  end

  defp dynamic_forward_router_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router

      @dynamic_path "/other"
      forward @dynamic_path, SampleWeb.OtherPlug
    end
    """
  end

  defp other_path_attesto_router_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router

      forward "/other", AttestoMCP.Server.Plug,
        server: Sample.OtherMCP,
        path: "/other",
        auth: [
          config: &Sample.OtherMCP.attesto_config/0,
          resource: "/other",
          base_url: "https://mcp.example.com"
        ]
    end
    """
  end

  defp nested_conflicting_router_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router

      scope "/" do
        forward "/mcp", SampleWeb.OtherPlug
      end
    end
    """
  end

  defp nested_exact_router_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router

      scope "/" do
        forward "/mcp", AttestoMCP.Server.Plug,
          server: Sample.MCP,
          path: "/mcp",
          auth: [
            config: &Sample.MCP.attesto_config/0,
            resource: "/mcp",
            base_url: "https://mcp.example.com"
          ]
      end
    end
    """
  end

  defp aliased_installed_router_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router

      alias AttestoMCP.Server.Plug
      alias Sample.MCP
      alias Sample.MCP.MetadataPlug

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

  defp admin_router_ex do
    """
    defmodule SampleWeb.AdminRouter do
      use SampleWeb, :router
    end
    """
  end

  defp mismatched_attesto_router_ex do
    """
    defmodule SampleWeb.Router do
      use SampleWeb, :router

      forward "/mcp", AttestoMCP.Server.Plug,
        server: Sample.OtherMCP,
        path: "/mcp",
        auth: [
          config: &Sample.OtherMCP.attesto_config/0,
          resource: "/mcp",
          base_url: "https://other.example.com"
        ]
    end
    """
  end

  defp plain_module_ex do
    """
    defmodule SampleWeb.Router do
      def application_owned, do: true
    end
    """
  end

  defp byte_offset(text, pattern) do
    {offset, _length} = :binary.match(text, pattern)
    offset
  end
end
