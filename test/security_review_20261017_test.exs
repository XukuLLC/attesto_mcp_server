defmodule AttestoMCP.Server.SecurityReview20261017Test do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server
  alias AttestoMCP.Server.{Registry, Session, Subscriptions}
  alias AttestoMCP.Server.SessionStore.ETS

  import AttestoMCP.Server.TestSupport.Async, only: [eventually: 1]

  @legacy "2025-11-25"

  defmodule LegacySessionStore do
    @moduledoc false
    @behaviour AttestoMCP.Server.SessionStore

    defdelegate save(store, key, record), to: ETS
    defdelegate load(store, key), to: ETS
    defdelegate delete(store, key), to: ETS
    defdelegate list_active(store), to: ETS
    defdelegate update_ttl(store, key, now), to: ETS
    defdelegate update(store, key, fun), to: ETS
    defdelegate cleanup_expired(store), to: ETS
  end

  test "rate decisions stay bounded and reclaim capacity only on full-table admission" do
    {:ok, loaded} =
      Server.start_link(
        rate_limits: %{
          auth_failures: %{burst: 1_000_000, window_ms: 60_000}
        }
      )

    {:ok, baseline} =
      Server.start_link(
        rate_limits: %{
          auth_failures: %{burst: 1_000_000, window_ms: 60_000}
        }
      )

    now = System.monotonic_time(:millisecond)

    buckets = %{
      auth_failures:
        Map.new(1..10_000, fn index ->
          {{:synthetic, index},
           %{tokens: 1_000_000.0, at: now, window_ms: 60_000, expires_at: now + 60_000}}
        end)
    }

    :sys.replace_state(loaded, &%{&1 | rate_buckets: buckets})

    {baseline_us, :ok} =
      :timer.tc(fn ->
        Enum.each(1..500, fn _ ->
          assert :ok = Server.allow_rate(baseline, :existing, :auth_failures)
        end)
      end)

    {loaded_us, :ok} =
      :timer.tc(fn ->
        Enum.each(1..500, fn _ ->
          assert :ok = Server.allow_rate(loaded, {:synthetic, 1}, :auth_failures)
        end)
      end)

    assert loaded_us < baseline_us * 30 + 100_000
    assert Server.stats(loaded).rate_buckets == 10_000

    {baseline_admission_us, :ok} =
      :timer.tc(fn ->
        Enum.each(1..500, fn index ->
          assert :ok = Server.allow_rate(baseline, {:fresh, index}, :auth_failures)
        end)
      end)

    {loaded_admission_us, :ok} =
      :timer.tc(fn ->
        Enum.each(1..500, fn index ->
          assert :ok = Server.allow_rate(loaded, {:fresh, index}, :auth_failures)
        end)
      end)

    assert loaded_admission_us < baseline_admission_us * 30 + 100_000
    assert :ok = Server.allow_rate(loaded, :new_bucket, :auth_failures)
    assert Server.stats(loaded).rate_buckets == 10_000

    full_state = :sys.get_state(loaded)
    assert Map.has_key?(full_state.rate_buckets.auth_failures, :new_bucket)

    :sys.replace_state(loaded, fn state ->
      call_bucket =
        Map.fetch!(state.rate_buckets.auth_failures, :new_bucket)
        |> Map.put(:expires_at, now + 30_000)

      rate_buckets =
        state.rate_buckets
        |> put_in([:auth_failures], Map.delete(state.rate_buckets.auth_failures, :new_bucket))
        |> Map.put(:calls, %{only_call_bucket: call_bucket})

      %{state | rate_buckets: rate_buckets}
    end)

    assert :ok = Server.allow_rate(loaded, :another_new_bucket, :auth_failures)
    rebalanced_state = :sys.get_state(loaded)
    assert Map.has_key?(rebalanced_state.rate_buckets.calls, :only_call_bucket)
    assert Map.has_key?(rebalanced_state.rate_buckets.auth_failures, :another_new_bucket)
    assert Server.stats(loaded).rate_buckets == 10_000

    :sys.replace_state(loaded, fn state ->
      expired =
        Map.new(state.rate_buckets, fn {category, category_buckets} ->
          {category,
           Map.new(category_buckets, fn {key, bucket} ->
             {key, %{bucket | expires_at: now - 1}}
           end)}
        end)

      %{state | rate_buckets: expired}
    end)

    send(loaded, :cleanup_sessions)
    assert eventually(fn -> Server.stats(loaded).rate_buckets == 0 end)
  end

  test "modern subscriptions enforce captured scopes without a transport authorizer" do
    {:ok, subscriptions} = Subscriptions.start_link([])
    filter = %{"resourceSubscriptions" => ["urn:private"]}

    assert {:ok, "without-scope"} =
             Subscriptions.open(
               subscriptions,
               "principal",
               nil,
               "without-scope",
               filter,
               self(),
               :without_scope,
               nil,
               []
             )

    assert_receive {:mcp_subscription, :without_scope, "without-scope", _ack}

    assert :ok =
             Subscriptions.publish_sync(
               subscriptions,
               %{"type" => "resource", "uri" => "urn:private"},
               required_scope_sets: [["private.read"]]
             )

    refute_receive {:mcp_subscription, :without_scope, "without-scope", _event}, 50

    assert {:ok, "with-scope"} =
             Subscriptions.open(
               subscriptions,
               "principal",
               nil,
               "with-scope",
               filter,
               self(),
               :with_scope,
               nil,
               ["private.read", "private.read"]
             )

    assert_receive {:mcp_subscription, :with_scope, "with-scope", _ack}

    assert :ok =
             Subscriptions.publish_sync(
               subscriptions,
               %{"type" => "resource", "uri" => "urn:private"},
               required_scope_sets: [["private.read"]]
             )

    assert_receive {:mcp_subscription, :with_scope, "with-scope", _event}
    refute_receive {:mcp_subscription, :without_scope, "without-scope", _event}, 50
  end

  test "legacy streams enforce captured scopes without a transport authorizer" do
    {:ok, server} = Server.start_link([])
    {:ok, session} = Server.new_session(server, "principal")
    :ok = Server.negotiate_session(server, session.id, "principal", nil, @legacy, %{})
    :ok = Server.mark_initialized(server, session.id)
    :ok = Server.subscribe_resource(server, session.id, "principal", nil, "urn:private")

    :ok =
      Server.register_resource(server, "urn:private", %{
        required_scopes: ["private.read"],
        handler: fn _, _ -> {:ok, %{contents: []}} end
      })

    assert {:ok, denied_stream} =
             Server.open_legacy_stream(server, session.id, "principal", nil, self())

    :ok = Server.publish(server, %{"type" => "resource", "uri" => "urn:private"})
    refute_receive {:mcp_legacy_event, ^denied_stream, _, _}, 50
    :ok = Server.close_legacy_stream(server, denied_stream)

    assert {:ok, allowed_stream} =
             Server.open_legacy_stream(
               server,
               session.id,
               "principal",
               nil,
               self(),
               nil,
               [
                 AttestoMCP.Scopes.resources_read(),
                 "private.read",
                 "private.read"
               ]
             )

    :ok = Server.publish(server, %{"type" => "resource", "uri" => "urn:private"})
    assert_receive {:mcp_legacy_event, ^allowed_stream, _, _}
  end

  test "legacy session and per-session stream limits reclaim capacity" do
    {:ok, server} =
      Server.start_link(max_sessions_per_principal: 2, max_legacy_streams_per_session: 2)

    assert {:ok, first} = Server.new_session(server, "principal", "tenant-a")
    assert {:ok, _second} = Server.new_session(server, "principal", "tenant-b")
    assert {:error, :session_limit} = Server.new_session(server, "principal", "tenant-c")
    assert {:ok, _other} = Server.new_session(server, "other", nil)

    assert :ok = Server.delete_session(server, first.id)
    assert {:ok, replacement} = Server.new_session(server, "principal", "tenant-c")
    :ok = Server.negotiate_session(server, replacement.id, "principal", "tenant-c", @legacy, %{})
    :ok = Server.mark_initialized(server, replacement.id)

    assert {:ok, stream_one} =
             Server.open_legacy_stream(
               server,
               replacement.id,
               "principal",
               "tenant-c",
               self()
             )

    assert {:ok, _stream_two} =
             Server.open_legacy_stream(
               server,
               replacement.id,
               "principal",
               "tenant-c",
               self()
             )

    assert {:error, :stream_limit} =
             Server.open_legacy_stream(
               server,
               replacement.id,
               "principal",
               "tenant-c",
               self()
             )

    :ok = Server.close_legacy_stream(server, stream_one)

    assert {:ok, _replacement_stream} =
             Server.open_legacy_stream(
               server,
               replacement.id,
               "principal",
               "tenant-c",
               self()
             )
  end

  test "ETS stats report every active session beyond the listing page" do
    {:ok, store} = ETS.start_link([])
    namespace = "exact-stats"

    Enum.each(1..1_500, fn index ->
      session = Session.new("principal-#{index}", nil)
      {:ok, record} = Session.to_record(session)
      :ok = ETS.save(store, {namespace, session.id}, record)
    end)

    other_session = Session.new("other-namespace", nil)
    {:ok, other_record} = Session.to_record(other_session)
    :ok = ETS.save(store, {"other-namespace", other_session.id}, other_record)

    {:ok, server} =
      Server.start_link(session_store: {ETS, store}, session_namespace: namespace)

    assert Server.stats(server).sessions == 1_500
  end

  test "shared ETS session limits remain isolated by namespace" do
    {:ok, store} = ETS.start_link([])

    {:ok, first} =
      Server.start_link(
        session_store: {ETS, store},
        session_namespace: "first",
        max_sessions_per_principal: 1
      )

    {:ok, second} =
      Server.start_link(
        session_store: {ETS, store},
        session_namespace: "second",
        max_sessions_per_principal: 1
      )

    assert {:ok, _session} = Server.new_session(first, "same-principal")
    assert {:ok, _session} = Server.new_session(second, "same-principal")
    assert {:error, :session_limit} = Server.new_session(first, "same-principal")
    assert Server.stats(first).sessions == 1
    assert Server.stats(second).sessions == 1
  end

  test "shared ETS admission enforces the principal limit atomically across servers" do
    {:ok, store} = ETS.start_link([])
    namespace = "atomic-limit"

    opts = [
      session_store: {ETS, store},
      session_namespace: namespace,
      max_sessions_per_principal: 1
    ]

    {:ok, first} = Server.start_link(opts)
    {:ok, second} = Server.start_link(opts)

    tasks =
      Enum.map([first, second], fn server ->
        Task.async(fn -> Server.new_session(server, "same-principal") end)
      end)

    results = Enum.map(tasks, &Task.await/1)
    assert Enum.count(results, &match?({:ok, %Session{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :session_limit})) == 1
    assert {:ok, 1} = ETS.count_active_for_principal(store, namespace, "same-principal")
  end

  test "older custom stores count durable sessions through list_active" do
    {:ok, store} = ETS.start_link([])
    namespace = "legacy-adapter-limit"
    existing = Session.new("same-principal", nil)
    {:ok, record} = Session.to_record(existing)
    :ok = ETS.save(store, {namespace, existing.id}, record)

    {:ok, server} =
      Server.start_link(
        session_store: {LegacySessionStore, store},
        session_namespace: namespace,
        max_sessions_per_principal: 1
      )

    assert {:error, :session_limit} = Server.new_session(server, "same-principal")
    assert {:ok, _session} = Server.new_session(server, "different-principal")
  end

  test "single-definition registry reads preserve normalized definitions" do
    {:ok, registry} = Registry.start_link([])

    assert :ok =
             Registry.register(registry, :tool, "selected", %{
               description: "selected tool",
               input_schema: %{"type" => "object"},
               handler: fn _, _ -> {:ok, "ok"} end
             })

    assert {:ok, %{identity: "selected", description: "selected tool"}} =
             Registry.fetch(registry, :tool, "selected")

    assert :error = Registry.fetch(registry, :tool, "missing")

    assert :ok =
             Registry.register(registry, :tool, "selected-alias", %{
               name: "selected",
               handler: fn _, _ -> {:ok, "alias"} end
             })

    assert Enum.map(Registry.candidates(registry, :tool, "selected"), & &1.identity) == [
             "selected",
             "selected-alias"
           ]
  end

  test "durable principal bindings use deterministic external-term encoding" do
    principal = Map.new(1..40, &{"claim-#{&1}", &1})
    session = Session.new(principal, nil)

    assert {:ok, record} = Session.to_record(session)

    assert record["principal"] ==
             Base.url_encode64(:erlang.term_to_binary(principal, [:deterministic]),
               padding: false
             )
  end
end
