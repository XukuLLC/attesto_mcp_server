defmodule AttestoMCP.Server.Error do
  @moduledoc "Dated MCP/JSON-RPC error values and safe encoders."

  defstruct [:code, :message, :data, :http_status]

  @type t :: %__MODULE__{
          code: integer(),
          message: String.t(),
          data: term(),
          http_status: pos_integer()
        }

  @spec parse(term()) :: t()
  def parse(data \\ nil), do: new(-32700, "Parse error", data, 400)
  def invalid_request(data \\ nil), do: new(-32600, "Invalid Request", data, 400)

  def method_not_found(method, status \\ 404),
    do: new(-32601, "Method not found", %{"method" => method}, status)

  def invalid_params(data \\ nil), do: new(-32602, "Invalid params", data, 400)
  def internal(data \\ nil), do: new(-32603, "Internal error", data, 500)
  def invalid_header(data \\ nil), do: new(-32020, "Invalid MCP metadata or header", data, 400)

  def unsupported_media(data \\ nil),
    do: new(-32020, "Unsupported media type", data, 415)

  def missing_capability(%{"requiredCapabilities" => _} = data),
    do: new(-32021, "Required client capability is missing", data, 400)

  def missing_capability(data),
    do:
      new(
        -32021,
        "Required client capability is missing",
        %{"requiredCapabilities" => data || %{}},
        400
      )

  def unsupported_version(version, versions),
    do:
      new(
        -32022,
        "Unsupported protocol version",
        %{"requested" => version, "supported" => versions},
        400
      )

  def legacy_resource_not_found(uri), do: new(-32002, "Resource not found", %{uri: uri}, 404)

  def insufficient_scope(scopes),
    do: new(-32003, "insufficient_scope", %{"required_scopes" => scopes}, 403)

  def rate_limited,
    do: new(-32029, "Rate limit exceeded", %{"reason" => "rate_limited"}, 429)

  def session_not_found,
    do: new(-32600, "Session not found", %{"reason" => "session_not_found"}, 404)

  def session_store_unavailable,
    do: %__MODULE__{
      internal(%{"reason" => "session_store_unavailable"})
      | http_status: 503
    }

  def application(message, code \\ nil) when is_binary(message) do
    data = if is_binary(code), do: %{"code" => code}, else: nil
    new(-32_000, message, data, 200)
  end

  def cancelled, do: new(-32800, "Request cancelled", nil, 499)

  defp new(code, message, data, http_status),
    do: %__MODULE__{code: code, message: message, data: data, http_status: http_status}

  @spec json(t(), term()) :: map()
  def json(%__MODULE__{} = error, id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" =>
        compact(%{"code" => error.code, "message" => error.message, "data" => error.data})
    }
  end

  defp compact(map), do: Enum.reject(map, fn {_k, value} -> is_nil(value) end) |> Map.new()
end
