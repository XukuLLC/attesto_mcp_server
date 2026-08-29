defmodule AttestoMCP.Server.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      %{
        id: AttestoMCP.Server.SessionCluster,
        start: {:pg, :start_link, [AttestoMCP.Server.SessionCluster]},
        type: :worker
      },
      {DynamicSupervisor, strategy: :one_for_one, name: AttestoMCP.Server.DynamicSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end
end
