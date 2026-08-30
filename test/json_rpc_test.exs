defmodule AttestoMCP.Server.JSONRPCTest do
  use ExUnit.Case, async: true
  alias AttestoMCP.Server.{Error, JSONRPC}

  @tag :t04
  @tag :t24
  test "decodes requests, notifications, and responses" do
    assert {:ok, %{kind: :request, id: 1, method: "ping", params: %{}}} =
             JSONRPC.decode(~s({"jsonrpc":"2.0","id":1,"method":"ping"}))

    assert {:ok, %{kind: :notification, method: "notifications/initialized"}} =
             JSONRPC.decode(~s({"jsonrpc":"2.0","method":"notifications/initialized"}))

    assert {:ok, %{kind: :response, id: "a", result: %{"ok" => true}}} =
             JSONRPC.decode(~s({"jsonrpc":"2.0","id":"a","result":{"ok":true}}))
  end

  test "decodes an already-parsed JSON value without weakening bounds" do
    parsed = %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping", "params" => %{}}

    assert {:ok, %{kind: :request, id: 1, method: "ping", params: %{}}} =
             JSONRPC.decode(parsed)

    assert {:error, %Error{code: -32700, data: %{"reason" => "message_too_large"}}} =
             JSONRPC.decode(parsed, max_bytes: 8)

    assert {:error, %Error{code: -32700, data: %{"reason" => "message_too_deep"}}} =
             JSONRPC.decode(Map.put(parsed, "params", %{"nested" => %{}}), max_depth: 1)

    assert {:error, %Error{code: -32600}} =
             JSONRPC.decode([parsed])

    assert JSONRPC.recover_id(Map.put(parsed, "params", [])) == 1
    assert JSONRPC.recover_id(parsed, max_bytes: 8) == nil
    assert JSONRPC.recover_id(Map.put(parsed, "id", nil)) == nil
  end

  test "invalid max_bytes values fail closed" do
    payload = ~s({"jsonrpc":"2.0","id":1,"method":"ping"})
    parsed = Jason.decode!(payload)

    for invalid <- [nil, true, "bad", 2.5, %{}] do
      assert {:error, %Error{code: -32700, data: %{"reason" => "message_too_large"}}} =
               JSONRPC.decode(payload, max_bytes: invalid)

      assert {:error, %Error{code: -32700, data: %{"reason" => "message_too_large"}}} =
               JSONRPC.decode(parsed, max_bytes: invalid)

      assert JSONRPC.recover_id(payload, max_bytes: invalid) == nil
      assert JSONRPC.recover_id(parsed, max_bytes: invalid) == nil
    end
  end

  test "detaches bounded string IDs from a larger decoded request body" do
    id = String.duplicate("i", 256)

    payload =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => "ping",
        "params" => %{"padding" => String.duplicate("p", 800_000)}
      })

    assert {:ok, %{kind: :request, id: decoded_id}} =
             JSONRPC.decode(payload, max_bytes: 900_000)

    assert decoded_id == id
    assert :binary.referenced_byte_size(decoded_id) == byte_size(decoded_id)
  end

  test "preserves unknown extension members on every JSON-RPC message kind" do
    assert {:ok, %{kind: :request, extensions: %{"x-request" => %{"value" => 1}}}} =
             JSONRPC.decode(~s({"jsonrpc":"2.0","id":1,"method":"ping","x-request":{"value":1}}))

    assert {:ok, %{kind: :notification, extensions: %{"x-notification" => [1, 2]}}} =
             JSONRPC.decode(
               ~s({"jsonrpc":"2.0","method":"notifications/initialized","x-notification":[1,2]})
             )

    assert {:ok, %{kind: :response, extensions: %{"x-response" => true}}} =
             JSONRPC.decode(~s({"jsonrpc":"2.0","id":"a","result":{},"x-response":true}))
  end

  @tag :t04
  test "rejects batches, null IDs, malformed JSON, and non-object params" do
    assert {:error, %Error{code: -32600}} =
             JSONRPC.decode(~s([{"jsonrpc":"2.0","id":1,"method":"ping"}]))

    assert {:error, %Error{code: -32600}} =
             JSONRPC.decode(~s({"jsonrpc":"2.0","id":null,"method":"ping"}))

    assert {:error, %Error{code: -32700}} = JSONRPC.decode("{")

    assert {:error, %Error{code: -32600}} =
             JSONRPC.decode(~s({"jsonrpc":"2.0","id":1,"method":"ping","params":[]}))
  end

  @tag :t24
  test "rejects mixed request/response fields and malformed error objects" do
    assert {:error, %Error{code: -32600}} =
             JSONRPC.decode(~s({"jsonrpc":"2.0","id":1,"method":"ping","result":{}}))

    assert {:error, %Error{code: -32600}} =
             JSONRPC.decode(~s({"jsonrpc":"2.0","id":1,"method":"ping","error":{}}))

    assert {:error, %Error{code: -32600}} =
             JSONRPC.decode(~s({"jsonrpc":"2.0","id":1,"error":{"code":"bad","message":"x"}}))

    assert {:error, %Error{code: -32600}} =
             JSONRPC.decode(~s({"jsonrpc":"2.0","id":1,"method":""}))
  end

  @tag :t04
  test "bounds UTF-8, numeric IDs, bytes, and nesting" do
    assert {:error, %Error{code: -32700}} = JSONRPC.decode(<<"{\"jsonrpc\":\"2.0\",", 0xFF, "}">>)

    assert {:error, %Error{code: -32600}} =
             JSONRPC.decode(~s({"jsonrpc":"2.0","id":1.5,"method":"ping"}))

    assert {:error, %Error{code: -32700}} =
             JSONRPC.decode(String.duplicate("x", 20), max_bytes: 10)

    nested = String.duplicate("[", 10) <> "0" <> String.duplicate("]", 10)

    assert {:error, %Error{code: -32700}} =
             JSONRPC.decode(nested, max_depth: 4)
  end

  @tag :t24
  test "documents deterministic duplicate-member handling" do
    assert {:ok, %{params: %{"value" => 1}}} =
             JSONRPC.decode(
               ~s({"jsonrpc":"2.0","id":1,"method":"ping","params":{"value":1,"value":2}})
             )
  end
end
