defmodule AttestoMCP.Server.Handlers do
  @moduledoc false

  alias AttestoMCP.Server.{Schema, Telemetry}

  @doc false
  def invoke(nil, _params, context),
    do: with_telemetry(fn -> {:error, :missing_handler} end, context)

  def invoke(fun, params, context) when is_function(fun, 2),
    do: with_telemetry(fn -> fun.(params, context) end, context)

  def invoke(fun, params, context) when is_function(fun, 1),
    do: with_telemetry(fn -> fun.(params) end, context)

  def invoke({module, function}, params, context),
    do: with_telemetry(fn -> apply(module, function, [params, context]) end, context)

  def invoke({module, function, args}, params, context),
    do: with_telemetry(fn -> apply(module, function, [params, context | args]) end, context)

  def invoke(_handler, _params, context),
    do: with_telemetry(fn -> {:error, :invalid_handler} end, context)

  @doc false
  def identity_context(context, type, definition) do
    context
    |> Map.put(:primitive_type, type)
    |> Map.put(:primitive_identity, definition[:identity] || definition["identity"])
  end

  @doc false
  def tool_arguments(arguments, schema, :atoms, handler) do
    _ = ensure_handler_module_loaded(handler)
    Schema.atomize_property_keys(arguments, schema)
  end

  def tool_arguments(arguments, _schema, _mode, _handler), do: arguments

  defp with_telemetry(callback, context) do
    Telemetry.span(
      :handler,
      %{
        method: Telemetry.protocol_method(Map.get(context, :method, "handler")),
        transport: Map.get(context, :transport, :core),
        correlation_id: Telemetry.correlation(Map.get(context, :request_id)),
        primitive_type: Map.get(context, :primitive_type),
        primitive_identity: Map.get(context, :primitive_identity),
        telemetry_metadata: Map.get(context, :telemetry_metadata)
      },
      fn ->
        result = normalize_result(callback.())
        {result, %{outcome: outcome(result)}}
      end,
      exception_reporter: Map.get(context, :exception_reporter)
    )
  end

  defp outcome({:ok, _}), do: :ok
  defp outcome({:input_required, _}), do: :input_required
  defp outcome({:error, _}), do: :error

  defp normalize_result({:ok, value}), do: {:ok, value}
  defp normalize_result({:input_required, value}), do: {:input_required, value}
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result(value), do: {:ok, value}

  # `String.to_existing_atom/1` can only see atoms introduced by loaded BEAM
  # modules. An MFA or external function capture may point at a module that is
  # available on the code path but has not been loaded yet.
  defp ensure_handler_module_loaded({module, _function}) when is_atom(module),
    do: ensure_module_loaded(module)

  defp ensure_handler_module_loaded({module, _function, _args}) when is_atom(module),
    do: ensure_module_loaded(module)

  defp ensure_handler_module_loaded(fun) when is_function(fun) do
    case :erlang.fun_info(fun, :type) do
      {:type, :external} ->
        case :erlang.fun_info(fun, :module) do
          {:module, module} when is_atom(module) -> ensure_module_loaded(module)
          _other -> :ok
        end

      _local_or_other ->
        :ok
    end
  end

  defp ensure_handler_module_loaded(_handler), do: :ok

  defp ensure_module_loaded(module) do
    _ = Code.ensure_loaded(module)
    :ok
  end
end
