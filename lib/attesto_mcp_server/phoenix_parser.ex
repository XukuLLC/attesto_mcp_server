defmodule AttestoMCP.Server.PhoenixParser do
  @moduledoc """
  MCP-route parser bypass for Phoenix endpoints.

  Phoenix endpoints commonly run `Plug.Parsers` before the router. This
  adapter keeps that parser unchanged for every request except the configured
  MCP routes, which must reach the MCP Plug with their bodies still unread so
  that authentication can run first. `:mcp_path` accepts one path or a
  non-empty list of at most 32 unique paths. Matching uses decoded `path_info`,
  covering route-equivalent trailing or repeated slashes that Phoenix also
  routes to each configured forward.
  """

  @behaviour Plug

  @max_mcp_paths 32
  @path_pattern ~r/\A\/(?:[A-Za-z0-9._~-]+(?:\/[A-Za-z0-9._~-]+)*)?\z/

  @impl Plug
  @spec init(keyword()) :: map()
  def init(options) when is_list(options) do
    paths = mcp_paths!(options)

    %{
      mcp_path_infos:
        paths
        |> Enum.map(&String.split(&1, "/", trim: true))
        |> MapSet.new(),
      parser_options: Plug.Parsers.init(Keyword.delete(options, :mcp_path))
    }
  end

  def init(_options) do
    raise ArgumentError,
          "mcp_path must be a non-root static MCP path or a non-empty list of at most #{@max_mcp_paths} unique paths"
  end

  @impl Plug
  @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def call(%Plug.Conn{path_info: path_info} = conn, %{
        mcp_path_infos: mcp_path_infos,
        parser_options: parser_options
      }) do
    # Phoenix route matching decodes each path segment with URI.decode/1. Match
    # that behavior here so an encoded spelling of the same forward cannot run
    # Plug.Parsers before reaching the authenticated MCP boundary.
    decoded_path_info = Enum.map(path_info, &URI.decode/1)

    if MapSet.member?(mcp_path_infos, decoded_path_info),
      do: conn,
      else: Plug.Parsers.call(conn, parser_options)
  end

  defp mcp_paths!(options) do
    paths =
      with true <- Keyword.keyword?(options),
           [value] <- Keyword.get_values(options, :mcp_path),
           {:ok, paths} <- normalize_mcp_paths(value),
           true <- length(paths) == length(Enum.uniq(paths)),
           true <- Enum.all?(paths, &valid_mcp_path?/1) do
        paths
      else
        _invalid -> nil
      end

    if is_list(paths) do
      paths
    else
      raise ArgumentError,
            "mcp_path must be a non-root static MCP path or a non-empty list of at most #{@max_mcp_paths} unique paths"
    end
  end

  defp normalize_mcp_paths(path) when is_binary(path), do: {:ok, [path]}
  defp normalize_mcp_paths(paths) when is_list(paths), do: collect_mcp_paths(paths, [], 0)
  defp normalize_mcp_paths(_paths), do: :error

  defp collect_mcp_paths([], paths, count) when count > 0,
    do: {:ok, Enum.reverse(paths)}

  defp collect_mcp_paths([path | rest], paths, count)
       when is_binary(path) and count < @max_mcp_paths,
       do: collect_mcp_paths(rest, [path | paths], count + 1)

  defp collect_mcp_paths(_paths, _collected, _count), do: :error

  defp valid_mcp_path?(path) do
    byte_size(path) <= 512 and String.valid?(path) and path != "/" and
      Regex.match?(@path_pattern, path) and
      not Enum.any?(String.split(path, "/"), &(&1 in [".", ".."]))
  end
end
