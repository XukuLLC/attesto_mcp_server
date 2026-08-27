defmodule InstallerHost.MixProject do
  use Mix.Project

  def project do
    [
      app: :installer_host,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {InstallerHost.Application, []}]
  end

  defp deps do
    [
      {:attesto_mcp_server, path: System.fetch_env!("ATTESTO_MCP_SERVER_PATH")},
      {:attesto_phoenix, "~> 2.13"},
      {:igniter, "== 0.6.0", override: true},
      {:phoenix, "~> 1.7.0"}
    ]
  end
end
