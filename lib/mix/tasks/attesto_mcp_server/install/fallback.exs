defmodule Mix.Tasks.AttestoMcpServer.Install do
  use Mix.Task

  @shortdoc Mix.Tasks.AttestoMcpServer.Install.Docs.short_doc()
  @moduledoc Mix.Tasks.AttestoMcpServer.Install.Docs.long_doc()

  @impl Mix.Task
  def run(_argv) do
    Mix.raise("""
    The task 'attesto_mcp_server.install' requires Igniter. Add the optional
    development dependency and try again:

        {:igniter, "~> 0.6", only: [:dev, :test], runtime: false}

    Or run `mix igniter.install attesto_mcp_server` from the host project.
    """)
  end
end
