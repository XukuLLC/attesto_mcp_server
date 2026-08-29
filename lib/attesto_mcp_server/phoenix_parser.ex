defmodule AttestoMCP.Server.PhoenixParser do
  @moduledoc """
  MCP-route parser bypass for Phoenix endpoints.

  Phoenix endpoints commonly run `Plug.Parsers` before the router. This
  adapter keeps that parser unchanged for every request except the configured
  MCP route, which must reach the MCP Plug with its body still unread so that
  authentication can run first. Matching uses decoded `path_info`, covering
  route-equivalent trailing or repeated slashes that Phoenix also routes to the
  configured forward.
  """

  @behaviour Plug

  @path_pattern ~r/\A\/(?:[A-Za-z0-9._~-]+(?:\/[A-Za-z0-9._~-]+)*)?\z/

  @impl Plug
  @spec init(keyword()) :: map()
  def init(options) when is_list(options) do
    path_entries = Enum.filter(options, &match?({:mcp_path, _value}, &1))

    path =
      case {Keyword.keyword?(options), path_entries} do
        {true, [{:mcp_path, value}]} -> value
        _invalid -> nil
      end

    unless is_binary(path) and byte_size(path) <= 512 and path != "/" and
             Regex.match?(@path_pattern, path) and
             not Enum.any?(String.split(path, "/"), &(&1 in [".", ".."])) do
      raise ArgumentError, "mcp_path must be a non-root static MCP path"
    end

    %{
      mcp_path_info: String.split(path, "/", trim: true),
      parser_options: Plug.Parsers.init(Keyword.delete(options, :mcp_path))
    }
  end

  @impl Plug
  @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def call(%Plug.Conn{path_info: path_info} = conn, %{mcp_path_info: path_info}), do: conn

  def call(conn, %{parser_options: parser_options}),
    do: Plug.Parsers.call(conn, parser_options)
end
