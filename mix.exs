defmodule AttestoMCP.Server.MixProject do
  use Mix.Project

  @version "0.13.0"
  @source_url "https://github.com/XukuLLC/attesto_mcp_server"

  def project do
    [
      app: :attesto_mcp_server,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      build_embedded: true,
      deps: deps(),
      description: "Authenticated Attesto-native MCP server with HTTP and stdio transports",
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs(),
      aliases: aliases(),
      dialyzer: [plt_add_apps: [:mix]],
      test_coverage: [
        output: System.get_env("MIX_COVERAGE_OUTPUT", "cover"),
        summary: [threshold: 75]
      ],
      test_ignore_filters: [&String.starts_with?(&1, "test/support/")]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {AttestoMCP.Server.Application, []}]
  end

  defp deps do
    [
      attesto_mcp_dep(),
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.2"},
      {:igniter, "~> 0.6", optional: true, runtime: false},
      {:bandit, "~> 1.6", only: [:dev, :test], runtime: false},
      {:phoenix, "~> 1.7.0", only: :test, runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false}
    ]
  end

  # Opt in explicitly while co-developing the coordinated Attesto release
  # train. Package and publish tasks always resolve the Hex range, even if an
  # inherited shell environment still carries the development opt-in.
  defp attesto_mcp_dep do
    local_path =
      System.get_env("ATTESTO_MCP_SOURCE_PATH")
      |> case do
        path when is_binary(path) and path != "" -> Path.expand(path, __DIR__)
        _ -> nil
      end

    if release_task?() do
      hex_attesto_mcp_dep()
    else
      if System.get_env("ATTESTO_MCP_PATH") in ~w(1 true) do
        cond do
          source_checkout?(__DIR__) and source_checkout?(local_path) ->
            {:attesto_mcp, path: local_path, override: true}

          source_checkout?(__DIR__) ->
            Mix.raise("ATTESTO_MCP_PATH requires an explicit AttestoMCP source checkout")

          true ->
            hex_attesto_mcp_dep()
        end
      else
        hex_attesto_mcp_dep()
      end
    end
  end

  defp hex_attesto_mcp_dep, do: {:attesto_mcp, ">= 1.3.0 and < 2.0.0"}

  defp source_checkout?(path) when is_binary(path) do
    marker = Path.join(path, ".git")
    File.dir?(marker) or File.regular?(marker)
  end

  defp source_checkout?(_path), do: false

  defp release_task? do
    Enum.any?(System.argv(), &(&1 in ["hex.build", "hex.publish"]))
  end

  defp package do
    [
      name: "attesto_mcp_server",
      licenses: ["Apache-2.0"],
      links: %{
        "Changelog" => "https://hexdocs.pm/attesto_mcp_server/changelog.html",
        "Documentation" => "https://hexdocs.pm/attesto_mcp_server",
        "GitHub" => @source_url
      },
      # Keep generated consumer dependencies/build output and local coverage
      # artifacts out of the archive while retaining the runnable example.
      files:
        ~w(lib config test fixtures examples/bandit.exs examples/stdio.exs examples/conformance_server.exs examples/attesto_mcp_server.livemd scripts examples/consumer/mix.exs examples/consumer/lib examples/consumer/README.md docs .github LICENSE README.md CONFORMANCE.md CHANGELOG.md CONTRIBUTING.md SECURITY.md .formatter.exs mix.exs)
    ]
  end

  defp docs do
    [
      main: "AttestoMCP.Server.API",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        "examples/attesto_mcp_server.livemd",
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "SECURITY.md",
        "CONFORMANCE.md",
        "docs/conformance.md",
        "docs/migration.md",
        "docs/usage.md",
        "docs/sbom.md"
      ]
    ]
  end

  defp aliases do
    [
      "test.all": [
        "format --check-formatted",
        "compile --warnings-as-errors",
        &test_with_coverage/1,
        "dialyzer",
        &build_unpacked/1,
        &audit_hex/1
      ]
    ]
  end

  defp test_with_coverage(_args) do
    run_command!(
      "MIX_ENV=test mix do compile --warnings-as-errors + test --cover --warnings-as-errors",
      "coverage test"
    )
  end

  defp build_unpacked(_args), do: run_command!("mix hex.build --unpack", "package build")
  defp audit_hex(_args), do: run_command!("mix hex.audit", "Hex audit")

  defp run_command!(command, label) do
    case Mix.shell().cmd(command) do
      0 -> :ok
      status -> Mix.raise("#{label} command failed with status #{status}")
    end
  end
end
