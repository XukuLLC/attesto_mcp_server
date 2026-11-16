defmodule OAuthHost.MixProject do
  use Mix.Project

  def project do
    [app: :oauth_host, version: "0.1.0", elixir: "~> 1.18", deps: deps()]
  end

  def application, do: [extra_applications: [:logger, :crypto]]

  defp deps do
    [
      family_dep(:attesto, "ATTESTO_SOURCE_PATH", ">= 2.26.0 and < 3.0.0", override: true),
      family_dep(:attesto_client, "ATTESTO_CLIENT_SOURCE_PATH", ">= 2.23.0 and < 3.0.0"),
      family_dep(:attesto_mcp, "ATTESTO_MCP_SOURCE_PATH", ">= 2.10.0 and < 3.0.0",
        override: true
      ),
      family_dep(:attesto_phoenix, "ATTESTO_PHOENIX_SOURCE_PATH", ">= 4.22.0 and < 5.0.0"),
      {:attesto_mcp_server, path: Path.expand("../..", __DIR__)},
      {:phoenix, ">= 1.7.0 and < 2.0.0"},
      {:bandit, "~> 1.14", override: true, only: :test},
      {:req, "~> 0.5"}
    ]
  end

  defp family_dep(app, variable, requirement, opts \\ []) do
    case System.get_env(variable) do
      path when is_binary(path) and path != "" -> {app, Keyword.put(opts, :path, path)}
      _ -> {app, requirement, opts}
    end
  end
end
