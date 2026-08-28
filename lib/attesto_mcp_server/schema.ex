defmodule AttestoMCP.Server.Schema do
  @moduledoc "Bounded JSON Schema 2020-12 validation without remote reference fetching."

  @max_depth 32
  @max_nodes 500
  @max_json_depth 64
  @max_json_nodes 10_000
  @max_json_bytes 2_000_000
  @dialyzer {:nowarn_function,
             unevaluated_properties: 4,
             evaluated_keys: 4,
             evaluated_keys_local: 4,
             successful_applicator_keys: 4,
             successful_dependent_keys: 4,
             conditional_keys: 4,
             unevaluated_items: 4,
             evaluated_indices: 4,
             evaluated_indices_local: 4,
             successful_array_applicator: 4,
             array_conditional_indices: 4}
  @supported_dialects [
    "https://json-schema.org/draft/2020-12/schema",
    "http://json-schema.org/draft-07/schema#",
    "http://json-schema.org/draft-07/schema",
    "https://json-schema.org/draft-07/schema#",
    "https://json-schema.org/draft-07/schema"
  ]
  @draft7_dialects [
    "http://json-schema.org/draft-07/schema#",
    "http://json-schema.org/draft-07/schema",
    "https://json-schema.org/draft-07/schema#",
    "https://json-schema.org/draft-07/schema"
  ]
  @default_dialect "https://json-schema.org/draft/2020-12/schema"
  # Standard 2020-12 vocabularies are accepted and validated below. Unknown
  # extension annotations are retained without evaluation.
  @unsupported_keywords ["$id", "$vocabulary", "$recursiveRef", "$recursiveAnchor"]
  @types ~w(null boolean object array number integer string)
  @formats ~w(date date-time duration email hostname ipv4 ipv6 regex time uri uri-reference)

  @doc "Validates a JSON-compatible instance against a bounded schema subset."
  @spec validate(term(), term()) :: :ok | {:error, term()}
  def validate(_value, nil), do: :ok
  def validate(_value, true), do: :ok
  def validate(_value, false), do: {:error, :schema_false}

  def validate(value, schema) when is_map(schema) do
    with :ok <- validate_schema(schema),
         :ok <- bounded(schema),
         :ok <- json_value(value) do
      validate_node(value, schema, schema, 0)
    end
  end

  def validate(_, _), do: {:error, :invalid_schema}

  @doc "Checks a schema without validating an instance. No network references are fetched."
  @spec validate_schema(term()) :: :ok | {:error, term()}
  def validate_schema(schema) when is_boolean(schema), do: :ok

  def validate_schema(schema) when is_map(schema) do
    with :ok <- bounded(schema),
         :ok <- json_value(schema),
         :ok <- schema_node(schema, 0, schema_dialect(schema)),
         :ok <- validate_anchors_unique(schema) do
      :ok
    end
  end

  def validate_schema(_), do: {:error, :invalid_schema}

  @doc "Checks that a term can be represented losslessly as JSON."
  @spec json_value(term()) :: :ok | {:error, :not_json}
  def json_value(value) do
    case bounded_json_value(value, 0, @max_json_nodes, 0) do
      {:ok, _nodes, _bytes} -> :ok
      {:error, _} = error -> error
    end
  end

  defp json_equal?(left, right) when is_number(left) and is_number(right),
    do: left == right

  defp json_equal?(left, right) when is_map(left) and is_map(right) do
    map_size(left) == map_size(right) and
      Enum.all?(left, fn {key, value} ->
        Map.has_key?(right, key) and json_equal?(value, Map.fetch!(right, key))
      end)
  end

  defp json_equal?(left, right) when is_list(left) and is_list(right) do
    length(left) == length(right) and
      Enum.zip(left, right) |> Enum.all?(fn {a, b} -> json_equal?(a, b) end)
  end

  defp json_equal?(left, right), do: left === right

  @doc "Validates the bounded modern result variants emitted by this package."
  @spec validate_modern_result(map()) :: :ok | {:error, term()}
  def validate_modern_result(%{"resultType" => "complete"} = result) when is_map(result) do
    with :ok <- optional_nonnegative_integer(result, "ttlMs"),
         :ok <- optional_cache_scope(result),
         :ok <- optional_result_catalog(result) do
      :ok
    end
  end

  def validate_modern_result(%{
        "resultType" => "input_required",
        "inputRequests" => requests,
        "requestState" => state
      })
      when is_map(requests) and is_binary(state) and map_size(requests) > 0 do
    if Enum.all?(requests, fn {key, request} ->
         is_binary(key) and byte_size(key) in 1..128 and is_map(request) and
           request["method"] in ["elicitation/create", "sampling/createMessage", "roots/list"] and
           is_map(request["params"])
       end) and is_binary(state) and byte_size(state) <= 4096,
       do: :ok,
       else: {:error, :invalid_input_requests}
  end

  def validate_modern_result(_), do: {:error, :invalid_modern_result}

  defp optional_nonnegative_integer(result, key) do
    case Map.fetch(result, key) do
      :error -> :ok
      {:ok, value} when is_integer(value) and value >= 0 -> :ok
      _ -> {:error, {:invalid, key}}
    end
  end

  defp optional_cache_scope(result) do
    case Map.fetch(result, "cacheScope") do
      :error -> :ok
      {:ok, scope} when scope in ["private", "public"] -> :ok
      _ -> {:error, :invalid_cache_scope}
    end
  end

  defp optional_result_catalog(result) do
    Enum.reduce_while(["tools", "resources", "resourceTemplates", "prompts"], :ok, fn key, :ok ->
      case Map.fetch(result, key) do
        :error -> {:cont, :ok}
        {:ok, values} when is_list(values) -> {:cont, :ok}
        {:ok, _} -> {:halt, {:error, {:invalid_catalog, key}}}
      end
    end)
  end

  defp validate_node(_value, _schema, _root, depth) when depth > @max_depth,
    do: {:error, :schema_too_deep}

  defp validate_node(_value, true, _root, _depth), do: :ok
  defp validate_node(_value, false, _root, _depth), do: {:error, :schema_false}

  defp validate_node(value, schema, root, depth) when is_map(schema) do
    case resolve_ref(schema, root) do
      {:ok, schema} ->
        validate_map_node(value, schema, root, depth)

      {:ref, target, siblings} ->
        merged =
          Map.update(siblings, "allOf", [target], fn all_of -> [target | List.wrap(all_of)] end)

        validate_map_node(value, merged, root, depth)

      {:error, _} = error ->
        error
    end
  end

  defp validate_node(_value, _schema, _root, _depth), do: {:error, :invalid_schema}

  defp validate_map_node(value, schema, root, depth) do
    with :ok <- type(value, Map.get(schema, "type")),
         :ok <- enum(value, Map.get(schema, "enum")),
         :ok <- const(value, schema),
         :ok <- combinators(value, schema, root, depth),
         :ok <- conditional(value, schema, root, depth),
         :ok <- string_rules(value, schema),
         :ok <- number_rules(value, schema),
         :ok <- object_rules(value, schema, root, depth),
         :ok <- array_rules(value, schema, root, depth) do
      :ok
    end
  end

  defp bounded(schema) when is_map(schema) do
    cond do
      Map.has_key?(schema, "$schema") and schema["$schema"] not in @supported_dialects ->
        {:error, :unsupported_dialect}

      has_remote_ref?(schema) ->
        {:error, :remote_ref_disabled}

      count(schema) > @max_nodes ->
        {:error, :schema_too_complex}

      depth(schema) > @max_depth ->
        {:error, :schema_too_deep}

      true ->
        :ok
    end
  end

  # Schema validation is deliberately conservative. Unknown keys are retained
  # as annotations/extensions, while recognized assertion/applicator keywords
  # must have a bounded, JSON-compatible form before a definition is accepted.
  defp schema_node(_schema, depth, _dialect) when depth > @max_depth,
    do: {:error, :schema_too_deep}

  defp schema_node(schema, depth, dialect) when is_map(schema) do
    dialect = schema_dialect(schema, dialect)

    with :ok <- reject_unsupported_keywords(schema),
         :ok <- validate_schema_dialect(schema),
         :ok <- validate_ref(schema),
         :ok <- validate_anchor_keyword(schema),
         :ok <- validate_dynamic_ref(schema),
         :ok <- validate_type_keyword(schema),
         :ok <- validate_enum_keyword(schema),
         :ok <- validate_boolean_keywords(schema),
         :ok <- validate_const_keyword(schema),
         :ok <- validate_required_keyword(schema),
         :ok <- validate_numeric_keywords(schema),
         :ok <- validate_string_keywords(schema, dialect),
         :ok <- validate_object_keywords(schema, depth, dialect),
         :ok <- validate_array_keywords(schema, depth, dialect),
         :ok <- validate_combinator_keywords(schema, depth, dialect),
         :ok <- validate_conditional_keywords(schema, depth, dialect) do
      :ok
    end
  end

  defp schema_node(true, _depth, _dialect), do: :ok
  defp schema_node(false, _depth, _dialect), do: :ok
  defp schema_node(_, _depth, _dialect), do: {:error, :invalid_schema}

  defp validate_schema_dialect(%{"$schema" => dialect}) when dialect in @supported_dialects,
    do: :ok

  defp validate_schema_dialect(%{"$schema" => _}), do: {:error, :unsupported_dialect}
  defp validate_schema_dialect(_), do: :ok

  defp schema_dialect(%{"$schema" => dialect}) when dialect in @supported_dialects,
    do: dialect

  defp schema_dialect(_), do: @default_dialect

  defp schema_dialect(%{"$schema" => dialect}, _parent) when dialect in @supported_dialects,
    do: dialect

  defp schema_dialect(_, parent), do: parent

  defp reject_unsupported_keywords(schema) do
    case Enum.find(@unsupported_keywords, &Map.has_key?(schema, &1)) do
      nil -> :ok
      keyword -> {:error, {:unsupported_keyword, keyword}}
    end
  end

  defp validate_ref(%{"$ref" => ref}) when is_binary(ref) do
    if local_ref?(ref), do: :ok, else: {:error, :unsupported_ref}
  end

  defp validate_ref(%{"$ref" => _}), do: {:error, :invalid_ref}
  defp validate_ref(_), do: :ok

  defp validate_anchor_keyword(schema) do
    Enum.reduce_while(["$anchor", "$dynamicAnchor"], :ok, fn key, :ok ->
      case Map.fetch(schema, key) do
        :error ->
          {:cont, :ok}

        {:ok, value} when is_binary(value) ->
          if Regex.match?(~r/^[A-Za-z][A-Za-z0-9._-]*$/, value),
            do: {:cont, :ok},
            else: {:halt, {:error, {:invalid_keyword, key}}}

        {:ok, _} ->
          {:halt, {:error, {:invalid_keyword, key}}}
      end
    end)
  end

  defp validate_dynamic_ref(schema) do
    case Map.fetch(schema, "$dynamicRef") do
      :error ->
        :ok

      {:ok, ref} when is_binary(ref) ->
        if local_ref?(ref), do: :ok, else: {:error, :unsupported_ref}

      {:ok, _} ->
        {:error, {:invalid_keyword, "$dynamicRef"}}
    end
  end

  defp local_ref?("#"), do: true
  defp local_ref?(<<"#/", _rest::binary>>), do: true

  defp local_ref?(<<"#", _rest::binary>> = ref),
    do: Regex.match?(~r/^#[A-Za-z][A-Za-z0-9._-]*$/, ref)

  defp local_ref?(_), do: false

  defp validate_type_keyword(%{"type" => type}) when is_binary(type) and type in @types,
    do: :ok

  defp validate_type_keyword(%{"type" => types}) when is_list(types) do
    cond do
      types == [] -> {:error, :invalid_type}
      Enum.uniq(types) != types -> {:error, :invalid_type}
      Enum.all?(types, &(&1 in @types)) -> :ok
      true -> {:error, :invalid_type}
    end
  end

  defp validate_type_keyword(%{"type" => _}), do: {:error, :invalid_type}
  defp validate_type_keyword(_), do: :ok

  defp validate_enum_keyword(%{"enum" => values}) when is_list(values) and values != [] do
    if Enum.all?(values, &(json_value(&1) == :ok)), do: :ok, else: {:error, :invalid_enum}
  end

  defp validate_enum_keyword(%{"enum" => _}), do: {:error, :invalid_enum}
  defp validate_enum_keyword(_), do: :ok

  defp validate_boolean_keywords(schema) do
    Enum.reduce_while(["uniqueItems", "exclusiveMinimum", "exclusiveMaximum"], :ok, fn key, :ok ->
      case Map.fetch(schema, key) do
        :error -> {:cont, :ok}
        {:ok, value} when key == "uniqueItems" and is_boolean(value) -> {:cont, :ok}
        {:ok, value} when key != "uniqueItems" and is_number(value) -> {:cont, :ok}
        {:ok, _} -> {:halt, {:error, {:invalid_keyword, key}}}
      end
    end)
  end

  defp validate_const_keyword(schema) do
    case Map.fetch(schema, "const") do
      :error -> :ok
      {:ok, value} -> if json_value(value) == :ok, do: :ok, else: {:error, :invalid_const}
    end
  end

  defp validate_required_keyword(%{"required" => names}) when is_list(names) do
    if names != [] and Enum.uniq(names) == names and Enum.all?(names, &is_binary/1),
      do: :ok,
      else: {:error, :invalid_required}
  end

  defp validate_required_keyword(%{"required" => _}), do: {:error, :invalid_required}
  defp validate_required_keyword(_), do: :ok

  defp validate_numeric_keywords(schema) do
    with :ok <- finite_number(schema, "minimum"),
         :ok <- finite_number(schema, "maximum"),
         :ok <- finite_number(schema, "exclusiveMinimum"),
         :ok <- finite_number(schema, "exclusiveMaximum"),
         :ok <- positive_number(schema, "multipleOf"),
         :ok <- bound_integer(schema, "minProperties"),
         :ok <- bound_integer(schema, "maxProperties"),
         :ok <- bound_integer(schema, "minItems"),
         :ok <- bound_integer(schema, "maxItems"),
         :ok <- bound_integer(schema, "minLength"),
         :ok <- bound_integer(schema, "maxLength"),
         :ok <- bound_integer(schema, "minContains"),
         :ok <- bound_integer(schema, "maxContains") do
      :ok
    end
  end

  defp finite_number(schema, key) do
    case Map.fetch(schema, key) do
      :error ->
        :ok

      {:ok, value} when is_integer(value) ->
        :ok

      {:ok, value} when is_float(value) and value == value ->
        :ok

      {:ok, _} ->
        {:error, {:invalid_keyword, key}}
    end
  end

  defp positive_number(schema, key) do
    case Map.fetch(schema, key) do
      :error -> :ok
      {:ok, value} when is_number(value) and value > 0 -> :ok
      {:ok, _} -> {:error, {:invalid_keyword, key}}
    end
  end

  defp bound_integer(schema, key) do
    case Map.fetch(schema, key) do
      :error -> :ok
      {:ok, value} when is_integer(value) and value >= 0 -> :ok
      {:ok, _} -> {:error, {:invalid_keyword, key}}
    end
  end

  defp validate_string_keywords(schema, dialect) do
    with :ok <- bounded_pattern(schema, "pattern"),
         :ok <- bounded_pattern_map(schema, "patternProperties", dialect),
         :ok <- valid_format(schema) do
      :ok
    end
  end

  defp bounded_pattern(schema, key) do
    case Map.fetch(schema, key) do
      :error ->
        :ok

      {:ok, expression} when is_binary(expression) and byte_size(expression) <= 256 ->
        case Regex.compile(expression) do
          {:ok, _} -> :ok
          _ -> {:error, :invalid_pattern}
        end

      {:ok, _} ->
        {:error, :invalid_pattern}
    end
  end

  defp bounded_pattern_map(schema, key, dialect) do
    case Map.fetch(schema, key) do
      :error ->
        :ok

      {:ok, patterns} when is_map(patterns) and map_size(patterns) <= 100 ->
        Enum.reduce_while(patterns, :ok, fn {expression, child}, :ok ->
          with :ok <- bounded_pattern(%{"pattern" => expression}, "pattern"),
               :ok <- schema_node(child, 1, dialect) do
            {:cont, :ok}
          else
            error -> {:halt, error}
          end
        end)

      {:ok, _} ->
        {:error, :invalid_pattern_properties}
    end
  end

  defp valid_format(%{"format" => format}) when format in @formats, do: :ok
  defp valid_format(%{"format" => _}), do: {:error, :unsupported_format}
  defp valid_format(_), do: :ok

  defp validate_object_keywords(schema, depth, dialect) do
    with :ok <- schema_map(schema, "properties", depth, dialect),
         :ok <- schema_map(schema, "patternProperties", depth, dialect),
         :ok <- schema_or_boolean(schema, "additionalProperties", depth, dialect),
         :ok <- schema_or_boolean(schema, "unevaluatedProperties", depth, dialect),
         :ok <- schema_or_boolean(schema, "propertyNames", depth, dialect),
         :ok <- schema_map_of_schemas(schema, "dependentSchemas", depth, dialect),
         :ok <- schema_map_of_schemas(schema, "$defs", depth, dialect),
         :ok <- schema_map_of_schemas(schema, "definitions", depth, dialect),
         :ok <- content_schema(schema, depth, dialect),
         :ok <- legacy_dependencies_schema(schema, depth, dialect),
         :ok <- dependencies(schema) do
      :ok
    end
  end

  defp validate_array_keywords(schema, depth, dialect) do
    with :ok <- schema_items_keyword(schema, depth, dialect),
         :ok <- schema_list(schema, "prefixItems", depth, dialect),
         :ok <- schema_or_boolean(schema, "additionalItems", depth, dialect),
         :ok <- schema_or_boolean(schema, "unevaluatedItems", depth, dialect),
         :ok <- schema_or_boolean(schema, "contains", depth, dialect),
         :ok <- content_encoding(schema),
         :ok <- content_media_type(schema) do
      :ok
    end
  end

  defp validate_combinator_keywords(schema, depth, dialect) do
    Enum.reduce_while(~w(allOf anyOf oneOf), :ok, fn key, :ok ->
      case Map.fetch(schema, key) do
        :error ->
          {:cont, :ok}

        {:ok, values} when is_list(values) and values != [] ->
          case Enum.reduce_while(values, :ok, fn child, :ok ->
                 case schema_node(child, depth + 1, dialect) do
                   :ok -> {:cont, :ok}
                   error -> {:halt, error}
                 end
               end) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end

        {:ok, _} ->
          {:halt, {:error, :invalid_combinator}}
      end
    end)
  end

  defp validate_conditional_keywords(schema, depth, dialect) do
    Enum.reduce_while(~w(not if then else), :ok, fn key, :ok ->
      case Map.fetch(schema, key) do
        :error ->
          {:cont, :ok}

        {:ok, value} ->
          case schema_node(value, depth + 1, dialect) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
      end
    end)
  end

  defp schema_map(schema, key, depth, dialect) do
    case Map.fetch(schema, key) do
      :error ->
        :ok

      {:ok, value} when is_map(value) ->
        Enum.reduce_while(value, :ok, fn {name, child}, :ok ->
          if is_binary(name) do
            case schema_node(child, depth + 1, dialect) do
              :ok -> {:cont, :ok}
              error -> {:halt, error}
            end
          else
            {:halt, {:error, :invalid_schema_property}}
          end
        end)

      {:ok, _} ->
        {:error, {:invalid_keyword, key}}
    end
  end

  defp schema_map_of_schemas(schema, key, depth, dialect),
    do: schema_map(schema, key, depth, dialect)

  defp schema_list(schema, key, depth, dialect) do
    case Map.fetch(schema, key) do
      :error ->
        :ok

      {:ok, values} when is_list(values) ->
        Enum.reduce_while(values, :ok, fn child, :ok ->
          case schema_node(child, depth + 1, dialect) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)

      {:ok, _} ->
        {:error, {:invalid_keyword, key}}
    end
  end

  defp schema_or_boolean(schema, key, depth, dialect) do
    case Map.fetch(schema, key) do
      :error ->
        :ok

      {:ok, value} when is_boolean(value) or is_map(value) ->
        schema_node(value, depth + 1, dialect)

      {:ok, _} ->
        {:error, {:invalid_keyword, key}}
    end
  end

  defp legacy_items_allowed?(dialect), do: dialect in @draft7_dialects

  defp schema_items_keyword(schema, depth, dialect) do
    case Map.fetch(schema, "items") do
      :error ->
        :ok

      {:ok, value} when is_boolean(value) or is_map(value) ->
        schema_node(value, depth + 1, dialect)

      {:ok, values} when is_list(values) ->
        if legacy_items_allowed?(dialect) do
          Enum.reduce_while(values, :ok, fn child, :ok ->
            case schema_node(child, depth + 1, dialect) do
              :ok -> {:cont, :ok}
              error -> {:halt, error}
            end
          end)
        else
          {:error, {:invalid_keyword, "items"}}
        end

      {:ok, _} ->
        {:error, {:invalid_keyword, "items"}}
    end
  end

  defp dependencies(schema) do
    case Map.fetch(schema, "dependentRequired") do
      :error ->
        :ok

      {:ok, deps} when is_map(deps) ->
        if Enum.all?(deps, fn {key, values} ->
             is_binary(key) and is_list(values) and Enum.all?(values, &is_binary/1)
           end),
           do: :ok,
           else: {:error, :invalid_dependent_required}

      {:ok, _} ->
        {:error, :invalid_dependent_required}
    end
  end

  defp legacy_dependencies_schema(schema, depth, dialect) do
    case Map.fetch(schema, "dependencies") do
      :error ->
        :ok

      {:ok, dependencies} when is_map(dependencies) ->
        Enum.reduce_while(dependencies, :ok, fn {_key, dependency}, :ok ->
          cond do
            is_list(dependency) and Enum.all?(dependency, &is_binary/1) ->
              {:cont, :ok}

            is_map(dependency) or is_boolean(dependency) ->
              case schema_node(dependency, depth + 1, dialect) do
                :ok -> {:cont, :ok}
                error -> {:halt, error}
              end

            true ->
              {:halt, {:error, :invalid_dependencies}}
          end
        end)

      {:ok, _} ->
        {:error, :invalid_dependencies}
    end
  end

  defp content_schema(schema, depth, dialect) do
    case Map.fetch(schema, "contentSchema") do
      :error -> :ok
      {:ok, value} -> schema_node(value, depth + 1, dialect)
    end
  end

  defp content_encoding(schema) do
    case Map.fetch(schema, "contentEncoding") do
      :error -> :ok
      {:ok, value} when is_binary(value) and byte_size(value) <= 128 -> :ok
      {:ok, _} -> {:error, {:invalid_keyword, "contentEncoding"}}
    end
  end

  defp content_media_type(schema) do
    case Map.fetch(schema, "contentMediaType") do
      :error -> :ok
      {:ok, value} when is_binary(value) and byte_size(value) <= 256 -> :ok
      {:ok, _} -> {:error, {:invalid_keyword, "contentMediaType"}}
    end
  end

  # Only these keywords introduce schema locations.  Traversing every nested
  # map would mistake annotation objects (and extension metadata) for schemas.
  defp schema_children(schema) when is_map(schema) do
    singleton_keys = [
      "additionalProperties",
      "additionalItems",
      "unevaluatedProperties",
      "unevaluatedItems",
      "propertyNames",
      "contains",
      "not",
      "if",
      "then",
      "else",
      "contentSchema"
    ]

    singleton_children =
      singleton_keys
      |> Enum.map(&Map.get(schema, &1))
      |> Enum.filter(&(is_map(&1) or is_boolean(&1)))

    map_children =
      ["properties", "patternProperties", "dependentSchemas", "$defs", "definitions"]
      |> Enum.flat_map(fn key ->
        case Map.get(schema, key) do
          value when is_map(value) -> Map.values(value)
          _ -> []
        end
      end)

    dependency_children =
      case Map.get(schema, "dependencies") do
        dependencies when is_map(dependencies) ->
          dependencies
          |> Map.values()
          |> Enum.filter(&(is_map(&1) or is_boolean(&1)))

        _ ->
          []
      end

    list_children =
      ["prefixItems", "allOf", "anyOf", "oneOf"]
      |> Enum.flat_map(fn key ->
        case Map.get(schema, key) do
          values when is_list(values) -> Enum.filter(values, &(is_map(&1) or is_boolean(&1)))
          _ -> []
        end
      end)

    items_children =
      case Map.get(schema, "items") do
        values when is_list(values) -> Enum.filter(values, &(is_map(&1) or is_boolean(&1)))
        value when is_map(value) or is_boolean(value) -> [value]
        _ -> []
      end

    singleton_children ++ map_children ++ dependency_children ++ list_children ++ items_children
  end

  defp validate_anchors_unique(schema) do
    case collect_anchor_names(schema, MapSet.new()) do
      {:ok, _names} -> :ok
      {:error, _} = error -> error
    end
  end

  defp collect_anchor_names(schema, names) when is_map(schema) do
    own_names =
      [Map.get(schema, "$anchor"), Map.get(schema, "$dynamicAnchor")]
      |> Enum.filter(&is_binary/1)

    if Enum.any?(own_names, &MapSet.member?(names, &1)) or
         length(own_names) != length(Enum.uniq(own_names)) do
      {:error, :duplicate_anchor}
    else
      names = Enum.reduce(own_names, names, &MapSet.put(&2, &1))

      Enum.reduce_while(schema_children(schema), {:ok, names}, fn child, {:ok, acc} ->
        case collect_anchor_names(child, acc) do
          {:ok, next} -> {:cont, {:ok, next}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  defp collect_anchor_names(_schema, names), do: {:ok, names}

  defp has_remote_ref?(value) when is_map(value) do
    Enum.any?(value, fn
      {key, ref} when key in ["$ref", "$dynamicRef"] and is_binary(ref) ->
        not local_ref?(ref)

      {_key, child} ->
        has_remote_ref?(child)
    end)
  end

  defp has_remote_ref?(value) when is_list(value), do: Enum.any?(value, &has_remote_ref?/1)
  defp has_remote_ref?(_), do: false

  defp resolve_ref(%{"$ref" => ref} = schema, root) when is_binary(ref) do
    cond do
      ref == "#" ->
        {:ref, Map.delete(root, "$ref"), Map.delete(schema, "$ref")}

      String.starts_with?(ref, "#/") ->
        case pointer(root, String.trim_leading(ref, "#/")) do
          {:ok, target} when is_map(target) or is_boolean(target) ->
            {:ref, target, Map.delete(schema, "$ref")}

          _ ->
            {:error, :unresolved_ref}
        end

      String.starts_with?(ref, "#") ->
        case anchor(root, String.trim_leading(ref, "#")) do
          {:ok, target} ->
            {:ref, target, Map.delete(schema, "$ref")}

          :error ->
            {:error, :unresolved_ref}
        end

      true ->
        {:error, :unsupported_ref}
    end
  end

  defp resolve_ref(%{"$dynamicRef" => ref} = schema, root) when is_binary(ref) do
    case ref do
      "#" ->
        {:ref, root, Map.delete(schema, "$dynamicRef")}

      <<"#/", path::binary>> ->
        case pointer(root, path) do
          {:ok, target} when is_map(target) or is_boolean(target) ->
            {:ref, target, Map.delete(schema, "$dynamicRef")}

          _ ->
            {:error, :unresolved_ref}
        end

      <<"#", anchor_name::binary>> ->
        case anchor(root, anchor_name) do
          {:ok, target} -> {:ref, target, Map.delete(schema, "$dynamicRef")}
          :error -> {:error, :unresolved_ref}
        end

      _ ->
        {:error, :unsupported_ref}
    end
  end

  defp resolve_ref(schema, _root), do: {:ok, schema}

  defp pointer(value, path) do
    with {:ok, decoded} <- decode_pointer(path) do
      Enum.reduce_while(String.split(decoded, "/"), {:ok, value}, fn segment, {:ok, current} ->
        with {:ok, segment} <- decode_pointer_segment(segment) do
          cond do
            is_map(current) and Map.has_key?(current, segment) ->
              {:cont, {:ok, current[segment]}}

            is_list(current) and pointer_index?(segment) ->
              index = String.to_integer(segment)

              if index < length(current),
                do: {:cont, {:ok, Enum.at(current, index)}},
                else: {:halt, :error}

            true ->
              {:halt, :error}
          end
        else
          _ -> {:halt, :error}
        end
      end)
    end
  end

  defp decode_pointer(path) when is_binary(path) do
    if Regex.match?(~r/%(?![0-9A-Fa-f]{2})/, path),
      do: :error,
      else: {:ok, URI.decode(path)}
  end

  defp decode_pointer_segment(segment) do
    if Regex.match?(~r/(?:~(?![01]))/, segment),
      do: :error,
      else: {:ok, String.replace(segment, "~1", "/") |> String.replace("~0", "~")}
  end

  defp anchor(value, name) when is_map(value) do
    cond do
      value["$anchor"] == name or value["$dynamicAnchor"] == name ->
        {:ok, value}

      true ->
        Enum.find_value(schema_children(value), fn child ->
          case anchor(child, name) do
            {:ok, _} = result -> result
            :error -> nil
          end
        end) || :error
    end
  end

  defp anchor(value, name) when is_list(value) do
    Enum.find_value(value, fn child ->
      case anchor(child, name) do
        {:ok, _} = result -> result
        :error -> nil
      end
    end) || :error
  end

  defp anchor(_value, _name), do: :error

  defp pointer_index?("0"), do: true

  defp pointer_index?(value) when is_binary(value),
    do: Regex.match?(~r/^[1-9][0-9]*$/, value)

  defp type(_, nil), do: :ok

  defp type(value, types) when is_list(types) do
    if Enum.any?(types, &(type(value, &1) == :ok)), do: :ok, else: {:error, {:type, types}}
  end

  defp type(value, "object") when is_map(value), do: :ok
  defp type(value, "array") when is_list(value), do: :ok
  defp type(value, "string") when is_binary(value), do: :ok
  defp type(value, "number") when is_number(value), do: :ok
  defp type(value, "integer") when is_integer(value), do: :ok

  defp type(value, "integer") when is_float(value) and value == value,
    do: if(value == trunc(value), do: :ok, else: {:error, {:type, "integer"}})

  defp type(value, "boolean") when is_boolean(value), do: :ok
  defp type(nil, "null"), do: :ok
  defp type(_, type), do: {:error, {:type, type}}

  defp enum(_, nil), do: :ok

  defp enum(value, values) when is_list(values),
    do:
      if(Enum.any?(values, &json_equal?(value, &1)),
        do: :ok,
        else: {:error, :not_in_enum}
      )

  defp enum(_, _), do: {:error, :invalid_enum}

  defp const(_value, schema) when not is_map_key(schema, "const"), do: :ok

  defp const(value, schema),
    do:
      if(json_equal?(value, schema["const"]),
        do: :ok,
        else: {:error, :const_mismatch}
      )

  defp combinators(value, schema, root, depth) do
    with :ok <- every_schema(value, Map.get(schema, "allOf"), root, depth),
         :ok <- some_schema(value, Map.get(schema, "anyOf"), root, depth, :any),
         :ok <- some_schema(value, Map.get(schema, "oneOf"), root, depth, :one),
         :ok <- negate_schema(value, Map.get(schema, "not"), root, depth) do
      :ok
    end
  end

  defp every_schema(_value, nil, _root, _depth), do: :ok

  defp every_schema(value, schemas, root, depth) when is_list(schemas) do
    Enum.reduce_while(schemas, :ok, fn schema, :ok ->
      case validate_node(value, schema, root, depth + 1) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp every_schema(_, _, _, _), do: {:error, :invalid_combinator}

  defp some_schema(_value, nil, _root, _depth, _kind), do: :ok

  defp some_schema(value, schemas, root, depth, kind) when is_list(schemas) do
    matches = Enum.count(schemas, &(validate_node(value, &1, root, depth + 1) == :ok))

    cond do
      kind == :any and matches > 0 -> :ok
      kind == :one and matches == 1 -> :ok
      true -> {:error, {kind, :mismatch}}
    end
  end

  defp some_schema(_, _, _, _, _), do: {:error, :invalid_combinator}

  defp negate_schema(_value, nil, _root, _depth), do: :ok

  defp negate_schema(value, schema, root, depth) do
    if validate_node(value, schema, root, depth + 1) == :ok,
      do: {:error, :not_allowed},
      else: :ok
  end

  defp conditional(_value, schema, _root, _depth) when not is_map_key(schema, "if"), do: :ok

  defp conditional(value, schema, root, depth) do
    branch =
      if validate_node(value, schema["if"], root, depth + 1) == :ok,
        do: schema["then"],
        else: schema["else"]

    if is_nil(branch), do: :ok, else: validate_node(value, branch, root, depth + 1)
  end

  defp string_rules(value, schema) when is_binary(value) do
    with :ok <- length_rule(String.length(value), schema["minLength"], :min_length),
         :ok <- length_rule(String.length(value), schema["maxLength"], :max_length),
         :ok <- pattern(value, schema["pattern"]) do
      format(value, schema["format"])
    end
  end

  defp string_rules(_, _), do: :ok

  defp length_rule(_, nil, _kind), do: :ok

  defp length_rule(value, bound, kind) when is_integer(bound) and bound >= 0 do
    if (kind == :min_length and value >= bound) or (kind == :max_length and value <= bound),
      do: :ok,
      else: {:error, kind}
  end

  defp length_rule(_, _, _), do: {:error, :invalid_length}

  defp pattern(_, nil), do: :ok

  defp pattern(value, expression) when is_binary(expression) do
    case Regex.compile(expression) do
      {:ok, regex} -> if Regex.match?(regex, value), do: :ok, else: {:error, :pattern_mismatch}
      _ -> {:error, :invalid_pattern}
    end
  end

  defp pattern(_, _), do: {:error, :invalid_pattern}

  defp format(_, nil), do: :ok

  defp format(value, "date") when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, _date} -> :ok
      _ -> {:error, :format}
    end
  end

  defp format(value, "time") when is_binary(value) do
    case Time.from_iso8601(value) do
      {:ok, _time} -> :ok
      _ -> {:error, :format}
    end
  end

  defp format(value, "date-time") when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} -> :ok
      _ -> {:error, :format}
    end
  end

  defp format(value, "duration") when is_binary(value) do
    valid? =
      Regex.match?(
        ~r/^P(?:\d+Y)?(?:\d+M)?(?:\d+D)?(?:T(?:\d+H)?(?:\d+M)?(?:\d+(?:\.\d+)?S)?)?$/,
        value
      ) and Regex.match?(~r/\d+(?:\.\d+)?[YMDHMS]/, value) and
        not String.ends_with?(value, "T")

    if valid?, do: :ok, else: {:error, :format}
  end

  defp format(value, "hostname") when is_binary(value),
    do:
      if(valid_hostname?(value),
        do: :ok,
        else: {:error, :format}
      )

  defp format(value, "ipv4") when is_binary(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, {_, _, _, _}} -> :ok
      _ -> {:error, :format}
    end
  end

  defp format(value, "ipv6") when is_binary(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, {_, _, _, _, _, _, _, _}} -> :ok
      _ -> {:error, :format}
    end
  end

  defp format(value, "regex") when is_binary(value),
    do: if(match?({:ok, _}, Regex.compile(value)), do: :ok, else: {:error, :format})

  defp format(value, "uri-reference") when is_binary(value),
    do: valid_uri_reference(value)

  defp format(value, "uri") when is_binary(value) do
    case valid_uri_reference(value) do
      :ok ->
        parsed = URI.parse(value)
        if is_binary(parsed.scheme) and parsed.scheme != "", do: :ok, else: {:error, :format}

      error ->
        error
    end
  end

  defp format(value, "email") when is_binary(value),
    do:
      if(Regex.match?(~r/^[^\s@]+@[^\s@.]+(?:\.[^\s@.]+)+$/, value),
        do: :ok,
        else: {:error, :format}
      )

  defp format(_, _), do: {:error, :format}

  defp valid_uri_reference(value) when is_binary(value) do
    with true <- String.valid?(value),
         true <- ascii_uri?(value),
         true <- not Regex.match?(~r/[\x00-\x20<>"{}|\\^`]/, value),
         true <- not Regex.match?(~r/%(?![0-9A-Fa-f]{2})/, value),
         :ok <- valid_uri_brackets(value) do
      :ok
    else
      _ -> {:error, :format}
    end
  end

  defp ascii_uri?(value), do: value |> :binary.bin_to_list() |> Enum.all?(&(&1 < 128))

  defp valid_hostname?(value) when is_binary(value) do
    labels = String.split(value, ".", trim: false)
    labels = if List.last(labels) == "", do: Enum.drop(labels, -1), else: labels

    byte_size(value) <= 253 and labels != [] and
      Enum.all?(labels, fn label ->
        byte_size(label) in 1..63 and
          Regex.match?(~r/^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$/, label)
      end)
  end

  defp valid_uri_brackets(value) do
    if String.contains?(value, ["[", "]"]) do
      case Regex.run(~r/^(?:[A-Za-z][A-Za-z0-9+.-]*:)?\/\/([^\/?#]*)/, value) do
        [_, authority] -> valid_authority_brackets(authority)
        _ -> {:error, :format}
      end
    else
      :ok
    end
  end

  defp valid_authority_brackets(authority) when is_binary(authority) do
    valid? =
      if String.contains?(authority, "@") do
        [userinfo, hostport] = String.split(authority, "@", parts: 2)
        valid_bracketed_hostport?(hostport) and not String.contains?(userinfo, ["[", "]"])
      else
        valid_bracketed_hostport?(authority)
      end

    if valid?, do: :ok, else: {:error, :format}
  end

  defp valid_bracketed_hostport?(hostport) do
    case Regex.run(~r/^\[([^\]]+)\](?::([0-9]+))?$/, hostport) do
      [_, literal | _] -> valid_ip_literal?(literal)
      _ -> false
    end
  end

  defp valid_ip_literal?(literal) do
    case :inet.parse_address(String.to_charlist(literal)) do
      {:ok, {_, _, _, _, _, _, _, _}} -> true
      _ -> Regex.match?(~r/^v[0-9A-Fa-f]+\.[A-Za-z0-9._~!$&'()*+,;=:-]+$/, literal)
    end
  end

  defp number_rules(value, schema) when is_number(value) do
    with :ok <- minimum(value, schema["minimum"], false),
         :ok <- exclusive_minimum(value, schema),
         :ok <- maximum(value, schema["maximum"], false),
         :ok <- exclusive_maximum(value, schema),
         :ok <- multiple_of(value, schema["multipleOf"]) do
      :ok
    end
  end

  defp number_rules(_, _), do: :ok
  defp minimum(_, nil, _exclusive), do: :ok
  defp minimum(value, bound, false), do: if(value >= bound, do: :ok, else: {:error, :minimum})

  defp minimum(value, bound, true),
    do: if(value > bound, do: :ok, else: {:error, :exclusive_minimum})

  defp exclusive_minimum(value, %{"exclusiveMinimum" => bound}),
    do: minimum(value, bound, true)

  defp exclusive_minimum(_, _), do: :ok

  defp maximum(_, nil, _exclusive), do: :ok
  defp maximum(value, bound, false), do: if(value <= bound, do: :ok, else: {:error, :maximum})

  defp maximum(value, bound, true),
    do: if(value < bound, do: :ok, else: {:error, :exclusive_maximum})

  defp exclusive_maximum(value, %{"exclusiveMaximum" => bound}),
    do: maximum(value, bound, true)

  defp exclusive_maximum(_, _), do: :ok

  defp multiple_of(_, nil), do: :ok

  defp multiple_of(value, bound) when is_number(bound) and bound > 0 do
    quotient = value / bound
    if abs(quotient - round(quotient)) < 1.0e-10, do: :ok, else: {:error, :multiple_of}
  end

  defp multiple_of(_, _), do: {:error, :invalid_multiple_of}

  defp object_rules(value, schema, root, depth) when is_map(value) do
    required = Map.get(schema, "required", [])

    with :ok <- required(value, required),
         :ok <- count_rule(map_size(value), schema["minProperties"], :min_properties),
         :ok <- count_rule(map_size(value), schema["maxProperties"], :max_properties),
         :ok <- properties(value, schema["properties"], root, depth),
         :ok <- pattern_properties(value, schema["patternProperties"], root, depth),
         :ok <- additional_properties(value, schema, root, depth),
         :ok <- unevaluated_properties(value, schema, root, depth),
         :ok <- property_names(value, schema["propertyNames"], root, depth),
         :ok <- legacy_dependencies(value, schema["dependencies"], root, depth),
         :ok <- dependent_required(value, schema["dependentRequired"]),
         :ok <- dependent_schemas(value, schema["dependentSchemas"], root, depth) do
      :ok
    end
  end

  defp object_rules(_, _, _, _), do: :ok

  defp required(_, []), do: :ok

  defp required(value, names) when is_map(value) and is_list(names) do
    missing = Enum.filter(names, &(not Map.has_key?(value, &1)))
    if missing == [], do: :ok, else: {:error, {:required, missing}}
  end

  defp required(_, _), do: {:error, :invalid_required}

  defp count_rule(_, nil, _), do: :ok

  defp count_rule(value, bound, kind) when is_integer(bound) do
    if (kind in [:min_properties, :min_items] and value >= bound) or
         (kind in [:max_properties, :max_items] and value <= bound),
       do: :ok,
       else: {:error, kind}
  end

  defp count_rule(_, _, _), do: {:error, :invalid_bound}

  defp properties(_, nil, _root, _depth), do: :ok

  defp properties(value, schemas, root, depth) when is_map(value) and is_map(schemas) do
    Enum.reduce_while(schemas, :ok, fn {key, schema}, :ok ->
      if Map.has_key?(value, key) do
        case validate_node(value[key], schema, root, depth + 1) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp properties(_, _, _, _), do: {:error, :invalid_properties}

  defp pattern_properties(_, nil, _root, _depth), do: :ok

  defp pattern_properties(value, schemas, root, depth) when is_map(value) and is_map(schemas) do
    Enum.reduce_while(schemas, :ok, fn {expression, schema}, :ok ->
      case Regex.compile(expression) do
        {:ok, regex} ->
          values =
            value
            |> Enum.filter(fn {key, _} -> Regex.match?(regex, key) end)
            |> Enum.map(&elem(&1, 1))

          case every_values(values, schema, root, depth) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end

        _ ->
          {:halt, {:error, :invalid_pattern}}
      end
    end)
  end

  defp pattern_properties(_, _, _, _), do: {:error, :invalid_pattern_properties}

  defp additional_properties(value, schema, root, depth) do
    properties = Map.get(schema, "properties", %{})
    patterns = Map.get(schema, "patternProperties", %{})

    extras =
      Enum.filter(value, fn {key, _} ->
        not Map.has_key?(properties, key) and not matches_pattern?(key, patterns)
      end)

    case Map.get(schema, "additionalProperties") do
      false ->
        if extras == [],
          do: :ok,
          else: {:error, {:additional_properties, Enum.map(extras, &elem(&1, 0))}}

      additional when is_map(additional) ->
        every_values(Enum.map(extras, &elem(&1, 1)), additional, root, depth)

      true ->
        :ok

      nil ->
        :ok

      _ ->
        {:error, :invalid_additional_properties}
    end
  end

  defp unevaluated_properties(value, schema, root, depth) when is_map(value) do
    case Map.get(schema, "unevaluatedProperties") do
      nil ->
        :ok

      true ->
        :ok

      false ->
        evaluated = evaluated_keys(schema, value, root, depth)

        extras =
          Enum.filter(value, fn {key, _} ->
            not MapSet.member?(evaluated, key)
          end)

        if extras == [],
          do: :ok,
          else: {:error, {:unevaluated_properties, Enum.map(extras, &elem(&1, 0))}}

      nested when is_map(nested) ->
        evaluated = evaluated_keys(schema, value, root, depth)

        value
        |> Enum.reject(fn {key, _} -> MapSet.member?(evaluated, key) end)
        |> Enum.map(&elem(&1, 1))
        |> every_values(nested, root, depth)

      _ ->
        {:error, :invalid_unevaluated_properties}
    end
  end

  defp property_names(_, nil, _root, _depth), do: :ok

  defp property_names(value, schema, root, depth) when is_map(value) do
    value
    |> Map.keys()
    |> every_values(schema, root, depth)
  end

  @spec evaluated_keys(term(), term(), term(), non_neg_integer()) :: MapSet.t()
  defp evaluated_keys(_schema, _value, _root, depth) when depth > @max_depth,
    do: MapSet.new()

  defp evaluated_keys(schema, value, root, depth) when is_map(schema) and is_map(value) do
    case resolve_ref(schema, root) do
      {:ok, local} ->
        evaluated_keys_local(local, value, root, depth + 1)

      {:ref, target, siblings} ->
        evaluated_keys(target, value, root, depth + 1)
        |> MapSet.union(evaluated_keys_local(siblings, value, root, depth + 1))

      {:error, _} ->
        MapSet.new()
    end
  end

  defp evaluated_keys(_schema, _value, _root, _depth), do: MapSet.new()

  @spec evaluated_keys_local(map(), map(), term(), non_neg_integer()) :: MapSet.t()
  defp evaluated_keys_local(schema, value, root, depth) when is_map(schema) do
    direct =
      schema
      |> Map.get("properties", %{})
      |> Map.keys()
      |> Enum.filter(&Map.has_key?(value, &1))
      |> MapSet.new()

    patterned =
      value
      |> Map.keys()
      |> Enum.filter(&matches_pattern?(&1, Map.get(schema, "patternProperties", %{})))
      |> MapSet.new()

    additional =
      case Map.get(schema, "additionalProperties") do
        true ->
          MapSet.new(Map.keys(value))

        additional when is_map(additional) ->
          properties = Map.get(schema, "properties", %{})
          patterns = Map.get(schema, "patternProperties", %{})

          value
          |> Enum.filter(fn {key, _item} ->
            not Map.has_key?(properties, key) and not matches_pattern?(key, patterns)
          end)
          |> Enum.map(&elem(&1, 0))
          |> MapSet.new()

        _ ->
          MapSet.new()
      end

    all_of = successful_applicator_keys(value, Map.get(schema, "allOf"), root, depth)
    any_of = successful_applicator_keys(value, Map.get(schema, "anyOf"), root, depth)
    one_of = successful_applicator_keys(value, Map.get(schema, "oneOf"), root, depth)
    dependent = successful_dependent_keys(value, Map.get(schema, "dependentSchemas"), root, depth)
    conditional = conditional_keys(value, schema, root, depth)

    direct
    |> MapSet.union(patterned)
    |> MapSet.union(additional)
    |> MapSet.union(all_of)
    |> MapSet.union(any_of)
    |> MapSet.union(one_of)
    |> MapSet.union(dependent)
    |> MapSet.union(conditional)
  end

  @spec successful_applicator_keys(term(), term(), term(), non_neg_integer()) :: MapSet.t()
  defp successful_applicator_keys(_value, nil, _root, _depth), do: MapSet.new()

  defp successful_applicator_keys(value, schemas, root, depth) when is_list(schemas) do
    schemas
    |> Enum.reduce(MapSet.new(), fn child, acc ->
      if validate_node(value, child, root, depth + 1) == :ok,
        do: MapSet.union(acc, evaluated_keys(child, value, root, depth + 1)),
        else: acc
    end)
  end

  defp successful_applicator_keys(_value, _schemas, _root, _depth), do: MapSet.new()

  @spec successful_dependent_keys(term(), term(), term(), non_neg_integer()) :: MapSet.t()
  defp successful_dependent_keys(_value, nil, _root, _depth), do: MapSet.new()

  defp successful_dependent_keys(value, dependencies, root, depth) when is_map(dependencies) do
    dependencies
    |> Enum.reduce(MapSet.new(), fn {key, child}, acc ->
      if Map.has_key?(value, key) and validate_node(value, child, root, depth + 1) == :ok,
        do: MapSet.union(acc, evaluated_keys(child, value, root, depth + 1)),
        else: acc
    end)
  end

  defp successful_dependent_keys(_value, _dependencies, _root, _depth), do: MapSet.new()

  @spec conditional_keys(map(), map(), term(), non_neg_integer()) :: MapSet.t()
  defp conditional_keys(value, schema, root, depth) do
    case Map.fetch(schema, "if") do
      :error ->
        MapSet.new()

      {:ok, if_schema} ->
        if_result = validate_node(value, if_schema, root, depth + 1)
        branch = if if_result == :ok, do: Map.get(schema, "then"), else: Map.get(schema, "else")

        keys = evaluated_keys(if_schema, value, root, depth + 1)

        if is_nil(branch) or validate_node(value, branch, root, depth + 1) != :ok,
          do: keys,
          else: MapSet.union(keys, evaluated_keys(branch, value, root, depth + 1))
    end
  end

  defp matches_pattern?(_key, patterns) when patterns == %{}, do: false

  defp matches_pattern?(key, patterns) do
    Enum.any?(patterns, fn {expression, _schema} ->
      case Regex.compile(expression) do
        {:ok, regex} -> Regex.match?(regex, key)
        _ -> false
      end
    end)
  end

  defp dependent_required(_, nil), do: :ok

  defp dependent_required(value, dependencies) when is_map(value) and is_map(dependencies) do
    Enum.reduce_while(dependencies, :ok, fn {key, required_names}, :ok ->
      if Map.has_key?(value, key),
        do: required(value, required_names) |> halt_or_continue(),
        else: {:cont, :ok}
    end)
  end

  defp dependent_required(_, _), do: {:error, :invalid_dependent_required}

  defp legacy_dependencies(_, nil, _root, _depth), do: :ok

  defp legacy_dependencies(value, dependencies, root, depth)
       when is_map(value) and is_map(dependencies) do
    Enum.reduce_while(dependencies, :ok, fn {key, dependency}, :ok ->
      if Map.has_key?(value, key) do
        result =
          cond do
            is_list(dependency) ->
              required(value, dependency)

            is_map(dependency) or is_boolean(dependency) ->
              validate_node(value, dependency, root, depth + 1)

            true ->
              {:error, :invalid_dependencies}
          end

        halt_or_continue(result)
      else
        {:cont, :ok}
      end
    end)
  end

  defp legacy_dependencies(_, _, _, _), do: {:error, :invalid_dependencies}

  defp dependent_schemas(_, nil, _root, _depth), do: :ok

  defp dependent_schemas(value, dependencies, root, depth)
       when is_map(value) and is_map(dependencies) do
    Enum.reduce_while(dependencies, :ok, fn {key, schema}, :ok ->
      if Map.has_key?(value, key) do
        case validate_node(value, schema, root, depth + 1) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp dependent_schemas(_, _, _, _), do: {:error, :invalid_dependent_schemas}

  defp halt_or_continue(:ok), do: {:cont, :ok}
  defp halt_or_continue(error), do: {:halt, error}

  defp array_rules(value, schema, root, depth) when is_list(value) do
    with :ok <- count_rule(length(value), schema["minItems"], :min_items),
         :ok <- count_rule(length(value), schema["maxItems"], :max_items),
         :ok <- unique_items(value, schema["uniqueItems"]),
         :ok <- prefix_items(value, schema["prefixItems"], root, depth),
         :ok <-
           array_items(
             value,
             schema["items"],
             schema["prefixItems"],
             schema["additionalItems"],
             root,
             depth
           ),
         :ok <- contains(value, schema, root, depth),
         :ok <- unevaluated_items(value, schema, root, depth) do
      :ok
    end
  end

  defp array_rules(_, _, _, _), do: :ok

  defp unique_items(_, nil), do: :ok

  defp unique_items(value, true),
    do: if(unique_json_items?(value), do: :ok, else: {:error, :unique_items})

  defp unique_items(_, false), do: :ok
  defp unique_items(_, _), do: {:error, :invalid_unique_items}

  defp unique_json_items?(values), do: unique_json_items?(values, [])

  defp unique_json_items?([], _seen), do: true

  defp unique_json_items?([value | rest], seen) do
    not Enum.any?(seen, &json_equal?(value, &1)) and unique_json_items?(rest, [value | seen])
  end

  defp prefix_items(_, nil, _root, _depth), do: :ok

  defp prefix_items(value, schemas, root, depth) when is_list(schemas) do
    value
    |> Enum.zip(schemas)
    |> Enum.reduce_while(:ok, fn {item, schema}, :ok ->
      case validate_node(item, schema, root, depth + 1) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp prefix_items(_, _, _, _), do: {:error, :invalid_prefix_items}

  defp array_items(_, nil, _prefix, _additional, _root, _depth), do: :ok

  defp array_items(value, schema, prefix, _additional, root, depth)
       when is_map(schema) or is_boolean(schema) do
    prefix_count = if is_list(prefix), do: length(prefix), else: 0
    value |> Enum.drop(prefix_count) |> every_values(schema, root, depth)
  end

  defp array_items(value, schemas, _prefix, additional, root, depth) when is_list(schemas) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {item, index}, :ok ->
      schema = Enum.at(schemas, index)

      cond do
        not is_nil(schema) ->
          case validate_node(item, schema, root, depth + 1) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end

        additional in [nil, true] ->
          {:cont, :ok}

        additional == false ->
          {:halt, {:error, :additional_items}}

        is_map(additional) ->
          case validate_node(item, additional, root, depth + 1) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end

        true ->
          {:halt, {:error, :invalid_additional_items}}
      end
    end)
  end

  defp array_items(_, _, _, _, _, _), do: {:error, :invalid_items}

  defp every_values(values, schema, root, depth) do
    Enum.reduce_while(values, :ok, fn item, :ok ->
      case validate_node(item, schema, root, depth + 1) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp contains(_, schema, _root, _depth) when not is_map_key(schema, "contains"), do: :ok

  defp contains(value, schema, root, depth) do
    matches = Enum.count(value, &(validate_node(&1, schema["contains"], root, depth + 1) == :ok))
    minimum = Map.get(schema, "minContains", 1)
    maximum = Map.get(schema, "maxContains")

    if matches >= minimum and (is_nil(maximum) or matches <= maximum),
      do: :ok,
      else: {:error, :contains}
  end

  defp unevaluated_items(value, schema, root, depth) do
    case Map.fetch(schema, "unevaluatedItems") do
      :error ->
        :ok

      {:ok, true} ->
        :ok

      {:ok, false} ->
        evaluated = evaluated_indices(value, schema, root, depth)

        if value == [] or Enum.all?(0..(length(value) - 1), &MapSet.member?(evaluated, &1)),
          do: :ok,
          else: {:error, :unevaluated_items}

      {:ok, nested} when is_map(nested) ->
        evaluated = evaluated_indices(value, schema, root, depth)

        value
        |> Enum.with_index()
        |> Enum.reject(fn {_item, index} -> MapSet.member?(evaluated, index) end)
        |> Enum.reduce_while(:ok, fn {item, _index}, :ok ->
          case validate_node(item, nested, root, depth + 1) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)

      {:ok, _} ->
        {:error, :invalid_unevaluated_items}
    end
  end

  @spec evaluated_indices(list(), term(), term(), non_neg_integer()) :: MapSet.t()
  defp evaluated_indices(_value, _schema, _root, depth) when depth > @max_depth,
    do: MapSet.new()

  defp evaluated_indices(value, schema, root, depth) when is_map(schema) do
    case resolve_ref(schema, root) do
      {:ok, local} ->
        evaluated_indices_local(value, local, root, depth + 1)

      {:ref, target, siblings} ->
        evaluated_indices(value, target, root, depth + 1)
        |> MapSet.union(evaluated_indices_local(value, siblings, root, depth + 1))

      {:error, _} ->
        MapSet.new()
    end
  end

  defp evaluated_indices(_value, _schema, _root, _depth), do: MapSet.new()

  @spec evaluated_indices_local(list(), map(), term(), non_neg_integer()) :: MapSet.t()
  defp evaluated_indices_local(value, schema, root, depth) do
    prefix_count = if is_list(schema["prefixItems"]), do: length(schema["prefixItems"]), else: 0

    direct_count =
      cond do
        is_list(schema["items"]) -> min(length(value), length(schema["items"]))
        is_map(schema["items"]) or is_boolean(schema["items"]) -> length(value)
        true -> min(length(value), prefix_count)
      end

    evaluated = index_set(direct_count)

    evaluated =
      if is_list(schema["items"]) and is_map(schema["additionalItems"]) do
        extra_count = max(length(value) - length(schema["items"]), 0)
        MapSet.union(evaluated, index_set_from(length(schema["items"]), extra_count))
      else
        if is_list(schema["items"]) and schema["additionalItems"] == true,
          do: MapSet.union(evaluated, index_set(length(value))),
          else: evaluated
      end

    evaluated =
      if is_map(schema["contains"]) or is_boolean(schema["contains"]) do
        value
        |> Enum.with_index()
        |> Enum.reduce(evaluated, fn {item, index}, acc ->
          if validate_node(item, schema["contains"], root, depth + 1) == :ok,
            do: MapSet.put(acc, index),
            else: acc
        end)
      else
        evaluated
      end

    evaluated
    |> MapSet.union(successful_array_applicator(value, Map.get(schema, "allOf"), root, depth))
    |> MapSet.union(successful_array_applicator(value, Map.get(schema, "anyOf"), root, depth))
    |> MapSet.union(successful_array_applicator(value, Map.get(schema, "oneOf"), root, depth))
    |> MapSet.union(array_conditional_indices(value, schema, root, depth))
  end

  defp index_set(0), do: MapSet.new()
  defp index_set(count), do: MapSet.new(0..(count - 1))

  defp index_set_from(_start, 0), do: MapSet.new()

  defp index_set_from(start, count), do: MapSet.new(start..(start + count - 1))

  @spec successful_array_applicator(list(), term(), term(), non_neg_integer()) :: MapSet.t()
  defp successful_array_applicator(_value, nil, _root, _depth), do: MapSet.new()

  defp successful_array_applicator(value, schemas, root, depth) when is_list(schemas) do
    Enum.reduce(schemas, MapSet.new(), fn child, acc ->
      if validate_node(value, child, root, depth + 1) == :ok,
        do: MapSet.union(acc, evaluated_indices(value, child, root, depth + 1)),
        else: acc
    end)
  end

  defp successful_array_applicator(_value, _schemas, _root, _depth), do: MapSet.new()

  @spec array_conditional_indices(list(), map(), term(), non_neg_integer()) :: MapSet.t()
  defp array_conditional_indices(value, schema, root, depth) do
    case Map.fetch(schema, "if") do
      :error ->
        MapSet.new()

      {:ok, if_schema} ->
        branch =
          if validate_node(value, if_schema, root, depth + 1) == :ok,
            do: Map.get(schema, "then"),
            else: Map.get(schema, "else")

        keys = evaluated_indices(value, if_schema, root, depth + 1)

        if is_nil(branch) or validate_node(value, branch, root, depth + 1) != :ok,
          do: keys,
          else: MapSet.union(keys, evaluated_indices(value, branch, root, depth + 1))
    end
  end

  defp count(value), do: count(value, 0)

  defp count(value, n) when is_map(value),
    do: Enum.reduce(value, n + 1, fn {k, v}, acc -> count(k, count(v, acc)) end)

  defp count(value, n) when is_list(value), do: Enum.reduce(value, n + 1, &count(&1, &2))
  defp count(_, n), do: n + 1

  defp depth(value), do: depth(value, 0)

  defp depth(value, n) when is_map(value),
    do: Enum.reduce(value, n + 1, fn {_k, v}, acc -> max(acc, depth(v, n + 1)) end)

  defp depth(value, n) when is_list(value),
    do: Enum.reduce(value, n + 1, &max(&2, depth(&1, n + 1)))

  defp depth(_, n), do: n

  defp bounded_json_value(value, depth, nodes, bytes) do
    cond do
      depth > @max_json_depth or nodes <= 0 or bytes > @max_json_bytes ->
        {:error, :not_json}

      is_binary(value) ->
        if String.valid?(value) and bytes + byte_size(value) <= @max_json_bytes,
          do: {:ok, nodes - 1, bytes + byte_size(value)},
          else: {:error, :not_json}

      is_integer(value) ->
        scalar_bytes = byte_size(Integer.to_string(value))

        if bytes + scalar_bytes <= @max_json_bytes,
          do: {:ok, nodes - 1, bytes + scalar_bytes},
          else: {:error, :not_json}

      is_boolean(value) or is_nil(value) ->
        if bytes + 1 <= @max_json_bytes,
          do: {:ok, nodes - 1, bytes + 1},
          else: {:error, :not_json}

      is_float(value) ->
        if value == value and value <= 1.7976931348623157e308 and
             value >= -1.7976931348623157e308,
           do: {:ok, nodes - 1, bytes},
           else: {:error, :not_json}

      is_list(value) ->
        bounded_json_children(value, depth + 1, nodes - 1, bytes)

      is_map(value) ->
        with true <- depth <= @max_json_depth,
             {:ok, nodes, bytes} <- bounded_json_map_children(value, depth + 1, nodes - 1, bytes) do
          {:ok, nodes, bytes}
        else
          _ -> {:error, :not_json}
        end

      true ->
        {:error, :not_json}
    end
  end

  defp bounded_json_children(children, depth, nodes, bytes) do
    Enum.reduce_while(children, {:ok, nodes, bytes}, fn child, {:ok, left, used} ->
      case bounded_json_value(child, depth, left, used) do
        {:ok, left, used} -> {:cont, {:ok, left, used}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp bounded_json_map_children(map, depth, nodes, bytes) do
    Enum.reduce_while(map, {:ok, nodes, bytes}, fn {key, value}, {:ok, left, used} ->
      if is_binary(key) and String.valid?(key) and used + byte_size(key) <= @max_json_bytes do
        case bounded_json_value(value, depth, left, used + byte_size(key)) do
          {:ok, left, used} -> {:cont, {:ok, left, used}}
          {:error, _} = error -> {:halt, error}
        end
      else
        {:halt, {:error, :not_json}}
      end
    end)
  end
end
