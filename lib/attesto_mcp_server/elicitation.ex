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

  def valid_response?(params, response, opts) when is_map(params) and is_map(response) do
    with {:ok, response} <- Output.canonicalize(response, budget(opts)),
         action when action in ["accept", "decline", "cancel"] <- response["action"] do
      case {params["mode"] || "form", action} do
        {"url", _} ->
          not Map.has_key?(response, "content")

        {"form", "accept"} ->
          is_map(params["requestedSchema"]) and is_map(response["content"]) and
            Schema.validate(
              response["content"],
              params["requestedSchema"],
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

  # Reuse the core authority/percent-encoding checks. The development exception
  # is narrower than core allow_http: only these literal loopback hosts qualify.
  def valid_url?(url, opts) when is_binary(url) do
    allow_http = opts[:elicitation_allow_loopback_http] == true

    Attesto.URI.https_identifier?(url, allow_http: allow_http) and
      not Regex.match?(~r/[\x{0000}-\x{0020}\x{007F}-\x{009F}]/u, url) and
      (URI.parse(url).scheme == "https" or
         URI.parse(url).host in ["localhost", "127.0.0.1", "::1"])
  end

  def valid_url?(_url, _opts), do: false

  defp valid_schema?(schema, opts) when is_map(schema) do
    properties = schema["properties"] || %{}
    required = schema["required"] || []

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
    Schema.validate_schema(schema, opts) == :ok and not Map.has_key?(schema, "properties") and
      multi_select_items?(schema["items"])
  end

  defp valid_property?(schema, opts) when is_map(schema) do
    schema["type"] in ["string", "number", "integer", "boolean"] and
      Schema.validate_schema(schema, opts) == :ok and
      not Map.has_key?(schema, "properties") and not Map.has_key?(schema, "items")
  end

  defp valid_property?(_schema, _opts), do: false

  defp multi_select_items?(%{"type" => "string", "enum" => [_ | _] = values} = items) do
    Enum.all?(values, &is_binary/1) and not Map.has_key?(items, "anyOf")
  end

  defp multi_select_items?(%{"anyOf" => [_ | _] = options} = items) do
    not Map.has_key?(items, "enum") and
      Enum.all?(options, fn
        %{"const" => value} = option when is_binary(value) ->
          option |> Map.keys() |> Enum.all?(&(&1 in ["const", "title"]))

        _other ->
          false
      end)
  end

  defp multi_select_items?(_items), do: false

  defp budget(opts),
    do: [max_bytes: opts[:max_json_bytes] || opts[:max_bytes] || Schema.default_instance_bytes()]
end
