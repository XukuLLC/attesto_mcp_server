defmodule AttestoMCP.Server.Registry do
  @moduledoc "Deterministic, authorization-filtered MCP primitive registry."

  @typedoc "Supported registration categories."
  @type primitive :: :tool | :resource | :template | :prompt | :completion

  @typedoc "A normalized JSON-compatible primitive definition."
  @type definition :: map()
  @typedoc "One primitive registration supplied to the atomic batch API."
  @type registration :: {primitive(), String.t(), map() | keyword()}
  use GenServer

  alias AttestoMCP.Server.Schema

  @types [:tool, :resource, :template, :prompt, :completion]
  @max_identity_bytes 256
  @max_name_bytes 64
  @max_definition_depth 64
  @max_batch_size 1_000
  @definition_key_aliases %{
    "name" => :name,
    "description" => :description,
    "input_schema" => :input_schema,
    "inputSchema" => :input_schema,
    "output_schema" => :output_schema,
    "outputSchema" => :output_schema,
    "annotations" => :annotations,
    "required_scopes" => :required_scopes,
    "requiredScopes" => :required_scopes,
    "handler" => :handler,
    "authorize" => :authorize,
    "arguments" => :arguments,
    "ref" => :ref,
    "reference" => :reference,
    "uri" => :uri,
    "uri_template" => :uri_template,
    "uriTemplate" => :uri_template,
    "mime_type" => :mime_type,
    "mimeType" => :mime_type
  }

  @doc "Starts the registry; registration is serialized through this process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @doc "Validates and registers one primitive, rejecting duplicate identities."
  @spec register(pid(), primitive(), String.t(), map() | keyword()) :: :ok | {:error, term()}
  def register(pid, type, identity, definition) when type in @types do
    with {:ok, normalized} <- normalize(type, identity, definition) do
      GenServer.call(pid, {:register, type, identity, normalized})
    end
  end

  def register(_pid, _type, _identity, _definition), do: {:error, :invalid_definition}

  @doc "Validates and registers a batch atomically, returning its normalized definitions."
  @spec register_all(pid(), [registration()]) ::
          {:ok, [{primitive(), String.t(), definition()}]} | {:error, term()}
  def register_all(pid, registrations)
      when is_pid(pid) and is_list(registrations) and length(registrations) <= @max_batch_size do
    with {:ok, normalized} <- normalize_registrations(registrations) do
      GenServer.call(pid, {:register_all, normalized})
    end
  end

  def register_all(_pid, registrations) when is_list(registrations),
    do: {:error, :too_many_registrations}

  def register_all(_pid, _registrations), do: {:error, :invalid_registrations}

  @doc "Returns all normalized definitions grouped by primitive category."
  @spec snapshot(pid()) :: %{primitive() => %{optional(term()) => definition()}}
  def snapshot(pid), do: GenServer.call(pid, :snapshot)

  @doc "Returns the monotonic catalog revision used to bind cursors."
  @spec revision(pid()) :: non_neg_integer()
  def revision(pid), do: GenServer.call(pid, :revision)

  @doc "Returns definitions for one category in deterministic identity order."
  @spec list(pid(), primitive()) :: [definition()]
  def list(pid, type) when type in @types, do: GenServer.call(pid, {:list, type})

  @impl true
  def init(opts), do: {:ok, %{items: Map.new(@types, &{&1, %{}}), revision: 0, opts: opts}}

  @impl true
  def handle_call({:register, type, identity, definition}, _from, state) do
    case put_registration(state.items, {type, identity, definition}) do
      {:ok, items} ->
        {:reply, :ok, %{state | items: items, revision: state.revision + 1}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:register_all, registrations}, _from, state) do
    result =
      Enum.reduce_while(registrations, {:ok, state.items}, fn registration, {:ok, items} ->
        case put_registration(items, registration) do
          {:ok, items} -> {:cont, {:ok, items}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, items} ->
        {:reply, {:ok, registrations},
         %{
           state
           | items: items,
             revision: state.revision + length(registrations)
         }}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:snapshot, _from, state), do: {:reply, state.items, state}
  def handle_call(:revision, _from, state), do: {:reply, state.revision, state}

  def handle_call({:list, type}, _from, state) do
    {:reply, state.items[type] |> Map.values() |> Enum.sort_by(& &1.identity), state}
  end

  defp normalize_registrations(registrations) do
    Enum.reduce_while(registrations, {:ok, []}, fn
      {type, identity, definition}, {:ok, normalized} when type in @types ->
        case normalize(type, identity, definition) do
          {:ok, definition} ->
            {:cont, {:ok, [{type, identity, definition} | normalized]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end

      _registration, _acc ->
        {:halt, {:error, :invalid_registration}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_registration(items, {type, identity, definition}) do
    type_items = items[type]
    ref = definition[:ref] || definition["ref"]

    duplicate_ref =
      if type == :completion do
        Enum.any?(type_items, fn {_key, item} ->
          item[:ref] == ref and not is_nil(ref)
        end)
      else
        false
      end

    cond do
      Map.has_key?(type_items, identity) ->
        {:error, {:duplicate, type, identity}}

      duplicate_ref ->
        {:error, {:duplicate, :completion_ref, ref}}

      true ->
        {:ok, put_in(items, [type, identity], definition)}
    end
  end

  defp normalize(type, identity, definition) do
    with :ok <- valid_identity(type, identity),
         {:ok, definition} <- map_definition(definition),
         {:ok, value} <- defaults(type, identity, definition),
         {:ok, value} <- normalize_definition_values(value),
         {:ok, value} <- normalize_nested(type, value),
         :ok <- validate_common(value),
         :ok <- validate_type(type, value) do
      {:ok, value}
    end
  end

  defp map_definition(definition) when is_map(definition),
    do: canonical_definition_map(Map.to_list(definition))

  defp map_definition(definition) when is_list(definition),
    do: canonical_definition_map(definition)

  defp map_definition(_), do: {:error, {:invalid_definition, :not_a_map}}

  defp canonical_definition_map(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case canonical_definition_key(key) do
        {:ok, canonical} when not is_map_key(acc, canonical) ->
          {:cont, {:ok, Map.put(acc, canonical, value)}}

        {:ok, _canonical} ->
          {:halt, {:error, {:invalid_definition, {:conflicting_key, key}}}}

        :error ->
          {:halt, {:error, {:invalid_definition, :non_json_key}}}
      end
    end)
  end

  defp canonical_definition_key(key) when is_atom(key) or is_binary(key) do
    key = to_string(key)
    {:ok, Map.get(@definition_key_aliases, key, key)}
  end

  defp canonical_definition_key(_key), do: :error

  defp normalize_definition_values(definition) when is_map(definition) do
    Enum.reduce_while(definition, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      if key in [:handler, :authorize] and valid_callback_term?(value) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        case canonical_json_value(value) do
          {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
          {:error, _} -> {:halt, {:error, {:invalid_definition, key}}}
        end
      end
    end)
  end

  defp valid_callback_term?(value) when is_function(value), do: true

  defp valid_callback_term?({module, function})
       when is_atom(module) and is_atom(function),
       do: true

  defp valid_callback_term?({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args),
       do: true

  defp valid_callback_term?(_), do: false

  defp normalize_nested(type, definition) do
    with {:ok, definition} <- normalize_json_fields(definition, json_fields(type)),
         {:ok, definition} <- normalize_prompt_arguments(type, definition),
         {:ok, definition} <- normalize_completion_ref(type, definition) do
      {:ok, definition}
    end
  end

  defp json_fields(:tool), do: [:input_schema, :output_schema, :annotations]
  defp json_fields(:resource), do: [:annotations]
  defp json_fields(:template), do: [:annotations]
  defp json_fields(:prompt), do: [:annotations]
  defp json_fields(:completion), do: [:annotations]

  defp normalize_json_fields(definition, fields) do
    Enum.reduce_while(fields, {:ok, definition}, fn field, {:ok, acc} ->
      case Map.fetch(acc, field) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, value} ->
          case canonical_json_value(value) do
            {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
            {:error, _} -> {:halt, {:error, {:invalid_definition, field}}}
          end
      end
    end)
  end

  defp normalize_prompt_arguments(:prompt, definition) do
    case Map.fetch(definition, :arguments) do
      :error ->
        {:ok, definition}

      {:ok, arguments} when is_list(arguments) ->
        case normalize_arguments(arguments) do
          {:ok, arguments} -> {:ok, Map.put(definition, :arguments, arguments)}
          {:error, _} = error -> error
        end

      {:ok, _} ->
        {:error, {:invalid_definition, :arguments}}
    end
  end

  defp normalize_prompt_arguments(_type, definition), do: {:ok, definition}

  defp normalize_completion_ref(:completion, definition) do
    ref = Map.get(definition, :ref) || Map.get(definition, :reference)

    if Map.has_key?(definition, :ref) and Map.has_key?(definition, :reference) do
      {:error, {:invalid_definition, :completion_ref}}
    else
      normalize_completion_ref_value(definition, ref)
    end
  end

  defp normalize_completion_ref(_type, definition), do: {:ok, definition}

  defp normalize_completion_ref_value(definition, ref) do
    if is_map(ref) do
      case canonical_json_value(ref) do
        {:ok, ref} -> {:ok, Map.put(definition, :ref, ref)}
        {:error, _} -> {:error, {:invalid_definition, :completion_ref}}
      end
    else
      {:ok, definition}
    end
  end

  defp normalize_arguments(arguments) when is_list(arguments) do
    Enum.reduce_while(arguments, {:ok, []}, fn argument, {:ok, acc} ->
      with true <- is_map(argument),
           {:ok, argument} <- canonical_json_map(Map.to_list(argument)),
           true <- is_binary(argument["name"]),
           required <- Map.get(argument, "required", false),
           true <- is_boolean(required),
           description <- Map.get(argument, "description"),
           true <- is_nil(description) or is_binary(description) do
        normalized =
          %{"name" => argument["name"], "required" => required}
          |> maybe_put_string("description", description)

        {:cont, {:ok, [normalized | acc]}}
      else
        _ -> {:halt, {:error, {:invalid_definition, :arguments}}}
      end
    end)
    |> case do
      {:ok, arguments} -> {:ok, Enum.reverse(arguments)}
      error -> error
    end
  end

  defp canonical_json_map(entries), do: canonical_json_map(entries, 0)

  defp canonical_json_map(_entries, depth) when depth > @max_definition_depth,
    do: {:error, :definition_too_deep}

  defp canonical_json_map(entries, depth) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with true <- is_binary(key) or is_atom(key),
           key <- to_string(key),
           false <- Map.has_key?(acc, key),
           {:ok, value} <- canonical_json_value(value, depth + 1) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        _ -> {:halt, {:error, :conflicting_key}}
      end
    end)
  end

  defp canonical_json_value(value), do: canonical_json_value(value, 0)

  defp canonical_json_value(_value, depth) when depth > @max_definition_depth,
    do: {:error, :definition_too_deep}

  defp canonical_json_value(value, depth) when is_map(value),
    do: canonical_json_map(Map.to_list(value), depth + 1)

  defp canonical_json_value(value, depth) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn item, {:ok, acc} ->
      case canonical_json_value(item, depth + 1) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp canonical_json_value(value, _depth)
       when is_binary(value) or is_boolean(value) or is_nil(value) or is_integer(value),
       do: {:ok, value}

  defp canonical_json_value(value, _depth) when is_float(value) and value == value,
    do: {:ok, value}

  defp canonical_json_value(_value, _depth), do: {:error, :not_json}

  defp maybe_put_string(map, _key, nil), do: map
  defp maybe_put_string(map, key, value), do: Map.put(map, key, value)

  defp defaults(:tool, identity, definition) do
    {:ok,
     Map.merge(
       %{
         identity: identity,
         name: identity,
         description: "Tool " <> identity,
         input_schema: %{"type" => "object"},
         output_schema: nil,
         annotations: %{},
         required_scopes: [],
         handler: nil
       },
       definition
     )}
  end

  defp defaults(:resource, identity, definition) do
    {:ok,
     Map.merge(
       %{
         identity: identity,
         uri: identity,
         name: identity,
         mime_type: nil,
         annotations: %{},
         required_scopes: [],
         handler: nil
       },
       definition
     )}
  end

  defp defaults(:template, identity, definition) do
    {:ok,
     Map.merge(
       %{
         identity: identity,
         uri_template: identity,
         name: identity,
         description: "",
         mime_type: nil,
         annotations: %{},
         required_scopes: [],
         handler: nil
       },
       definition
     )}
  end

  defp defaults(:prompt, identity, definition) do
    {:ok,
     Map.merge(
       %{
         identity: identity,
         name: identity,
         description: "",
         annotations: %{},
         arguments: [],
         required_scopes: [],
         handler: nil
       },
       definition
     )}
  end

  defp defaults(:completion, identity, definition) do
    {:ok,
     Map.merge(
       %{identity: identity, name: identity, annotations: %{}, required_scopes: [], handler: nil},
       definition
     )}
  end

  defp validate_common(value) do
    with :ok <- valid_text(value[:name], :name),
         :ok <- valid_scopes(value[:required_scopes]),
         :ok <- valid_annotations(value[:annotations]),
         :ok <- valid_metadata(value),
         :ok <- valid_authorize(value[:authorize]),
         :ok <- valid_handler(value[:handler]) do
      :ok
    else
      {:error, _} = error -> error
    end
  end

  defp valid_description(value) when is_binary(value) and byte_size(value) in 1..4_096 do
    if String.valid?(value) and String.trim(value) != "",
      do: :ok,
      else: {:error, {:invalid_definition, :description}}
  end

  defp valid_description(_), do: {:error, {:invalid_definition, :description}}

  defp valid_annotations(value) when is_map(value) do
    case Schema.json_value(value) do
      :ok -> valid_annotation_fields(value)
      _ -> {:error, {:invalid_definition, :annotations}}
    end
  end

  defp valid_annotations(_), do: {:error, {:invalid_definition, :annotations}}

  defp valid_metadata(value) do
    title = value[:title] || value["title"]
    icons = value[:icons] || value["icons"]
    meta = value[:_meta] || value["_meta"]
    size = value[:size] || value["size"]

    with :ok <- optional_metadata_string(title, :title),
         :ok <- optional_icons(icons),
         :ok <- optional_json_metadata(meta),
         :ok <- optional_size(size) do
      :ok
    end
  end

  defp optional_metadata_string(nil, _field), do: :ok

  defp optional_metadata_string(value, _field) when is_binary(value) and byte_size(value) > 0,
    do: :ok

  defp optional_metadata_string(_, field), do: {:error, {:invalid_definition, field}}

  defp optional_icons(nil), do: :ok

  defp optional_icons(icons) when is_list(icons) do
    if Enum.all?(icons, fn icon ->
         is_map(icon) and is_binary(icon["src"]) and icon["src"] != "" and
           (is_nil(icon["mimeType"]) or is_binary(icon["mimeType"])) and
           (is_nil(icon["theme"]) or icon["theme"] in ["light", "dark"]) and
           (is_nil(icon["sizes"]) or
              (is_list(icon["sizes"]) and Enum.all?(icon["sizes"], &is_binary/1)))
       end),
       do: :ok,
       else: {:error, {:invalid_definition, :icons}}
  end

  defp optional_icons(_), do: {:error, {:invalid_definition, :icons}}

  defp optional_json_metadata(nil), do: :ok

  defp optional_json_metadata(value) do
    if Schema.json_value(value) == :ok,
      do: :ok,
      else: {:error, {:invalid_definition, :_meta}}
  end

  defp optional_size(nil), do: :ok
  defp optional_size(value) when is_integer(value) and value >= 0, do: :ok
  defp optional_size(_), do: {:error, {:invalid_definition, :size}}

  defp valid_annotation_fields(value) do
    audience = value[:audience] || value["audience"]
    priority = value[:priority] || value["priority"]
    boolean_hints = ["readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint"]

    cond do
      not is_nil(audience) and
          not (is_list(audience) and Enum.all?(audience, &(&1 in ["user", "assistant"]))) ->
        {:error, {:invalid_definition, :annotations}}

      not is_nil(priority) and not (is_number(priority) and priority >= 0 and priority <= 1) ->
        {:error, {:invalid_definition, :annotations}}

      Enum.any?(boolean_hints, fn key ->
        Map.has_key?(value, key) and not is_boolean(value[key])
      end) ->
        {:error, {:invalid_definition, :annotations}}

      true ->
        :ok
    end
  end

  defp validate_type(:tool, value) do
    with :ok <- valid_name(value[:name], :name),
         :ok <- valid_description(value[:description]),
         :ok <- valid_tool_input_schema(value[:input_schema]),
         :ok <- optional_schema(value[:output_schema]) do
      :ok
    else
      {:error, reason} -> {:error, {:invalid_schema, reason}}
    end
  end

  defp validate_type(:resource, value) do
    with :ok <- valid_uri(value[:uri]),
         :ok <- valid_optional_mime(value[:mime_type]) do
      :ok
    end
  end

  defp validate_type(:template, value) do
    with true <- valid_template(value[:uri_template]),
         :ok <- valid_optional_mime(value[:mime_type]) do
      :ok
    else
      _ -> {:error, {:invalid_definition, :uri_template}}
    end
  end

  defp validate_type(:prompt, value) do
    with :ok <- valid_name(value[:name], :name), do: valid_arguments(value[:arguments])
  end

  defp validate_type(:completion, value) do
    with :ok <- valid_name(value[:name], :name) do
      ref = value[:ref] || value["ref"] || value[:reference] || value["reference"]

      if valid_completion_ref?(ref),
        do: :ok,
        else: {:error, {:invalid_definition, :completion_ref}}
    end
  end

  defp optional_schema(nil), do: :ok
  defp optional_schema(schema), do: Schema.validate_schema(schema)

  defp valid_tool_input_schema(schema) when is_map(schema) do
    with :ok <- Schema.validate_schema(schema) do
      cond do
        schema["type"] != "object" -> {:error, :root_type}
        validate_header_declarations(schema) != :ok -> {:error, :x_mcp_header}
        true -> :ok
      end
    end
  end

  defp valid_tool_input_schema(_), do: {:error, :root_type}

  defp validate_header_declarations(schema) when is_map(schema) do
    with false <- Map.has_key?(schema, "x-mcp-header"),
         false <- header_annotation_outside_properties?(schema, false),
         {:ok, names} <- collect_header_declarations(schema, [], []),
         names <- Enum.map(names, fn {name, _path} -> String.downcase(name) end),
         true <- Enum.uniq(names) == names do
      :ok
    else
      _ -> {:error, :x_mcp_header}
    end
  end

  defp collect_header_declarations(schema, path, acc) when is_map(schema) do
    properties = Map.get(schema, "properties", %{})

    with {:ok, acc} <- collect_property_headers(properties, path, acc) do
      {:ok, acc}
    end
  end

  defp collect_property_headers(properties, path, acc) when is_map(properties) do
    Enum.reduce_while(properties, {:ok, acc}, fn {property, schema}, {:ok, acc} ->
      with true <- is_binary(property),
           true <- is_map(schema),
           {:ok, acc} <- validate_property_header(schema, property, path, acc),
           {:ok, acc} <- collect_header_declarations(schema, path ++ [property], acc) do
        {:cont, {:ok, acc}}
      else
        _ -> {:halt, {:error, :x_mcp_header}}
      end
    end)
  end

  defp collect_property_headers(_, _, _), do: {:error, :x_mcp_header}

  defp validate_property_header(schema, property, path, acc) do
    annotation = Map.get(schema, "x-mcp-header") || Map.get(schema, :"x-mcp-header")

    if is_nil(annotation) do
      {:ok, acc}
    else
      primitive =
        Map.get(schema, "type") in ["string", "integer", "boolean"] and
          not Map.has_key?(schema, "$ref") and
          not Map.has_key?(schema, "anyOf") and
          not Map.has_key?(schema, "oneOf") and
          not Map.has_key?(schema, "allOf") and
          not Map.has_key?(schema, "if") and
          not Map.has_key?(schema, "then") and
          not Map.has_key?(schema, "else")

      with true <- primitive,
           {:ok, names} <- header_names(annotation),
           true <- Enum.all?(names, &valid_header_name?/1) do
        {:ok, acc ++ Enum.map(names, &{&1, path ++ [property]})}
      else
        _ -> {:error, :x_mcp_header}
      end
    end
  end

  defp header_names(suffix) when is_binary(suffix) do
    if valid_header_suffix?(suffix),
      do: {:ok, ["mcp-param-" <> suffix]},
      else: {:error, :x_mcp_header}
  end

  defp header_names(_), do: {:error, :x_mcp_header}

  defp valid_header_suffix?(suffix) when byte_size(suffix) in 1..128 do
    not String.starts_with?(String.downcase(suffix), "mcp-param-") and
      Regex.match?(~r/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/, suffix)
  end

  defp valid_header_suffix?(_), do: false

  defp header_annotation_outside_properties?(schema, allow_direct)
       when is_map(schema) and is_boolean(allow_direct) do
    Enum.any?(schema, fn
      {key, value} when key in ["properties", :properties] and is_map(value) ->
        Enum.any?(value, fn {_property, child} ->
          is_map(child) and header_annotation_outside_properties?(child, true)
        end)

      {key, _value} when key in ["x-mcp-header", :"x-mcp-header"] ->
        not allow_direct

      {key, value} when key in ["annotations", :annotations] ->
        has_header_annotation?(value)

      {_key, value} ->
        has_header_annotation?(value)
    end)
  end

  defp header_annotation_outside_properties?(_schema, _allow_direct), do: false

  defp has_header_annotation?(value) when is_map(value) do
    Map.has_key?(value, "x-mcp-header") or
      Map.has_key?(value, :"x-mcp-header") or
      (is_map(value["annotations"]) and
         (Map.has_key?(value["annotations"], "x-mcp-header") or
            Map.has_key?(value["annotations"], :"x-mcp-header"))) or
      (is_map(value[:annotations]) and
         (Map.has_key?(value[:annotations], "x-mcp-header") or
            Map.has_key?(value[:annotations], :"x-mcp-header"))) or
      Enum.any?(value, fn {_key, nested} -> has_header_annotation?(nested) end)
  end

  defp has_header_annotation?(value) when is_list(value),
    do: Enum.any?(value, &has_header_annotation?/1)

  defp has_header_annotation?(_), do: false

  defp valid_header_name?(name) when is_binary(name) and byte_size(name) in 1..256 do
    Regex.match?(~r/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/, name)
  end

  defp valid_header_name?(_), do: false

  defp valid_identity(type, identity) do
    case type do
      :resource ->
        if valid_uri(identity), do: :ok, else: {:error, {:invalid_definition, :uri}}

      :template ->
        if valid_template(identity), do: :ok, else: {:error, {:invalid_definition, :uri_template}}

      type when type in [:tool, :prompt, :completion] ->
        if valid_name(identity, :identity) == :ok,
          do: :ok,
          else: {:error, {:invalid_definition, :identity}}

      _ ->
        if valid_text(identity, :identity) == :ok,
          do: :ok,
          else: {:error, {:invalid_definition, :identity}}
    end
  end

  defp valid_name(value, _field)
       when is_binary(value) and byte_size(value) in 1..@max_name_bytes do
    if String.valid?(value) and Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9_.-]*$/, value),
      do: :ok,
      else: {:error, {:invalid_definition, :name}}
  end

  defp valid_name(_, field), do: {:error, {:invalid_definition, field}}

  defp valid_text(value, _field)
       when is_binary(value) and byte_size(value) in 1..@max_identity_bytes do
    if String.valid?(value) and not String.contains?(value, ["\u0000", "\r", "\n"]) and
         String.trim(value) == value,
       do: :ok,
       else: {:error, {:invalid_definition, :text}}
  end

  defp valid_text(_, field), do: {:error, {:invalid_definition, field}}

  defp valid_scopes(scopes) when is_list(scopes) do
    if Enum.uniq(scopes) == scopes and Attesto.Scope.valid_list?(scopes, allow_empty?: true),
      do: :ok,
      else: {:error, {:invalid_definition, :required_scopes}}
  end

  defp valid_scopes(_), do: {:error, {:invalid_definition, :required_scopes}}

  defp valid_handler(nil), do: :ok
  defp valid_handler(fun) when is_function(fun, 1) or is_function(fun, 2), do: :ok
  defp valid_handler({module, function}) when is_atom(module) and is_atom(function), do: :ok

  defp valid_handler({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args),
       do: :ok

  defp valid_handler(_), do: {:error, {:invalid_definition, :handler}}

  defp valid_authorize(nil), do: :ok
  defp valid_authorize(fun) when is_function(fun, 1), do: :ok

  defp valid_authorize({module, function}) when is_atom(module) and is_atom(function),
    do: :ok

  defp valid_authorize({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args),
       do: :ok

  defp valid_authorize(_), do: {:error, {:invalid_definition, :authorize}}

  defp valid_optional_mime(nil), do: :ok
  defp valid_optional_mime(value), do: valid_text(value, :mime_type)

  defp valid_uri(uri) when is_binary(uri) and byte_size(uri) in 1..@max_identity_bytes do
    parsed = URI.parse(uri)
    host = parsed.host || ""

    String.valid?(uri) and not String.contains?(uri, ["..", "\\", "\u0000", "\r", "\n"]) and
      is_nil(parsed.userinfo) and
      host not in ["localhost", "127.0.0.1", "::1", "0.0.0.0"] and
      (String.starts_with?(uri, ["http://", "https://", "urn:", "file:", "/"]) or
         parsed.scheme not in [nil, ""])
      |> bool_ok(:uri)
  end

  defp valid_uri(_), do: {:error, {:invalid_definition, :uri}}

  defp bool_ok(true, _), do: :ok
  defp bool_ok(false, field), do: {:error, {:invalid_definition, field}}

  defp valid_template(template) when is_binary(template) do
    placeholders = Regex.scan(~r/\{([^{}]*)\}/, template, capture: :all_but_first)

    valid_uri(template) == :ok and balanced_braces?(template) and placeholders != [] and
      not String.contains?(Regex.replace(~r/\{[^{}]*\}/, template, ""), ["{", "}"]) and
      Enum.all?(placeholders, fn [expression] -> valid_template_expression?(expression) end) and
      supported_template_layout?(template, placeholders)
  end

  defp valid_template(_), do: false

  # The server performs reverse matching for one expression at a time. Reject
  # layouts that would otherwise be accepted but cannot be matched without
  # guessing (for example multiple query expressions or unsupported operators).
  defp supported_template_layout?(template, [[expression]]) do
    marker = "{" <> expression <> "}"

    case String.split(template, marker, parts: 2) do
      [prefix, suffix] ->
        {operator, variables} = template_operator(expression)

        operator in [nil, ?+, ??] and
          (operator != ?? or suffix == "") and
          variables != "" and
          String.valid?(prefix) and String.valid?(suffix)

      _ ->
        false
    end
  end

  defp supported_template_layout?(_template, _placeholders), do: false

  defp template_operator(expression) when is_binary(expression) do
    case expression do
      <<operator, rest::binary>> when operator in [?+, ?#, ?., ?/, ?;, ??, ?&] ->
        {operator, rest}

      _ ->
        {nil, expression}
    end
  end

  defp balanced_braces?(value),
    do:
      count_char(value, ?{) == count_char(value, ?}) and not String.contains?(value, ["{{", "}}"])

  defp valid_template_expression?(expression) when is_binary(expression) do
    {operator, variables} =
      case expression do
        <<operator, rest::binary>> when operator in [?+, ?#, ?., ?/, ?;, ??, ?&] ->
          {operator, rest}

        _ ->
          {nil, expression}
      end

    operator in [nil, ?+, ?#, ?., ?/, ?;, ??, ?&] and variables != "" and
      variables
      |> String.split(",", trim: false)
      |> Enum.uniq()
      |> length() == length(String.split(variables, ",", trim: false)) and
      Enum.all?(String.split(variables, ",", trim: false), &valid_template_varspec?/1)
  end

  defp valid_template_expression?(_), do: false

  defp valid_template_varspec?(value) when is_binary(value) do
    Regex.match?(~r/^[A-Za-z][A-Za-z0-9_.]*(?::[1-9][0-9]{0,3})?\*?$/, value)
  end

  defp valid_template_varspec?(_), do: false

  defp count_char(value, codepoint),
    do: value |> String.to_charlist() |> Enum.count(&(&1 == codepoint))

  defp valid_arguments(arguments) when is_list(arguments) do
    if Enum.all?(arguments, &valid_argument?/1),
      do: :ok,
      else: {:error, {:invalid_definition, :arguments}}
  end

  defp valid_arguments(_), do: {:error, {:invalid_definition, :arguments}}

  defp valid_argument?(argument) when is_map(argument) do
    name = argument[:name] || argument["name"]
    required = argument[:required] || argument["required"] || false
    description = argument[:description] || argument["description"]

    is_binary(name) and name != "" and is_boolean(required) and
      (is_nil(description) or valid_description(description) == :ok)
  end

  defp valid_argument?(_), do: false

  defp valid_completion_ref?(ref) when is_map(ref) do
    type = ref["type"]
    name = ref["name"]
    uri = ref["uri"]

    type in ["ref/prompt", "ref/resource"] and
      ((type == "ref/prompt" and valid_text(name, :name) == :ok) or
         (type == "ref/resource" and valid_uri(uri) == :ok))
  end

  defp valid_completion_ref?(_), do: false
end
