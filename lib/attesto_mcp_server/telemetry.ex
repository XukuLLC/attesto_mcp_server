defmodule AttestoMCP.Server.Telemetry do
  @moduledoc "Telemetry helpers for protocol, auth, handler, and transport events."

  @prefix [:attesto_mcp_server]
  @allowed_metadata ~w(
    version protocol_version method transport status outcome duration count
    correlation_id category reason error
  )a

  @doc "Emits a safe event after removing credential and private payload fields."
  @spec execute(atom() | [atom()], map(), map()) :: :ok
  def execute(event, measurements \\ %{}, metadata \\ %{}) do
    :telemetry.execute(@prefix ++ List.wrap(event), measurements, safe_metadata(metadata))
  end

  @doc "Emits start/stop (or exception) events around a callback."
  @spec span(atom() | [atom()], map(), (-> {term(), map()})) :: term()
  def span(event, metadata, fun) do
    started = System.monotonic_time()
    execute([event, :start], %{system_time: System.system_time()}, metadata)

    try do
      {result, extra} = fun.()
      duration = System.monotonic_time() - started
      execute([event, :stop], %{duration: duration}, Map.merge(metadata, safe_metadata(extra)))
      result
    rescue
      error ->
        duration = System.monotonic_time() - started

        execute(
          [event, :exception],
          %{duration: duration},
          Map.put(metadata, :error, :exception)
        )

        reraise error, __STACKTRACE__
    end
  end

  defp safe_metadata(metadata) when is_map(metadata) do
    metadata
    |> Map.take(@allowed_metadata)
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, key, safe_field(key, value))
    end)
  end

  defp safe_metadata(_), do: %{}

  defp safe_field(:correlation_id, value) when is_binary(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp safe_field(:reason, value) when is_atom(value), do: value
  defp safe_field(:category, value) when is_atom(value), do: value
  defp safe_field(:error, value) when is_atom(value), do: value
  defp safe_field(_key, value), do: safe(value)

  defp safe(value) when is_binary(value) and byte_size(value) > 256,
    do: String.slice(value, 0, 256)

  defp safe(value) when is_binary(value), do: value

  defp safe(value) when is_atom(value) or is_number(value) or is_boolean(value) or is_nil(value),
    do: value

  defp safe(value) when is_list(value), do: Enum.map(value, &safe/1)

  defp safe(value) when is_map(value),
    do: Map.take(value, [:method, :transport, :protocol_version, :status, :outcome])

  defp safe(_), do: :opaque
end
