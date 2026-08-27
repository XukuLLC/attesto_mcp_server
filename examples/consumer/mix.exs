defmodule AttestoMCP.ExternalConsumer.MixProject do
  use Mix.Project

  def project do
    [app: :attesto_mcp_external_consumer, version: "0.8.0", elixir: "~> 1.18", deps: deps()]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [{:attesto_mcp_server, path: "../.."}]
  end
end
