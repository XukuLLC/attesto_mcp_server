defmodule AttestoMCP.Server.TraceContextTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server

  @modern "2026-07-28"

  @tag :t04
  @tag :t22
  test "valid W3C trace context is bounded and propagated to the handler" do
    parent = self()
    {:ok, server} = Server.start_link([])

    assert :ok =
             Server.register_tool(server, "trace", %{
               handler: fn _arguments, context ->
                 send(parent, {:trace_context, context.trace_context})
                 {:ok, "ok"}
               end
             })

    request =
      request(1, %{
        "traceparent" => "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
        "tracestate" => "vendor=value",
        "baggage" => "private-marker=do-not-log"
      })

    assert {1, %{"result" => %{"resultType" => "complete"}}} =
             Server.dispatch(server, request, %{principal: "trace"}, version: @modern)

    assert_receive {:trace_context, context}
    assert context["traceparent"] =~ "00-4bf92f"
    assert context["tracestate"] == "vendor=value"
    assert context["baggage"] == "private-marker=do-not-log"
  end

  @tag :t04
  test "invalid or oversized W3C trace context is rejected before dispatch" do
    {:ok, server} = Server.start_link([])

    assert :ok =
             Server.register_tool(server, "trace", %{
               handler: fn _arguments, _context ->
                 flunk("invalid trace context reached the handler")
               end
             })

    for traceparent <- ["not-a-traceparent", String.duplicate("a", 4097)] do
      assert {1, %{"error" => %{"code" => -32602}}} =
               Server.dispatch(
                 server,
                 request(1, %{"traceparent" => traceparent}),
                 %{principal: "trace"},
                 version: @modern
               )
    end
  end

  @tag :t04
  test "trace context values with line breaks or control characters are rejected" do
    {:ok, server} = Server.start_link([])

    assert :ok =
             Server.register_tool(server, "trace", %{
               handler: fn _arguments, _context -> {:ok, "ok"} end
             })

    valid = %{
      "traceparent" => "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
      "tracestate" => "vendor=value,other=x\ty",
      "baggage" => "key=value;prop, other=%20v"
    }

    assert {1, %{"result" => %{"resultType" => "complete"}}} =
             Server.dispatch(server, request(1, valid), %{principal: "trace"}, version: @modern)

    for {key, value, reason} <- [
          {"traceparent", valid["traceparent"] <> "\n", "invalid_traceparent"},
          {"traceparent", "\n" <> valid["traceparent"], "invalid_traceparent"},
          {"tracestate", "a=b\r\nX-Injected: 1", "invalid_trace_context"},
          {"tracestate", "a=b\n", "invalid_trace_context"},
          {"tracestate", "a=b\0", "invalid_trace_context"},
          {"baggage", "a=b\r\nX-Injected: 1", "invalid_trace_context"},
          {"baggage", "a=café", "invalid_trace_context"}
        ] do
      assert {2, %{"error" => %{"code" => -32602, "data" => %{"reason" => ^reason}}}} =
               Server.dispatch(
                 server,
                 request(2, Map.put(valid, key, value)),
                 %{principal: "trace"},
                 version: @modern
               )
    end
  end

  defp request(id, trace) do
    %{
      kind: :request,
      id: id,
      method: "tools/call",
      params: %{
        "name" => "trace",
        "arguments" => %{},
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @modern,
          "io.modelcontextprotocol/clientCapabilities" => %{},
          "traceparent" => trace["traceparent"],
          "tracestate" => trace["tracestate"],
          "baggage" => trace["baggage"]
        }
      }
    }
  end
end
