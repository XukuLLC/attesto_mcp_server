defmodule AttestoMCP.Server.Test do
  @moduledoc """
  Helpers for exercising a registered catalog in host test suites.

  Each helper builds a JSON-RPC request, encodes and decodes it as JSON,
  dispatches it through the supervised server, and returns the complete
  JSON-RPC response map. Requests take the same operation-scope,
  definition-scope, definition `authorize`, schema, handler, cache-hint, and
  final wire-output path as transport dispatch. Handlers are never called
  directly.

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

  The same request path is available for the other primitives:

      AttestoMCP.Server.Test.read_resource(MyApp.MCP, "file:///docs/item-7")
      AttestoMCP.Server.Test.get_prompt(MyApp.MCP, "summarize", %{"topic" => "release"})
      AttestoMCP.Server.Test.complete(MyApp.MCP, %{"type" => "ref/prompt", "name" => "summarize"},
        %{"name" => "topic", "value" => "rel"})
      AttestoMCP.Server.Test.discover(MyApp.MCP)
      AttestoMCP.Server.Test.list_tools(MyApp.MCP, cursor: next_cursor)

  `request/4` sends any other method through the same builder.

  ## Boundaries

  The helpers start after transport authentication. `:principal`, `:tenant`,
  `:scopes`, and `:host_context` represent an already authenticated request.
  They do not verify a token, DPoP proof, mTLS certificate, HTTP header, or
  Plug parser order, and they do not establish HTTP header/body mirroring,
  legacy session negotiation, stdio framing, or disconnect behaviour. Keep
  separate Plug and stdio tests for those boundaries.

  ## Options

  Every helper accepts:

    * `:principal` (default `"test-principal"`), `:tenant`, `:scopes`
      (default `[]`), and `:host_context`: the authenticated handler context.
      These are never copied into protocol parameters.
    * `:request_id`: a stable response ID.
    * `:protocol_version`: the request revision, default `"2026-07-28"`.
    * `:client_capabilities`: the modern request's declared capabilities.
    * `:meta`: application metadata for `params["_meta"]`, which handlers see
      as `context.request_meta`. The helper generates the protocol version and
      client capability keys; supplying either in `:meta` raises.
    * `:request_state` and `:input_responses`: modern multi-round retry fields
      for `call_tool/4`, `read_resource/3`, `get_prompt/4`, and `request/4`.
    * `:timeout`: a positive request timeout in milliseconds, still capped by
      the server's `:max_request_timeout`.

  List helpers also accept `:cursor`, and `complete/4` accepts
  `:completion_context` (the request's `context` member).

  Protocol failures, including denied definitions, invalid schemas, missing
  prompt arguments, invalid completion references, invalid cursors, handler
  failures, and invalid outputs, are returned as the server's `"error"` or
  `"result"` members. Malformed helper options and values that cannot be
  represented as JSON raise `ArgumentError` because they are test setup
  errors.
  """

  alias AttestoMCP.Server
  alias AttestoMCP.Server.{Error, JSONRPC}

  @modern "2026-07-28"
  @generated_meta_keys [
    "io.modelcontextprotocol/protocolVersion",
    "io.modelcontextprotocol/clientCapabilities"
  ]
  @common_options [
    :principal,
    :tenant,
    :scopes,
    :host_context,
    :request_id,
    :protocol_version,
    :client_capabilities,
    :meta,
    :timeout
  ]
  @retry_options [:request_state, :input_responses]
  @protocol_param_keys [
    "_meta",
    "requestState",
    "inputResponses",
    :_meta,
    :requestState,
    :inputResponses
  ]

  @type option ::
          {:principal, term()}
          | {:tenant, term()}
          | {:scopes, [String.t()]}
          | {:host_context, map()}
          | {:request_id, String.t() | integer()}
          | {:protocol_version, String.t()}
          | {:client_capabilities, map()}
          | {:meta, map()}
          | {:request_state, String.t()}
          | {:input_responses, map()}
          | {:cursor, String.t()}
          | {:completion_context, map()}
          | {:timeout, pos_integer()}

  @doc """
  Calls one registered tool and returns its complete JSON-RPC response map.

  The default protocol revision is `2026-07-28`, the default principal is
  `"test-principal"`, and the default scope list is empty. Use `:request_id`
  when a stable response ID is useful in an assertion. `:client_capabilities`
  supplies the modern request's declared capabilities, including capabilities
  needed by a tool that returns an interactive request.
  """
  @spec call_tool(AttestoMCP.Server.API.server(), String.t(), map(), [option()]) :: map()
  def call_tool(server, name, arguments, opts \\ []) do
    unless is_binary(name) and name != "" and is_map(arguments) do
      raise ArgumentError, "tool name must be a non-empty string and arguments must be a map"
    end

    send_request(
      server,
      "tools/call",
      %{"name" => name, "arguments" => arguments},
      opts,
      @retry_options
    )
  end

  @doc "Reads a static or templated resource through the production resolver."
  @spec read_resource(AttestoMCP.Server.API.server(), String.t(), [option()]) :: map()
  def read_resource(server, uri, opts \\ []) do
    unless is_binary(uri) and uri != "",
      do: raise(ArgumentError, "resource URI must be a non-empty string")

    send_request(server, "resources/read", %{"uri" => uri}, opts, @retry_options)
  end

  @doc "Retrieves a prompt with string arguments."
  @spec get_prompt(AttestoMCP.Server.API.server(), String.t(), map(), [option()]) :: map()
  def get_prompt(server, name, arguments, opts \\ []) do
    unless is_binary(name) and name != "" and is_map(arguments) do
      raise ArgumentError, "prompt name must be a non-empty string and arguments must be a map"
    end

    send_request(
      server,
      "prompts/get",
      %{"name" => name, "arguments" => arguments},
      opts,
      @retry_options
    )
  end

  @doc """
  Requests completions for a prompt or resource-template reference.

  `ref` is the wire reference, for example
  `%{"type" => "ref/prompt", "name" => "summarize"}`, and `argument` is
  `%{"name" => name, "value" => partial_value}`.
  """
  @spec complete(AttestoMCP.Server.API.server(), map(), map(), [option()]) :: map()
  def complete(server, ref, argument, opts \\ []) do
    unless is_map(ref) and is_map(argument),
      do: raise(ArgumentError, "completion ref and argument must be maps")

    {completion_context, opts} = pop_option(opts, :completion_context)

    unless is_nil(completion_context) or is_map(completion_context),
      do: raise(ArgumentError, ":completion_context must be a map")

    params =
      %{"ref" => ref, "argument" => argument}
      |> maybe_put("context", completion_context)

    send_request(server, "completion/complete", params, opts, [])
  end

  @doc "Sends modern `server/discover`."
  @spec discover(AttestoMCP.Server.API.server(), [option()]) :: map()
  def discover(server, opts \\ []) do
    opts = options!(opts, @common_options)

    if Keyword.get(opts, :protocol_version, @modern) != @modern,
      do: raise(ArgumentError, "server/discover is defined only for #{@modern}")

    send_request(server, "server/discover", %{}, opts, [])
  end

  @doc "Lists one page of tools. Pass `:cursor` for a continuation."
  @spec list_tools(AttestoMCP.Server.API.server(), [option()]) :: map()
  def list_tools(server, opts \\ []), do: list(server, "tools/list", opts)

  @doc "Lists one page of static resources."
  @spec list_resources(AttestoMCP.Server.API.server(), [option()]) :: map()
  def list_resources(server, opts \\ []), do: list(server, "resources/list", opts)

  @doc "Lists one page of resource templates."
  @spec list_resource_templates(AttestoMCP.Server.API.server(), [option()]) :: map()
  def list_resource_templates(server, opts \\ []),
    do: list(server, "resources/templates/list", opts)

  @doc "Lists one page of prompts."
  @spec list_prompts(AttestoMCP.Server.API.server(), [option()]) :: map()
  def list_prompts(server, opts \\ []), do: list(server, "prompts/list", opts)

  @doc """
  Sends any request method through the shared builder.

  `params` must not contain `_meta`, `requestState`, or `inputResponses`; use
  the `:meta`, `:request_state`, and `:input_responses` options so the helper
  can keep protocol fields separate from application metadata.
  """
  @spec request(AttestoMCP.Server.API.server(), String.t(), map(), [option()]) :: map()
  def request(server, method, params \\ %{}, opts \\ []) do
    unless is_binary(method) and method != "" and is_map(params),
      do: raise(ArgumentError, "method must be a non-empty string and params must be a map")

    if Enum.any?(@protocol_param_keys, &Map.has_key?(params, &1)) do
      raise ArgumentError,
            "pass _meta, requestState, and inputResponses through :meta, :request_state, and :input_responses"
    end

    send_request(server, method, params, opts, @retry_options)
  end

  defp list(server, method, opts) do
    {cursor, opts} = pop_option(opts, :cursor)

    unless is_nil(cursor) or is_binary(cursor),
      do: raise(ArgumentError, ":cursor must be a string")

    send_request(server, method, maybe_put(%{}, "cursor", cursor), opts, [])
  end

  defp send_request(server, method, params, opts, extra_options) do
    opts = options!(opts, @common_options ++ extra_options)

    id = Keyword.get(opts, :request_id, System.unique_integer([:positive, :monotonic]))
    version = Keyword.get(opts, :protocol_version, @modern)
    client_capabilities = Keyword.get(opts, :client_capabilities, %{})
    meta = Keyword.get(opts, :meta, %{})
    timeout = Keyword.get(opts, :timeout)

    validate_option_values!(id, version, client_capabilities, meta, timeout, opts)

    params =
      params
      |> put_retry_fields(version, opts)
      |> put_protocol_metadata(version, client_capabilities, meta)

    wire_request = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
    max_bytes = Server.options(server)[:max_json_bytes]

    with {:ok, encoded} <- Jason.encode(wire_request),
         {:ok, request} <- JSONRPC.decode(encoded, max_bytes: max_bytes) do
      dispatch_opts = maybe_put_option([version: version], :timeout, timeout)

      case Server.dispatch(server, request, context(opts), dispatch_opts) do
        {^id, response} when is_map(response) -> response
      end
    else
      {:error, %Error{} = error} -> JSONRPC.error_response(id, error)
      {:error, _reason} -> raise ArgumentError, "request values must be JSON-encodable"
    end
  end

  defp options!(opts, allowed) do
    valid? =
      is_list(opts) and Keyword.keyword?(opts) and
        Keyword.keys(opts) == Enum.uniq(Keyword.keys(opts)) and
        Enum.all?(Keyword.keys(opts), &(&1 in allowed))

    if valid?, do: opts, else: raise(ArgumentError, "invalid or duplicate test request option")
  end

  defp pop_option(opts, key) when is_list(opts) do
    if Keyword.keyword?(opts) and length(Keyword.get_values(opts, key)) <= 1,
      do: Keyword.pop(opts, key),
      else: raise(ArgumentError, "invalid or duplicate test request option")
  end

  defp pop_option(_opts, _key),
    do: raise(ArgumentError, "invalid or duplicate test request option")

  defp validate_option_values!(id, version, client_capabilities, meta, timeout, opts) do
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
      raise ArgumentError, "invalid test request option value"
    end

    validate_meta!(meta)
  end

  defp validate_meta!(meta) when is_map(meta) do
    unless Enum.all?(Map.keys(meta), &is_binary/1),
      do: raise(ArgumentError, ":meta must use string keys")

    case Enum.filter(@generated_meta_keys, &Map.has_key?(meta, &1)) do
      [] ->
        :ok

      conflicts ->
        raise ArgumentError,
              ":meta cannot set #{Enum.join(conflicts, ", ")}; use :protocol_version or :client_capabilities"
    end
  end

  defp validate_meta!(_meta), do: raise(ArgumentError, ":meta must be a map")

  defp put_retry_fields(params, version, opts) do
    request_state = Keyword.get(opts, :request_state)
    input_responses = Keyword.get(opts, :input_responses)

    cond do
      is_nil(request_state) and is_nil(input_responses) ->
        params

      version != @modern ->
        raise ArgumentError, "multi-round retry fields require protocol version #{@modern}"

      not (is_nil(request_state) or is_binary(request_state)) or
          not (is_nil(input_responses) or is_map(input_responses)) ->
        raise ArgumentError, ":request_state must be a string and :input_responses a map"

      true ->
        params
        |> maybe_put("requestState", request_state)
        |> maybe_put("inputResponses", input_responses)
    end
  end

  defp put_protocol_metadata(params, @modern, client_capabilities, meta) do
    Map.put(
      params,
      "_meta",
      Map.merge(meta, %{
        "io.modelcontextprotocol/protocolVersion" => @modern,
        "io.modelcontextprotocol/clientCapabilities" => client_capabilities
      })
    )
  end

  defp put_protocol_metadata(params, _version, _client_capabilities, meta)
       when map_size(meta) == 0,
       do: params

  defp put_protocol_metadata(params, _version, _client_capabilities, meta),
    do: Map.put(params, "_meta", meta)

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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_option(opts, _key, nil), do: opts
  defp maybe_put_option(opts, key, value), do: Keyword.put(opts, key, value)
end
