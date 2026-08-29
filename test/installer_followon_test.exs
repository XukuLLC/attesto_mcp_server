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
      assert Igniter.Test.diff(installed) == ""
    end
  end

  defp install(igniter, args), do: Igniter.compose_task(igniter, @task, args)

  defp project(options \\ []) do
    router_source = Keyword.get(options, :router_source, router_source())

    files =
      %{
        "mix.exs" =>
          mix_source(
            Keyword.get(options, :attesto_phoenix?, true),
            Keyword.get(options, :req_source)
          ),
        "lib/sample/application.ex" => application_source(),
        "lib/sample_web/router.ex" => router_source
      }
      |> Map.merge(Keyword.get(options, :extra_files, %{}))

    Igniter.Test.test_project(app_name: :sample, files: files)
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

  defp mix_source(attesto_phoenix?, req_source) do
    attesto = if attesto_phoenix?, do: "{:attesto_phoenix, \"~> 2.0\"},", else: ""
    req = if is_binary(req_source), do: req_source <> ",", else: ""

    """
    defmodule Sample.MixProject do
      use Mix.Project
      def project, do: [app: :sample, version: "0.1.0", deps: deps()]
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

  defp byte_offset(text, pattern) do
    case :binary.match(text, pattern) do
      {offset, _length} -> offset
      :nomatch -> raise "expected #{inspect(pattern)} in #{inspect(text)}"
    end
  end
end
