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
    assert diff =~ ~s({:req, ">= 0.6.1 and < 1.0.0"})
    assert diff =~ "client_id_metadata: [enabled: true]"
    assert diff =~ "native_apps: [loopback_include_localhost: true]"
    assert diff =~ "Keyword.put_new_lazy(:server_version, &application_version/0)"
    refute diff =~ "server_version: \""
    assert diff =~ "Sample.MCP"
    assert diff =~ "server_status"

    metadata = ~s("/.well-known/oauth-protected-resource/mcp")
    endpoint = ~s(Elixir.Phoenix.Router.forward("/mcp")

    assert diff =~ "Elixir.Phoenix.Router.forward"
    assert diff =~ metadata
    assert diff =~ endpoint
    assert diff =~ "Sample.MCP.MetadataPlug"
    assert diff =~ "config: &Elixir.Sample.MCP.attesto_config/0"
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
    diff = Igniter.Test.diff(installed)

    assert diff =~ "Sample.Attesto.config()"
    refute diff =~ "client_id_metadata"
    refute diff =~ "loopback_include_localhost"
    refute diff =~ ~s({:req, ">= 0.6.1 and < 1.0.0"})
  end

  test "accepts callback punctuation only as a terminal suffix" do
    for callback <- ["Sample.Attesto.config?/0", "Sample.Attesto.config!/0"] do
      installed =
        false
        |> project()
        |> install([
          "--base-url",
          "https://mcp.example.com",
          "--attesto-config",
          callback
        ])

      assert installed.issues == []
      assert Igniter.Test.diff(installed) =~ String.replace_suffix(callback, "/0", "()")
    end

    for callback <- [
          "Sample.Attesto.con?fig/0",
          "Sample.Attesto.con!fig/0",
          "Sample.Attesto.config?!/0"
        ] do
      refused =
        false
        |> project()
        |> install([
          "--base-url",
          "https://mcp.example.com",
          "--attesto-config",
          callback
        ])

      assert Enum.any?(refused.issues, &String.contains?(&1, "zero-arity callback"))
      assert Igniter.Test.diff(refused) == ""
    end
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
            "https://mcp.example.com",
            "--mcp-path",
            "/:tenant/mcp",
            "--attesto-config",
            "Sample.Attesto.config/0"
          ],
          [
            "--base-url",
            "https://mcp.example.com",
            "--mcp-path",
            "/mcp/*rest",
            "--attesto-config",
            "Sample.Attesto.config/0"
          ],
          [
            "--base-url",
            "https://mcp.example.com",
            "--mcp-path",
            "/literal\\segment",
            "--attesto-config",
            "Sample.Attesto.config/0"
          ],
          [
            "--base-url",
            "https://mcp.example.com",
            "--mcp-path",
            "/encoded%3Asegment",
            "--attesto-config",
            "Sample.Attesto.config/0"
          ],
          [
            "--base-url",
            "https://mcp.example.com",
            "--mcp-path",
            "/café",
            "--attesto-config",
            "Sample.Attesto.config/0"
          ],
          [
            "--base-url",
            "https://mcp.example.com",
            "--mcp-path",
            "/mcp{unsafe}",
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

  test "preserves existing authorization-server client policy" do
    config_source = """
    import Config

    config :sample, AttestoPhoenix.Config,
      client_id_metadata: [enabled: true, allowed_hosts: ["clients.example"]],
      native_apps: [loopback_include_localhost: false, reject_embedded_user_agents: true]
    """

    installed =
      true
      |> project(config_source: config_source)
      |> install(["--base-url", "https://mcp.example.com"])

    assert installed.issues == []

    content =
      installed
      |> apply_igniter!()
      |> Map.fetch!(:rewrite)
      |> Rewrite.source!("config/config.exs")
      |> Rewrite.Source.get(:content)

    assert content =~ ~s(allowed_hosts: ["clients.example"])
    assert content =~ "loopback_include_localhost: false"
    assert content =~ "reject_embedded_user_agents: true"
  end

  test "adds missing compatibility keys inside existing policy blocks" do
    config_source = """
    import Config

    config :sample, AttestoPhoenix.Config,
      client_id_metadata: [allowed_hosts: ["clients.example"]],
      native_apps: [reject_embedded_user_agents: true]
    """

    installed =
      true
      |> project(config_source: config_source)
      |> install(["--base-url", "https://mcp.example.com"])

    assert installed.issues == []

    content =
      installed
      |> apply_igniter!()
      |> Map.fetch!(:rewrite)
      |> Rewrite.source!("config/config.exs")
      |> Rewrite.Source.get(:content)

    assert content =~
             ~s(client_id_metadata: [allowed_hosts: ["clients.example"], enabled: true])

    assert content =~
             "native_apps: [reject_embedded_user_agents: true, loopback_include_localhost: true]"
  end

  test "intersects compatible dependency requirements and preserves dependency options" do
    installed =
      true
      |> project(
        req_dependency:
          ~s({:req, "~> 0.5", override: true, runtime: true, optional: false, app: true, hex: :req, manager: :mix, env: :prod})
      )
      |> install(["--base-url", "https://mcp.example.com"])

    assert installed.issues == []
    diff = Igniter.Test.diff(installed)

    assert diff =~ ~s|{:req, ">= 0.6.1 and < 1.0.0",|

    for option <- [
          "override: true",
          "runtime: true",
          "optional: false",
          "app: true",
          "hex: :req",
          "manager: :mix",
          "env: :prod"
        ] do
      assert diff =~ option
    end

    assert diff =~
             ~s({:attesto_phoenix, ">= 2.14.0 and < 3.0.0"})

    partial =
      true
      |> project(req_dependency: ~s({:req, ">= 0.6.0 and < 0.8.0"}))
      |> install(["--base-url", "https://mcp.example.com"])

    assert partial.issues == []

    assert Igniter.Test.diff(partial) =~
             ~s({:req, ">= 0.6.1 and < 0.8.0"})

    narrower =
      true
      |> project(req_dependency: ~s({:req, "~> 0.7"}))
      |> install(["--base-url", "https://mcp.example.com"])

    assert narrower.issues == []
    assert Igniter.Test.diff(narrower) =~ ~s({:req, "~> 0.7"})

    redundant =
      true
      |> project(req_dependency: ~s({:req, ">= 0.6.1 and < 1.0.0 and >= 0.7.0"}))
      |> install(["--base-url", "https://mcp.example.com"])

    assert redundant.issues == []

    assert Igniter.Test.diff(redundant) =~
             ~s({:req, ">= 0.7.0 and < 1.0.0"})
  end

  test "rejects incompatible or runtime-restricted authorization dependencies before editing" do
    cases = [
      [req_dependency: ~s({:req, "~> 1.0"})],
      [req_dependency: ~s({:req, "< 0.5.0"})],
      [req_dependency: ~s({:req, "> 0.7.0 and < 0.7.0"})],
      [req_dependency: ~s({:req, "> 0.6.0 and < 0.6.1"})],
      [req_dependency: ~s({:req, "!= 0.7.0"})],
      [req_dependency: ~s({:req, "~> 0.7 or ~> 0.8"})],
      [req_dependency: ~s({:req, "~> 0.7", only: :dev})],
      [req_dependency: ~s({:req, "~> 0.7", runtime: nil})],
      [req_dependency: ~s({:req, "~> 0.7", optional: :yes})],
      [req_dependency: ~s({:req, "~> 0.7", app: false})],
      [req_dependency: ~s({:req, "~> 0.7", compile: false})],
      [req_dependency: ~s({:req, "~> 0.7", compile: "make"})],
      [req_dependency: ~s({:req, "~> 0.7", targets: :host})],
      [req_dependency: ~s({:req, "~> 0.7", path: "../req"})],
      [req_dependency: ~s({:req, "~> 0.7", git: "https://example.com/req.git"})],
      [req_dependency: ~s({:req, "~> 0.7", github: "example/req"})],
      [req_dependency: ~s({:req, "~> 0.7", in_umbrella: true})],
      [req_dependency: ~s({:req, "~> 0.7", repo: "private"})],
      [req_dependency: ~s({:req, "~> 0.7", organization: "example"})],
      [req_dependency: ~s({:req, "~> 0.7", branch: "main"})],
      [req_dependency: ~s({:req, "~> 0.7", tag: "v0.7.0"})],
      [req_dependency: ~s({:req, "~> 0.7", ref: "abc123"})],
      [req_dependency: ~s({:req, "~> 0.7", submodules: true})],
      [req_dependency: ~s({:req, "~> 0.7", sparse: "lib"})],
      [req_dependency: ~s({:req, "~> 0.7", subdir: "package"})],
      [req_dependency: ~s({:req, "~> 0.7", depth: 1})],
      [req_dependency: ~s({:req, "~> 0.7", env: :dev})],
      [req_dependency: ~s({:req, "~> 0.7", system_env: [{"FLAG", "1"}]})],
      [req_dependency: ~s({:req, "~> 0.7", override: :yes})],
      [req_dependency: ~s({:req, "~> 0.7", unknown_option: true})],
      [req_dependency: ~s({:req, "~> 0.7", hex: :different_package})],
      [req_dependency: ~s({:req, "~> 0.7", manager: :rebar3})],
      [req_dependency: ~s({:req, "~> 0.6.1-rc.0"})],
      [req_dependency: ~s({:req, "~> 0.7", [:not_a_keyword_option]})],
      [attesto_phoenix_requirement: "2.13.0"],
      [attesto_phoenix_requirement: "< 2.14.0"]
    ]

    for options <- cases do
      installed =
        true
        |> project(options)
        |> install(["--base-url", "https://mcp.example.com"])

      assert installed.issues != []
      assert Igniter.Test.diff(installed) == ""
    end
  end

  test "does not evaluate dynamic dependency declarations" do
    installed =
      true
      |> project(
        req_dependency: "{:req, (send(self(), :installer_dependency_evaluated); \"~> 0.6\")}"
      )
      |> install(["--base-url", "https://mcp.example.com"])

    assert Enum.any?(installed.issues, &String.contains?(&1, "dynamic"))
    assert Igniter.Test.diff(installed) == ""
    refute_received :installer_dependency_evaluated
  end

  test "rejects hidden and duplicate required dependency declarations before editing" do
    cases = [
      [
        req_dependency: "req_dependency()",
        project_helpers: ~s(defp req_dependency, do: {:req, "~> 1.0"})
      ],
      [
        req_dependency: ~s({:req, "~> 0.7"}),
        additional_dependencies: [~s({:req, "~> 1.0"})]
      ],
      [
        project_helpers: "defp deps when node() == :special@host, do: [{:req, \"~> 1.0\"}]"
      ]
    ]

    for options <- cases do
      installed =
        true
        |> project(options)
        |> install(["--base-url", "https://mcp.example.com"])

      assert installed.issues != []
      assert Igniter.Test.diff(installed) == ""
    end
  end

  test "accepts stable build metadata without broadening an exact requirement" do
    installed =
      true
      |> project(req_dependency: ~s({:req, "0.7.0+private"}))
      |> install(["--base-url", "https://mcp.example.com"])

    assert installed.issues == []

    assert Igniter.Test.diff(installed) =~
             ~s({:req, "0.7.0+private"})
  end

  test "does not confuse an unrelated package named unknown with an unresolved entry" do
    installed =
      true
      |> project(additional_dependencies: [~s({:unknown, "~> 1.0"})])
      |> install(["--base-url", "https://mcp.example.com"])

    assert installed.issues == []
    assert Igniter.Test.diff(installed) =~ ~s({:unknown, "~> 1.0"})
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

    assert Enum.any?(installed.issues, &String.contains?(&1, "scoped forward"))
    assert Igniter.Test.diff(installed) == ""
  end

  test "does not accept an exact forward nested inside a scope" do
    installed =
      true
      |> project(router_source: nested_exact_router_ex())
      |> install(["--base-url", "https://mcp.example.com"])

    assert Enum.any?(installed.issues, &String.contains?(&1, "scoped forward"))
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
        "mix.exs" => mix_exs(attesto_phoenix?, options),
        "lib/sample/application.ex" => application_ex()
      }
      |> maybe_put_router(router_source)
      |> maybe_put_config(Keyword.get(options, :config_source))

    Igniter.Test.test_project(app_name: :sample, files: files)
  end

  defp maybe_put_router(files, source) when is_binary(source),
    do: Map.put(files, "lib/sample_web/router.ex", source)

  defp maybe_put_router(files, nil), do: files

  defp maybe_put_config(files, source) when is_binary(source),
    do: Map.put(files, "config/config.exs", source)

  defp maybe_put_config(files, nil), do: files

  defp mix_exs(attesto_phoenix?, options) do
    phoenix_dependency =
      if attesto_phoenix?,
        do:
          ~s({:attesto_phoenix, #{inspect(Keyword.get(options, :attesto_phoenix_requirement, "~> 2.0"))}}),
        else: ""

    dependencies =
      [
        ~s({:attesto_mcp_server, "~> 0.10"}),
        phoenix_dependency,
        Keyword.get(options, :req_dependency, "")
      ] ++ Keyword.get(options, :additional_dependencies, [])

    dependencies =
      dependencies
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(",\n          ")

    project_helpers = Keyword.get(options, :project_helpers, "")

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
          #{dependencies}
        ]
      end

      #{project_helpers}
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
