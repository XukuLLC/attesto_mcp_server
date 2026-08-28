defmodule AttestoMCP.Server.StateSubscriptionTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server
  alias AttestoMCP.Server.{RequestState, Subscriptions}

  test "request state is bound and single-use" do
    state =
      RequestState.issue("alice", "tenant-a", "2026-07-28", "tools/call", %{"n" => 1}, ttl: 5_000)

    assert {:ok, _nonce} =
             RequestState.verify(state, "alice", "tenant-a", "2026-07-28", "tools/call", %{
               "n" => 1
             })

    assert {:error, :invalid_request_state} =
             RequestState.verify(state, "alice", "tenant-a", "2026-07-28", "tools/call", %{
               "n" => 1
             })

    other = RequestState.issue("alice", "tenant-a", "2026-07-28", "tools/call", %{"n" => 1})

    assert {:error, :invalid_request_state} =
             RequestState.verify(other, "bob", "tenant-a", "2026-07-28", "tools/call", %{"n" => 1})
  end

  test "subscriptions acknowledge filters and deliver only matching events" do
    {:ok, subscriptions} = Subscriptions.start_link([])

    assert {:ok, id} =
             Subscriptions.open(
               subscriptions,
               "alice",
               "tenant-a",
               7,
               %{"resourceSubscriptions" => ["urn:one"]},
               self(),
               :stream,
               nil
             )

    assert id == 7
    assert_receive {:mcp_subscription, :stream, 7, acknowledgment}
    assert acknowledgment["method"] == "notifications/subscriptions/acknowledged"

    assert get_in(acknowledgment, ["params", "_meta", "io.modelcontextprotocol/subscriptionId"]) ==
             7

    :ok =
      Subscriptions.publish(subscriptions, %{
        "method" => "notifications/resources/updated",
        "params" => %{"uri" => "urn:one"}
      })

    assert_receive {:mcp_subscription, :stream, ^id, event}
    assert event["method"] == "notifications/resources/updated"
    assert get_in(event, ["params", "_meta", "io.modelcontextprotocol/subscriptionId"]) == id
    Subscriptions.ack(subscriptions, id)

    :ok =
      Subscriptions.publish(subscriptions, %{
        "method" => "notifications/resources/updated",
        "params" => %{"uri" => "urn:two"}
      })

    refute_receive {:mcp_subscription, :stream, ^id, _event}, 25

    assert :ok = Subscriptions.close(subscriptions, id)
  end

  test "resource subscription filters validate, deduplicate, and detach retained URI binaries" do
    {:ok, subscriptions} = Subscriptions.start_link([])

    backing =
      String.duplicate("p", 100_000) <>
        "urn:" <> String.duplicate("x", 4_092) <> String.duplicate("s", 100_000)

    uri = binary_part(backing, 100_000, 4_096)
    assert :binary.referenced_byte_size(uri) > byte_size(uri)

    id_backing = String.duplicate("a", 100_000) <> String.duplicate("i", 256) <> backing
    requested_id = binary_part(id_backing, 100_000, 256)
    assert :binary.referenced_byte_size(requested_id) > byte_size(requested_id)

    assert {:ok, stored_id} =
             Subscriptions.open(
               subscriptions,
               "alice",
               "tenant-a",
               requested_id,
               %{"resourceSubscriptions" => [uri, uri]},
               self(),
               :bounded,
               nil
             )

    assert stored_id == requested_id
    assert :binary.referenced_byte_size(stored_id) == byte_size(stored_id)
    assert_receive {:mcp_subscription, :bounded, ^stored_id, acknowledgment}
    assert get_in(acknowledgment, ["params", "notifications", "resourceSubscriptions"]) == [uri]

    state = :sys.get_state(subscriptions)
    subscription = state.subscriptions |> Map.values() |> List.first()
    assert subscription.id == requested_id
    assert :binary.referenced_byte_size(subscription.id) == byte_size(subscription.id)
    [stored_uri] = subscription.filter["resourceSubscriptions"]
    assert stored_uri == uri
    assert :binary.referenced_byte_size(stored_uri) == byte_size(stored_uri)

    invalid_filters = [
      [""],
      [<<255>>],
      ["urn:bad\0"],
      ["urn:bad\r"],
      ["urn:bad\n"],
      ["urn:" <> String.duplicate("x", 4_093)]
    ]

    for {uris, index} <- Enum.with_index(invalid_filters, 1) do
      assert {:error, :invalid_filter} =
               Subscriptions.open(
                 subscriptions,
                 "alice",
                 "tenant-a",
                 "invalid-#{index}",
                 %{"resourceSubscriptions" => uris},
                 self(),
                 :invalid,
                 nil
               )
    end

    assert {:error, :invalid_filter} =
             Subscriptions.open(
               subscriptions,
               "alice",
               "tenant-a",
               "invalid-key",
               %{%{} => true},
               self(),
               :invalid,
               nil
             )

    assert Subscriptions.stats(subscriptions) == %{count: 1, queued: 0}
    assert :ok = Subscriptions.close(subscriptions, requested_id)
  end

  test "malformed direct notifications are suppressed without terminating the registry" do
    {:ok, subscriptions} = Subscriptions.start_link([])

    assert {:ok, "guarded"} =
             Subscriptions.open(
               subscriptions,
               "alice",
               "tenant-a",
               "guarded",
               %{"resourceSubscriptions" => ["urn:one"]},
               self(),
               :guarded,
               nil
             )

    assert_receive {:mcp_subscription, :guarded, "guarded", _acknowledgment}

    malformed = [
      %{
        "method" => "notifications/resources/updated",
        "params" => %{"resource" => 5}
      },
      %{"type" => %{}},
      %{
        "method" => "notifications/resources/updated",
        "params" => %URI{scheme: "urn"}
      },
      %{"type" => "resource", "uri" => "urn:one", "_meta" => 5},
      %{
        "method" => "notifications/resources/updated",
        "params" => %{"uri" => "urn:one", "_meta" => %URI{scheme: "urn"}}
      }
    ]

    for notification <- malformed do
      assert :ok = Subscriptions.publish_sync(subscriptions, notification)
      refute_receive {:mcp_subscription, :guarded, "guarded", _event}, 25
      assert Process.alive?(subscriptions)
    end

    assert :ok =
             Subscriptions.publish_sync(subscriptions, %{
               "type" => "resourceSubscriptions",
               "uri" => "urn:one"
             })

    assert_receive {:mcp_subscription, :guarded, "guarded", event}
    assert event["method"] == "notifications/resources/updated"

    assert get_in(event, ["params", "_meta", "io.modelcontextprotocol/subscriptionId"]) ==
             "guarded"

    assert Subscriptions.stats(subscriptions) == %{count: 1, queued: 1}
    assert :ok = Subscriptions.close(subscriptions, "guarded")
  end

  test "resource subscription filters cap unique URIs while preserving first-seen order" do
    {:ok, subscriptions} = Subscriptions.start_link([])
    uris = Enum.map(1..128, &"urn:bounded:#{&1}")
    offered = uris ++ Enum.take(uris, 8)

    assert {:ok, "at-limit"} =
             Subscriptions.open(
               subscriptions,
               "alice",
               "tenant-a",
               "at-limit",
               %{"resourceSubscriptions" => offered},
               self(),
               :at_limit,
               nil
             )

    assert_receive {:mcp_subscription, :at_limit, "at-limit", acknowledgment}
    assert get_in(acknowledgment, ["params", "notifications", "resourceSubscriptions"]) == uris

    assert {:error, :invalid_filter} =
             Subscriptions.open(
               subscriptions,
               "alice",
               "tenant-a",
               "over-limit",
               %{"resourceSubscriptions" => uris ++ ["urn:bounded:129"]},
               self(),
               :over_limit,
               nil
             )

    assert Subscriptions.stats(subscriptions) == %{count: 1, queued: 0}
    assert :ok = Subscriptions.close(subscriptions, "at-limit")
  end

  test "server-assigned subscription IDs do not replace explicit owner IDs" do
    {:ok, subscriptions} = Subscriptions.start_link([])

    assert {:ok, "sub_1"} =
             Subscriptions.open(
               subscriptions,
               "alice",
               "tenant-a",
               "sub_1",
               %{"toolsListChanged" => true},
               self(),
               :explicit,
               nil
             )

    assert_receive {:mcp_subscription, :explicit, "sub_1", _acknowledgment}

    assert {:ok, "sub_2"} =
             Subscriptions.open(
               subscriptions,
               "alice",
               "tenant-a",
               %{"promptsListChanged" => true},
               self(),
               :generated,
               nil
             )

    assert_receive {:mcp_subscription, :generated, "sub_2", _acknowledgment}
    assert Subscriptions.stats(subscriptions) == %{count: 2, queued: 0}

    assert :ok = Subscriptions.publish_sync(subscriptions, %{"type" => "toolsListChanged"})
    assert_receive {:mcp_subscription, :explicit, "sub_1", _event}
    refute_receive {:mcp_subscription, :generated, "sub_2", _event}, 25

    assert :ok = Subscriptions.close(subscriptions, "sub_1")
    assert :ok = Subscriptions.close(subscriptions, "sub_2")
  end

  test "subscriptions isolate filters and suppress revoked deliveries" do
    {:ok, subscriptions} = Subscriptions.start_link([])
    allowed = Agent.start_link(fn -> true end) |> elem(1)

    authorize = fn _ -> Agent.get(allowed, & &1) end

    assert {:ok, first} =
             Subscriptions.open(
               subscriptions,
               "alice",
               "tenant-a",
               "first",
               %{"toolsListChanged" => true},
               self(),
               :first,
               authorize
             )

    assert {:ok, second} =
             Subscriptions.open(
               subscriptions,
               "alice",
               "tenant-a",
               "second",
               %{"promptsListChanged" => true},
               self(),
               :second,
               authorize
             )

    assert_receive {:mcp_subscription, :first, ^first, _}
    assert_receive {:mcp_subscription, :second, ^second, _}

    Subscriptions.publish(subscriptions, %{"type" => "toolsListChanged"})
    assert_receive {:mcp_subscription, :first, ^first, event}
    assert event["method"] == "notifications/tools/list_changed"
    refute_receive {:mcp_subscription, :second, ^second, _}, 25
    Subscriptions.ack(subscriptions, first)

    Agent.update(allowed, fn _ -> false end)
    Subscriptions.publish(subscriptions, %{"type" => "toolsListChanged"})
    refute_receive {:mcp_subscription, :first, ^first, _}, 25

    Subscriptions.close(subscriptions, first)
    Subscriptions.close(subscriptions, second)
    Agent.stop(allowed)
  end

  test "subscription controls are owner-bound and explicit nil fails closed" do
    {:ok, subscriptions} = Subscriptions.start_link([])
    parent = self()
    other_sink = spawn(fn -> relay_subscription_messages(parent) end)
    id = "shared-id"

    assert {:ok, ^id} =
             Subscriptions.open(
               subscriptions,
               "first",
               "tenant",
               id,
               %{"toolsListChanged" => true},
               self(),
               :first,
               nil
             )

    assert {:ok, ^id} =
             Subscriptions.open(
               subscriptions,
               "second",
               "tenant",
               id,
               %{"toolsListChanged" => true},
               other_sink,
               :second,
               nil
             )

    assert_receive {:mcp_subscription, :first, ^id, _acknowledgment}

    assert_receive {:relayed_subscription, {:mcp_subscription, :second, ^id, _acknowledgment}}

    assert :ok = Subscriptions.publish_sync(subscriptions, %{"type" => "toolsListChanged"})
    assert_receive {:mcp_subscription, :first, ^id, _event}
    assert_receive {:relayed_subscription, {:mcp_subscription, :second, ^id, _event}}
    assert Subscriptions.stats(subscriptions) == %{count: 2, queued: 2}

    Subscriptions.ack(subscriptions, id, nil)
    assert Subscriptions.stats(subscriptions) == %{count: 2, queued: 2}
    assert :ok = Subscriptions.close(subscriptions, id, nil)
    assert :ok = Subscriptions.cancel(subscriptions, id, nil)
    assert Subscriptions.stats(subscriptions) == %{count: 2, queued: 2}

    Subscriptions.ack(subscriptions, id)
    assert Subscriptions.stats(subscriptions) == %{count: 2, queued: 1}
    assert :ok = Subscriptions.close(subscriptions, id)
    assert Subscriptions.stats(subscriptions) == %{count: 1, queued: 1}
    refute_receive {:mcp_subscription_close, ^id}, 25
    refute_receive {:mcp_subscription_cancel, ^id}, 25

    assert :ok = Subscriptions.cancel(subscriptions, id, other_sink)
    assert_receive {:relayed_subscription, {:mcp_subscription_cancel, ^id}}
    assert Subscriptions.stats(subscriptions) == %{count: 0, queued: 0}
    send(other_sink, :stop)
  end

  test "modern listen uses request id and sends acknowledgment before real notifications" do
    {:ok, server} = Server.start_link([])
    parent = self()

    params = %{
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities" => %{}
      },
      "notifications" => %{"toolsListChanged" => true}
    }

    assert {21,
            %{
              "result" => %{
                "resultType" => "complete",
                "_meta" => %{
                  "io.modelcontextprotocol/subscriptionId" => 21,
                  "io.modelcontextprotocol/serverInfo" => %{"name" => _, "version" => _}
                }
              }
            }} =
             Server.dispatch(
               server,
               %{kind: :request, id: 21, method: "subscriptions/listen", params: params},
               %{principal: "alice"},
               version: "2026-07-28",
               on_event: fn event -> send(parent, {:subscription_event, event}) end
             )

    assert_receive {:subscription_event, acknowledgment}
    assert acknowledgment["method"] == "notifications/subscriptions/acknowledged"

    assert get_in(acknowledgment, ["params", "_meta", "io.modelcontextprotocol/subscriptionId"]) ==
             21

    :ok = Server.publish(server, %{"type" => "toolsListChanged"})
    assert_receive {:mcp_subscription, _tag, 21, notification}
    assert notification["method"] == "notifications/tools/list_changed"

    assert get_in(notification, ["params", "_meta", "io.modelcontextprotocol/subscriptionId"]) ==
             21

    Server.ack_subscription(server, 21)

    outsider =
      Task.async(fn ->
        Server.dispatch(
          server,
          %{
            kind: :notification,
            method: "notifications/cancelled",
            params: %{"requestId" => 21}
          },
          %{principal: "bob"},
          version: "2026-07-28"
        )
      end)

    assert :notification == Task.await(outsider)
    refute_receive {:mcp_subscription_cancel, 21}, 25

    :ok = Server.publish(server, %{"type" => "toolsListChanged"})
    assert_receive {:mcp_subscription, _tag, 21, retained_notification}
    assert retained_notification["method"] == "notifications/tools/list_changed"
    Server.ack_subscription(server, 21)

    cancellation =
      Task.async(fn ->
        Server.dispatch(
          server,
          %{
            kind: :notification,
            method: "notifications/cancelled",
            params: %{"requestId" => 21}
          },
          %{principal: "alice"},
          version: "2026-07-28",
          owner: parent
        )
      end)

    assert :notification == Task.await(cancellation)

    assert_receive {:mcp_subscription_cancel, 21}
  end

  @tag :t25_catalog_invalidation
  test "registered primitive mutations publish modern invalidation events and advance cursors" do
    {:ok, server} = Server.start_link(page_size: 1, cursor_secret: "mutation-secret")

    assert :ok = Server.register_tool(server, "before", %{handler: fn _, _ -> {:ok, "ok"} end})

    assert :ok =
             Server.register_tool(server, "before_two", %{handler: fn _, _ -> {:ok, "ok"} end})

    request = %{
      kind: :request,
      id: 1,
      method: "tools/list",
      params: %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    assert {1, %{"result" => %{"nextCursor" => cursor}}} =
             Server.dispatch(server, request, %{principal: "p", tenant: "t"},
               version: "2026-07-28"
             )

    assert {2,
            %{
              "result" => %{
                "resultType" => "complete",
                "_meta" => %{
                  "io.modelcontextprotocol/subscriptionId" => 2,
                  "io.modelcontextprotocol/serverInfo" => %{"name" => _, "version" => _}
                }
              }
            }} =
             Server.dispatch(
               server,
               %{
                 request
                 | id: 2,
                   method: "subscriptions/listen",
                   params: Map.put(request.params, "notifications", %{"toolsListChanged" => true})
               },
               %{principal: "p", tenant: "t"},
               version: "2026-07-28",
               on_event: fn event -> send(self(), {:catalog_event, event}) end
             )

    assert_receive {:catalog_event, %{"method" => "notifications/subscriptions/acknowledged"}}

    assert :ok = Server.register_tool(server, "after", %{handler: fn _, _ -> {:ok, "ok"} end})
    assert_receive {:mcp_subscription, _tag, 2, %{"method" => "notifications/tools/list_changed"}}

    assert {3, %{"error" => %{"code" => -32602}}} =
             Server.dispatch(
               server,
               %{request | id: 3, params: Map.put(request.params, "cursor", cursor)},
               %{principal: "p", tenant: "t"},
               version: "2026-07-28"
             )

    Server.ack_subscription(server, 2)
    Server.close_subscription(server, 2)
  end

  test "subscription queues apply backpressure, drain on acknowledgment, and clean up disconnected sinks" do
    {:ok, subscriptions} = Subscriptions.start_link([])

    assert {:ok, id} =
             Subscriptions.open(
               subscriptions,
               "alice",
               "tenant-a",
               "bounded",
               %{"toolsListChanged" => true},
               self(),
               :bounded,
               nil
             )

    assert_receive {:mcp_subscription, :bounded, ^id, _ack}

    Enum.each(1..128, fn _ ->
      Subscriptions.publish(subscriptions, %{"type" => "toolsListChanged"})
    end)

    drain_subscription_events(id, 128)

    Subscriptions.publish(subscriptions, %{"type" => "toolsListChanged"})
    assert_receive {:mcp_subscription_backpressure, ^id}, 1_000

    Subscriptions.ack(subscriptions, id)
    Subscriptions.publish(subscriptions, %{"type" => "toolsListChanged"})
    assert_receive {:mcp_subscription, :bounded, ^id, _event}, 1_000

    sink = spawn(fn -> receive do: (_message -> :ok) end)

    assert {:ok, disconnected} =
             Subscriptions.open(
               subscriptions,
               "alice",
               "tenant-a",
               "disconnected",
               %{"toolsListChanged" => true},
               sink,
               :disconnected,
               nil
             )

    Process.exit(sink, :kill)
    Process.sleep(20)
    assert :ok = Subscriptions.publish(subscriptions, %{"type" => "toolsListChanged"})

    assert eventually(fn ->
             match?(
               {:ok, ^disconnected},
               Subscriptions.open(
                 subscriptions,
                 "alice",
                 "tenant-a",
                 disconnected,
                 %{"toolsListChanged" => true},
                 self(),
                 :reconnected,
                 nil
               )
             )
           end)

    Subscriptions.close(subscriptions, disconnected)
  end

  defp drain_subscription_events(_id, 0), do: :ok

  defp drain_subscription_events(id, remaining) do
    receive do
      {:mcp_subscription, :bounded, ^id, _event} -> drain_subscription_events(id, remaining - 1)
    after
      1_000 -> flunk("subscription event queue did not drain")
    end
  end

  defp relay_subscription_messages(parent) do
    receive do
      :stop ->
        :ok

      message ->
        send(parent, {:relayed_subscription, message})
        relay_subscription_messages(parent)
    end
  end

  defp eventually(fun, attempts \\ 20)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(5)
          eventually(fun, attempts - 1)
        )
  end
end
