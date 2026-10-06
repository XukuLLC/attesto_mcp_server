defmodule AttestoMCP.Server.RequestMeta do
  @moduledoc """
  Untrusted request metadata exposed to handlers as `context.request_meta`.

  Every handler and per-request callback receives an immutable snapshot of the
  incoming request's `params["_meta"]` object with its JSON string keys and
  values unchanged. An absent object, which only legacy revisions permit,
  produces `%{}`. The snapshot is the same for HTTP, stdio, and direct
  dispatch through `AttestoMCP.Server.Test`.

  The snapshot is client input. It is never merged into `principal`,
  `principal_binding`, `tenant`, `scopes`, claims, sender constraints, or
  `host_context`, and the server never derives an issuer, audience,
  authorization decision, or outbound destination from it. Protocol-owned keys
  such as `io.modelcontextprotocol/protocolVersion` appear exactly as the client
  sent them; the server's validated interpretation remains in the normalized
  context fields (`:protocol_version`, `:trace_context`, `:logging_level`) and
  is not changed by the snapshot. Use `application/1` to read only keys outside
  the reserved MCP namespaces.

  The complete `_meta` object must encode within `:max_request_meta_bytes`
  (65,536 bytes by default, configurable up to `:max_json_bytes`) and within
  the server's existing JSON depth and node bounds. Larger metadata is rejected
  with an invalid-params error whose reason is `"request_meta_too_large"`;
  it is never truncated. String keys and values are copied out of the request
  body so a retained snapshot does not keep the body alive.

  Metadata values are not added to logs, telemetry, error payloads, or response
  metadata. The existing trace-context extraction remains separate.

  A multi-round retry exposes its own metadata. The signed retry state binds
  operation parameters and all metadata except `traceparent`, `tracestate`,
  `baggage`, `progressToken`, and `io.modelcontextprotocol/clientInfo`.
  Application keys and protocol settings remain bound to the first round;
  tracing, progress, and display values may change. Operation targets and
  confirmation-bound values belong in operation parameters, not those volatile
  fields. No identity or authority is recovered from earlier metadata.
  """

  alias AttestoMCP.Server.Schema

  @default_max_bytes 65_536
  @reserved_names ["progressToken", "traceparent", "tracestate", "baggage"]
  @label "[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?"
  @key_pattern Regex.compile!(
                 "^(?:#{@label}(?:\\.#{@label})*/)?(?:[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?)?$"
               )

  @doc "Returns the default metadata byte budget."
  @spec default_max_bytes() :: pos_integer()
  def default_max_bytes, do: @default_max_bytes

  @doc false
  @spec snapshot(term(), keyword()) ::
          {:ok, map()} | {:error, :invalid_request_meta | :request_meta_too_large}
  def snapshot(params, opts) when is_map(params) do
    case Map.fetch(params, "_meta") do
      :error -> {:ok, %{}}
      {:ok, meta} when is_map(meta) -> bounded_copy(meta, opts)
      {:ok, _meta} -> {:error, :invalid_request_meta}
    end
  end

  def snapshot(_params, _opts), do: {:ok, %{}}

  @doc """
  Returns the entries whose keys are outside MCP-reserved metadata names.

      iex> AttestoMCP.Server.RequestMeta.application(%{
      ...>   "com.example/request-purpose" => "audit",
      ...>   "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      ...>   "progressToken" => 7
      ...> })
      %{"com.example/request-purpose" => "audit"}
  """
  @spec application(map()) :: map()
  def application(meta) when is_map(meta),
    do: meta |> Enum.reject(fn {key, _value} -> reserved_key?(key) end) |> Map.new()

  @doc """
  Returns true for keys reserved by MCP: `progressToken`, the trace-context
  keys, and any prefix whose second label is `modelcontextprotocol` or `mcp`.
  """
  @spec reserved_key?(term()) :: boolean()
  def reserved_key?(key) when key in @reserved_names, do: true

  def reserved_key?(key) when is_binary(key) do
    case String.split(key, "/", parts: 2) do
      [prefix, _name] ->
        case String.split(prefix, ".") do
          [_first, second | _rest] -> String.downcase(second) in ["modelcontextprotocol", "mcp"]
          _labels -> false
        end

      [_name] ->
        false
    end
  end

  def reserved_key?(_key), do: false

  @doc "Returns true when a key follows the MCP `_meta` key grammar."
  @spec valid_key?(term()) :: boolean()
  def valid_key?(key) when is_binary(key) and byte_size(key) in 1..256,
    do: String.valid?(key) and Regex.match?(@key_pattern, key)

  def valid_key?(_key), do: false

  defp bounded_copy(meta, opts) do
    json_budget = Keyword.get(opts, :max_json_bytes, Schema.default_instance_bytes())
    max_bytes = min(Keyword.get(opts, :max_request_meta_bytes) || @default_max_bytes, json_budget)

    cond do
      Schema.json_value(meta, max_bytes: max_bytes) == :ok -> {:ok, copy(meta)}
      Schema.json_value(meta, max_bytes: json_budget) == :ok -> {:error, :request_meta_too_large}
      true -> {:error, :invalid_request_meta}
    end
  end

  defp copy(value) when is_binary(value), do: :binary.copy(value)
  defp copy(value) when is_list(value), do: Enum.map(value, &copy/1)
  defp copy(value) when is_map(value), do: Map.new(value, fn {k, v} -> {copy(k), copy(v)} end)
  defp copy(value), do: value
end
