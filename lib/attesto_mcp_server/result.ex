defmodule AttestoMCP.Server.Result do
  @moduledoc """
  Typed MCP result constructors and explicit client-visible business failures.

  `tool/2` and `resource/2` emit canonical string-key maps and validate their
  complete aggregate against the same bounds used for raw handler output.
  They use the secure 2,000,000-byte default; pass
  `max_json_bytes: server_budget` when the supervised server explicitly uses a
  larger finite JSON budget.

  Inside an arity-two tool handler, `tool_from_context/2` and
  `tool_from_context/3` inherit the supervised server's JSON budget and output
  canonicalization mode from the handler context without allowing those
  settings to be overridden. Standalone `tool/1` and `tool/2` retain their
  secure defaults and explicit configuration options.

  Protocol-owned `resultType`, cache, and server-identity fields are added by
  the server after a handler returns.

  Arbitrary handler errors and exceptions remain private. Use `error/2` only
  for bounded text and a machine-readable code that are safe to disclose to
  the calling client.
  """

  alias AttestoMCP.Server.{Content, Output, Schema}

  @max_message_bytes 4_096
  @max_code_bytes 128
  @canonicalization_modes [:strict, :json, :jason]
  @tool_option_keys [
    :structured_content,
    :is_error,
    :meta,
    :max_json_bytes,
    :output_canonicalization
  ]
  @context_tool_option_keys [:structured_content, :is_error, :meta]

  @type tool_result :: %{required(String.t()) => term()}
  @type resource_result :: %{required(String.t()) => term()}
  @type canonicalization_mode :: :strict | :json | :jason
  @type result_context :: %{
          required(:max_json_bytes) => pos_integer(),
          required(:output_canonicalization) => canonicalization_mode(),
          optional(term()) => term()
        }
  @type tool_option ::
          {:structured_content, term()}
          | {:is_error, boolean()}
          | {:meta, map()}
          | {:max_json_bytes, pos_integer()}
          | {:output_canonicalization, canonicalization_mode()}
  @type context_tool_option ::
          {:structured_content, term()}
          | {:is_error, boolean()}
          | {:meta, map()}
  @type resource_option :: {:meta, map()} | {:max_json_bytes, pos_integer()}

  defmodule ClientError do
    @moduledoc """
    A bounded business error explicitly approved for disclosure to an MCP client.

    Construct values with `AttestoMCP.Server.Result.error/2` so the public
    message and optional machine-readable code are validated.
    """
    @enforce_keys [:message]
    defstruct [:message, :code]

    @type t :: %__MODULE__{message: String.t(), code: String.t() | nil}
  end

  @doc "Builds one explicitly client-visible business error."
  @spec error(String.t(), String.t() | nil) :: ClientError.t()
  def error(message, code \\ nil) do
    unless valid_message?(message) do
      raise ArgumentError, "client error message must be valid UTF-8 between 1 and 4096 bytes"
    end

    unless valid_code?(code) do
      raise ArgumentError, "client error code must be nil or valid UTF-8 between 1 and 128 bytes"
    end

    %ClientError{message: message, code: code}
  end

  @doc """
  Builds a complete tool result from one content block or a list of blocks.

  `:structured_content`, when present, must be a bounded JSON value. Pass
  `output_canonicalization: :json` or `:jason` to opt into the corresponding
  encoder protocol for structs and string conversion for non-boolean atoms.
  `:meta` must be a bounded JSON object. Unknown and duplicate options are
  rejected.
  """
  @spec tool(Content.t() | [Content.t()], [tool_option()]) :: tool_result()
  def tool(content, opts \\ []) do
    opts = options!(opts, @tool_option_keys)

    %{"content" => list_wrap(content)}
    |> put_options(
      opts,
      structured_content: "structuredContent",
      is_error: "isError",
      meta: "_meta"
    )
    |> tool_result!(opts)
  end

  @doc """
  Builds a complete tool result using the supervised server settings in a
  handler context.

  The context must contain valid atom-keyed `:max_json_bytes` and
  `:output_canonicalization` values. The inherited settings cannot be
  overridden through this constructor; use standalone `tool/2` when an
  intentional per-result override is required. Unknown and duplicate options
  are rejected.

  Use this constructor inside a tool handler when its result must follow the
  server's configured JSON budget and output-canonicalization mode.
  """
  @spec tool_from_context(
          Content.t() | [Content.t()],
          result_context(),
          [context_tool_option()]
        ) :: tool_result()
  def tool_from_context(content, context, opts \\ []) do
    context_opts = result_context_options!(context)
    opts = options!(opts, @context_tool_option_keys)

    tool(content, Keyword.merge(opts, context_opts))
  end

  @doc """
  Builds a complete resource result from one resource-content entry or a list.

  The server owns modern cache and result-discrimination fields. Unknown and
  duplicate options are rejected.
  """
  @spec resource(Content.resource_content() | [Content.resource_content()], [resource_option()]) ::
          resource_result()
  def resource(contents, opts \\ []) do
    opts = options!(opts, [:meta, :max_json_bytes])

    %{"contents" => list_wrap(contents)}
    |> put_options(opts, meta: "_meta")
    |> resource_result!(opts)
  end

  @doc false
  @spec valid_message?(term()) :: boolean()
  def valid_message?(message) when is_binary(message),
    do: byte_size(message) in 1..@max_message_bytes and String.valid?(message)

  def valid_message?(_message), do: false

  @doc false
  @spec valid_code?(term()) :: boolean()
  def valid_code?(nil), do: true

  def valid_code?(code) when is_binary(code),
    do: byte_size(code) in 1..@max_code_bytes and String.valid?(code)

  def valid_code?(_code), do: false

  defp tool_result!(value, opts) do
    case Output.normalize_tool_result_detailed(value, budget_opts(opts)) do
      {:ok, result} ->
        result

      {:error, %Output.CanonicalizationError{} = error} ->
        raise ArgumentError, Exception.message(error)

      {:error, _reason} ->
        raise ArgumentError, "invalid MCP tool result"
    end
  end

  defp resource_result!(value, opts) do
    case Output.normalize_resource_result(value, budget_opts(opts)) do
      {:ok, result} -> result
      {:error, _reason} -> raise ArgumentError, "invalid MCP resource result"
    end
  end

  defp options!(opts, allowed) do
    case Output.normalize_options(opts, allowed) do
      {:ok, opts} -> opts
      {:error, :invalid_options} -> raise ArgumentError, "invalid or duplicate MCP result option"
    end
  end

  defp budget_opts(opts) do
    max_bytes = Keyword.get(opts, :max_json_bytes, Schema.default_instance_bytes())
    output_canonicalization = Keyword.get(opts, :output_canonicalization, :strict)

    unless is_integer(max_bytes) and max_bytes >= Schema.min_allowed_instance_bytes() and
             max_bytes <= Schema.max_allowed_instance_bytes() do
      raise ArgumentError,
            ":max_json_bytes must be between #{Schema.min_allowed_instance_bytes()} and #{Schema.max_allowed_instance_bytes()} bytes"
    end

    unless output_canonicalization in @canonicalization_modes,
      do:
        raise(
          ArgumentError,
          ":output_canonicalization must be :strict, :json, or :jason"
        )

    [max_bytes: max_bytes, output_canonicalization: output_canonicalization]
  end

  defp result_context_options!(context) when is_map(context) do
    with {:ok, max_json_bytes} <- Map.fetch(context, :max_json_bytes),
         {:ok, output_canonicalization} <- Map.fetch(context, :output_canonicalization) do
      opts = [
        max_json_bytes: max_json_bytes,
        output_canonicalization: output_canonicalization
      ]

      _validated = budget_opts(opts)
      opts
    else
      :error -> invalid_result_context!()
    end
  end

  defp result_context_options!(_context), do: invalid_result_context!()

  defp invalid_result_context! do
    raise ArgumentError,
          "handler context must be a map containing :max_json_bytes and :output_canonicalization"
  end

  defp put_options(map, opts, mapping) do
    Enum.reduce(mapping, map, fn {option, key}, acc ->
      case Keyword.fetch(opts, option) do
        {:ok, nil} when option == :meta -> acc
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  defp list_wrap(value) when is_list(value), do: value
  defp list_wrap(value), do: [value]
end
