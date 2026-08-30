defmodule AttestoMCP.Server.ScopeMap do
  @moduledoc false

  @max_methods 128
  @max_scopes_per_method 128
  @max_scope_bytes 256
  @max_method_scope_bytes 8_192
  @max_total_scope_bytes 65_536

  @supported_methods MapSet.new([
                       "server/discover",
                       "initialize",
                       "ping",
                       "logging/setLevel",
                       "tools/list",
                       "tools/call",
                       "resources/list",
                       "resources/templates/list",
                       "resources/read",
                       "resources/subscribe",
                       "resources/unsubscribe",
                       "prompts/list",
                       "prompts/get",
                       "completion/complete",
                       "subscriptions/listen"
                     ])

  @doc false
  @spec validate(term()) :: :ok | {:error, :invalid_scope_map}
  def validate(nil), do: :ok

  def validate(scope_map) when is_map(scope_map) and map_size(scope_map) <= @max_methods do
    scope_map
    |> Enum.reduce_while({:ok, 0}, fn {method, scopes}, {:ok, total_bytes} ->
      with true <- supported_method?(method),
           {:ok, method_bytes} <- validate_scopes(scopes),
           next_total <- total_bytes + method_bytes,
           true <- next_total <= @max_total_scope_bytes do
        {:cont, {:ok, next_total}}
      else
        _ -> {:halt, {:error, :invalid_scope_map}}
      end
    end)
    |> case do
      {:ok, _total_bytes} -> :ok
      {:error, :invalid_scope_map} = error -> error
    end
  rescue
    _ -> {:error, :invalid_scope_map}
  catch
    _, _ -> {:error, :invalid_scope_map}
  end

  def validate(_scope_map), do: {:error, :invalid_scope_map}

  @doc false
  @spec validate!(term()) :: :ok
  def validate!(scope_map) do
    case validate(scope_map) do
      :ok ->
        :ok

      {:error, :invalid_scope_map} ->
        raise ArgumentError,
              ":scope_map must map supported MCP methods to bounded unique scope lists"
    end
  end

  @doc false
  @spec supported_methods() :: [String.t()]
  def supported_methods, do: @supported_methods |> MapSet.to_list() |> Enum.sort()

  defp supported_method?(method) when is_binary(method),
    do: MapSet.member?(@supported_methods, method)

  defp supported_method?(_method), do: false

  defp validate_scopes(scopes) when is_list(scopes) do
    with {:ok, scopes, bytes} <- collect_scopes(scopes, 0, 0, %{}, []),
         true <- Attesto.Scope.valid_list?(scopes, allow_empty?: true) do
      {:ok, bytes}
    else
      _ -> {:error, :invalid_scope_map}
    end
  rescue
    _ -> {:error, :invalid_scope_map}
  catch
    _, _ -> {:error, :invalid_scope_map}
  end

  defp validate_scopes(_scopes), do: {:error, :invalid_scope_map}

  defp collect_scopes([], _count, bytes, _seen, scopes),
    do: {:ok, Enum.reverse(scopes), bytes}

  defp collect_scopes([scope | rest], count, bytes, seen, scopes)
       when count < @max_scopes_per_method do
    scope_bytes = if is_binary(scope), do: byte_size(scope), else: 0
    next_bytes = bytes + scope_bytes

    cond do
      not is_binary(scope) or not String.valid?(scope) or
          scope_bytes not in 1..@max_scope_bytes ->
        {:error, :invalid_scope_map}

      String.contains?(scope, ["\u0000", "\r", "\n"]) ->
        {:error, :invalid_scope_map}

      next_bytes > @max_method_scope_bytes ->
        {:error, :invalid_scope_map}

      Map.has_key?(seen, scope) ->
        {:error, :invalid_scope_map}

      true ->
        collect_scopes(
          rest,
          count + 1,
          next_bytes,
          Map.put(seen, scope, true),
          [scope | scopes]
        )
    end
  end

  defp collect_scopes(_scopes, _count, _bytes, _seen, _collected),
    do: {:error, :invalid_scope_map}
end
