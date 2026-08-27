defmodule AttestoMCP.Server.LegacySSEPropertyTest do
  use ExUnit.Case, async: true

  @max_event_bytes 1_024

  test "legacy wire framing survives every byte split and legal line ending" do
    wire =
      "id: 1\r\nevent: message\r\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/a\"}\r\n\r\n" <>
        "id: 2\nevent: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/b\"}\n\n"

    expected = [
      %{
        "id" => "1",
        "event" => "message",
        "data" => "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/a\"}"
      },
      %{
        "id" => "2",
        "event" => "message",
        "data" => "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/b\"}"
      }
    ]

    for split <- 0..byte_size(wire) do
      {left, right} = :erlang.split_binary(wire, split)
      {:ok, events, remainder} = consume_sse(left, [])
      {:ok, events, remainder} = consume_sse(remainder <> right, events)
      assert events == expected
      assert remainder == ""
    end
  end

  test "a trailing fragment is held until its blank-line terminator" do
    partial = "id: 9\nevent: message\ndata: {\"jsonrpc\":\"2.0\"}"
    assert {:ok, [], ^partial} = consume_sse(partial, [])
    assert {:ok, [%{"id" => "9"}], ""} = consume_sse(partial <> "\n\n", [])
  end

  test "the consumer rejects an oversized event before parsing data" do
    oversized = "data: " <> String.duplicate("x", @max_event_bytes) <> "\n\n"
    assert {:error, :event_too_large} = consume_sse(oversized, [])
  end

  test "the event bound is per event rather than an aggregate stream bound" do
    one = "data: " <> String.duplicate("x", 700) <> "\n\n"
    combined = one <> one

    assert byte_size(combined) > @max_event_bytes
    assert {:ok, [_, _], ""} = consume_sse(combined, [])
  end

  defp consume_sse(data, events) do
    data = String.replace(data, "\r\n", "\n")

    case String.split(data, "\n\n", parts: 2) do
      [remainder] ->
        if byte_size(remainder) > @max_event_bytes,
          do: {:error, :event_too_large},
          else: {:ok, events, remainder}

      [event, remainder] ->
        if byte_size(event) > @max_event_bytes do
          {:error, :event_too_large}
        else
          fields =
            event
            |> String.split("\n", trim: true)
            |> Enum.reduce(%{}, fn line, acc ->
              case String.split(line, ":", parts: 2) do
                [key, value] -> Map.put(acc, key, String.trim_leading(value))
                _ -> acc
              end
            end)

          consume_sse(remainder, events ++ [fields])
        end
    end
  end
end
