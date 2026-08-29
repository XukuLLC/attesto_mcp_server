defmodule InstallerHostWeb.ParsedBodyProbe do
  @moduledoc false

  def init(action), do: action

  def call(conn, :accept), do: Plug.Conn.send_resp(conn, 204, "")
end
