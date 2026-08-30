defmodule AttestoMCP.Server.SessionStoreClusterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AttestoMCP.Server
  alias AttestoMCP.Server.Session
  alias AttestoMCP.Server.SessionStore.ETS
  alias AttestoMCP.Server.Subscriptions

  @legacy "2025-11-25"
  @resources_read AttestoMCP.Scopes.resources_read()
  @tools_read AttestoMCP.Scopes.tools_read()

  defmodule FailingUpdates do
    @moduledoc false
    @behaviour AttestoMCP.Server.SessionStore

    defdelegate save(store, key, record), to: ETS
    defdelegate load(store, key), to: ETS
    defdelegate list_active(store), to: ETS
    defdelegate cleanup_expired(store), to: ETS

    def delete(_store, _key), do: {:error, :write_failed}
    def update_ttl(_store, _key, _now), do: {:error, :write_failed}
    def update(_store, _key, _fun), do: {:error, :write_failed}
  end

  defmodule ToggleLoads do
    @moduledoc false
    @behaviour AttestoMCP.Server.SessionStore

    def save({store, _gate}, key, record), do: ETS.save(store, key, record)

    def load({store, gate}, key) do
      if Agent.get(gate, & &1), do: {:error, :temporary}, else: ETS.load(store, key)
    end

    def delete({store, _gate}, key), do: ETS.delete(store, key)
    def list_active({store, _gate}), do: ETS.list_active(store)
    def update_ttl({store, _gate}, key, now), do: ETS.update_ttl(store, key, now)
    def update({store, _gate}, key, fun), do: ETS.update(store, key, fun)
    def cleanup_expired({store, _gate}), do: ETS.cleanup_expired(store)
  end

  test "session records round-trip, preserve extensions on update, and fail closed" do
    principal = %{
      "sub" => "alice",
      "profile" => %URI{scheme: "https", host: "example.com", path: "/alice"}
    }

    session =
      Session.new(principal, "tenant-a")
      |> Map.put(:version, @legacy)
      |> Map.put(:initialized, true)
      |> Map.put(:client_capabilities, %{"sampling" => %{}})
      |> Map.put(:resource_subscriptions, %{"urn:item" => true})

    assert {:ok, record} = Session.to_record(session)
    refute Map.has_key?(record, "streams")
    assert {:ok, restored} = Session.from_record(Map.put(record, "future_extension", 42))
    assert restored.id == session.id
    assert restored.principal == session.principal
    assert restored.tenant == session.tenant
    assert restored.streams == %{}

    assert {:error, :unknown_record_version} =
             Session.from_record(Map.put(record, "format_version", 99))

    assert {:error, :invalid_record} = Session.from_record(Map.delete(record, "id"))
    assert {:error, :nonportable_binding} = Session.to_record(%{session | principal: self()})

    compressed_principal =
      %{"sub" => String.duplicate("a", 2_000)}
      |> :erlang.term_to_binary(compressed: 9)
      |> Base.url_encode64(padding: false)

    assert {:error, :invalid_binding} =
             Session.from_record(Map.put(record, "principal", compressed_principal))

    assert {:error, :invalid_record} =
             Session.from_record(
               Map.put(record, "resource_subscriptions", %{"urn:item" => false})
             )

    {:ok, store} = start_supervised(ETS)
    namespace = unique_namespace()

    {:ok, server} =
      start_supervised({Server, session_store: {ETS, store}, session_namespace: namespace})

    assert :ok = ETS.save(store, {namespace, session.id}, Map.put(record, "future_extension", 42))
    assert :ok = Server.touch_session(server, session.id)
    assert {:ok, updated} = ETS.load(store, {namespace, session.id})
    assert updated["future_extension"] == 42
  end

  test "shared store survives a server restart and rejects binding changes" do
    {:ok, store} = start_supervised(ETS)
    namespace = unique_namespace()
    opts = [session_store: {ETS, store}, session_namespace: namespace]

    {:ok, first} = Server.start_link(opts)
    assert {:ok, session} = Server.new_session(first, %{"sub" => "alice"}, "tenant-a")

    assert :ok =
             Server.negotiate_session(
               first,
               session.id,
               %{"sub" => "alice"},
               "tenant-a",
               @legacy,
               %{"sampling" => %{}}
             )

    assert :ok = Server.mark_initialized(first, session.id)
    assert :ok = GenServer.stop(first)

    {:ok, second} = start_supervised(Server.child_spec(opts))

    assert {:ok, restored} =
             Server.get_session(second, session.id, %{"sub" => "alice"}, "tenant-a")

    assert restored.initialized
    assert restored.version == @legacy
    assert restored.client_capabilities == %{"sampling" => %{}}
    assert {:error, :not_found} = Server.get_session(second, session.id, "mallory", "tenant-a")

    assert {:error, :not_found} =
             Server.get_session(second, session.id, %{"sub" => "alice"}, "other")
  end

  test "session refresh and initialization fail closed on backend write failure" do
    {:ok, store} = start_supervised(ETS)

    {:ok, server} =
      start_supervised(
        {Server, session_store: {FailingUpdates, store}, session_namespace: unique_namespace()}
      )

    assert {:ok, session} = Server.new_session(server, "alice", "tenant-a")
    assert {:error, :not_found} = Server.get_session(server, session.id, "alice", "tenant-a")
    assert {:error, :write_failed} = Server.touch_session(server, session.id)
    assert {:error, :write_failed} = Server.mark_initialized(server, session.id)
    assert {:error, :write_failed} = Server.delete_session(server, session.id)
    assert {:ok, _record} = ETS.load(store, {server_namespace(server), session.id})
  end

  test "atomic TTL refresh cannot renew an expired record" do
    {:ok, store} = start_supervised(ETS)
    session = Session.new("alice", "tenant-a")
    assert {:ok, record} = Session.to_record(session)

    expired =
      record
      |> Map.put("created_at_ms", 0)
      |> Map.put("last_seen_ms", 0)
      |> Map.put("absolute_timeout_ms", 1)
      |> Map.put("idle_timeout_ms", 1)

    key = {unique_namespace(), session.id}
    assert :ok = ETS.save(store, key, expired)
    assert {:ok, []} = ETS.list_active(store)
    assert :not_found = ETS.load(store, key)

    assert :ok = ETS.save(store, key, expired)
    assert :not_found = ETS.update_ttl(store, key, 10)
    assert :not_found = ETS.load(store, key)
  end

  test "explicit deletion removes cleanup bookkeeping and permits safe key reuse" do
    {:ok, store} = start_supervised(ETS)
    session = Session.new("alice", "tenant-a")
    assert {:ok, record} = Session.to_record(session)

    for index <- 1..256 do
      key = {"delete-churn", Integer.to_string(index)}
      assert :ok = ETS.save(store, key, Map.put(record, "id", elem(key, 1)))
      assert :ok = ETS.delete(store, key)
    end

    assert %{records: records, cleanup_queue: queue, queued: queued} = :sys.get_state(store)
    assert records == %{}
    assert :queue.len(queue) == 0
    assert MapSet.size(queued) == 0

    key = {"delete-churn", "reused"}
    assert :ok = ETS.save(store, key, Map.put(record, "id", "reused"))
    assert :ok = ETS.delete(store, key)
    assert :ok = ETS.save(store, key, Map.put(record, "id", "reused"))
    assert {:ok, _record} = ETS.load(store, key)
    assert :queue.len(:sys.get_state(store).cleanup_queue) == 1
  end

  test "invalid session bindings are distinct from store outages" do
    {:ok, server} = start_supervised(%{Server.child_spec([]) | id: make_ref()})
    assert {:error, :nonportable_binding} = Server.new_session(server, self(), nil)
    assert Process.alive?(server)
  end

  test "transient store load failures preserve live legacy streams" do
    {:ok, store} = start_supervised(ETS)
    {:ok, gate} = start_supervised({Agent, fn -> false end})

    {:ok, server} =
      start_supervised(
        {Server,
         session_store: {ToggleLoads, {store, gate}}, session_namespace: unique_namespace()}
      )

    assert {:ok, session} = Server.new_session(server, "alice", "tenant-a")
    assert :ok = Server.negotiate_session(server, session.id, "alice", "tenant-a", @legacy, %{})
    assert :ok = Server.mark_initialized(server, session.id)

    assert {:ok, stream} =
             Server.open_legacy_stream(server, session.id, "alice", "tenant-a", self())

    Agent.update(gate, fn _ -> true end)
    assert :ok = Server.publish(server, %{"type" => "toolsListChanged"})
    refute_receive {:mcp_legacy_close, ^stream, _reason}, 50

    Agent.update(gate, fn _ -> false end)
    assert :ok = Server.publish(server, %{"type" => "toolsListChanged"})
    assert_receive {:mcp_legacy_event, ^stream, 1, _event}, 500
  end

  test "updates evict corrupt durable records" do
    {:ok, store} = start_supervised(ETS)
    namespace = unique_namespace()

    {:ok, server} =
      start_supervised({Server, session_store: {ETS, store}, session_namespace: namespace})

    key = {namespace, "corrupt"}

    assert :ok = ETS.save(store, key, %{"format_version" => 999})
    assert :ok = Server.mark_initialized(server, "corrupt")
    assert :not_found = ETS.load(store, key)
  end

  test "unnamed servers use the documented default namespace and preserve missing-session init" do
    {:ok, server} = start_supervised(%{Server.child_spec([]) | id: make_ref()})
    assert :sys.get_state(server).session_namespace == "default"
    assert :ok = Server.mark_initialized(server, "missing-session")
  end

  test "cluster peers share sessions and receive modern, legacy, and catalog events once" do
    {:ok, store} = start_supervised(ETS)
    namespace = unique_namespace()

    opts = [
      session_store: {ETS, store},
      session_namespace: namespace,
      session_clustered: true
    ]

    {:ok, first} = start_supervised(%{Server.child_spec(opts) | id: make_ref()})
    {:ok, second} = start_supervised(%{Server.child_spec(opts) | id: make_ref()})

    assert {:ok, session} = Server.new_session(first, "alice", "tenant-a")
    assert :ok = Server.negotiate_session(first, session.id, "alice", "tenant-a", @legacy, %{})
    assert :ok = Server.mark_initialized(first, session.id)
    assert {:ok, restored} = Server.get_session(second, session.id, "alice", "tenant-a")
    assert restored.initialized

    assert {:ok, legacy_stream} =
             Server.open_legacy_stream(second, session.id, "alice", "tenant-a", self())

    subscriptions = GenServer.call(second, :subscriptions)

    assert {:ok, "modern"} =
             Subscriptions.open(
               subscriptions,
               "alice",
               "tenant-a",
               "modern",
               %{"toolsListChanged" => true},
               self(),
               :peer,
               nil
             )

    assert_receive {:mcp_subscription, :peer, "modern",
                    %{"method" => "notifications/subscriptions/acknowledged"}}

    assert :ok = Server.publish(first, %{"type" => "toolsListChanged"})

    assert_receive {:mcp_subscription, :peer, "modern", modern_event}, 1_000
    assert modern_event["method"] == "notifications/tools/list_changed"

    assert_receive {:mcp_legacy_event, ^legacy_stream, 1, legacy_event}, 1_000
    assert legacy_event["method"] == "notifications/tools/list_changed"
    refute_receive {:mcp_subscription, :peer, "modern", _duplicate}, 50
    refute_receive {:mcp_legacy_event, ^legacy_stream, _, _duplicate}, 50

    Server.ack_subscription(second, "modern", self())
    Server.ack_legacy_stream(second, legacy_stream)

    assert :ok =
             Server.register_tool(first, "clustered", %{
               handler: fn _arguments, _context -> {:ok, "ok"} end
             })

    assert_receive {:mcp_subscription, :peer, "modern", catalog_event}, 1_000
    assert catalog_event["method"] == "notifications/tools/list_changed"
    assert_receive {:mcp_legacy_event, ^legacy_stream, 2, _catalog_event}, 1_000
  end

  test "cluster resource notifications union divergent static and template scopes" do
    {publisher, recipient} = clustered_servers()
    parent = self()

    cases = [
      {:static_static, "urn:cluster/static-static", :static, :static, "publisher.ss",
       "recipient.ss"},
      {:static_template, "urn:cluster/static-template/item", :static, :template, "publisher.st",
       "recipient.st"},
      {:template_static, "urn:cluster/template-static/item", :template, :static, "publisher.ts",
       "recipient.ts"},
      {:template_template, "urn:cluster/template-template/item", :template, :template,
       "publisher.tt", "recipient.tt"},
      {:publisher_only, "urn:cluster/publisher-only", :static, :absent, "publisher.only", nil},
      {:recipient_only, "urn:cluster/recipient-only", :absent, :static, nil, "recipient.only"}
    ]

    Enum.each(cases, fn {_name, uri, publisher_kind, recipient_kind, publisher_scope,
                         recipient_scope} ->
      register_definition(publisher, publisher_kind, uri, publisher_scope)
      register_definition(recipient, recipient_kind, uri, recipient_scope)
    end)

    uris = Enum.map(cases, &elem(&1, 1))
    subscriptions = GenServer.call(recipient, :subscriptions)

    assert {:ok, subscription_id} =
             Subscriptions.open(
               subscriptions,
               "alice",
               "tenant-a",
               "cluster-scopes",
               %{"resourceSubscriptions" => uris},
               self(),
               :cluster,
               fn context ->
                 send(
                   parent,
                   {:modern_authorizer, context.event["params"]["uri"], context.required_scopes}
                 )

                 true
               end
             )

    assert_receive {:mcp_subscription, :cluster, "cluster-scopes", _ack}, 1_000

    {:ok, session} = Server.new_session(recipient, "alice", "tenant-a")
    :ok = Server.negotiate_session(recipient, session.id, "alice", "tenant-a", @legacy, %{})
    :ok = Server.mark_initialized(recipient, session.id)

    Enum.each(uris, fn uri ->
      assert :ok = Server.subscribe_resource(recipient, session.id, "alice", "tenant-a", uri)
    end)

    assert {:ok, legacy_stream} =
             Server.open_legacy_stream(
               recipient,
               session.id,
               "alice",
               "tenant-a",
               self(),
               fn context ->
                 send(
                   parent,
                   {:legacy_authorizer, context.event["params"]["uri"], context.required_scopes}
                 )

                 true
               end
             )

    Enum.each(Enum.with_index(cases), fn {{_name, uri, _publisher_kind, _recipient_kind,
                                           publisher_scope, recipient_scope}, index} ->
      alias_name =
        Enum.at(["resource", "resourceUpdated", "resourceSubscriptions"], rem(index, 3))

      assert :ok = Server.publish(publisher, %{"type" => alias_name, "uri" => uri})

      expected = Enum.reject([@resources_read, publisher_scope, recipient_scope], &is_nil/1)
      assert_receive {:modern_authorizer, ^uri, ^expected}, 1_000
      assert_receive {:mcp_subscription, :cluster, "cluster-scopes", modern_event}, 1_000
      assert modern_event["method"] == "notifications/resources/updated"

      assert_receive {:legacy_authorizer, ^uri, ^expected}, 1_000
      assert_receive {:mcp_legacy_event, ^legacy_stream, _, legacy_event}, 1_000
      assert legacy_event["method"] == "notifications/resources/updated"
    end)

    assert :ok = Subscriptions.close(subscriptions, subscription_id, self())
    assert :ok = Server.close_legacy_stream(recipient, legacy_stream)
  end

  test "cluster resource notifications conjoin publisher and recipient alternative clauses" do
    {publisher, recipient} = clustered_servers()
    parent = self()
    uri = "urn:cluster/alternative-clauses"

    assert :ok =
             Server.register_resource(publisher, "alternative-publisher", %{
               uri: uri,
               required_scopes: ["publisher.read"],
               alternative_scope_sets: [
                 ["publisher.admin"],
                 ["publisher.team", "publisher.execute"]
               ]
             })

    assert :ok =
             Server.register_resource(recipient, "alternative-recipient", %{
               uri: uri,
               required_scopes: ["recipient.read"],
               alternative_scope_sets: [["recipient.admin"]]
             })

    subscriptions = GenServer.call(recipient, :subscriptions)

    assert {:ok, subscription_id} =
             Subscriptions.open(
               subscriptions,
               "alice",
               "tenant-a",
               "alternative-clauses",
               %{"resourceSubscriptions" => [uri]},
               self(),
               :alternative_clauses,
               fn context ->
                 send(
                   parent,
                   {:cluster_alternative_modern, context.required_scopes,
                    context.required_scope_sets}
                 )

                 true
               end
             )

    assert_receive {:mcp_subscription, :alternative_clauses, "alternative-clauses", _ack},
                   1_000

    {:ok, session} = Server.new_session(recipient, "alice", "tenant-a")
    :ok = Server.negotiate_session(recipient, session.id, "alice", "tenant-a", @legacy, %{})
    :ok = Server.mark_initialized(recipient, session.id)
    :ok = Server.subscribe_resource(recipient, session.id, "alice", "tenant-a", uri)

    assert {:ok, legacy_stream} =
             Server.open_legacy_stream(
               recipient,
               session.id,
               "alice",
               "tenant-a",
               self(),
               fn context ->
                 send(
                   parent,
                   {:cluster_alternative_legacy, context.required_scopes,
                    context.required_scope_sets}
                 )

                 true
               end
             )

    assert :ok = Server.publish(publisher, %{"type" => "resourceUpdated", "uri" => uri})

    expected_scope_sets = [
      [@resources_read, "publisher.read", "recipient.read"],
      [@resources_read, "publisher.read", "recipient.admin"],
      [@resources_read, "publisher.admin", "recipient.read"],
      [@resources_read, "publisher.admin", "recipient.admin"],
      [@resources_read, "publisher.team", "publisher.execute", "recipient.read"],
      [@resources_read, "publisher.team", "publisher.execute", "recipient.admin"]
    ]

    assert_receive {:cluster_alternative_modern,
                    [@resources_read, "publisher.read", "recipient.read"], ^expected_scope_sets},
                   1_000

    assert_receive {:mcp_subscription, :alternative_clauses, "alternative-clauses", event},
                   1_000

    assert event["method"] == "notifications/resources/updated"

    assert_receive {:cluster_alternative_legacy,
                    [@resources_read, "publisher.read", "recipient.read"], ^expected_scope_sets},
                   1_000

    assert_receive {:mcp_legacy_event, ^legacy_stream, _, legacy_event}, 1_000
    assert legacy_event["method"] == "notifications/resources/updated"

    assert :ok = Subscriptions.close(subscriptions, subscription_id, self())
    assert :ok = Server.close_legacy_stream(recipient, legacy_stream)
  end

  test "legacy three-tuple resource notifications fail closed while catalog messages deliver once" do
    {publisher, recipient} = clustered_servers()
    uri = "urn:cluster/legacy-resource"

    assert :ok =
             Server.register_resource(publisher, "legacy-publisher", %{
               uri: uri,
               required_scopes: ["publisher.read"]
             })

    assert :ok =
             Server.register_resource(recipient, "legacy-recipient", %{
               uri: uri,
               required_scopes: ["recipient.read"]
             })

    subscriptions = GenServer.call(recipient, :subscriptions)

    assert {:ok, subscription_id} =
             Subscriptions.open(
               subscriptions,
               "alice",
               "tenant-a",
               "legacy-resource",
               %{"toolsListChanged" => true, "resourceSubscriptions" => [uri]},
               self(),
               :legacy,
               nil
             )

    assert_receive {:mcp_subscription, :legacy, "legacy-resource", _ack}, 1_000

    {:ok, session} = Server.new_session(recipient, "alice", "tenant-a")

    assert :ok =
             Server.negotiate_session(recipient, session.id, "alice", "tenant-a", @legacy, %{})

    assert :ok = Server.mark_initialized(recipient, session.id)

    assert {:ok, legacy_stream} =
             Server.open_legacy_stream(recipient, session.id, "alice", "tenant-a", self())

    GenServer.cast(
      recipient,
      {:cluster_publish, %{"type" => "resourceUpdated", "uri" => uri}, []}
    )

    refute_receive {:mcp_subscription, :legacy, "legacy-resource", _event}, 200
    refute_receive {:mcp_legacy_event, ^legacy_stream, _, _event}, 200

    GenServer.cast(recipient, {:cluster_publish, %{"type" => "toolsListChanged"}, []})
    assert_receive {:mcp_subscription, :legacy, "legacy-resource", event}, 1_000
    assert event["method"] == "notifications/tools/list_changed"
    assert_receive {:mcp_legacy_event, ^legacy_stream, _, legacy_event}, 1_000
    assert legacy_event["method"] == "notifications/tools/list_changed"
    refute_receive {:mcp_subscription, :legacy, "legacy-resource", _duplicate}, 200
    refute_receive {:mcp_legacy_event, ^legacy_stream, _, _legacy_duplicate}, 200

    assert :ok = Subscriptions.close(subscriptions, subscription_id, self())
    assert :ok = Server.close_legacy_stream(recipient, legacy_stream)
    assert Process.alive?(publisher)
  end

  test "cluster resource envelopes fail closed without killing the recipient" do
    {_publisher, recipient} = clustered_servers()
    uri = "urn:cluster/envelope"
    assert :ok = Server.register_resource(recipient, "envelope-resource", %{uri: uri})

    subscriptions = GenServer.call(recipient, :subscriptions)

    assert {:ok, subscription_id} =
             Subscriptions.open(
               subscriptions,
               "alice",
               "tenant-a",
               "envelope",
               %{"resourceSubscriptions" => [uri]},
               self(),
               :envelope,
               nil
             )

    assert_receive {:mcp_subscription, :envelope, "envelope", _ack}, 1_000

    {:ok, session} = Server.new_session(recipient, "alice", "tenant-a")

    assert :ok =
             Server.negotiate_session(recipient, session.id, "alice", "tenant-a", @legacy, %{})

    assert :ok = Server.mark_initialized(recipient, session.id)
    assert :ok = Server.subscribe_resource(recipient, session.id, "alice", "tenant-a", uri)

    assert {:ok, legacy_stream} =
             Server.open_legacy_stream(recipient, session.id, "alice", "tenant-a", self())

    valid_notification = %{"type" => "resourceUpdated", "uri" => uri}
    valid_scopes = [@resources_read]
    valid_scope_sets = [valid_scopes]

    envelope = fn notification, opts, scope_sets ->
      %{
        version: 2,
        notification: notification,
        opts: opts,
        resource_scope_sets: scope_sets
      }
    end

    legacy_envelope = fn notification, opts, scopes ->
      %{version: 1, notification: notification, opts: opts, resource_scopes: scopes}
    end

    oversized_scopes =
      Enum.map(1..129, fn index -> "cluster.scope.#{index}" end)

    oversized_aggregate =
      Enum.map(1..40, fn index -> String.pad_trailing("cluster.scope.#{index}", 256, "x") end)

    too_many_scope_sets =
      Enum.map(1..9, fn index -> [@resources_read, "cluster.alternative.#{index}"] end)

    too_many_scope_memberships =
      Enum.map(1..8, fn set ->
        [@resources_read | Enum.map(1..16, &"cluster.member.#{set}.#{&1}")]
      end)

    too_many_scope_set_bytes =
      Enum.map(1..8, fn set ->
        [
          @resources_read
          | Enum.map(1..5, fn index ->
              String.pad_trailing("cluster.bytes.#{set}.#{index}", 220, "x")
            end)
        ]
      end)

    malformed = [
      envelope.(valid_notification, [], valid_scope_sets) |> Map.put(:version, 3),
      legacy_envelope.(valid_notification, [], valid_scopes) |> Map.put(:version, 2),
      envelope.(valid_notification, [], [["resource.read"]]),
      envelope.(valid_notification, [], [[@resources_read, :atom_scope]]),
      envelope.(valid_notification, [], [[@resources_read | :improper]]),
      envelope.(valid_notification, [], [[@resources_read] | :improper]),
      envelope.(valid_notification, [], [[@resources_read, @resources_read]]),
      envelope.(valid_notification, [], [["cluster.scope.1"]]),
      envelope.(valid_notification, [], []),
      envelope.(valid_notification, [], [[]]),
      envelope.(valid_notification, [], [valid_scopes, valid_scopes]),
      envelope.(valid_notification, [], too_many_scope_sets),
      envelope.(valid_notification, [], too_many_scope_memberships),
      envelope.(valid_notification, [], too_many_scope_set_bytes),
      envelope.(valid_notification, [], [[@resources_read | oversized_scopes]]),
      envelope.(valid_notification, [], [[@resources_read, String.duplicate("a", 257)]]),
      envelope.(valid_notification, [], [[@resources_read | oversized_aggregate]]),
      envelope.(valid_notification, [:not_keyword], valid_scope_sets),
      envelope.(valid_notification, [{:authorize, :not_a_function}], valid_scope_sets),
      envelope.(valid_notification, [{:authorize, fn _ -> true end, :extra}], valid_scope_sets),
      %{
        version: 2,
        notification: valid_notification,
        opts: [],
        resource_scope_sets: valid_scope_sets,
        extra: true
      },
      %{
        version: 2,
        notification: %{"type" => "unknown", "uri" => uri},
        opts: [],
        resource_scope_sets: valid_scope_sets
      },
      %{
        version: 2,
        notification: %{type: "resourceUpdated", uri: uri},
        opts: [],
        resource_scope_sets: valid_scope_sets
      },
      %{
        version: 2,
        notification: %{"jsonrpc" => "2.0", "method" => "notifications/resources/updated"},
        opts: [],
        resource_scope_sets: valid_scope_sets
      },
      %{
        version: 2,
        notification: valid_notification,
        opts: [],
        resource_scope_sets: :not_a_list
      },
      %{
        version: 2,
        notification: valid_notification,
        opts: [],
        resource_scope_sets: valid_scope_sets,
        bad: self()
      },
      legacy_envelope.(valid_notification, [], ["resource.read"]),
      legacy_envelope.(valid_notification, [], [@resources_read | :improper]),
      legacy_envelope.(valid_notification, [], :not_a_list)
    ]

    Enum.each(malformed, &GenServer.cast(recipient, {:cluster_publish, &1}))
    _ = :sys.get_state(recipient)
    assert Process.alive?(recipient)
    assert Process.alive?(subscriptions)
    refute_receive {:mcp_subscription, :envelope, "envelope", _event}, 200
    refute_receive {:mcp_legacy_event, ^legacy_stream, _, _event}, 200

    GenServer.cast(
      recipient,
      {:cluster_publish, legacy_envelope.(valid_notification, [], valid_scopes)}
    )

    assert_receive {:mcp_subscription, :envelope, "envelope", legacy_compatible_event}, 1_000
    assert legacy_compatible_event["method"] == "notifications/resources/updated"

    assert_receive {:mcp_legacy_event, ^legacy_stream, _, legacy_compatible_legacy_event}, 1_000
    assert legacy_compatible_legacy_event["method"] == "notifications/resources/updated"

    GenServer.cast(
      recipient,
      {:cluster_publish, envelope.(valid_notification, [], valid_scope_sets)}
    )

    assert_receive {:mcp_subscription, :envelope, "envelope", event}, 1_000
    assert event["method"] == "notifications/resources/updated"
    assert_receive {:mcp_legacy_event, ^legacy_stream, _, legacy_event}, 1_000
    assert legacy_event["method"] == "notifications/resources/updated"
    refute_receive {:mcp_subscription, :envelope, "envelope", _duplicate}, 200
    refute_receive {:mcp_legacy_event, ^legacy_stream, _, _legacy_duplicate}, 200

    assert :ok = Subscriptions.close(subscriptions, subscription_id, self())
    assert :ok = Server.close_legacy_stream(recipient, legacy_stream)
  end

  test "local resource scope resolution gives static definitions precedence and stable templates" do
    {:ok, server} = Server.start_link([])
    parent = self()
    uri = "urn:cluster/precedence/item"
    ordered_uri = "urn:cluster/ordered/item"

    assert :ok =
             Server.register_resource_template(server, "urn:cluster/precedence/{id}", %{
               required_scopes: ["template.read"]
             })

    assert :ok =
             Server.register_resource(server, "precedence-static", %{
               uri: uri,
               required_scopes: []
             })

    assert :ok =
             Server.register_resource_template(server, "urn:cluster/ordered/{z}", %{
               required_scopes: ["z.read"]
             })

    assert :ok =
             Server.register_resource_template(server, "urn:cluster/ordered/{a}", %{
               required_scopes: ["a.read"]
             })

    subscriptions = GenServer.call(server, :subscriptions)
    uris = [uri, ordered_uri]

    assert {:ok, subscription_id} =
             Subscriptions.open(
               subscriptions,
               "alice",
               "tenant-a",
               "resolution",
               %{"resourceSubscriptions" => uris},
               self(),
               :resolution,
               fn context ->
                 send(
                   parent,
                   {:resolved_modern, context.event["params"]["uri"], context.required_scopes}
                 )

                 true
               end
             )

    assert_receive {:mcp_subscription, :resolution, "resolution", _ack}, 1_000

    {:ok, session} = Server.new_session(server, "alice", "tenant-a")
    :ok = Server.negotiate_session(server, session.id, "alice", "tenant-a", @legacy, %{})
    :ok = Server.mark_initialized(server, session.id)

    Enum.each(uris, fn resource_uri ->
      assert :ok =
               Server.subscribe_resource(server, session.id, "alice", "tenant-a", resource_uri)
    end)

    assert {:ok, legacy_stream} =
             Server.open_legacy_stream(
               server,
               session.id,
               "alice",
               "tenant-a",
               self(),
               fn context ->
                 send(
                   parent,
                   {:resolved_legacy, context.event["params"]["uri"], context.required_scopes}
                 )

                 true
               end
             )

    assert :ok = Server.publish(server, %{"type" => "resourceUpdated", "uri" => uri})
    assert_receive {:resolved_modern, ^uri, [@resources_read]}, 1_000
    assert_receive {:mcp_subscription, :resolution, "resolution", _static_event}, 1_000
    assert_receive {:resolved_legacy, ^uri, [@resources_read]}, 1_000
    assert_receive {:mcp_legacy_event, ^legacy_stream, _, _static_legacy_event}, 1_000

    assert :ok = Server.publish(server, %{"type" => "resourceUpdated", "uri" => ordered_uri})
    assert_receive {:resolved_modern, ^ordered_uri, [@resources_read, "a.read"]}, 1_000
    assert_receive {:mcp_subscription, :resolution, "resolution", _ordered_event}, 1_000
    assert_receive {:resolved_legacy, ^ordered_uri, [@resources_read, "a.read"]}, 1_000
    assert_receive {:mcp_legacy_event, ^legacy_stream, _, _ordered_legacy_event}, 1_000

    assert :ok = Subscriptions.close(subscriptions, subscription_id, self())
    assert :ok = Server.close_legacy_stream(server, legacy_stream)
    GenServer.stop(server)
  end

  test "cluster caller authorizers allow, deny, and raise neutrally" do
    {publisher, recipient} = clustered_servers()
    parent = self()
    uri = "urn:cluster/caller-authorizer"

    assert :ok =
             Server.register_resource(publisher, "caller-publisher", %{
               uri: uri,
               required_scopes: ["publisher.read"]
             })

    assert :ok =
             Server.register_resource(recipient, "caller-recipient", %{
               uri: uri,
               required_scopes: ["recipient.read"]
             })

    subscriptions = GenServer.call(recipient, :subscriptions)

    assert {:ok, subscription_id} =
             Subscriptions.open(
               subscriptions,
               "alice",
               "tenant-a",
               "caller-authorizer",
               %{"toolsListChanged" => true, "resourceSubscriptions" => [uri]},
               self(),
               :caller,
               nil
             )

    assert_receive {:mcp_subscription, :caller, "caller-authorizer", _ack}, 1_000

    {:ok, session} = Server.new_session(recipient, "alice", "tenant-a")

    assert :ok =
             Server.negotiate_session(recipient, session.id, "alice", "tenant-a", @legacy, %{})

    assert :ok = Server.mark_initialized(recipient, session.id)
    assert :ok = Server.subscribe_resource(recipient, session.id, "alice", "tenant-a", uri)

    assert {:ok, legacy_stream} =
             Server.open_legacy_stream(recipient, session.id, "alice", "tenant-a", self())

    assert :ok =
             Server.publish(publisher, %{"type" => "resourceUpdated", "uri" => uri},
               authorize: fn context ->
                 send(parent, {:caller_authorizer, :allow, context.required_scopes})
                 true
               end
             )

    assert_receive {:caller_authorizer, :allow,
                    [@resources_read, "publisher.read", "recipient.read"]},
                   1_000

    assert_receive {:caller_authorizer, :allow,
                    [@resources_read, "publisher.read", "recipient.read"]},
                   1_000

    assert_receive {:mcp_subscription, :caller, "caller-authorizer", _allowed_event}, 1_000
    assert_receive {:mcp_legacy_event, ^legacy_stream, _, _allowed_legacy_event}, 1_000

    assert :ok =
             Server.publish(publisher, %{"type" => "resourceUpdated", "uri" => uri},
               authorize: fn context ->
                 send(parent, {:caller_authorizer, :deny, context.required_scopes})
                 false
               end
             )

    assert_receive {:caller_authorizer, :deny,
                    [@resources_read, "publisher.read", "recipient.read"]},
                   1_000

    assert_receive {:caller_authorizer, :deny,
                    [@resources_read, "publisher.read", "recipient.read"]},
                   1_000

    refute_receive {:mcp_subscription, :caller, "caller-authorizer", _denied_event}, 200
    refute_receive {:mcp_legacy_event, ^legacy_stream, _, _denied_legacy_event}, 200

    assert :ok =
             Server.publish(publisher, %{"type" => "resourceUpdated", "uri" => uri},
               authorize: fn context ->
                 send(parent, {:caller_authorizer, :raise, context.required_scopes})
                 raise "test authorizer failure"
               end
             )

    assert_receive {:caller_authorizer, :raise,
                    [@resources_read, "publisher.read", "recipient.read"]},
                   1_000

    assert_receive {:caller_authorizer, :raise,
                    [@resources_read, "publisher.read", "recipient.read"]},
                   1_000

    refute_receive {:mcp_subscription, :caller, "caller-authorizer", _raised_event}, 200
    refute_receive {:mcp_legacy_event, ^legacy_stream, _, _raised_legacy_event}, 200

    assert :ok =
             Server.publish(publisher, %{"type" => "toolsListChanged"},
               authorize: fn context ->
                 send(
                   parent,
                   {:catalog_authorizer, context.event["method"], context.required_scopes}
                 )

                 false
               end
             )

    assert_receive {:catalog_authorizer, "notifications/tools/list_changed", []}, 1_000

    assert_receive {:catalog_authorizer, "notifications/tools/list_changed", [@tools_read]},
                   1_000

    refute_receive {:mcp_subscription, :caller, "caller-authorizer", _catalog_event}, 200
    refute_receive {:mcp_legacy_event, ^legacy_stream, _, _catalog_legacy_event}, 200

    assert {:error, :invalid_options} =
             Server.publish(publisher, %{"type" => "resourceUpdated", "uri" => uri},
               authorize: :invalid
             )

    assert {:error, :invalid_options} =
             Server.publish(publisher, %{"type" => "resourceUpdated", "uri" => uri},
               authorize: fn _ -> false end,
               authorize: fn _ -> true end
             )

    assert Process.alive?(recipient)

    assert :ok = Subscriptions.close(subscriptions, subscription_id, self())
    assert :ok = Server.close_legacy_stream(recipient, legacy_stream)
  end

  test "cluster publisher keeps over-limit resource delivery local and removes duplicates" do
    {server, recipient} = clustered_servers()
    parent = self()
    uri = "urn:cluster/many-scopes"
    scopes = Enum.map(1..129, fn index -> "cluster.scope.#{index}" end)

    assert :ok =
             Server.register_resource(server, "many-scopes", %{
               uri: uri,
               required_scopes: [@resources_read | scopes]
             })

    subscriptions = GenServer.call(server, :subscriptions)
    recipient_subscriptions = GenServer.call(recipient, :subscriptions)

    assert {:ok, subscription_id} =
             Subscriptions.open(
               subscriptions,
               "alice",
               "tenant-a",
               "many-scopes",
               %{"resourceSubscriptions" => [uri]},
               self(),
               :many,
               fn context ->
                 send(parent, {:many_scopes, context.required_scopes})
                 true
               end
             )

    assert_receive {:mcp_subscription, :many, "many-scopes", _ack}, 1_000

    assert {:ok, recipient_subscription_id} =
             Subscriptions.open(
               recipient_subscriptions,
               "alice",
               "tenant-a",
               "many-scopes-recipient",
               %{"resourceSubscriptions" => [uri]},
               self(),
               :many_recipient,
               nil
             )

    assert_receive {:mcp_subscription, :many_recipient, "many-scopes-recipient", _ack}, 1_000
    assert :ok = Server.publish(server, %{"type" => "resourceUpdated", "uri" => uri})
    assert_receive {:many_scopes, required}, 1_000
    assert required == [@resources_read | scopes]
    assert_receive {:mcp_subscription, :many, "many-scopes", _event}, 1_000
    refute_receive {:mcp_subscription, :many_recipient, "many-scopes-recipient", _event}, 200
    refute_receive {:mcp_subscription, :many, "many-scopes", _duplicate}, 200

    {:ok, session} = Server.new_session(server, "alice", "tenant-a")
    assert :ok = Server.negotiate_session(server, session.id, "alice", "tenant-a", @legacy, %{})
    assert :ok = Server.mark_initialized(server, session.id)
    assert :ok = Server.subscribe_resource(server, session.id, "alice", "tenant-a", uri)

    assert {:ok, legacy_stream} =
             Server.open_legacy_stream(
               server,
               session.id,
               "alice",
               "tenant-a",
               self(),
               fn context ->
                 send(parent, {:many_legacy_scopes, context.required_scopes})
                 true
               end
             )

    assert :ok = Server.publish(server, %{"type" => "resourceUpdated", "uri" => uri})
    assert_receive {:many_legacy_scopes, [@resources_read | ^scopes]}, 1_000
    assert_receive {:mcp_legacy_event, ^legacy_stream, _, _legacy_event}, 1_000
    refute_receive {:mcp_subscription, :many_recipient, "many-scopes-recipient", _event}, 200

    assert :ok = Subscriptions.close(subscriptions, subscription_id, self())

    assert :ok =
             Subscriptions.close(recipient_subscriptions, recipient_subscription_id, self())

    assert :ok = Server.close_legacy_stream(server, legacy_stream)
  end

  test "cluster mode requires an explicit shared adapter and namespace" do
    assert_invalid_start(session_clustered: true)

    {:ok, store} = start_supervised(ETS)
    assert_invalid_start(session_clustered: true, session_store: {ETS, store})
  end

  test "loss of a session store stops the server instead of falling back" do
    {:ok, store} = ETS.start_link([])

    {:ok, server} =
      Server.start_link(
        session_store: {ETS, store},
        session_namespace: unique_namespace()
      )

    Process.unlink(server)
    monitor = Process.monitor(server)

    capture_log(fn ->
      GenServer.stop(store)
      assert_receive {:DOWN, ^monitor, :process, ^server, :session_store_unavailable}, 1_000
    end)
  end

  defp unique_namespace,
    do: "test-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

  defp clustered_servers do
    {:ok, store} = start_supervised(ETS)
    namespace = unique_namespace()

    opts = [
      session_store: {ETS, store},
      session_namespace: namespace,
      session_clustered: true
    ]

    {:ok, publisher} = start_supervised(%{Server.child_spec(opts) | id: make_ref()})
    {:ok, recipient} = start_supervised(%{Server.child_spec(opts) | id: make_ref()})
    {publisher, recipient}
  end

  defp register_definition(server, :static, uri, scope) do
    Server.register_resource(server, uri, %{required_scopes: [scope]})
  end

  defp register_definition(server, :template, uri, scope) do
    template = String.replace_suffix(uri, "/item", "/{id}")
    Server.register_resource_template(server, template, %{required_scopes: [scope]})
  end

  defp register_definition(_server, :absent, _uri, nil), do: :ok

  defp server_namespace(server) do
    server
    |> Server.options()
    |> Keyword.fetch!(:session_namespace)
  end

  defp assert_invalid_start(opts) do
    {_pid, monitor} = spawn_monitor(fn -> Server.start_link(opts) end)
    assert_receive {:DOWN, ^monitor, :process, _pid, reason}, 1_000
    assert inspect(reason) =~ "requires an explicit shared"
  end
end
