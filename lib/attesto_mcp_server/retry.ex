defmodule AttestoMCP.Server.Retry do
  @moduledoc false

  alias AttestoMCP.Server.{Error, Output, Protocol, RequestState, Schema, Telemetry}

  @modern Protocol.modern()

  @volatile_meta_keys [
    "traceparent",
    "tracestate",
    "baggage",
    "progressToken",
    "io.modelcontextprotocol/clientInfo"
  ]

  @doc false
  def salient(params) when is_map(params) do
    params = Map.drop(params, ["requestState", "inputResponses"])

    case Map.fetch(params, "_meta") do
      {:ok, meta} when is_map(meta) ->
        Map.put(params, "_meta", Map.drop(meta, @volatile_meta_keys))

      _other ->
        params
    end
  end

  @doc false
  def verify(params, binding, method, salient, operation, opts)

  def verify(
        %{"requestState" => state} = params,
        %{principal: principal, tenant: tenant, era: era, request_id: request_id},
        method,
        salient,
        operation,
        opts
      )
      when is_binary(state) and era == @modern do
    case RequestState.verify_payload(state, principal, tenant, era, method, salient,
           secret: opts[:request_state_secret],
           instance: opts[:request_state_instance],
           store: opts[:request_state_store],
           request_id: request_id,
           operation_identity: operation,
           responses: responses(params),
           allow_missing_responses: true,
           consume: false
         ) do
      {:ok, payload} -> {:ok, payload}
      _ -> invalid_state()
    end
  end

  def verify(%{"requestState" => _}, _binding, _method, _salient, _operation, _opts),
    do: invalid_state()

  def verify(_params, _binding, _method, _salient, _operation, _opts), do: {:ok, nil}

  @doc false
  def responses(%{"inputResponses" => responses}) when is_map(responses), do: responses
  def responses(_params), do: %{}

  @doc false
  def responses(%{"inputResponses" => _}, nil), do: %{}
  def responses(_params, nil), do: %{}

  def responses(params, %{"k" => keys} = payload) do
    Map.merge(Map.get(payload, "a", %{}), Map.take(responses(params), keys))
  end

  def responses(params, _payload), do: responses(params)

  @doc false
  def input_keys(nil), do: []

  def input_keys(payload) when is_map(payload) do
    requested = map_keys(Map.get(payload, "q", %{}))
    carried = map_keys(Map.get(payload, "a", %{}))

    Enum.uniq(requested ++ Map.get(payload, "k", []) ++ carried)
  end

  def input_keys(_payload), do: []

  @doc false
  def reject_retry_collisions(payload, disallowed_keys),
    do: reject_collisions(input_keys(payload), disallowed_keys)

  @doc false
  def reject_request_collisions(requests, disallowed_keys) when is_map(requests),
    do: reject_collisions(Map.keys(requests), disallowed_keys)

  @doc false
  def reject_collisions(input_keys, disallowed_keys) do
    disallowed = MapSet.new(disallowed_keys)

    if Enum.any?(input_keys, &MapSet.member?(disallowed, &1)),
      do: {:error, :invalid_input_requests},
      else: :ok
  end

  @doc false
  def consume(nil, _opts), do: :ok

  def consume(payload, opts) do
    if RequestState.consume_payload(payload, store: opts[:request_state_store]),
      do: :ok,
      else: invalid_state()
  end

  @doc false
  def validate_responses(nil, params, _opts) do
    if Map.has_key?(params, "inputResponses"),
      do: {:error, Error.invalid_params(%{"reason" => "request_state_required"})},
      else: :ok
  end

  def validate_responses(%{"q" => input_types} = payload, params, opts)
      when is_map(input_types) do
    supplied = responses(params)

    if Map.has_key?(params, "inputResponses") and not is_map(params["inputResponses"]) do
      {:error, Error.invalid_params(%{"reason" => "invalid_input_response"})}
    else
      case validate_present_responses(input_types, supplied, opts) do
        {:missing_keys, requests} -> {:missing_inputs, payload, requests}
        result -> result
      end
    end
  end

  def validate_responses(_payload, _params, _opts), do: :ok

  @doc false
  def normalize_requests(input, opts) do
    budget_opts =
      json_budget_opts(opts) ++
        [
          elicitation_allow_loopback_http: opts[:elicitation_allow_loopback_http] == true,
          display_text_policy: opts[:display_text_policy] || :off
        ]

    with {:ok, input} <- Output.canonicalize(input, budget_opts) do
      cond do
        is_map(input) and Map.has_key?(input, "method") ->
          normalize_entries([{"input_1", input}], budget_opts)

        is_map(input) ->
          input
          |> Enum.sort_by(fn {key, _value} -> key end)
          |> normalize_entries(budget_opts)

        is_list(input) ->
          input
          |> Enum.with_index(1)
          |> Enum.map(fn {value, index} -> {"input_#{index}", value} end)
          |> normalize_entries(budget_opts)

        true ->
          {:error, :invalid_input_requests}
      end
    else
      _ -> {:error, :invalid_input_requests}
    end
  end

  @doc false
  def require_capabilities(params, requests) do
    capabilities =
      case Protocol.metadata_value(params, "io.modelcontextprotocol/clientCapabilities") do
        value when is_map(value) -> value
        _ -> %{}
      end

    {_supported, missing} =
      Enum.split_with(requests, fn {_key, %{"method" => method}} ->
        Map.has_key?(capabilities, input_capability(method))
      end)

    if missing == [] do
      {:ok, Map.new(requests)}
    else
      required =
        missing
        |> Enum.map(fn {_key, %{"method" => method}} -> {input_capability(method), %{}} end)
        |> Map.new()

      {:error, Error.missing_capability(%{"requiredCapabilities" => required})}
    end
  end

  @doc false
  def issue(input, params, binding, method, salient, operation, opts, disallowed_keys \\ []) do
    with {:ok, requests} <- normalize_requests(input, opts),
         :ok <- reject_request_collisions(requests, disallowed_keys),
         {:ok, requests} <- require_capabilities(params, requests) do
      state =
        RequestState.issue(
          binding.principal,
          binding.tenant,
          binding.era,
          method,
          salient,
          secret: opts[:request_state_secret],
          instance: opts[:request_state_instance],
          ttl: opts[:request_state_ttl],
          request_id: binding.request_id,
          operation_identity: operation,
          input_keys: Map.keys(requests),
          input_types: request_types(requests)
        )

      Telemetry.execute([:mrtr, :round], %{count: 1}, %{method: method})
      modern_result(requests, state, opts)
    else
      {:error, :invalid_input_requests} ->
        {:error, Error.invalid_params(%{"reason" => "invalid_input_requests"})}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @doc false
  def recover(payload, requests, params, binding, method, salient, operation, opts) do
    accepted = responses(params, payload)

    with true <- payload["e"] >= System.system_time(:millisecond),
         {:ok, requests} <- require_capabilities(params, requests) do
      state =
        RequestState.issue(
          binding.principal,
          binding.tenant,
          binding.era,
          method,
          salient,
          secret: opts[:request_state_secret],
          instance: opts[:request_state_instance],
          expires_at: payload["e"],
          request_id: binding.request_id,
          operation_identity: operation,
          input_keys: Map.keys(requests),
          input_types: request_types(requests),
          input_responses: accepted
        )

      # Check the complete response budget before consuming the parent token.
      with {:ok, result} <- modern_result(requests, state, opts),
           :ok <- consume(payload, opts) do
        Telemetry.execute([:mrtr, :round], %{count: 1}, %{method: method})
        {:ok, result}
      end
    else
      false -> invalid_state()
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp validate_present_responses(input_types, supplied, opts) do
    Enum.reduce_while(input_types, [], fn {key, method}, missing ->
      case Map.fetch(supplied, key) do
        {:ok, response} ->
          if valid_response?(method, response, opts),
            do: {:cont, missing},
            else: {:halt, :invalid}

        :error ->
          {:cont, [key | missing]}
      end
    end)
    |> case do
      [] -> :ok
      :invalid -> {:error, Error.invalid_params(%{"reason" => "invalid_input_response"})}
      missing -> {:missing_keys, Map.take(input_types, missing)}
    end
  end

  defp valid_response?("elicitation/create:url", response, opts),
    do: AttestoMCP.Server.Elicitation.valid_response?(%{"mode" => "url"}, response, opts)

  # Old untyped state cannot establish a requested form schema. Decline/cancel
  # remain usable, but accepted content must have a schema to validate against.
  defp valid_response?("elicitation/create", response, opts),
    do: AttestoMCP.Server.Elicitation.valid_response?(%{}, response, opts)

  defp valid_response?(%{"method" => "elicitation/create", "params" => params}, response, opts),
    do: AttestoMCP.Server.Elicitation.valid_response?(params, response, opts)

  defp valid_response?("sampling/createMessage", response, opts) when is_map(response) do
    response["role"] == "assistant" and valid_sampling_content?(response["content"], opts) and
      is_binary(response["model"]) and
      (is_nil(response["stopReason"]) or is_binary(response["stopReason"]))
  end

  defp valid_response?(%{"method" => "sampling/createMessage"}, response, opts),
    do: valid_response?("sampling/createMessage", response, opts)

  defp valid_response?("roots/list", response, _opts) when is_map(response) do
    is_list(response["roots"]) and Enum.all?(response["roots"], &valid_root_response?/1)
  end

  defp valid_response?(%{"method" => "roots/list"}, response, opts),
    do: valid_response?("roots/list", response, opts)

  defp valid_response?(_method, _response, _opts), do: false

  defp valid_sampling_content?(content, opts) when is_map(content),
    do: match?({:ok, _}, Output.normalize_content_item(content, json_budget_opts(opts)))

  defp valid_sampling_content?(content, opts) when is_list(content),
    do: Enum.all?(content, &valid_sampling_content?(&1, opts))

  defp valid_sampling_content?(_content, _opts), do: false

  defp valid_root_response?(%{"uri" => uri} = root) when is_binary(uri) do
    String.starts_with?(uri, "file://") and (is_nil(root["name"]) or is_binary(root["name"]))
  end

  defp valid_root_response?(_root), do: false

  defp normalize_entries(entries, opts) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {key, request}, {:ok, acc} ->
      with true <- is_binary(key) and byte_size(key) in 1..128,
           {:ok, request} <- normalize_request(request, opts),
           false <- Map.has_key?(acc, key) do
        {:cont, {:ok, Map.put(acc, key, request)}}
      else
        _ -> {:halt, {:error, :invalid_input_requests}}
      end
    end)
  end

  defp normalize_request(request, opts) when is_map(request) do
    with {:ok, request} <- Output.canonicalize(request, opts),
         method when method in ["elicitation/create", "sampling/createMessage", "roots/list"] <-
           request["method"],
         params when is_map(params) <- Map.get(request, "params", %{}),
         :ok <- validate_request_json(params, opts),
         true <- valid_request_params?(method, params, opts),
         :ok <- AttestoMCP.Server.Text.wire(params, opts) do
      {:ok, %{"method" => method, "params" => params}}
    else
      _ -> {:error, :invalid_input_request}
    end
  end

  defp normalize_request(_request, _opts), do: {:error, :invalid_input_request}

  defp valid_request_params?("elicitation/create", params, opts),
    do: AttestoMCP.Server.Elicitation.valid_request?(params, opts)

  defp valid_request_params?("sampling/createMessage", params, opts) do
    is_list(params["messages"]) and
      Enum.all?(params["messages"], fn message ->
        is_map(message) and message["role"] in ["user", "assistant"] and
          valid_sampling_content?(message["content"], opts)
      end)
  end

  defp valid_request_params?("roots/list", _params, _opts), do: true

  defp validate_request_json(params, opts) do
    if Schema.json_value(params, opts) == :ok, do: :ok, else: {:error, :invalid_input_request}
  end

  defp input_capability("elicitation/create"), do: "elicitation"
  defp input_capability("sampling/createMessage"), do: "sampling"
  defp input_capability("roots/list"), do: "roots"

  defp request_types(requests) do
    Map.new(requests, fn {key, %{"method" => method, "params" => params}} ->
      {key, %{"method" => method, "params" => params}}
    end)
  end

  defp modern_result(requests, state, opts) do
    result = %{
      "resultType" => "input_required",
      "inputRequests" => requests,
      "requestState" => state
    }

    case Schema.validate_modern_result(result, json_budget_opts(opts)) do
      :ok -> {:ok, result}
      _ -> {:error, Error.internal(%{"reason" => "invalid_modern_result"})}
    end
  end

  defp json_budget_opts(opts) when is_list(opts) do
    [
      max_bytes:
        Keyword.get(
          opts,
          :max_json_bytes,
          Keyword.get(opts, :max_bytes, Schema.default_instance_bytes())
        )
    ]
  end

  defp json_budget_opts(opts) when is_map(opts),
    do: [max_bytes: Map.get(opts, :max_json_bytes, Schema.default_instance_bytes())]

  defp json_budget_opts(_opts), do: [max_bytes: Schema.default_instance_bytes()]

  defp map_keys(value) when is_map(value), do: Map.keys(value)
  defp map_keys(_value), do: []

  defp invalid_state,
    do: {:error, Error.invalid_params(%{"reason" => "invalid_request_state"})}
end
