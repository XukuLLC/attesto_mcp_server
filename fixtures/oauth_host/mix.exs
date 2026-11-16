defmodule OAuthHost.MixProject do
  use Mix.Project

  def project do
    [app: :oauth_host, version: "0.1.0", elixir: "~> 1.18", deps: deps()]
  end

  def application, do: [extra_applications: [:logger, :crypto]]

  defp deps do
    [
      family_dep(:attesto, ">= 2.28.0 and < 3.0.0", override: true),
      family_dep(:attesto_client, ">= 2.23.0 and < 3.0.0"),
      family_dep(:attesto_mcp, ">= 2.11.0 and < 3.0.0", override: true),
      family_dep(:attesto_phoenix, ">= 4.23.0 and < 5.0.0"),
      {:attesto_mcp_server, path: Path.expand("../..", __DIR__)},
      {:phoenix, ">= 1.7.0 and < 2.0.0"},
      {:bandit, "~> 1.14", override: true, only: :test},
      {:req, "~> 0.5"}
    ]
  end

  # Hex by default. ATTESTO_SOURCE_PATH, ATTESTO_CLIENT_SOURCE_PATH,
  # ATTESTO_MCP_SOURCE_PATH or ATTESTO_PHOENIX_SOURCE_PATH selects a source
  # checkout for that package, as the coordinated CI jobs do.
  defp family_dep(app, requirement, opts \\ []) do
    case System.get_env(String.upcase("#{app}_source_path")) do
      path when is_binary(path) and path != "" -> {app, Keyword.put(opts, :path, path)}
      _ -> {app, requirement, opts}
    end
  end
end
