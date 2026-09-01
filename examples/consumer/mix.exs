defmodule AttestoMCP.ExternalConsumer.MixProject do
  use Mix.Project

  def project do
    [app: :attesto_mcp_external_consumer, version: "0.1.0", elixir: "~> 1.18", deps: deps()]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    base = [{:attesto_mcp_server, path: "../.."}]

    if System.get_env("ATTESTO_MCP_CONSUMER_ECTO") == "1" do
      base ++ [{:ecto_sql, "~> 3.10"}, {:postgrex, ">= 0.22.4 and < 1.0.0"}]
    else
      base
    end
  end
end
