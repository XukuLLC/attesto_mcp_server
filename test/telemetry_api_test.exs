defmodule AttestoMCP.Server.TelemetryAPITest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server.Telemetry

  test "execute redacts credentials and limits nested metadata" do
    event = [:telemetry_test]
    full_event = [:attesto_mcp_server | event]
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        full_event,
        &__MODULE__.telemetry_handler/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok =
             Telemetry.execute(event, %{count: 1}, %{
               token: "secret-token",
               method: "tools/list",
               nested: %{method: "kept", secret: "removed"},
               long: String.duplicate("x", 300)
             })

    assert_receive {:telemetry, %{count: 1}, metadata}
    refute Map.has_key?(metadata, :token)
    assert metadata.method == "tools/list"
    refute Map.has_key?(metadata, :nested)
    refute Map.has_key?(metadata, :long)
  end

  test "span emits stop and exception lifecycle events" do
    stop = [:attesto_mcp_server, :telemetry_span, :stop]
    exception = [:attesto_mcp_server, :telemetry_span, :exception]
    stop_id = {__MODULE__, :stop, make_ref()}
    exception_id = {__MODULE__, :exception, make_ref()}

    :ok = :telemetry.attach(stop_id, stop, &__MODULE__.telemetry_handler/4, self())
    :ok = :telemetry.attach(exception_id, exception, &__MODULE__.telemetry_handler/4, self())

    on_exit(fn ->
      :telemetry.detach(stop_id)
      :telemetry.detach(exception_id)
    end)

    assert :done =
             Telemetry.span(:telemetry_span, %{method: "ping"}, fn ->
               {:done, %{outcome: :ok}}
             end)

    assert_receive {:span, ^stop, %{duration: duration}, %{method: "ping", outcome: :ok}}
    assert is_integer(duration) and duration >= 0

    assert_raise RuntimeError, fn ->
      Telemetry.span(:telemetry_span, %{method: "secret"}, fn -> raise "private reason" end)
    end

    assert_receive {:span, ^exception, %{duration: duration},
                    %{method: "secret", error: :exception}}

    assert is_integer(duration) and duration >= 0
  end

  def telemetry_handler(event, measurements, metadata, pid) do
    case event do
      [:attesto_mcp_server, :telemetry_test] -> send(pid, {:telemetry, measurements, metadata})
      _ -> send(pid, {:span, event, measurements, metadata})
    end
  end
end
