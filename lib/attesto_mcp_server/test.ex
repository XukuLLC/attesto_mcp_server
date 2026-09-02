defmodule AttestoMCP.Server.Test do
  @moduledoc """
  Focused helpers for exercising registered tools in host test suites.

  `call_tool/4` builds and decodes a JSON-RPC `tools/call` request, dispatches it
  through the supervised server, and returns the complete JSON-RPC response
  map. This uses the same operation-scope, definition-scope, definition
  `authorize`, input-schema, handler, output-schema, and wire-output path as
  transport dispatch.

  The helper starts after transport authentication. `:principal`, `:tenant`,
  `:scopes`, and `:host_context` represent an already authenticated request; it
  does not verify a token, DPoP proof, mTLS certificate, HTTP header, or parser
  order. Keep separate Plug-level tests for that boundary.

      response =
        AttestoMCP.Server.Test.call_tool(
          MyApp.MCP,
          "get_item",
          %{"id" => "item-7"},
          principal: principal,
          scopes: ["items.read"],
          host_context: %{account_id: "acct-1"}
        )

      assert %{"result" => %{"structuredContent" => %{"id" => "item-7"}}} = response

  JSON encoding and decoding are performed before dispatch, so the server
  receives the same nested string keys that a JSON client sends before any
  configured tool-argument key policy is applied.
  """

  alias AttestoMCP.Server
  alias AttestoMCP.Server.{Error, JSONRPC}

  @modern "2026-07-28"
  @allowed_options [
    :principal,
    :tenant,
    :scopes,
    :host_context,
    :request_id,
    :protocol_version,
    :client_capabilities,
    :timeout
  ]

  @type option ::
          {:principal, term()}
          | {:tenant, term()}
          | {:scopes, [String.t()]}
          | {:host_context, map()}
          | {:request_id, String.t() | integer()}
          | {:protocol_version, String.t()}
          | {:client_capabilities, map()}
          | {:timeout, pos_integer()}

  @doc """
  Calls one registered tool and returns its complete JSON-RPC response map.

  The default protocol revision is `2026-07-28`, the default principal is
  `"test-principal"`, and the default scope list is empty. Use `:request_id`
  when a stable response ID is useful in an assertion. `:client_capabilities`
  supplies the modern request's declared capabilities, including capabilities
  needed by a tool that returns an interactive request.

  Invalid schemas, insufficient scopes, denied `authorize` callbacks, handler
  failures, and invalid outputs are returned exactly as protocol `"error"` or
  `"result"` members. Malformed helper options and values that cannot be
  represented as JSON raise `ArgumentError` because they are test setup errors.
  """
  @spec call_tool(AttestoMCP.Server.API.server(), String.t(), map(), [option()]) :: map()
  def call_tool(server, name, arguments, opts \\ []) do
    validate_arguments!(name, arguments)
    opts = options!(opts)

    id = Keyword.get(opts, :request_id, System.unique_integer([:positive, :monotonic]))
    version = Keyword.get(opts, :protocol_version, @modern)
    client_capabilities = Keyword.get(opts, :client_capabilities, %{})
    timeout = Keyword.get(opts, :timeout)

    validate_option_values!(id, version, client_capabilities, timeout, opts)

    params =
      %{"name" => name, "arguments" => arguments}
      |> put_protocol_metadata(version, client_capabilities)

    wire_request = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => params
    }

    max_bytes = Server.options(server)[:max_json_bytes]

    with {:ok, encoded} <- Jason.encode(wire_request),
         {:ok, request} <- JSONRPC.decode(encoded, max_bytes: max_bytes) do
      dispatch_opts =
        [version: version]
        |> maybe_put_option(:timeout, timeout)

      case Server.dispatch(server, request, context(opts), dispatch_opts) do
        {^id, response} when is_map(response) -> response
      end
    else
      {:error, %Error{} = error} -> JSONRPC.error_response(id, error)
      {:error, _reason} -> raise ArgumentError, "tool arguments must be JSON-encodable"
    end
  end

  defp validate_arguments!(name, arguments) do
    unless is_binary(name) and name != "" and is_map(arguments) do
      raise ArgumentError, "tool name must be a non-empty string and arguments must be a map"
    end
  end

  defp options!(opts) do
    valid? =
      is_list(opts) and Keyword.keyword?(opts) and
        Keyword.keys(opts) == Enum.uniq(Keyword.keys(opts)) and
        Enum.all?(Keyword.keys(opts), &(&1 in @allowed_options))

    if valid?, do: opts, else: raise(ArgumentError, "invalid or duplicate tool test option")
  end

  defp validate_option_values!(id, version, client_capabilities, timeout, opts) do
    valid_id? =
      is_integer(id) or
        (is_binary(id) and byte_size(id) in 1..256 and String.valid?(id))

    scopes = Keyword.get(opts, :scopes, [])
    host_context = Keyword.get(opts, :host_context, %{})

    valid_scopes? =
      is_list(scopes) and scopes == Enum.uniq(scopes) and
        Enum.all?(scopes, fn scope ->
          is_binary(scope) and byte_size(scope) in 1..256 and String.valid?(scope)
        end)

    valid_timeout? = is_nil(timeout) or (is_integer(timeout) and timeout > 0)

    unless valid_id? and is_binary(version) and version != "" and
             is_map(client_capabilities) and valid_scopes? and is_map(host_context) and
             valid_timeout? do
      raise ArgumentError, "invalid tool test option value"
    end
  end

  defp put_protocol_metadata(params, @modern, client_capabilities) do
    Map.put(params, "_meta", %{
      "io.modelcontextprotocol/protocolVersion" => @modern,
      "io.modelcontextprotocol/clientCapabilities" => client_capabilities
    })
  end

  defp put_protocol_metadata(params, _version, _client_capabilities), do: params

  defp context(opts) do
    %{
      principal: Keyword.get(opts, :principal, "test-principal"),
      scopes: Keyword.get(opts, :scopes, [])
    }
    |> maybe_put_context(:tenant, opts)
    |> maybe_put_context(:host_context, opts)
  end

  defp maybe_put_context(context, key, opts) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> Map.put(context, key, value)
      :error -> context
    end
  end

  defp maybe_put_option(opts, _key, nil), do: opts
  defp maybe_put_option(opts, key, value), do: Keyword.put(opts, key, value)
end
