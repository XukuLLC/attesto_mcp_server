defmodule AttestoMCP.Server.UrlElicitationTest do
  use ExUnit.Case, async: true

  alias AttestoMCP.Server.API

  setup do
    {:ok, server} = API.start_link(name: :"server_#{System.unique_integer([:positive])}")
    {:ok, server: server}
  end

  test "stage, resolve, and consume happy path", %{server: server} do
    context = %{principal_binding: %{user_id: "user-123", role: "admin"}}
    action = "transfer_funds"
    fields = %{"amount" => 100, "recipient" => "alice"}

    assert {:ok, %{id: id, expires_at_ms: expires_at}} =
             API.stage_url_elicitation(server, context, action, fields, ttl_ms: 60_000)

    assert is_binary(id)
    assert byte_size(id) == 43
    assert is_integer(expires_at)
    assert expires_at > System.system_time(:millisecond)

    assert {:ok, resolved} = API.resolve_url_elicitation(server, id, context.principal_binding)
    assert resolved.action == action
    assert resolved.fields == fields
    assert resolved.expires_at_ms == expires_at

    assert {:ok, consumed} = API.consume_url_elicitation(server, id, context.principal_binding)
    assert consumed.action == action
    assert consumed.fields == fields
    assert consumed.expires_at_ms == expires_at

    assert {:error, :consumed} =
             API.resolve_url_elicitation(server, id, context.principal_binding)

    assert {:error, :consumed} =
             API.consume_url_elicitation(server, id, context.principal_binding)
  end

  test "consume is single use under 100 concurrent callers", %{server: server} do
    context = %{principal_binding: "caller-principal"}
    action = "approve_release"
    fields = %{"version" => "2.1.0"}

    {:ok, %{id: id}} = API.stage_url_elicitation(server, context, action, fields)

    tasks =
      for _i <- 1..100 do
        Task.async(fn ->
          API.consume_url_elicitation(server, id, context.principal_binding)
        end)
      end

    results = Task.await_many(tasks)

    successes = Enum.filter(results, &match?({:ok, _}, &1))
    consumed = Enum.filter(results, &match?({:error, :consumed}, &1))

    assert length(successes) == 1
    assert length(consumed) == 99
  end

  test "expired records return :expired and are swept by cleanup", %{server: server} do
    context = %{principal_binding: "expiring-principal"}
    action = "fast_action"
    fields = %{"key" => "value"}

    {:ok, %{id: id, expires_at_ms: _expires_at}} =
      API.stage_url_elicitation(server, context, action, fields, ttl_ms: 1_000)

    # Wait until expired
    Process.sleep(1_100)

    assert {:error, :expired} = API.resolve_url_elicitation(server, id, context.principal_binding)
    assert {:error, :expired} = API.consume_url_elicitation(server, id, context.principal_binding)

    # Trigger cleanup via store
    %{module: module, store: store} = AttestoMCP.Server.url_elicitation_store(server)
    now = System.system_time(:millisecond)

    assert {:ok, swept_ids} = apply(module, :cleanup_expired, [store, now])
    assert id in swept_ids

    # After sweep, lookup is :not_found
    assert {:error, :not_found} =
             API.resolve_url_elicitation(server, id, context.principal_binding)

    assert {:error, :not_found} =
             API.consume_url_elicitation(server, id, context.principal_binding)
  end

  test "wrong subject returns :foreign without content", %{server: server} do
    owner_binding = %{user: "alice", tenant: "t1"}
    stranger_binding = %{user: "bob", tenant: "t1"}
    action = "sensitive_operation"
    fields = %{"secret" => "classified_data"}

    {:ok, %{id: id}} =
      API.stage_url_elicitation(server, %{principal_binding: owner_binding}, action, fields)

    # Stranger receives :foreign with no field/action disclosure
    assert {:error, :foreign} = API.resolve_url_elicitation(server, id, stranger_binding)
    assert {:error, :foreign} = API.consume_url_elicitation(server, id, stranger_binding)

    # Even after owner consumes, stranger still receives :foreign, not :consumed
    assert {:ok, _} = API.consume_url_elicitation(server, id, owner_binding)
    assert {:error, :foreign} = API.resolve_url_elicitation(server, id, stranger_binding)
    assert {:error, :foreign} = API.consume_url_elicitation(server, id, stranger_binding)
  end

  test "foreign precedence applies when record is expired", %{server: server} do
    owner_binding = "owner"
    stranger_binding = "stranger"

    {:ok, %{id: id}} =
      API.stage_url_elicitation(
        server,
        %{principal_binding: owner_binding},
        "act",
        %{"k" => "v"},
        ttl_ms: 1_000
      )

    Process.sleep(1_100)

    # Stranger receives :foreign rather than :expired
    assert {:error, :foreign} = API.resolve_url_elicitation(server, id, stranger_binding)
    assert {:error, :foreign} = API.consume_url_elicitation(server, id, stranger_binding)

    # Owner receives :expired
    assert {:error, :expired} = API.resolve_url_elicitation(server, id, owner_binding)
    assert {:error, :expired} = API.consume_url_elicitation(server, id, owner_binding)
  end

  test "unknown and malformed ids return :not_found", %{server: server} do
    binding = "test_binding"

    # Valid format, unknown ID
    unknown_id = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    assert {:error, :not_found} = API.resolve_url_elicitation(server, unknown_id, binding)
    assert {:error, :not_found} = API.consume_url_elicitation(server, unknown_id, binding)

    # Malformed IDs
    malformed_ids = [
      "",
      "short",
      "not_base64!",
      String.duplicate("a", 42),
      String.duplicate("a", 44),
      nil,
      12_345,
      :atom
    ]

    for bad_id <- malformed_ids do
      assert {:error, :not_found} = API.resolve_url_elicitation(server, bad_id, binding)
      assert {:error, :not_found} = API.consume_url_elicitation(server, bad_id, binding)
    end
  end

  test "context without principal_binding is rejected", %{server: server} do
    action = "act"
    fields = %{"a" => 1}

    assert {:error, :principal_binding_required} =
             API.stage_url_elicitation(server, %{}, action, fields)

    assert {:error, :principal_binding_required} =
             API.stage_url_elicitation(server, %{principal_binding: nil}, action, fields)

    assert {:error, :principal_binding_required} =
             API.stage_url_elicitation(server, "not_a_map", action, fields)
  end

  test "action validation", %{server: server} do
    context = %{principal_binding: "binding"}
    fields = %{"a" => 1}

    assert {:error, :invalid_action} = API.stage_url_elicitation(server, context, "", fields)
    assert {:error, :invalid_action} = API.stage_url_elicitation(server, context, nil, fields)
    assert {:error, :invalid_action} = API.stage_url_elicitation(server, context, :act, fields)

    assert {:error, :invalid_action} =
             API.stage_url_elicitation(server, context, String.duplicate("a", 257), fields)

    assert {:error, :invalid_action} =
             API.stage_url_elicitation(server, context, "action\0null", fields)
  end

  test "ttl bounds validation", %{server: server} do
    context = %{principal_binding: "binding"}

    assert {:error, :invalid_ttl} =
             API.stage_url_elicitation(server, context, "act", %{}, ttl_ms: 999)

    assert {:error, :invalid_ttl} =
             API.stage_url_elicitation(server, context, "act", %{}, ttl_ms: 86_400_001)

    assert {:error, :invalid_ttl} =
             API.stage_url_elicitation(server, context, "act", %{}, ttl_ms: "60000")

    assert {:error, :invalid_ttl} =
             API.stage_url_elicitation(server, context, "act", %{}, ttl_ms: -1)

    assert {:ok, _} = API.stage_url_elicitation(server, context, "act", %{}, ttl_ms: 1_000)
    assert {:ok, _} = API.stage_url_elicitation(server, context, "act", %{}, ttl_ms: 86_400_000)
  end

  test "fields validation and JSON budget rejection", %{server: server} do
    context = %{principal_binding: "binding"}

    assert {:error, :invalid_fields} =
             API.stage_url_elicitation(server, context, "act", "not_a_map")

    assert {:error, :invalid_fields} =
             API.stage_url_elicitation(server, context, "act", %{atom_key: "val"})

    assert {:error, :invalid_fields} =
             API.stage_url_elicitation(server, context, "act", %{"key" => self()})

    # Field exceeding server's max_json_bytes budget
    context_with_small_budget = %{principal_binding: "binding", max_json_bytes: 50}
    oversized_fields = %{"long_data" => String.duplicate("x", 100)}

    assert {:error, :invalid_fields} =
             API.stage_url_elicitation(server, context_with_small_budget, "act", oversized_fields)
  end

  test "dead server returns :store_unavailable without raising", %{server: server} do
    context = %{principal_binding: "binding"}
    GenServer.stop(server)

    assert {:error, :store_unavailable} =
             API.stage_url_elicitation(server, context, "act", %{"a" => 1})

    assert {:error, :not_found} =
             API.resolve_url_elicitation(server, "malformed", "binding")

    valid_id = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    assert {:error, :store_unavailable} =
             API.resolve_url_elicitation(server, valid_id, "binding")

    assert {:error, :store_unavailable} =
             API.consume_url_elicitation(server, valid_id, "binding")
  end
end
