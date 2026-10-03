defmodule OAuthHost.MixProject do
  use Mix.Project

  def project do
    [app: :oauth_host, version: "0.1.0", elixir: "~> 1.18", deps: deps()]
  end

  def application, do: [extra_applications: [:logger, :crypto]]

  defp deps do
    [
      {:attesto, path: source("ATTESTO_SOURCE_PATH", "attesto"), override: true},
      {:attesto_client, path: source("ATTESTO_CLIENT_SOURCE_PATH", "attesto_client")},
      {:attesto_mcp, path: source("ATTESTO_MCP_SOURCE_PATH", "attesto_mcp"), override: true},
      {:attesto_phoenix, path: source("ATTESTO_PHOENIX_SOURCE_PATH", "attesto_phoenix")},
      {:attesto_mcp_server, path: Path.expand("../..", __DIR__)},
      {:phoenix, ">= 1.7.0 and < 2.0.0"},
      {:bandit, "~> 1.0", only: :test},
      {:req, "~> 0.5"}
    ]
  end

  defp source(variable, sibling) do
    System.get_env(variable) || Path.expand("../../../#{sibling}", __DIR__)
  end
end
