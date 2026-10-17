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

  @doc false
  @spec default_scopes(String.t()) :: [String.t()]
  def default_scopes("tools/list"), do: [AttestoMCP.Scopes.tools_read()]
  def default_scopes("tools/call"), do: [AttestoMCP.Scopes.tools_call()]

  def default_scopes(method)
      when method in ["resources/list", "resources/read", "resources/templates/list"],
      do: [AttestoMCP.Scopes.resources_read()]

  def default_scopes(method)
      when method in ["resources/subscribe", "resources/unsubscribe"],
      do: [AttestoMCP.Scopes.resources_read()]

  def default_scopes(method)
      when method in ["prompts/list", "prompts/get", "completion/complete"],
      do: [AttestoMCP.Scopes.prompts_read()]

  def default_scopes(_method), do: []

  @doc false
  @spec required_http_scopes(
          String.t(),
          map(),
          map() | nil,
          [String.t()] | nil,
          [String.t()] | nil
        ) ::
          [String.t()]
  def required_http_scopes(method, params, scope_map, default_scopes, subscription_scopes)

  def required_http_scopes(
        "subscriptions/listen",
        params,
        scope_map,
        default_scopes,
        subscription_scopes
      ) do
    notifications = if is_map(params), do: Map.get(params, "notifications"), else: nil
    explicit = configured_scopes(scope_map, "subscriptions/listen")
    fallback = configured_default(default_scopes)

    category_scopes =
      cond do
        is_list(fallback) and is_list(explicit) -> subscription_category_scopes(notifications)
        is_list(fallback) -> fallback
        true -> subscription_category_scopes(notifications)
      end

    configured = explicit || fallback || []

    Enum.uniq(
      category_scopes ++ configured ++ Enum.filter(List.wrap(subscription_scopes), &is_binary/1)
    )
  end

  def required_http_scopes(
        "completion/complete",
        params,
        scope_map,
        _default_scopes,
        _subscription_scopes
      ) do
    case configured_scopes(scope_map, "completion/complete") do
      scopes when is_list(scopes) ->
        scopes

      nil ->
        case if(is_map(params), do: Map.get(params, "ref"), else: nil) do
          %{"type" => "ref/resource"} -> default_scopes("resources/read")
          _other -> default_scopes("completion/complete")
        end
    end
  end

  def required_http_scopes(method, _params, scope_map, default_scopes, _subscription_scopes) do
    configured_scopes(scope_map, method) || configured_default(default_scopes) ||
      default_scopes(method)
  end

  defp configured_scopes(scope_map, method) when is_map(scope_map) do
    case Map.get(scope_map, method) do
      scopes when is_list(scopes) and scopes != [] -> scopes
      _other -> nil
    end
  end

  defp configured_scopes(_scope_map, _method), do: nil

  defp configured_default(scopes) when is_list(scopes) and scopes != [], do: scopes
  defp configured_default(_scopes), do: nil

  defp subscription_category_scopes(notifications) when is_map(notifications) do
    [
      {"toolsListChanged", :toolsListChanged, AttestoMCP.Scopes.tools_read()},
      {"promptsListChanged", :promptsListChanged, AttestoMCP.Scopes.prompts_read()},
      {"resourcesListChanged", :resourcesListChanged, AttestoMCP.Scopes.resources_read()}
    ]
    |> Enum.reduce([], fn {string_key, atom_key, scope}, scopes ->
      if Map.get(notifications, string_key, Map.get(notifications, atom_key, false)) == true,
        do: [scope | scopes],
        else: scopes
    end)
    |> maybe_add_resource_subscription_scope(notifications)
    |> Enum.reverse()
  end

  defp subscription_category_scopes(_notifications), do: []

  defp maybe_add_resource_subscription_scope(scopes, notifications) do
    subscriptions =
      Map.get(
        notifications,
        "resourceSubscriptions",
        Map.get(notifications, :resourceSubscriptions)
      )

    if is_list(subscriptions) and subscriptions != [],
      do: [AttestoMCP.Scopes.resources_read() | scopes],
      else: scopes
  end

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
