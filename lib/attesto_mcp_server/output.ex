defmodule AttestoMCP.Server.Output do
  @moduledoc false

  alias AttestoMCP.Server.Schema

  @max_output_depth 64
  @max_output_nodes 10_000
  @default_output_bytes 2_000_000
  @max_error_path_bytes 512
  @error_path_hash_bytes 8

  defmodule CanonicalizationError do
    @moduledoc false

    defexception [:path, :reason, :value_type, :encoder, :encoder_exception]

    @type t :: %__MODULE__{
            path: String.t(),
            reason: atom(),
            value_type: atom() | {:struct, module()},
            encoder: :strict | :json | :jason,
            encoder_exception: module() | atom() | nil
          }

    @impl true
    def message(error) do
      location = if error.path == "", do: "the document root", else: error.path
      encoder = if error.encoder in [:json, :jason], do: " via #{error.encoder}", else: ""

      "output canonicalization rejected #{inspect(error.value_type)} at #{location}#{encoder}: #{error.reason}"
    end
  end

  @type normalization_error ::
          :not_json
          | :invalid_content
          | :invalid_prompt_message
          | :invalid_prompt_result
          | :invalid_resource_content
          | :invalid_resource_result
          | :invalid_tool_result

  @doc false
  @spec canonicalize(term(), keyword()) :: {:ok, term()} | {:error, :not_json}
  def canonicalize(value, opts \\ []) do
    case canonicalize_detailed(value, opts) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, %CanonicalizationError{}} -> {:error, :not_json}
    end
  end

  @doc false
  @spec canonicalize_detailed(term(), keyword()) ::
          {:ok, term()} | {:error, CanonicalizationError.t()}
  def canonicalize_detailed(value, opts \\ []) do
    max_bytes = configured_max_bytes(opts)
    mode = configured_canonicalization(opts)

    if max_bytes > 0 and mode in [:strict, :json, :jason] do
      case canonicalize(value, 0, @max_output_nodes, 0, max_bytes, [], mode) do
        {:ok, normalized, _left, _used} -> {:ok, normalized}
        {:error, %CanonicalizationError{}} = error -> error
      end
    else
      canonicalization_error([], :invalid_options, value, :strict)
    end
  end

  @doc false
  @spec normalize_content_item(term(), keyword()) ::
          {:ok, map()} | {:error, normalization_error()}
  def normalize_content_item(value, opts \\ []),
    do: normalize(value, &valid_content_item?/1, :invalid_content, opts)

  @doc false
  @spec normalize_resource_content(term(), keyword()) ::
          {:ok, map()} | {:error, normalization_error()}
  def normalize_resource_content(value, opts \\ []),
    do: normalize(value, &valid_resource_content?/1, :invalid_resource_content, opts)

  @doc false
  @spec normalize_prompt_message(term(), keyword()) ::
          {:ok, map()} | {:error, normalization_error()}
  def normalize_prompt_message(value, opts \\ []),
    do: normalize(value, &valid_prompt_message?/1, :invalid_prompt_message, opts)

  @doc false
  @spec normalize_tool_result(term(), keyword()) :: {:ok, map()} | {:error, normalization_error()}
  def normalize_tool_result(value, opts \\ []),
    do: normalize(value, &valid_tool_result?/1, :invalid_tool_result, opts)

  @doc false
  @spec normalize_tool_result_detailed(term(), keyword()) ::
          {:ok, map()} | {:error, normalization_error() | CanonicalizationError.t()}
  def normalize_tool_result_detailed(value, opts \\ []) do
    with {:ok, normalized} <- canonicalize_detailed(value, opts),
         true <- valid_tool_result?(normalized) do
      {:ok, normalized}
    else
      {:error, %CanonicalizationError{}} = error -> error
      _other -> {:error, :invalid_tool_result}
    end
  end

  @doc false
  @spec normalize_resource_result(term(), keyword()) ::
          {:ok, map()} | {:error, normalization_error()}
  def normalize_resource_result(value, opts \\ []),
    do: normalize(value, &valid_resource_result?/1, :invalid_resource_result, opts)

  @doc false
  @spec normalize_prompt_result(term(), keyword()) ::
          {:ok, map()} | {:error, normalization_error()}
  def normalize_prompt_result(value, opts \\ []),
    do: normalize(value, &valid_prompt_result?/1, :invalid_prompt_result, opts)

  @doc false
  @spec normalize_options(term(), [atom()]) :: {:ok, keyword()} | {:error, :invalid_options}
  def normalize_options(opts, allowed) when is_list(opts) and is_list(allowed) do
    keys =
      Enum.map(opts, fn
        {key, _value} when is_atom(key) -> key
        _other -> nil
      end)

    if Keyword.keyword?(opts) and length(keys) == length(Enum.uniq(keys)) and
         Enum.all?(keys, &(&1 in allowed)) do
      {:ok, opts}
    else
      {:error, :invalid_options}
    end
  rescue
    _ -> {:error, :invalid_options}
  catch
    _, _ -> {:error, :invalid_options}
  end

  def normalize_options(_opts, _allowed), do: {:error, :invalid_options}

  @doc false
  @spec safe_uri?(term()) :: boolean()
  def safe_uri?(uri) when is_binary(uri) do
    if String.valid?(uri) and not String.contains?(uri, ["..", "\\", "\u0000", "\r", "\n"]) do
      try do
        parsed = URI.parse(uri)
        scheme = parsed.scheme
        host = parsed.host && String.downcase(parsed.host)

        valid_scheme? = is_binary(scheme) and byte_size(scheme) > 0
        safe_host? = host not in ["localhost", "127.0.0.1", "::1", "0.0.0.0"]

        (valid_scheme? or String.starts_with?(uri, "/")) and is_nil(parsed.userinfo) and
          safe_host?
      rescue
        _ -> false
      end
    else
      false
    end
  end

  def safe_uri?(_uri), do: false

  @doc false
  @spec canonical_base64?(term()) :: boolean()
  def canonical_base64?(value) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, decoded} -> Base.encode64(decoded) == value
      :error -> false
    end
  rescue
    _ -> false
  end

  def canonical_base64?(_value), do: false

  defp normalize(value, validator, error, opts) do
    with {:ok, normalized} <- canonicalize(value, opts),
         true <- validator.(normalized) do
      {:ok, normalized}
    else
      {:error, :not_json} = invalid_json -> invalid_json
      _ -> {:error, error}
    end
  end

  defp valid_tool_result?(%{"content" => content} = result) when is_list(content) do
    optional_boolean?(result, "isError") and optional_map?(result, "_meta") and
      Enum.all?(content, &valid_content_item?/1)
  end

  defp valid_tool_result?(_result), do: false

  defp valid_resource_result?(%{"contents" => contents} = result) when is_list(contents) do
    optional_map?(result, "_meta") and Enum.all?(contents, &valid_resource_content?/1)
  end

  defp valid_resource_result?(_result), do: false

  defp valid_prompt_result?(%{"messages" => messages} = result) when is_list(messages) do
    optional_binary?(result, "description") and optional_map?(result, "_meta") and
      Enum.all?(messages, &valid_prompt_message?/1)
  end

  defp valid_prompt_result?(_result), do: false

  defp valid_prompt_message?(%{"role" => role, "content" => content})
       when role in ["user", "assistant"],
       do: valid_content_item?(content)

  defp valid_prompt_message?(_message), do: false

  defp valid_content_item?(%{"type" => "text", "text" => text} = item)
       when is_binary(text),
       do: optional_annotations?(item) and optional_map?(item, "_meta")

  defp valid_content_item?(%{"type" => type, "data" => data, "mimeType" => mime} = item)
       when type in ["image", "audio"] and is_binary(data) and is_binary(mime),
       do:
         mime != "" and canonical_base64?(data) and optional_annotations?(item) and
           optional_map?(item, "_meta")

  defp valid_content_item?(%{"type" => "resource_link", "uri" => uri, "name" => name} = item)
       when is_binary(uri) and is_binary(name) do
    safe_uri?(uri) and optional_binary?(item, "title") and
      optional_binary?(item, "description") and optional_binary?(item, "mimeType") and
      optional_nonnegative_integer?(item, "size") and optional_icons?(item) and
      optional_annotations?(item) and optional_map?(item, "_meta")
  end

  defp valid_content_item?(%{"type" => "resource", "resource" => resource} = item)
       when is_map(resource),
       do:
         valid_resource_content?(resource) and optional_annotations?(item) and
           optional_map?(item, "_meta")

  defp valid_content_item?(_item), do: false

  defp valid_resource_content?(resource) when is_map(resource) do
    uri = Map.get(resource, "uri")
    has_text? = Map.has_key?(resource, "text")
    has_blob? = Map.has_key?(resource, "blob")

    is_binary(uri) and safe_uri?(uri) and has_text? != has_blob? and
      optional_binary?(resource, "mimeType") and optional_map?(resource, "_meta") and
      optional_annotations?(resource) and optional_icons?(resource) and
      ((has_text? and is_binary(resource["text"])) or
         (has_blob? and canonical_base64?(resource["blob"])))
  end

  defp valid_resource_content?(_resource), do: false

  defp optional_annotations?(map) do
    case Map.fetch(map, "annotations") do
      :error -> true
      {:ok, annotations} -> valid_annotations?(annotations)
    end
  end

  defp valid_annotations?(annotations) when is_map(annotations) do
    (is_nil(annotations["audience"]) or
       (is_list(annotations["audience"]) and
          Enum.all?(annotations["audience"], &(&1 in ["user", "assistant"])))) and
      (is_nil(annotations["priority"]) or
         (is_number(annotations["priority"]) and annotations["priority"] >= 0 and
            annotations["priority"] <= 1)) and
      (is_nil(annotations["lastModified"]) or is_binary(annotations["lastModified"])) and
      Enum.all?(
        ["readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint"],
        fn key -> not Map.has_key?(annotations, key) or is_boolean(annotations[key]) end
      )
  end

  defp valid_annotations?(_annotations), do: false

  defp optional_icons?(map) do
    case Map.fetch(map, "icons") do
      :error -> true
      {:ok, icons} when is_list(icons) -> Enum.all?(icons, &valid_icon?/1)
      {:ok, _icons} -> false
    end
  end

  defp valid_icon?(%{"src" => src} = icon) when is_binary(src) and src != "" do
    optional_binary?(icon, "mimeType") and
      (not Map.has_key?(icon, "theme") or icon["theme"] in ["light", "dark"]) and
      (not Map.has_key?(icon, "sizes") or
         (is_list(icon["sizes"]) and Enum.all?(icon["sizes"], &is_binary/1)))
  end

  defp valid_icon?(_icon), do: false

  defp optional_binary?(map, key) do
    not Map.has_key?(map, key) or is_binary(map[key])
  end

  defp optional_boolean?(map, key) do
    not Map.has_key?(map, key) or is_boolean(map[key])
  end

  defp optional_map?(map, key) do
    not Map.has_key?(map, key) or is_map(map[key])
  end

  defp optional_nonnegative_integer?(map, key) do
    not Map.has_key?(map, key) or (is_integer(map[key]) and map[key] >= 0)
  end

  defp canonicalize(value, depth, _nodes, _bytes, _max_bytes, path, encoder)
       when depth > @max_output_depth,
       do: canonicalization_error(path, :max_depth, value, encoder)

  defp canonicalize(value, _depth, nodes, _bytes, _max_bytes, path, encoder)
       when nodes <= 0,
       do: canonicalization_error(path, :max_nodes, value, encoder)

  defp canonicalize(value, _depth, _nodes, bytes, max_bytes, path, encoder)
       when bytes > max_bytes,
       do: canonicalization_error(path, :max_bytes, value, encoder)

  defp canonicalize(%_{} = value, _depth, _nodes, _bytes, _max_bytes, path, :strict),
    do: canonicalization_error(path, :unsupported_value, value, :strict)

  defp canonicalize(%_{} = value, depth, nodes, bytes, max_bytes, path, encoder)
       when encoder in [:json, :jason] do
    with :ok <- bounded_encoder_input(value, max_bytes - bytes),
         {:ok, encoded} <- encode_protocol_value(value, encoder, max_bytes - bytes, path),
         {:ok, decoded} <- decode_protocol_value(encoded, encoder, path, value) do
      canonicalize(decoded, depth, nodes, bytes, max_bytes, path, encoder)
    else
      {:error, %CanonicalizationError{}} = error -> error
      {:error, reason} -> canonicalization_error(path, reason, value, encoder)
    end
  end

  defp canonicalize(value, depth, nodes, bytes, max_bytes, path, encoder)
       when is_map(value) do
    with {:ok, bytes} <- add_bytes(bytes, 2, max_bytes) do
      Enum.reduce_while(value, {:ok, %{}, nodes - 1, bytes, true}, fn {key, nested},
                                                                      {:ok, acc, left, used,
                                                                       first?} ->
        with {:ok, key} <- canonical_key(key),
             {:ok, used} <- add_bytes(used, if(first?, do: 1, else: 2), max_bytes),
             {:ok, used} <- add_json_string_bytes(key, used, max_bytes),
             {:ok, nested, left, used} <-
               canonicalize(nested, depth + 1, left, used, max_bytes, [key | path], encoder),
             false <- Map.has_key?(acc, key) do
          {:cont, {:ok, Map.put(acc, key, nested), left, used, false}}
        else
          {:error, %CanonicalizationError{}} = error ->
            {:halt, error}

          {:error, :not_json} ->
            {:halt, canonicalization_error(path, :invalid_map_key, key, encoder)}

          true ->
            {:halt, canonicalization_error([key | path], :duplicate_map_key, key, encoder)}

          _ ->
            {:halt, canonicalization_error([key | path], :max_bytes, nested, encoder)}
        end
      end)
      |> case do
        {:ok, normalized, left, used, _first?} -> {:ok, normalized, left, used}
        {:error, %CanonicalizationError{}} = error -> error
      end
    else
      :error -> canonicalization_error(path, :max_bytes, value, encoder)
    end
  end

  defp canonicalize(value, depth, nodes, bytes, max_bytes, path, encoder)
       when is_list(value) do
    with {:ok, bytes} <- add_bytes(bytes, 2, max_bytes) do
      canonicalize_list(value, depth, nodes - 1, bytes, [], true, max_bytes, path, encoder, 0)
    else
      :error -> canonicalization_error(path, :max_bytes, value, encoder)
    end
  end

  defp canonicalize(value, _depth, nodes, bytes, max_bytes, path, encoder)
       when is_binary(value) do
    case add_json_string_bytes(value, bytes, max_bytes) do
      {:ok, bytes} ->
        {:ok, value, nodes - 1, bytes}

      :error ->
        reason = if String.valid?(value), do: :max_bytes, else: :invalid_utf8
        canonicalization_error(path, reason, value, encoder)
    end
  end

  defp canonicalize(value, _depth, nodes, bytes, max_bytes, path, encoder)
       when is_integer(value) do
    scalar_bytes = byte_size(Integer.to_string(value))

    case add_bytes(bytes, scalar_bytes, max_bytes) do
      {:ok, bytes} -> {:ok, value, nodes - 1, bytes}
      :error -> canonicalization_error(path, :max_bytes, value, encoder)
    end
  end

  defp canonicalize(value, _depth, nodes, bytes, max_bytes, path, encoder)
       when value in [true, nil] do
    case add_bytes(bytes, 4, max_bytes) do
      {:ok, bytes} -> {:ok, value, nodes - 1, bytes}
      :error -> canonicalization_error(path, :max_bytes, value, encoder)
    end
  end

  defp canonicalize(false, _depth, nodes, bytes, max_bytes, path, encoder) do
    case add_bytes(bytes, 5, max_bytes) do
      {:ok, bytes} -> {:ok, false, nodes - 1, bytes}
      :error -> canonicalization_error(path, :max_bytes, false, encoder)
    end
  end

  defp canonicalize(value, _depth, nodes, bytes, max_bytes, path, encoder)
       when is_float(value) do
    if value == value and value <= 1.7976931348623157e308 and
         value >= -1.7976931348623157e308 do
      scalar_bytes = byte_size(:erlang.float_to_binary(value, [:short]))

      case add_bytes(bytes, scalar_bytes, max_bytes) do
        {:ok, bytes} -> {:ok, value, nodes - 1, bytes}
        :error -> canonicalization_error(path, :max_bytes, value, encoder)
      end
    else
      canonicalization_error(path, :non_finite_float, value, encoder)
    end
  end

  defp canonicalize(value, depth, nodes, bytes, max_bytes, path, encoder)
       when is_atom(value) and encoder in [:json, :jason] do
    canonicalize(Atom.to_string(value), depth, nodes, bytes, max_bytes, path, encoder)
  end

  defp canonicalize(value, _depth, _nodes, _bytes, _max_bytes, path, encoder),
    do: canonicalization_error(path, :unsupported_value, value, encoder)

  defp canonicalize_list(
         [],
         _depth,
         nodes,
         bytes,
         items,
         _first?,
         _max_bytes,
         _path,
         _encoder,
         _index
       ),
       do: {:ok, Enum.reverse(items), nodes, bytes}

  defp canonicalize_list(
         [item | rest],
         depth,
         nodes,
         bytes,
         items,
         first?,
         max_bytes,
         path,
         encoder,
         index
       ) do
    with {:ok, bytes} <- add_bytes(bytes, if(first?, do: 0, else: 1), max_bytes),
         {:ok, item, nodes, bytes} <-
           canonicalize(item, depth + 1, nodes, bytes, max_bytes, [index | path], encoder) do
      canonicalize_list(
        rest,
        depth,
        nodes,
        bytes,
        [item | items],
        false,
        max_bytes,
        path,
        encoder,
        index + 1
      )
    else
      {:error, %CanonicalizationError{}} = error -> error
      _ -> canonicalization_error([index | path], :max_bytes, item, encoder)
    end
  end

  defp canonicalize_list(
         improper,
         _depth,
         _nodes,
         _bytes,
         _items,
         _first?,
         _max_bytes,
         path,
         encoder,
         index
       ),
       do: canonicalization_error([index | path], :improper_list, improper, encoder)

  defp encode_protocol_value(value, :json, remaining, path) when remaining >= 0 do
    try do
      value
      |> JSON.encode_to_iodata!()
      |> bounded_encoded_binary(remaining, path, value, :json)
    catch
      kind, reason -> encoder_failure(path, value, :json, kind, reason)
    end
  end

  defp encode_protocol_value(value, :jason, remaining, path) when remaining >= 0 do
    try do
      case Jason.encode_to_iodata(value) do
        {:ok, encoded} -> bounded_encoded_binary(encoded, remaining, path, value, :jason)
        {:error, reason} -> encoder_failure(path, value, :jason, :error, reason)
      end
    catch
      kind, reason -> encoder_failure(path, value, :jason, kind, reason)
    end
  end

  defp encode_protocol_value(value, encoder, _remaining, path),
    do: canonicalization_error(path, :max_bytes, value, encoder)

  defp bounded_encoded_binary(encoded, remaining, path, value, encoder) do
    if IO.iodata_length(encoded) <= remaining do
      {:ok, IO.iodata_to_binary(encoded)}
    else
      canonicalization_error(path, :max_bytes, value, encoder)
    end
  rescue
    error -> encoder_failure(path, value, encoder, :error, error)
  catch
    kind, reason -> encoder_failure(path, value, encoder, kind, reason)
  end

  defp decode_protocol_value(encoded, :json, path, value) do
    case JSON.decode(encoded) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> canonicalization_error(path, :encoder_invalid_json, value, :json)
    end
  rescue
    error -> encoder_failure(path, value, :json, :error, error)
  catch
    kind, reason -> encoder_failure(path, value, :json, kind, reason)
  end

  defp decode_protocol_value(encoded, :jason, path, value) do
    case Jason.decode(encoded) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> canonicalization_error(path, :encoder_invalid_json, value, :jason)
    end
  rescue
    error -> encoder_failure(path, value, :jason, :error, error)
  catch
    kind, reason -> encoder_failure(path, value, :jason, kind, reason)
  end

  defp encoder_failure(path, value, encoder, kind, reason) do
    exception =
      case reason do
        %{__struct__: module} when is_atom(module) -> module
        _other -> kind
      end

    {:error,
     %CanonicalizationError{
       path: json_pointer(path),
       reason: :encoder_failure,
       value_type: value_type(value),
       encoder: encoder,
       encoder_exception: exception
     }}
  end

  # Encoder protocols are trusted host code, but invoking one still requires a
  # finite input walk. The encoded iodata is independently bounded above and
  # the decoded value is sent through the normal exact JSON budget afterward.
  defp bounded_encoder_input(value, max_bytes) do
    case encoder_input_budget(value, 0, @max_output_nodes, 0, max_bytes) do
      {:ok, _nodes, _bytes} -> :ok
      :error -> {:error, :encoder_input_limit}
    end
  end

  defp encoder_input_budget(_value, depth, nodes, bytes, max_bytes)
       when depth > @max_output_depth or nodes <= 0 or bytes > max_bytes,
       do: :error

  defp encoder_input_budget(value, depth, nodes, bytes, max_bytes) when is_map(value) do
    with {:ok, bytes} <- add_bytes(bytes, 2, max_bytes) do
      value
      |> :maps.to_list()
      |> Enum.reduce_while({:ok, nodes - 1, bytes}, fn {key, nested}, {:ok, left, used} ->
        with {:ok, left, used} <-
               encoder_input_budget(key, depth + 1, left, used, max_bytes),
             {:ok, left, used} <-
               encoder_input_budget(nested, depth + 1, left, used, max_bytes) do
          {:cont, {:ok, left, used}}
        else
          _ -> {:halt, :error}
        end
      end)
    else
      _ -> :error
    end
  end

  defp encoder_input_budget(value, depth, nodes, bytes, max_bytes) when is_list(value) do
    with {:ok, bytes} <- add_bytes(bytes, 2, max_bytes) do
      encoder_input_list_budget(value, depth, nodes - 1, bytes, max_bytes)
    else
      _ -> :error
    end
  end

  defp encoder_input_budget(value, depth, nodes, bytes, max_bytes) when is_tuple(value) do
    with {:ok, bytes} <- add_bytes(bytes, 2, max_bytes) do
      value
      |> Tuple.to_list()
      |> encoder_input_list_budget(depth, nodes - 1, bytes, max_bytes)
    else
      _ -> :error
    end
  end

  defp encoder_input_budget(value, _depth, nodes, bytes, max_bytes) when is_binary(value) do
    case add_bytes(bytes, byte_size(value), max_bytes) do
      {:ok, bytes} -> {:ok, nodes - 1, bytes}
      :error -> :error
    end
  end

  defp encoder_input_budget(value, _depth, nodes, bytes, max_bytes) when is_atom(value) do
    case add_bytes(bytes, byte_size(Atom.to_string(value)), max_bytes) do
      {:ok, bytes} -> {:ok, nodes - 1, bytes}
      :error -> :error
    end
  end

  defp encoder_input_budget(value, _depth, nodes, bytes, max_bytes) when is_integer(value) do
    case add_bytes(bytes, byte_size(Integer.to_string(value)), max_bytes) do
      {:ok, bytes} -> {:ok, nodes - 1, bytes}
      :error -> :error
    end
  end

  defp encoder_input_budget(_value, _depth, nodes, bytes, max_bytes) do
    case add_bytes(bytes, 1, max_bytes) do
      {:ok, bytes} -> {:ok, nodes - 1, bytes}
      :error -> :error
    end
  end

  defp encoder_input_list_budget([], _depth, nodes, bytes, _max_bytes),
    do: {:ok, nodes, bytes}

  defp encoder_input_list_budget([item | rest], depth, nodes, bytes, max_bytes) do
    with {:ok, nodes, bytes} <-
           encoder_input_budget(item, depth + 1, nodes, bytes, max_bytes) do
      encoder_input_list_budget(rest, depth, nodes, bytes, max_bytes)
    else
      _ -> :error
    end
  end

  defp encoder_input_list_budget(_improper, _depth, _nodes, _bytes, _max_bytes), do: :error

  defp canonicalization_error(path, reason, value, encoder) do
    {:error,
     %CanonicalizationError{
       path: json_pointer(path),
       reason: reason,
       value_type: value_type(value),
       encoder: encoder
     }}
  end

  defp json_pointer(path) do
    path
    |> Enum.reverse()
    |> Enum.map_join(fn segment -> "/" <> escape_pointer_segment(to_string(segment)) end)
    |> bound_error_path()
  end

  defp escape_pointer_segment(segment),
    do:
      segment
      |> String.replace("~", "~0")
      |> String.replace("/", "~1")
      |> escape_control_bytes()

  # Error paths are private diagnostics, but they can contain handler- or
  # client-derived property names. Keep them safe for logs and bounded even
  # when a rejected value contains a very large key. The digest is over the
  # escaped pointer, so the marker is deterministic without retaining the
  # rejected value anywhere in the error.
  defp bound_error_path(path) when byte_size(path) <= @max_error_path_bytes, do: path

  defp bound_error_path(path) do
    digest =
      :crypto.hash(:sha256, path)
      |> Base.encode16(case: :lower)
      |> binary_part(0, @error_path_hash_bytes * 2)

    marker = "[path-truncated:" <> digest <> "]"
    prefix = utf8_prefix(path, @max_error_path_bytes - byte_size(marker))
    prefix <> marker
  end

  defp utf8_prefix(_value, max_bytes) when max_bytes <= 0, do: ""
  defp utf8_prefix(value, max_bytes) when byte_size(value) <= max_bytes, do: value

  defp utf8_prefix(value, max_bytes),
    do: utf8_prefix(value, max_bytes, "")

  defp utf8_prefix(<<>>, _remaining, acc), do: acc

  defp utf8_prefix(<<codepoint::utf8, rest::binary>>, remaining, acc) do
    encoded = <<codepoint::utf8>>

    if byte_size(encoded) <= remaining do
      utf8_prefix(rest, remaining - byte_size(encoded), acc <> encoded)
    else
      acc
    end
  end

  defp utf8_prefix(_invalid, _remaining, acc), do: acc

  defp escape_control_bytes(segment) do
    # A bounded number of binary replacement passes avoids recursive descent
    # over a potentially very large property name.
    Enum.reduce(0..31, segment, fn byte, acc ->
      String.replace(acc, <<byte>>, "\\u" <> hex_byte(byte))
    end)
    |> String.replace(<<0x7F>>, "\\u007f")
  end

  defp hex_byte(byte) do
    <<hex_digit(div(byte, 16)), hex_digit(rem(byte, 16))>>
  end

  defp hex_digit(digit) when digit < 10, do: ?0 + digit
  defp hex_digit(digit), do: ?a + digit - 10

  defp value_type(%module{}) when is_atom(module), do: {:struct, module}
  defp value_type(value) when is_map(value), do: :map
  defp value_type(value) when is_list(value), do: :list
  defp value_type(value) when is_binary(value), do: :binary
  defp value_type(value) when is_integer(value), do: :integer
  defp value_type(value) when is_float(value), do: :float
  defp value_type(value) when is_atom(value), do: :atom
  defp value_type(value) when is_tuple(value), do: :tuple
  defp value_type(value) when is_pid(value), do: :pid
  defp value_type(value) when is_reference(value), do: :reference
  defp value_type(value) when is_function(value), do: :function
  defp value_type(_value), do: :other

  # Count the default Jason JSON encoding without constructing escaped output. JSON
  # leaves valid non-ASCII UTF-8 bytes unchanged, while the ASCII cases below are
  # the only bytes whose encoded length differs from their input length.
  defp add_json_string_bytes(value, bytes, max_bytes) when is_binary(value) do
    with true <- String.valid?(value),
         {:ok, bytes} <- add_bytes(bytes, 2, max_bytes) do
      add_escaped_string_bytes(value, bytes, max_bytes)
    else
      _ -> :error
    end
  end

  defp add_escaped_string_bytes(<<>>, bytes, _max_bytes), do: {:ok, bytes}

  defp add_escaped_string_bytes(<<byte, rest::binary>>, bytes, max_bytes)
       when byte in [0x08, 0x09, 0x0A, 0x0C, 0x0D, 0x22, 0x5C] do
    with {:ok, bytes} <- add_bytes(bytes, 2, max_bytes),
         do: add_escaped_string_bytes(rest, bytes, max_bytes)
  end

  defp add_escaped_string_bytes(<<byte, rest::binary>>, bytes, max_bytes) when byte <= 0x1F do
    with {:ok, bytes} <- add_bytes(bytes, 6, max_bytes),
         do: add_escaped_string_bytes(rest, bytes, max_bytes)
  end

  defp add_escaped_string_bytes(<<_byte, rest::binary>>, bytes, max_bytes) do
    with {:ok, bytes} <- add_bytes(bytes, 1, max_bytes),
         do: add_escaped_string_bytes(rest, bytes, max_bytes)
  end

  defp add_bytes(bytes, count, max_bytes)
       when is_integer(bytes) and is_integer(count) and bytes >= 0 and count >= 0 and
              bytes <= max_bytes and count <= max_bytes - bytes,
       do: {:ok, bytes + count}

  defp add_bytes(_bytes, _count, _max_bytes), do: :error

  defp configured_max_bytes(opts) when is_list(opts) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_output_bytes)

    if is_integer(max_bytes) and max_bytes >= Schema.min_allowed_instance_bytes() and
         max_bytes <= Schema.max_allowed_instance_bytes(),
       do: max_bytes,
       else: 0
  end

  defp configured_max_bytes(_opts), do: 0

  defp configured_canonicalization(opts) when is_list(opts) do
    case Keyword.get(opts, :output_canonicalization, :strict) do
      mode when mode in [:strict, :json, :jason] -> mode
      _other -> :invalid
    end
  end

  defp configured_canonicalization(_opts), do: :invalid

  defp canonical_key(key) when is_binary(key) do
    if String.valid?(key), do: {:ok, key}, else: {:error, :not_json}
  end

  defp canonical_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp canonical_key(_key), do: {:error, :not_json}
end
