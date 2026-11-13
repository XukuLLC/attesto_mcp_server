defmodule AttestoMCP.Server.Text do
  @moduledoc false

  @controls ~r/[\x{0000}-\x{0008}\x{000B}-\x{001F}\x{007F}-\x{009F}]/u
  @single_line_controls ~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}]/u
  @display_fields ~w(name version title description instructions message text)
  @opaque_fields ~w(structuredContent data blob _meta default enum const examples)

  # Optional display fields consistently allow nil (omitted) and empty strings.
  # Required identifiers must be nonempty; protocol-specific syntax stays with
  # the caller. Limits are UTF-8 byte counts, not grapheme counts.
  def valid?(value, max_bytes, opts \\ []) do
    cond do
      is_nil(value) -> not Keyword.get(opts, :required, false)
      not is_binary(value) -> false
      not String.valid?(value) -> false
      byte_size(value) > max_bytes -> false
      value == "" and Keyword.get(opts, :required, false) -> false
      true -> controls_allowed?(value, opts)
    end
  end

  defp controls_allowed?(value, opts) do
    regex = if Keyword.get(opts, :multiline, true), do: @controls, else: @single_line_controls
    Keyword.get(opts, :display_text_policy, :off) == :off or not Regex.match?(regex, value)
  end

  def catalog(value, opts) do
    with :ok <- field(value[:name], :name, 256, opts, required: true, multiline: false),
         :ok <- field(value[:description], :description, 4_096, opts),
         :ok <- field(value["title"], :title, 1_024, opts, multiline: false),
         :ok <- arguments(value[:arguments], opts),
         :ok <- annotations(value[:annotations], opts),
         :ok <- schema(value[:input_schema], opts),
         :ok <- schema(value[:output_schema], opts) do
      :ok
    end
  end

  def server_options!(opts) do
    Enum.each([server_name: 1_024, server_version: 1_024, instructions: 65_536], fn {key, max} ->
      value = opts[key]

      field_opts = [
        required: key != :instructions and not is_nil(value),
        multiline: key == :instructions
      ]

      unless valid?(value, max, Keyword.merge(opts, field_opts)),
        do:
          raise(
            ArgumentError,
            "#{key} must be valid UTF-8 text of at most #{max} bytes allowed by :display_text_policy"
          )
    end)
  end

  defp field(value, key, max, opts, extra \\ []) do
    if valid?(value, max, Keyword.merge(opts, extra)),
      do: :ok,
      else: {:error, {:invalid_definition, key}}
  end

  defp arguments(nil, _opts), do: :ok

  defp arguments(arguments, opts) when is_list(arguments) do
    Enum.reduce_while(arguments, :ok, fn argument, :ok ->
      with :ok <- field(argument["name"], :arguments, 256, opts, required: true, multiline: false),
           :ok <- field(argument["description"], :description, 4_096, opts) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp arguments(_arguments, _opts), do: {:error, {:invalid_definition, :arguments}}

  defp annotations(value, opts) when is_map(value),
    do: field(value["title"], :title, 1_024, opts, multiline: false)

  defp annotations(_value, _opts), do: :ok

  # Traverse schema-bearing keywords only: property names and arbitrary default,
  # enum, const and example data are not schema annotations.
  defp schema(value, opts) when is_map(value) do
    with :ok <- field(value["title"], :title, 1_024, opts, multiline: false),
         :ok <- field(value["description"], :description, 4_096, opts) do
      Enum.reduce_while(value, :ok, fn {key, child}, :ok ->
        result = schema_child(key, child, opts)
        if result == :ok, do: {:cont, :ok}, else: {:halt, result}
      end)
    end
  end

  defp schema(_value, _opts), do: :ok

  defp schema_child(key, children, opts)
       when key in ["properties", "patternProperties", "$defs", "definitions", "dependentSchemas"] and
              is_map(children),
       do: schema_list(Map.values(children), opts)

  defp schema_child(key, children, opts)
       when key in ["allOf", "anyOf", "oneOf", "prefixItems", "items"] and is_list(children),
       do: schema_list(children, opts)

  defp schema_child(key, child, opts)
       when key in [
              "items",
              "additionalItems",
              "additionalProperties",
              "unevaluatedProperties",
              "unevaluatedItems",
              "contains",
              "propertyNames",
              "not",
              "if",
              "then",
              "else"
            ],
       do: schema(child, opts)

  defp schema_child(_key, _child, _opts), do: :ok

  defp schema_list(children, opts) do
    Enum.reduce_while(children, :ok, fn child, :ok ->
      case schema(child, opts) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # Only protocol display text is inspected. Binary/base64 and structured
  # application data are deliberately opaque, as is application-owned _meta.
  def wire(value, opts) do
    if opts[:display_text_policy] != :reject or wire_safe?(value),
      do: :ok,
      else: {:error, :terminal_control_character}
  end

  defp wire_safe?(value) when is_map(value) do
    Enum.all?(value, fn
      {"_meta", meta} when is_map(meta) ->
        wire_safe?(meta["io.modelcontextprotocol/serverInfo"])

      {key, _value} when key in @opaque_fields ->
        true

      {key, value} when key in @display_fields and is_binary(value) ->
        valid?(value, byte_size(value),
          display_text_policy: :reject,
          multiline: key not in ["name", "version", "title"]
        )

      {key, value} when key in ["inputSchema", "outputSchema", "requestedSchema"] ->
        schema(value, display_text_policy: :reject) == :ok

      {_key, value} ->
        wire_safe?(value)
    end)
  end

  defp wire_safe?(values) when is_list(values), do: Enum.all?(values, &wire_safe?/1)
  defp wire_safe?(_value), do: true
end
