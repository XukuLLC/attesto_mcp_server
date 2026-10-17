defmodule AttestoMCP.Server.TestSupport.ServerCase do
  @moduledoc false

  alias AttestoMCP.Server

  def start_server(opts \\ []) do
    child_spec = Supervisor.child_spec({Server, opts}, id: make_ref())
    ExUnit.Callbacks.start_supervised!(child_spec)
  end
end
