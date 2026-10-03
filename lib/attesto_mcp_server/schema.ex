defmodule AttestoMCP.Server.Schema do
  @moduledoc """
  Bounded JSON Schema 2020-12 and draft-07 validation.

  JSV evaluates the declared dialect, including reference scope and evaluation
  annotations. Network resolvers and data casting are disabled. Format
  assertions remain enabled for compatibility; pass `formats: false` to use
  the dialect's format annotation semantics. Defaults remain annotations unless
  explicitly applied.
  """

  @max_depth 32
  @max_nodes 500
  @max_json_depth 64
  @max_json_nodes 10_000
  @min_json_bytes 512
  @default_json_bytes 2_000_000
  @max_json_bytes 64_000_000
  @max_default_applications 500
  @operation_timeout_ms 1_000
  @default_dialect "https://json-schema.org/draft/2020-12/schema"
  @supported_dialects [
    @default_dialect,
    "http://json-schema.org/draft-07/schema#",
    "http://json-schema.org/draft-07/schema",
    "https://json-schema.org/draft-07/schema#",
    "https://json-schema.org/draft-07/schema"
  ]
  @schema_maps ~w($defs definitions properties patternProperties dependentSchemas)
  @schema_arrays ~w(allOf anyOf oneOf prefixItems)
  @schema_values ~w(additionalProperties unevaluatedProperties propertyNames items additionalItems contains unevaluatedItems not if then else)

  def max_instance_bytes, do: @default_json_bytes
  def max_allowed_instance_bytes, do: @max_json_bytes
  def min_allowed_instance_bytes, do: @min_json_bytes
  def default_instance_bytes, do: @default_json_bytes

  @doc "Validates the original JSON instance without casting or inserting defaults."
  @spec validate(term(), term(), keyword()) :: :ok | {:error, term()}
  def validate(value, schema, opts \\ [])
  def validate(value, nil, opts), do: json_value(value, opts)
  def validate(value, true, opts), do: json_value(value, opts)
  def validate(_value, false, _opts), do: {:error, :schema_false}

  def validate(value, schema, opts) when is_map(schema) do
    with :ok <- json_value(value, opts),
         {:ok, root} <- build_schema(schema, opts) do
      run_bounded(fn ->
        case JSV.validate(normalize_numbers(value), root, cast: false, cast_formats: false) do
          {:ok, _original} -> :ok
          {:error, error} -> {:error, validation_reason(error)}
        end
      end)
    end
  end

  def validate(_, _, _), do: {:error, :invalid_schema}

  @doc """
  Applies bounded, direct JSON Schema property defaults and validates the result.

  Only defaults reached through literal `properties` entries are applied. The
  helper recurses into existing object properties and objects supplied by an
  explicit property default. It does not infer defaults through references,
  combinators, conditionals, array items, or pattern properties, and it never
  creates an absent parent object unless that property declares its own
  `default`.

  Presence is determined with `Map.has_key?/2`, so `nil`, `false`, zero, and an
  empty string are never replaced. At most 500 defaults are applied, and the
  completed value must satisfy the normal depth, node, byte, and schema bounds.
  Server dispatch never calls this helper automatically.
  """
  @spec apply_property_defaults(map(), map() | boolean(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def apply_property_defaults(value, schema, opts \\ [])

  def apply_property_defaults(value, schema, opts) when is_map(value) do
    max_bytes = configured_max_bytes(opts)
    validation_opts = Keyword.put(opts, :max_bytes, max_bytes)

    with :ok <- validate_schema(schema, validation_opts),
         :ok <- json_value(value, validation_opts),
         {:ok, completed, _remaining} <-
           apply_property_defaults_node(value, schema, @max_default_applications, 0),
         :ok <- json_value(completed, validation_opts),
         :ok <- validate(completed, schema, validation_opts) do
      {:ok, completed}
    end
  end

  def apply_property_defaults(_value, _schema, _opts), do: {:error, :invalid_instance}

  @doc false
  @spec atomize_property_keys(term(), map() | boolean()) :: term()
  def atomize_property_keys(value, schema)

  def atomize_property_keys(value, schema) when is_map(value) and is_map(schema) do
    properties = Map.get(schema, "properties", %{})

    if is_map(properties) do
      Map.new(value, fn {key, nested} ->
        case Map.fetch(properties, key) do
          {:ok, property_schema} ->
            {existing_property_atom(key), atomize_property_keys(nested, property_schema)}

          :error ->
            {key, nested}
        end
      end)
    else
      value
    end
  end

  def atomize_property_keys(value, schema) when is_list(value) and is_map(schema) do
    prefix_items = Map.get(schema, "prefixItems", [])
    items = Map.get(schema, "items")

    value
    |> Enum.with_index()
    |> Enum.map(fn {item, index} ->
      case item_schema(prefix_items, items, index) do
        nil -> item
        item_schema -> atomize_property_keys(item, item_schema)
      end
    end)
  end

  def atomize_property_keys(value, _schema), do: value

  defp item_schema(prefix_items, items, index) when is_list(prefix_items) do
    case Enum.fetch(prefix_items, index) do
      {:ok, schema} -> schema
      :error -> items
    end
  end

  defp item_schema(_prefix_items, items, _index), do: items

  # Never create atoms from schemas or client input. A host that wants an atom
  # key already references that atom in compiled application code; otherwise
  # the declared key remains a string.
  defp existing_property_atom(property) when is_binary(property) do
    String.to_existing_atom(property)
  rescue
    ArgumentError -> property
  end

  defp existing_property_atom(property), do: property

  @doc "Checks the schema's declared dialect without fetching network references."
  @spec validate_schema(term(), keyword()) :: :ok | {:error, term()}
  def validate_schema(schema, opts \\ [])
  def validate_schema(schema, _opts) when is_boolean(schema), do: :ok

  def validate_schema(schema, opts) when is_map(schema) do
    case build_schema(schema, opts) do
      {:ok, _root} -> :ok
      {:error, _} = error -> error
    end
  end

  def validate_schema(_, _), do: {:error, :invalid_schema}

  defp build_schema(schema, opts) do
    max_bytes = configured_max_bytes(opts)

    with :ok <- bounded(schema),
         :ok <- json_value(schema, max_bytes: max_bytes),
         :ok <- validate_anchor_names(schema),
         {:ok, prepared} <- prepare_schema(schema) do
      dialect = Map.get(prepared, "$schema", @default_dialect)
      meta = meta_root(dialect)

      run_bounded(fn ->
        case JSV.validate(normalize_numbers(schema), meta, cast: false, cast_formats: false) do
          {:ok, _} ->
            case JSV.build(normalize_numbers(compilation_schema(prepared)),
                   resolver: [],
                   atoms: false,
                   formats: format_validators(opts),
                   vocabularies: draft7_vocabularies(),
                   warnings: :silence
                 ) do
              {:ok, root} ->
                {:ok, root}

              {:error, %JSV.BuildError{reason: {:resolver_error, _}}} ->
                {:error, :remote_ref_disabled}

              {:error, _} ->
                {:error, :invalid_schema}
            end

          {:error, error} ->
            {:error, schema_reason(error)}
        end
      end)
    end
  end

  defp format_validators(opts) do
    if Keyword.get(opts, :formats, true) == true,
      do: [AttestoMCP.Server.Schema.Formats | JSV.default_format_validator_modules()],
      else: nil
  end

  # Only fixed, embedded meta-schemas are cached; user schemas never enter a
  # global cache. No network resolver is installed, including for $schema.
  defp meta_root(dialect) do
    key = {__MODULE__, :meta, dialect}

    case :persistent_term.get(key, nil) do
      nil ->
        :global.trans(
          {key, self()},
          fn ->
            case :persistent_term.get(key, nil) do
              nil ->
                root =
                  JSV.build!(%{"$ref" => dialect}, resolver: [], atoms: false, warnings: :silence)

                :persistent_term.put(key, root)
                root

              root ->
                root
            end
          end,
          [node()]
        )

      root ->
        root
    end
  end

  defp bounded(schema) do
    cond do
      Map.get(schema, "$schema", @default_dialect) not in @supported_dialects ->
        {:error, :unsupported_dialect}

      true ->
        case schema_limits(schema, 0, @max_nodes) do
          {:ok, _remaining} -> :ok
          error -> error
        end
    end
  end

  defp schema_limits(_value, depth, _remaining) when depth > @max_depth,
    do: {:error, :schema_too_deep}

  defp schema_limits(_value, _depth, 0), do: {:error, :schema_too_complex}

  defp schema_limits(value, depth, _remaining)
       when (is_map(value) or is_list(value)) and depth >= @max_depth,
       do: {:error, :schema_too_deep}

  defp schema_limits(value, depth, remaining) when is_map(value) do
    Enum.reduce_while(value, {:ok, remaining - 1}, fn {key, child}, {:ok, left} ->
      with {:ok, left} <- schema_limits(key, depth + 1, left),
           {:ok, next} <- schema_limits(child, depth + 1, left) do
        {:cont, {:ok, next}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp schema_limits(value, depth, remaining) when is_list(value) do
    Enum.reduce_while(value, {:ok, remaining - 1}, fn child, {:ok, left} ->
      case schema_limits(child, depth + 1, left) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  defp schema_limits(_, _, remaining), do: {:ok, remaining - 1}

  # Strip validator-specific casting instructions from actual schema nodes.
  # Unknown annotations, const/enum/default values and property names stay intact.
  defp prepare_schema(schema),
    do: prepare_schema(schema, Map.get(schema, "$schema", @default_dialect))

  defp prepare_schema(schema, _dialect) when is_boolean(schema), do: {:ok, schema}

  defp prepare_schema(schema, dialect) when is_map(schema) do
    ignored =
      if draft7?(dialect),
        do: ~w(jsv-cast x-jsv-cast $anchor $dynamicAnchor),
        else: ~w(jsv-cast x-jsv-cast)

    schema
    |> Map.drop(ignored)
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      result =
        cond do
          key in @schema_maps and is_map(value) ->
            prepare_map(value, dialect)

          key in @schema_arrays and is_list(value) ->
            prepare_list(value, dialect)

          key in @schema_values and is_list(value) ->
            prepare_list(value, dialect)

          key in @schema_values and (is_map(value) or is_boolean(value)) ->
            prepare_schema(value, dialect)

          key == "dependencies" and is_map(value) ->
            prepare_dependencies(value, dialect)

          true ->
            {:ok, value}
        end

      case result do
        {:ok, prepared} -> {:cont, {:ok, Map.put(acc, key, prepared)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp prepare_schema(other, _dialect), do: {:ok, other}

  # Defaults are literal annotation data. JSV's resolver scans them for schema
  # identifiers even though casting/default insertion is disabled. Remove them
  # only from its private copy, and retain all defaults whenever a JSON Pointer
  # could address one. The public defaults helper always uses the original.
  defp compilation_schema(schema) do
    if default_pointer?(schema), do: schema, else: remove_default_annotations(schema)
  end

  defp default_pointer?(value) when is_map(value) do
    Enum.any?(value, fn
      {key, reference} when key in ["$ref", "$dynamicRef"] and is_binary(reference) ->
        case URI.parse(reference).fragment do
          "/" <> pointer ->
            pointer |> URI.decode() |> String.split("/") |> Enum.member?("default")

          _ ->
            false
        end

      {_, child} ->
        default_pointer?(child)
    end)
  end

  defp default_pointer?(value) when is_list(value), do: Enum.any?(value, &default_pointer?/1)
  defp default_pointer?(_), do: false

  defp remove_default_annotations(schema) when is_map(schema) do
    schema
    |> Map.delete("default")
    |> Map.new(fn {key, value} ->
      prepared =
        cond do
          key in @schema_maps and is_map(value) ->
            Map.new(value, fn {name, child} -> {name, remove_default_annotations(child)} end)

          (key in @schema_arrays or key in @schema_values) and is_list(value) ->
            Enum.map(value, &remove_default_annotations/1)

          key in @schema_values ->
            remove_default_annotations(value)

          key == "dependencies" and is_map(value) ->
            Map.new(value, fn {name, child} -> {name, remove_default_annotations(child)} end)

          true ->
            value
        end

      {key, prepared}
    end)
  end

  defp remove_default_annotations(other), do: other

  defp prepare_map(map, dialect) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case prepare_schema(value, dialect) do
        {:ok, prepared} -> {:cont, {:ok, Map.put(acc, key, prepared)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp prepare_list(list, dialect) do
    Enum.reduce_while(list, {:ok, []}, fn value, {:ok, acc} ->
      case prepare_schema(value, dialect) do
        {:ok, prepared} -> {:cont, {:ok, [prepared | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp prepare_dependencies(map, dialect) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case if(is_map(value) or is_boolean(value),
             do: prepare_schema(value, dialect),
             else: {:ok, value}
           ) do
        {:ok, prepared} -> {:cont, {:ok, Map.put(acc, key, prepared)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp draft7?(dialect), do: dialect != @default_dialect

  defp draft7_vocabularies do
    %{
      "https://json-schema.org/draft-07/--fallback--vocab/applicator" =>
        AttestoMCP.Server.Schema.Draft7Applicator,
      "https://json-schema.org/draft-07/--fallback--vocab/validation" =>
        AttestoMCP.Server.Schema.Draft7Validation
    }
  end

  defp validate_anchor_names(schema) do
    dialect = Map.get(schema, "$schema", @default_dialect)
    base = "https://attesto.invalid/schema"
    resources = collect_resources(schema, base, schema, dialect, %{})

    case collect_anchors(schema, base, [], %{}, schema, dialect, resources) do
      {:ok, anchors} ->
        validate_anchor_references(schema, base, schema, dialect, resources, anchors)

      error ->
        error
    end
  rescue
    ArgumentError -> {:error, :invalid_schema}
  end

  defp collect_resources(schema, base, parent_resource, dialect, resources) when is_map(schema) do
    {base, resource} = schema_resource(schema, base, parent_resource)
    resources = Map.put(resources, base, resource)

    Enum.reduce(schema_children(schema, dialect), resources, fn {_, _, child}, acc ->
      collect_resources(child, base, resource, dialect, acc)
    end)
  end

  defp collect_resources(_, _, _, _, resources), do: resources

  defp collect_anchors(schema, base, path, anchors, parent_resource, dialect, resources)
       when is_map(schema) do
    parent_base = base
    {base, resource} = schema_resource(schema, base, parent_resource)
    # Draft-07 reference objects ignore sibling keywords, including a nested
    # $id; a reference on the resource root still uses that resource's base.
    ignored_sibling_id =
      draft7?(dialect) and schema != parent_resource and Map.has_key?(schema, "$ref")

    pointer_resource = if ignored_sibling_id, do: parent_resource, else: resource
    pointer_base = if ignored_sibling_id, do: parent_base, else: base

    with :ok <- pattern_budget(schema),
         :ok <-
           validate_pointer_indexes(schema, pointer_base, pointer_resource, dialect, resources),
         {:ok, anchors} <- add_anchors(schema, base, path, anchors, dialect) do
      Enum.reduce_while(schema_children(schema, dialect), {:ok, anchors}, fn {key, name, child},
                                                                             {:ok, acc} ->
        case collect_anchors(child, base, [key, name | path], acc, resource, dialect, resources) do
          {:ok, next} -> {:cont, {:ok, next}}
          error -> {:halt, error}
        end
      end)
    end
  rescue
    ArgumentError -> {:error, :invalid_schema}
  end

  defp collect_anchors(_schema, _base, _path, anchors, _resource, _dialect, _resources),
    do: {:ok, anchors}

  defp schema_resource(schema, base, parent_resource) do
    case schema["$id"] do
      id when is_binary(id) ->
        uri = reference_uri(base, id)
        resolved = URI.to_string(%{uri | fragment: nil})
        # A draft-07 plain-name fragment is an anchor within the enclosing
        # resource; it is not a new document for JSON Pointer resolution.
        if String.starts_with?(id, "#"), do: {base, parent_resource}, else: {resolved, schema}

      _ ->
        {base, parent_resource}
    end
  end

  # Elixir 1.18 URI.merge/2 rejects hostless absolute bases such as URNs.
  # Resolve namespaces with the same rules as the compiler, retaining the
  # reference fragment for our local anchor and JSON Pointer checks.
  defp reference_uri(base, reference) do
    case JSV.RNS.derive(base, reference) do
      {:ok, namespace} ->
        %{URI.parse(namespace) | fragment: URI.parse(reference).fragment}

      {:error, reason} ->
        raise ArgumentError, "invalid schema reference: #{inspect(reason)}"
    end
  end

  defp add_anchors(schema, base, path, anchors, dialect) when dialect != @default_dialect do
    case schema["$id"] do
      "#" <> anchor when anchor != "" -> {:ok, Map.put(anchors, {base, anchor}, path)}
      _ -> {:ok, anchors}
    end
  end

  defp add_anchors(schema, base, path, anchors, _dialect) do
    Enum.reduce_while(["$anchor", "$dynamicAnchor"], {:ok, anchors}, fn key, {:ok, acc} ->
      case schema[key] do
        anchor when is_binary(anchor) ->
          case Map.fetch(acc, {base, anchor}) do
            {:ok, other_path} when other_path != path -> {:halt, {:error, :duplicate_anchor}}
            _ -> {:cont, {:ok, Map.put(acc, {base, anchor}, path)}}
          end

        _ ->
          {:cont, {:ok, acc}}
      end
    end)
  end

  # The resolver must not turn an identifier inside an unrelated annotation
  # into an active schema anchor. Only dialect-defined schema locations count.
  defp validate_anchor_references(schema, base, parent_resource, dialect, resources, anchors)
       when is_map(schema) do
    parent_base = base
    {base, resource} = schema_resource(schema, base, parent_resource)

    reference_base =
      if draft7?(dialect) and schema != parent_resource and Map.has_key?(schema, "$ref"),
        do: parent_base,
        else: base

    keys = if draft7?(dialect), do: ["$ref"], else: ["$ref", "$dynamicRef"]

    references =
      Enum.reduce_while(keys, :ok, fn key, :ok ->
        case schema[key] do
          reference when is_binary(reference) ->
            uri = reference_uri(reference_base, reference)
            namespace = URI.to_string(%{uri | fragment: nil})

            if is_binary(uri.fragment) and uri.fragment != "" and
                 not String.starts_with?(uri.fragment, "/") and
                 Map.has_key?(resources, namespace) and
                 not Map.has_key?(anchors, {namespace, URI.decode(uri.fragment)}),
               do: {:halt, {:error, :unresolved_ref}},
               else: {:cont, :ok}

          _ ->
            {:cont, :ok}
        end
      end)

    with :ok <- references do
      Enum.reduce_while(schema_children(schema, dialect), :ok, fn {_, _, child}, :ok ->
        case validate_anchor_references(child, base, resource, dialect, resources, anchors) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp validate_anchor_references(_, _, _, _, _, _), do: :ok

  defp schema_children(schema, dialect) do
    maps =
      if draft7?(dialect), do: ~w(definitions properties patternProperties), else: @schema_maps

    arrays = if draft7?(dialect), do: ~w(allOf anyOf oneOf), else: @schema_arrays

    values =
      if draft7?(dialect),
        do:
          ~w(additionalProperties propertyNames items additionalItems contains not if then else),
        else: @schema_values

    Enum.flat_map(schema, fn {key, value} ->
      cond do
        key in maps and is_map(value) ->
          Enum.map(value, fn {name, child} -> {key, name, child} end)

        key in arrays and is_list(value) ->
          value |> Enum.with_index() |> Enum.map(fn {child, index} -> {key, index, child} end)

        key in values and is_list(value) ->
          value |> Enum.with_index() |> Enum.map(fn {child, index} -> {key, index, child} end)

        key in values ->
          [{key, nil, value}]

        key == "dependencies" and is_map(value) ->
          Enum.map(value, fn {name, child} -> {key, name, child} end)

        true ->
          []
      end
    end)
  end

  defp pattern_budget(schema) do
    patterns =
      [Map.get(schema, "pattern")] ++
        if is_map(schema["patternProperties"]),
          do: Map.keys(schema["patternProperties"]),
          else: []

    if Enum.any?(patterns, &(is_binary(&1) and byte_size(&1) > 256)),
      do: {:error, :invalid_pattern},
      else: :ok
  end

  # JSON numbers compare by mathematical value, including nested enum/const
  # values and uniqueItems. The original input is never changed or returned.
  defp normalize_numbers(value) when is_float(value) do
    if trunc(value) == value, do: trunc(value), else: value
  end

  defp normalize_numbers(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, normalize_numbers(item)} end)

  defp normalize_numbers(value) when is_list(value), do: Enum.map(value, &normalize_numbers/1)
  defp normalize_numbers(value), do: value

  # JSON Pointer array indexes cannot have leading zeroes. Map keys may.
  defp validate_pointer_indexes(schema, base, resource, dialect, resources) do
    keys = if draft7?(dialect), do: ["$ref"], else: ["$ref", "$dynamicRef"]

    Enum.reduce_while(keys, :ok, fn key, :ok ->
      case schema[key] do
        reference when is_binary(reference) ->
          uri = reference_uri(base, reference)
          namespace = URI.to_string(%{uri | fragment: nil})

          target =
            if String.starts_with?(reference, "#"), do: resource, else: resources[namespace]

          case {uri.fragment, target} do
            {"/" <> pointer, target} when is_map(target) ->
              tokens =
                pointer
                |> URI.decode()
                |> String.split("/")
                |> Enum.map(&(String.replace(&1, "~1", "/") |> String.replace("~0", "~")))

              case pointer_index_walk(target, tokens) do
                :invalid_index -> {:halt, {:error, :unresolved_ref}}
                _ -> {:cont, :ok}
              end

            _ ->
              {:cont, :ok}
          end

        _ ->
          {:cont, :ok}
      end
    end)
  end

  defp pointer_index_walk(_value, []), do: :ok

  defp pointer_index_walk(value, [key | rest]) when is_map(value) do
    case Map.fetch(value, key) do
      {:ok, child} -> pointer_index_walk(child, rest)
      :error -> :unresolved
    end
  end

  defp pointer_index_walk(value, [index | rest]) when is_list(value) do
    if Regex.match?(~r/^(0|[1-9][0-9]*)$/, index) do
      case Enum.fetch(value, String.to_integer(index)) do
        {:ok, child} -> pointer_index_walk(child, rest)
        :error -> :unresolved
      end
    else
      :invalid_index
    end
  end

  defp pointer_index_walk(_, _), do: :unresolved

  # Bound compilation and validation as well as bytes/depth. A reference cycle
  # or expensive composition cannot retain the caller indefinitely. Exceptions
  # are converted inside the task so its link cannot terminate the caller.
  defp run_bounded(operation) do
    task =
      Task.async(fn ->
        try do
          operation.()
        rescue
          _ -> {:error, :invalid_schema}
        catch
          _, _ -> {:error, :invalid_schema}
        end
      end)

    case Task.yield(task, @operation_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, :schema_validation_timeout}
    end
  end

  defp schema_reason(%JSV.ValidationError{errors: errors}) do
    error =
      errors
      |> flatten_errors()
      |> Enum.reverse()
      |> Enum.find(&is_binary(List.first(&1.data_path)))

    case error do
      nil -> :invalid_schema
      %{data_path: [keyword | _]} -> {:invalid_keyword, keyword}
    end
  end

  defp flatten_errors(errors) do
    Enum.flat_map(errors, fn error ->
      nested = Keyword.get(error.args, :invalidated, [])

      children =
        Enum.flat_map(nested, fn
          {_index, %{errors: children}} -> flatten_errors(children)
          _ -> []
        end)

      [error | children]
    end)
  end

  defp validation_reason(%JSV.ValidationError{errors: errors}) do
    flattened = flatten_errors(errors)
    structural = Enum.find(errors, &(&1.kind in [:anyOf, :oneOf, :not]))

    additional =
      Enum.filter(
        flattened,
        &(&1.kind == :additionalProperties and Keyword.get(&1.args, :boolean_schema_false))
      )

    error = structural || Enum.find(flattened, &unevaluated_error?/1) || List.last(flattened)

    cond do
      structural ->
        compatible_validation_reason(structural, flattened, errors)

      additional != [] ->
        {:additional_properties,
         additional |> Enum.map(&Keyword.get(&1.args, :key)) |> Enum.uniq() |> Enum.sort()}

      true ->
        compatible_validation_reason(error, flattened, errors)
    end
  end

  defp unevaluated_error?(%{schema_path: path}),
    do:
      Enum.any?(
        path,
        &(&1 in [
            :unevaluatedItems,
            :unevaluatedProperties,
            "unevaluatedItems",
            "unevaluatedProperties"
          ])
      )

  defp compatible_validation_reason(%{kind: :type, args: args}, _flattened, _errors),
    do: {:type, type_name(Keyword.get(args, :type))}

  defp compatible_validation_reason(
         %{kind: :required, args: args, data: data},
         _flattened,
         _errors
       ),
       do: {:required, Enum.reject(Keyword.get(args, :required, []), &Map.has_key?(data, &1))}

  defp compatible_validation_reason(%{kind: :dependentRequired, args: args}, _flattened, _errors),
    do: {:required, Keyword.get(args, :missing, [])}

  defp compatible_validation_reason(
         %{schema_path: path, data_path: data_path, kind: :boolean_schema},
         flattened,
         _errors
       ) do
    cond do
      :unevaluatedItems in path or "unevaluatedItems" in path ->
        :unevaluated_items

      :unevaluatedProperties in path or "unevaluatedProperties" in path ->
        keys =
          flattened
          |> Enum.filter(
            &(&1.kind == :boolean_schema and &1.schema_path == path and
                tl(&1.data_path) == tl(data_path))
          )
          |> Enum.map(&hd(&1.data_path))
          |> Enum.uniq()
          |> Enum.sort()

        {:unevaluated_properties, keys}

      :additionalItems in path ->
        :additional_items

      true ->
        :schema_false
    end
  end

  defp compatible_validation_reason(%{kind: kind}, _flattened, errors) do
    case kind do
      :enum -> :not_in_enum
      :const -> :const_mismatch
      :uniqueItems -> :unique_items
      :minimum -> :minimum
      :maximum -> :maximum
      :exclusiveMinimum -> :exclusive_minimum
      :exclusiveMaximum -> :exclusive_maximum
      :multipleOf -> :multiple_of
      :minLength -> :min_length
      :maxLength -> :max_length
      :pattern -> :pattern_mismatch
      :minProperties -> :min_properties
      :maxProperties -> :max_properties
      :minItems -> :min_items
      :maxItems -> :max_items
      :minContains -> :contains
      :maxContains -> :contains
      :unevaluatedItems -> :unevaluated_items
      :format -> :format
      :anyOf -> {:any, :mismatch}
      :oneOf -> {:one, :mismatch}
      :not -> :not_allowed
      _ -> {:schema_validation, JSV.normalize_error(%JSV.ValidationError{errors: errors})}
    end
  end

  defp type_name(type) when is_atom(type), do: Atom.to_string(type)
  defp type_name(types), do: types

  @doc "Checks that a term can be represented losslessly as JSON."
  @spec json_value(term(), keyword()) :: :ok | {:error, :not_json}
  def json_value(value, opts \\ []) do
    max_bytes = configured_max_bytes(opts)

    case bounded_json_value(value, 0, @max_json_nodes, 0, max_bytes) do
      {:ok, _nodes, _bytes} ->
        case Jason.encode(value) do
          {:ok, encoded} when byte_size(encoded) <= max_bytes -> :ok
          _ -> {:error, :not_json}
        end

      {:error, _} = error ->
        error
    end
  end

  defp apply_property_defaults_node(value, schema, remaining, depth)
       when is_map(value) and is_map(schema) and depth <= @max_depth do
    case Map.get(schema, "properties") do
      properties when is_map(properties) ->
        Enum.reduce_while(properties, {:ok, value, remaining}, fn {property, property_schema},
                                                                  {:ok, acc, left} ->
          apply_property_default(acc, property, property_schema, left, depth)
        end)

      _other ->
        {:ok, value, remaining}
    end
  end

  defp apply_property_defaults_node(value, _schema, remaining, _depth),
    do: {:ok, value, remaining}

  defp apply_property_default(value, property, property_schema, remaining, depth) do
    cond do
      Map.has_key?(value, property) ->
        current = Map.fetch!(value, property)

        case apply_property_defaults_node(current, property_schema, remaining, depth + 1) do
          {:ok, ^current, left} -> {:cont, {:ok, value, left}}
          {:ok, completed, left} -> {:cont, {:ok, Map.put(value, property, completed), left}}
          {:error, _reason} = error -> {:halt, error}
        end

      is_map(property_schema) and Map.has_key?(property_schema, "default") and remaining > 0 ->
        default = Map.fetch!(property_schema, "default")

        case apply_property_defaults_node(default, property_schema, remaining - 1, depth + 1) do
          {:ok, completed, left} -> {:cont, {:ok, Map.put(value, property, completed), left}}
          {:error, _reason} = error -> {:halt, error}
        end

      is_map(property_schema) and Map.has_key?(property_schema, "default") ->
        {:halt, {:error, :default_application_limit}}

      true ->
        {:cont, {:ok, value, remaining}}
    end
  end

  @doc "Validates the bounded modern result variants emitted by this package."
  @spec validate_modern_result(map(), keyword()) :: :ok | {:error, term()}
  def validate_modern_result(result, opts \\ [])

  def validate_modern_result(%{"resultType" => "complete"} = result, opts) when is_map(result) do
    with :ok <- json_value(result, opts),
         :ok <- optional_nonnegative_integer(result, "ttlMs"),
         :ok <- optional_cache_scope(result),
         :ok <- optional_result_catalog(result) do
      :ok
    end
  end

  def validate_modern_result(
        %{
          "resultType" => "input_required",
          "inputRequests" => requests,
          "requestState" => state
        } = result,
        opts
      )
      when is_map(requests) and is_binary(state) and map_size(requests) > 0 do
    if json_value(result, opts) == :ok and
         Enum.all?(requests, fn {key, request} ->
           is_binary(key) and byte_size(key) in 1..128 and is_map(request) and
             request["method"] in ["elicitation/create", "sampling/createMessage", "roots/list"] and
             is_map(request["params"])
         end) and is_binary(state) and byte_size(state) <= 4096,
       do: :ok,
       else: {:error, :invalid_input_requests}
  end

  def validate_modern_result(_, _opts), do: {:error, :invalid_modern_result}

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

  defp bounded_json_value(value, depth, nodes, bytes, max_bytes) do
    cond do
      depth > @max_json_depth or nodes <= 0 or bytes > max_bytes ->
        {:error, :not_json}

      is_binary(value) ->
        if String.valid?(value) and bytes + byte_size(value) <= max_bytes,
          do: {:ok, nodes - 1, bytes + byte_size(value)},
          else: {:error, :not_json}

      is_integer(value) ->
        scalar_bytes = byte_size(Integer.to_string(value))

        if bytes + scalar_bytes <= max_bytes,
          do: {:ok, nodes - 1, bytes + scalar_bytes},
          else: {:error, :not_json}

      is_boolean(value) or is_nil(value) ->
        if bytes + 1 <= max_bytes,
          do: {:ok, nodes - 1, bytes + 1},
          else: {:error, :not_json}

      is_float(value) ->
        if value == value and value <= 1.7976931348623157e308 and
             value >= -1.7976931348623157e308,
           do: {:ok, nodes - 1, bytes},
           else: {:error, :not_json}

      is_list(value) ->
        bounded_json_children(value, depth + 1, nodes - 1, bytes, max_bytes)

      is_map(value) ->
        with true <- depth <= @max_json_depth,
             {:ok, nodes, bytes} <-
               bounded_json_map_children(value, depth + 1, nodes - 1, bytes, max_bytes) do
          {:ok, nodes, bytes}
        else
          _ -> {:error, :not_json}
        end

      true ->
        {:error, :not_json}
    end
  end

  defp bounded_json_children(children, depth, nodes, bytes, max_bytes) do
    Enum.reduce_while(children, {:ok, nodes, bytes}, fn child, {:ok, left, used} ->
      case bounded_json_value(child, depth, left, used, max_bytes) do
        {:ok, left, used} -> {:cont, {:ok, left, used}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp bounded_json_map_children(map, depth, nodes, bytes, max_bytes) do
    Enum.reduce_while(map, {:ok, nodes, bytes}, fn {key, value}, {:ok, left, used} ->
      if is_binary(key) and String.valid?(key) and used + byte_size(key) <= max_bytes do
        case bounded_json_value(value, depth, left, used + byte_size(key), max_bytes) do
          {:ok, left, used} -> {:cont, {:ok, left, used}}
          {:error, _} = error -> {:halt, error}
        end
      else
        {:halt, {:error, :not_json}}
      end
    end)
  end

  defp configured_max_bytes(opts) when is_list(opts) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_json_bytes)

    if is_integer(max_bytes) and max_bytes >= @min_json_bytes and
         max_bytes <= @max_json_bytes,
       do: max_bytes,
       else: 0
  end

  defp configured_max_bytes(_opts), do: 0
end
