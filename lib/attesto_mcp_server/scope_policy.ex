defmodule AttestoMCP.Server.ScopePolicy do
  @moduledoc false

  @visible_definition_methods [
    "tools/list",
    "resources/list",
    "resources/templates/list"
  ]
  @selected_definition_methods ["tools/call", "resources/read"]
  @definition_modes [:visible_definitions, :selected_definition]

  @doc false
  def validate!(nil), do: :ok

  def validate!(policy) when is_map(policy) do
    valid? =
      Enum.all?(policy, fn
        {method, :visible_definitions} -> method in @visible_definition_methods
        {method, :selected_definition} -> method in @selected_definition_methods
        _ -> false
      end)

    if valid?,
      do: :ok,
      else:
        raise(
          ArgumentError,
          ":scope_policy must map supported string methods to :visible_definitions or :selected_definition"
        )
  end

  def validate!(_policy), do: raise(ArgumentError, ":scope_policy must be a map")

  @doc false
  def validate_overlap!(scope_map, policy) when is_map(scope_map) and is_map(policy) do
    overlap =
      scope_map
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.intersection(MapSet.new(Map.keys(policy)))

    if MapSet.size(overlap) > 0 do
      raise ArgumentError,
            ":scope_policy cannot overlap :scope_map; choose one policy for each method"
    end

    :ok
  end

  def validate_overlap!(_scope_map, _policy), do: :ok

  @doc false
  def mode(%{method: method}, policy) when is_binary(method) and is_map(policy),
    do: Map.get(policy, method)

  def mode(_request, _policy), do: nil

  @doc false
  def definition_mode?(mode), do: mode in @definition_modes

  @doc false
  def normalize_scopes(scopes) when is_list(scopes) do
    valid? =
      length(scopes) <= 128 and
        Enum.all?(scopes, &(is_binary(&1) and byte_size(&1) in 1..256)) and
        Enum.reduce(scopes, 0, &(byte_size(&1) + &2)) <= 8_192

    if valid?, do: {:ok, scopes |> Enum.uniq() |> Enum.map(&:binary.copy/1)}, else: :error
  end

  def normalize_scopes(_scopes), do: :error

  @doc false
  def scope_sets_grant?(scope_sets, granted)
      when is_list(scope_sets) and scope_sets != [] and is_list(granted),
      do: Enum.any?(scope_sets, &scopes_grant?(&1, granted))

  def scope_sets_grant?(_scope_sets, _granted), do: false

  @doc false
  def scopes_grant?([], _granted), do: true

  def scopes_grant?(required, granted) when is_list(required) and is_list(granted) do
    catalog = Attesto.Scope.new_catalog(required)
    Attesto.Scope.grants_all?(catalog, granted, required)
  rescue
    _ -> false
  end

  def scopes_grant?(_required, _granted), do: false
end
