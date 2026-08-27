defmodule AttestoMCP.Server.JSONRPC do
  @moduledoc "Strict JSON-RPC 2.0 decoding and encoding for MCP wire messages."

  alias AttestoMCP.Server.{Error, Schema}

  @type id :: String.t() | integer()
  @type json_value :: nil | boolean() | number() | String.t() | [json_value()] | json_object()
  @type json_object :: %{optional(String.t()) => json_value()}
  @type extensions :: json_object()
  @type request :: %{
          required(:kind) => :request,
          required(:id) => id(),
          required(:method) => String.t(),
          required(:params) => map(),
          optional(:extensions) => extensions()
        }
  @type notification :: %{
          required(:kind) => :notification,
          required(:method) => String.t(),
          required(:params) => map(),
          optional(:extensions) => extensions()
        }
  @type response :: %{
          required(:kind) => :response,
          required(:id) => id(),
          required(:result) => json_value(),
          required(:error) => map() | nil,
          optional(:extensions) => extensions()
        }

  @spec decode(binary(), keyword()) ::
          {:ok, request() | notification() | response()} | {:error, Error.t()}
  def decode(payload, opts \\ [])

  def decode(payload, opts) when is_binary(payload) do
    max = Keyword.get(opts, :max_bytes, 1_000_000)
    max_depth = Keyword.get(opts, :max_depth, 64)

    cond do
      byte_size(payload) > max ->
        {:error, Error.parse(%{"reason" => "message_too_large"})}

      not String.valid?(payload) ->
        {:error, Error.parse(%{"reason" => "invalid_utf8"})}

      true ->
        case Jason.decode(payload) do
          {:ok, value} ->
            if within_depth?(value, 0, max_depth),
              do: validate(value),
              else: {:error, Error.parse(%{"reason" => "message_too_deep"})}

          {:error, _} ->
            {:error, Error.parse()}
        end
    end
  end

  def decode(_, _), do: {:error, Error.parse()}

  @doc "Recovers a valid JSON-RPC ID from an otherwise invalid JSON object."
  @spec recover_id(binary(), keyword()) :: id() | nil
  def recover_id(payload, opts \\ [])

  def recover_id(payload, opts) when is_binary(payload) do
    max_bytes = Keyword.get(opts, :max_bytes, 1_000_000)

    with true <- byte_size(payload) <= max_bytes,
         true <- String.valid?(payload),
         {:ok, %{"id" => id}} <- Jason.decode(payload),
         true <- valid_recoverable_id?(id) do
      id
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def recover_id(_, _opts), do: nil

  defp valid_recoverable_id?(id) when is_integer(id), do: true

  defp valid_recoverable_id?(id) when is_binary(id),
    do: byte_size(id) in 1..256 and String.valid?(id)

  defp valid_recoverable_id?(_), do: false

  @spec encode(map()) :: binary()
  def encode(message) do
    if json_value?(message) do
      Jason.encode!(message)
    else
      id = if is_map(message), do: Map.get(message, "id"), else: nil

      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => if(is_binary(id) or is_integer(id), do: id, else: nil),
        "error" => %{"code" => -32603, "message" => "Internal error"}
      })
    end
  rescue
    _ -> ~s({"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}})
  end

  defp json_value?(value), do: Schema.json_value(value) == :ok

  defp validate(value) when is_list(value),
    do: {:error, Error.invalid_request(%{"reason" => "batch_not_supported"})}

  defp validate(value) when not is_map(value), do: {:error, Error.invalid_request()}

  defp validate(%{"jsonrpc" => "2.0", "method" => method} = map) when is_binary(method) do
    with :ok <- validate_method(method),
         :ok <- reject_response_fields(map),
         :ok <- validate_id(Map.get(map, "id", :missing)),
         :ok <- validate_params(Map.get(map, "params", %{})) do
      if Map.has_key?(map, "id") do
        {:ok,
         with_extensions(
           %{
             kind: :request,
             id: Map.fetch!(map, "id"),
             method: method,
             params: Map.get(map, "params", %{})
           },
           map,
           ["jsonrpc", "id", "method", "params"]
         )}
      else
        {:ok,
         with_extensions(
           %{kind: :notification, method: method, params: Map.get(map, "params", %{})},
           map,
           ["jsonrpc", "method", "params"]
         )}
      end
    end
  end

  defp validate(%{"jsonrpc" => "2.0", "id" => id} = map) do
    with :ok <- validate_id(id),
         :ok <- reject_request_fields(map),
         {:ok, result} <- response_result(map) do
      {:ok,
       with_extensions(
         %{kind: :response, id: id, result: result, error: Map.get(map, "error")},
         map,
         ["jsonrpc", "id", "result", "error"]
       )}
    end
  end

  defp validate(_), do: {:error, Error.invalid_request()}

  defp response_result(%{"result" => result} = map) when not is_map_key(map, "error"),
    do: {:ok, result}

  defp response_result(%{"error" => error} = map)
       when is_map(error) and not is_map_key(map, "result") do
    if valid_error_object?(error), do: {:ok, nil}, else: {:error, Error.invalid_request()}
  end

  defp response_result(_), do: {:error, Error.invalid_request()}

  defp validate_id(id) when is_binary(id) and byte_size(id) in 1..256 do
    if String.valid?(id),
      do: :ok,
      else: {:error, Error.invalid_request(%{"reason" => "invalid_id"})}
  end

  defp validate_id(id) when is_integer(id), do: :ok
  defp validate_id(:missing), do: :ok

  defp validate_id(_),
    do: {:error, Error.invalid_request(%{"reason" => "id_must_be_string_or_integer"})}

  defp validate_method(method) when byte_size(method) in 1..256 do
    if String.valid?(method) and not String.contains?(method, ["\u0000", "\r", "\n"]),
      do: :ok,
      else: {:error, Error.invalid_request(%{"reason" => "invalid_method"})}
  end

  defp validate_method(_), do: {:error, Error.invalid_request(%{"reason" => "invalid_method"})}

  defp reject_response_fields(map) do
    if Map.has_key?(map, "result") or Map.has_key?(map, "error"),
      do: {:error, Error.invalid_request(%{"reason" => "request_has_response_fields"})},
      else: :ok
  end

  defp reject_request_fields(map) do
    if Map.has_key?(map, "method"),
      do: {:error, Error.invalid_request(%{"reason" => "response_has_method"})},
      else: :ok
  end

  defp valid_error_object?(%{"code" => code, "message" => message})
       when is_integer(code) and is_binary(message) and byte_size(message) <= 256,
       do: true

  defp valid_error_object?(_), do: false

  defp validate_params(params) when is_map(params), do: :ok

  defp validate_params(_),
    do: {:error, Error.invalid_request(%{"reason" => "params_must_be_object"})}

  defp with_extensions(message, map, known_keys) do
    case Map.drop(map, known_keys) do
      extensions when map_size(extensions) == 0 -> message
      extensions -> Map.put(message, :extensions, extensions)
    end
  end

  @spec response(term(), term()) :: map()
  def response(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  def error_response(id, %Error{} = error), do: Error.json(error, id)

  defp within_depth?(_value, depth, max_depth) when depth > max_depth, do: false

  defp within_depth?(value, depth, max_depth) when is_map(value) do
    Enum.all?(value, fn {_key, child} -> within_depth?(child, depth + 1, max_depth) end)
  end

  defp within_depth?(value, depth, max_depth) when is_list(value),
    do: Enum.all?(value, &within_depth?(&1, depth + 1, max_depth))

  defp within_depth?(_value, _depth, _max_depth), do: true
end
