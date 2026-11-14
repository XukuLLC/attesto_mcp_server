defmodule AttestoMCP.Server.Elicitation do
  @moduledoc false

  alias AttestoMCP.Server.{Output, Schema}

  def valid_request?(params, opts) when is_map(params) do
    budget = budget(opts)
    message = params["message"]

    Schema.json_value(params, budget) == :ok and is_binary(message) and
      byte_size(message) in 1..10_000 and
      case params["mode"] || "form" do
        "form" -> valid_schema?(params["requestedSchema"], budget)
        "url" -> valid_url?(params["url"], opts)
        _ -> false
      end
  end

  def valid_request?(_params, _opts), do: false

  @root_schema_keys ~w($schema type title description properties required additionalProperties)
  @banned_property_keys ~w($ref $defs definitions patternProperties additionalProperties allOf anyOf not if then else)

  def valid_response?(params, response, opts) when is_map(params) and is_map(response) do
    with {:ok, response} <- Output.canonicalize(response, budget(opts)),
         action when action in ["accept", "decline", "cancel"] <- response["action"] do
      case {params["mode"] || "form", action} do
        {"url", _} ->
          not Map.has_key?(response, "content")

        {"form", "accept"} ->
          schema = params["requestedSchema"]
          content = response["content"]

          declared =
            if is_map(schema) and is_map(schema["properties"]),
              do: schema["properties"],
              else: %{}

          is_map(schema) and is_map(content) and
            Map.keys(content) -- Map.keys(declared) == [] and
            Schema.validate(
              content,
              schema,
              Keyword.put(budget(opts), :formats, true)
            ) == :ok

        {"form", _} ->
          true

        _ ->
          false
      end
    else
      _ -> false
    end
  end

  def valid_response?(_params, _response, _opts), do: false

  # Reuse the core authority/percent-encoding and control-character checks.
  # Loopback http:// is permitted only when `:elicitation_allow_loopback_http` is true.
  def valid_url?(url, opts) when is_binary(url) do
    allow_http = opts[:elicitation_allow_loopback_http] == true

    if Attesto.URI.https_identifier?(url, allow_loopback_http: allow_http) and
         not String.contains?(url, " ") and
         Attesto.Claims.no_terminal_controls?(url, allow_multiline?: false) do
      parsed = URI.parse(url)
      scheme = parsed.scheme && String.downcase(parsed.scheme)
      host = parsed.host && String.downcase(parsed.host)

      scheme == "https" or host in ["localhost", "127.0.0.1", "::1"]
    else
      false
    end
  end

  def valid_url?(_url, _opts), do: false

  defp valid_schema?(schema, opts) when is_map(schema) do
    properties = schema["properties"] || %{}
    required = schema["required"] || []

    Map.keys(schema) -- @root_schema_keys == [] and
      is_boolean(Map.get(schema, "additionalProperties", false)) and
      Schema.validate_schema(schema, opts) == :ok and schema["type"] == "object" and
      is_map(properties) and is_list(required) and
      Enum.all?(required, &(is_binary(&1) and Map.has_key?(properties, &1))) and
      Enum.all?(properties, fn {name, property} ->
        is_binary(name) and valid_property?(property, opts)
      end)
  end

  defp valid_schema?(_schema, _opts), do: false

  # MCP 2025-11-25 elicitation `requestedSchema` properties are primitive:
  # string (including single-select enums, titled through `oneOf`), number,
  # integer and boolean. The one non-primitive form is the multi-select enum
  # (SEP-1330): an array whose `items` is an untitled string enum or a titled
  # `anyOf` of `{const, title}` options. No other nesting is allowed.
  defp valid_property?(%{"type" => "array"} = schema, opts) do
    Schema.validate_schema(schema, opts) == :ok and
      not Map.has_key?(schema, "properties") and
      not Map.has_key?(schema, "oneOf") and
      not Enum.any?(@banned_property_keys, &Map.has_key?(schema, &1)) and
      multi_select_items?(schema["items"])
  end

  defp valid_property?(schema, opts) when is_map(schema) do
    schema["type"] in ["string", "number", "integer", "boolean"] and
      Schema.validate_schema(schema, opts) == :ok and
      not Map.has_key?(schema, "properties") and not Map.has_key?(schema, "items") and
      not Enum.any?(@banned_property_keys, &Map.has_key?(schema, &1)) and
      valid_property_one_of?(schema)
  end

  defp valid_property?(_schema, _opts), do: false

  defp valid_property_one_of?(%{"type" => "string", "oneOf" => options}),
    do: titled_const_options?(options)

  defp valid_property_one_of?(schema), do: not Map.has_key?(schema, "oneOf")

  defp multi_select_items?(%{"type" => "string", "enum" => [_ | _] = values} = items) do
    Map.keys(items) -- ["type", "enum"] == [] and Enum.all?(values, &is_binary/1)
  end

  defp multi_select_items?(%{"anyOf" => options} = items) do
    Map.keys(items) -- ["anyOf"] == [] and titled_const_options?(options)
  end

  defp multi_select_items?(_items), do: false

  defp titled_const_options?([_ | _] = options) do
    Enum.all?(options, fn
      %{"const" => value} = option when is_binary(value) ->
        option |> Map.keys() |> Enum.all?(&(&1 in ["const", "title"]))

      _other ->
        false
    end)
  end

  defp titled_const_options?(_options), do: false

  defp budget(opts),
    do: [max_bytes: opts[:max_json_bytes] || opts[:max_bytes] || Schema.default_instance_bytes()]
end
