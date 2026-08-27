defmodule AttestoMCP.Server do
  @moduledoc """
  Attesto-native MCP server core.

  The core is transport-neutral. `AttestoMCP.Server.Plug` and
  `AttestoMCP.Server.Stdio` both call `dispatch/4`; handlers run under a
  separately supervised task and receive only an explicit authorization
  context.
  """
  use GenServer

  alias AttestoMCP.Server.{
    Cursor,
    Error,
    JSONRPC,
    Registry,
    RequestState,
    Schema,
    Session,
    Subscriptions,
    Tasks,
    Telemetry
  }

  @modern "2026-07-28"
  @legacy "2025-11-25"
  @legacy_2025_06_18 "2025-06-18"
  @legacy_versions [@legacy, @legacy_2025_06_18]
  @versions [@modern | @legacy_versions]
  @default_stream_queue 128
  @private_option_keys [
    :cursor_secret,
    :request_state_secret,
    :request_state_instance,
    :request_state_store,
    :request_store,
    :request_store_external
  ]
  @max_trace_state_bytes 4096
  @max_output_depth 64
  @max_output_nodes 10_000
  @max_output_bytes 2_000_000
  @max_template_uri_bytes 4_096
  @max_template_value_bytes 2_048
  @max_template_query_pairs 32
  @max_notifications_per_request 128
  @max_rate_buckets 10_000
  @log_levels ["debug", "info", "notice", "warning", "error", "critical", "alert", "emergency"]
  @traceparent_pattern ~r/^00-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})$/
  @primitive_types [:tool, :resource, :template, :prompt, :completion]
  @allowed_startup_option_keys [
    :name,
    :protocol_versions,
    :max_concurrency,
    :per_principal_concurrency,
    :request_timeout,
    :max_request_timeout,
    :client_request_timeout,
    :legacy_initialized_grace_ms,
    :session_idle_timeout,
    :session_absolute_timeout,
    :max_body_bytes,
    :max_message_bytes,
    :max_queue,
    :stream_keepalive_ms,
    :legacy_keepalive_ms,
    :stream_queue_size,
    :subscription_queue_size,
    :subscription_timeout,
    :rate_limits,
    :cursor_secret,
    :cursor_ttl,
    :request_state_secret,
    :request_state_instance,
    :request_state_store,
    :clustered,
    :request_state_ttl,
    :scope_map,
    :initialize_callback,
    :instructions,
    :server_name,
    :server_version,
    :capabilities,
    :modern_tasks,
    :legacy_tasks,
    :page_size,
    :cache_ttl_ms,
    :cache_scope,
    :allow_public_cache
  ]

  defstruct [
    :registry,
    :task_supervisor,
    :tasks,
    :subscriptions,
    :request_store,
    :request_store_external,
    :request_store_monitor,
    :opts,
    :sessions,
    :active,
    :rate_buckets,
    :legacy_streams,
    :client_requests,
    :definitions
  ]

  @type context :: map()

  @typedoc "Options for startup, limits, timeouts, cursor policy, and disabled task flags."
  @type server_opts :: AttestoMCP.Server.API.server_opts()

  @typedoc "Registered primitive definition accepted by the registry."
  @type definition :: map() | keyword()

  @typedoc "A normal, failed, or modern interactive handler return."
  @type handler_return :: {:ok, term()} | {:error, term()} | {:input_required, map()}

  @doc "Starts the supervised protocol core and its registry/subscription children."
  @spec start_link(server_opts()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @doc "Registers a tool and publishes a modern tools-list invalidation."
  @spec register_tool(pid() | atom(), String.t(), definition()) :: :ok | {:error, term()}
  def register_tool(server, name, definition), do: register(server, :tool, name, definition)

  @doc "Registers a static resource and publishes a modern resources-list invalidation."
  @spec register_resource(pid() | atom(), String.t(), definition()) :: :ok | {:error, term()}
  def register_resource(server, uri, definition), do: register(server, :resource, uri, definition)

  @doc "Registers a URI-template resource and publishes a modern resources-list invalidation."
  @spec register_resource_template(pid() | atom(), String.t(), definition()) ::
          :ok | {:error, term()}
  def register_resource_template(server, template, definition),
    do: register(server, :template, template, definition)

  @doc "Registers a prompt and publishes a modern prompts-list invalidation."
  @spec register_prompt(pid() | atom(), String.t(), definition()) :: :ok | {:error, term()}
  def register_prompt(server, name, definition), do: register(server, :prompt, name, definition)

  @doc "Registers a completion handler for an explicit prompt/template reference."
  @spec register_completion(pid() | atom(), String.t(), definition()) :: :ok | {:error, term()}
  def register_completion(server, name, definition),
    do: register(server, :completion, name, definition)

  @doc "Registers one supported primitive type."
  @spec register(pid() | atom(), atom(), String.t(), definition()) :: :ok | {:error, term()}
  def register(server, type, identity, definition) do
    result = Registry.register(GenServer.call(server, :registry), type, identity, definition)

    if result == :ok do
      normalized =
        server
        |> GenServer.call(:registry)
        |> Registry.list(type)
        |> Enum.find(fn item -> item[:identity] == identity end)

      :ok = GenServer.call(server, {:remember_definition, type, identity, normalized || %{}})
      publish_catalog_invalidation(server, type)
    end

    result
  end

  @doc "Returns a deterministic registry snapshot."
  @spec snapshot(pid() | atom()) :: map()
  def snapshot(server), do: Registry.snapshot(GenServer.call(server, :registry))

  @doc "Dispatch one decoded request and return a correlated response/result."
  @spec dispatch(pid() | atom(), map(), context(), keyword()) :: term()
  def dispatch(server, request, context \\ %{}, opts \\ []) do
    runtime = GenServer.call(server, :runtime)
    id = Map.get(request, :id)
    method = Map.get(request, :method, "")
    principal = Map.get(context, :principal) || Map.get(context, "principal")

    if request.kind == :notification and method == "notifications/cancelled" and
         cancellation_notification_allowed?(opts) do
      request_id =
        get_in(request, [:params, "requestId"]) || get_in(request, [:params, "request_id"])

      cancel_request(server, principal, request_id, Keyword.get(opts, :owner))
      cancel_subscription(server, request_id, Keyword.get(opts, :owner))

      :notification
    else
      if request.kind == :notification and method == "notifications/cancelled" do
        # Modern Streamable HTTP uses closure of the response stream as the
        # cancellation signal.  A POST notification must never cancel another
        # request, even when its wire request id happens to match one owned by
        # this transport.  Stdio and the dated legacy HTTP session retain their
        # protocol-defined notification behaviour above.
        :notification
      else
        request_started = System.monotonic_time()
        request_metadata = request_telemetry_metadata(method, id, opts)

        parent = self()
        ref = Keyword.get(opts, :request_ref, make_ref())
        on_event = Keyword.get(opts, :on_event)

        detached_legacy? =
          Keyword.get(opts, :transport) == :http and
            normalize_era(Keyword.get(opts, :version)) == @legacy

        monitor_owner? = not detached_legacy?

        on_event = detached_legacy_delivery(on_event, detached_legacy?)
        raw_version = Keyword.get(opts, :version, detect_era(request, request.params))
        era = request_era(opts, request, request.params)

        context =
          context
          |> Map.put_new(:server_capabilities, capabilities(runtime.opts))
          |> Map.put_new(:protocol_version, raw_version)
          |> enrich_logging_context(runtime, era)

        case Task.Supervisor.start_child(runtime.task_supervisor, fn ->
               Telemetry.execute(
                 [:request, :start],
                 %{system_time: System.system_time()},
                 request_metadata
               )

               case GenServer.call(
                      server,
                      {:acquire_request, principal, id, parent, ref, self(),
                       Keyword.get(opts, :owner), monitor_owner?, request_started,
                       request_metadata}
                    ) do
                 :ok ->
                   progress_token = get_in(request, [:params, "_meta", "progressToken"])
                   progress = progress_callback(parent, ref, progress_token, on_event)

                   notify =
                     notification_callback(
                       parent,
                       ref,
                       on_event,
                       era,
                       request,
                       context,
                       runtime.opts[:max_queue] || @max_notifications_per_request
                     )

                   task_context =
                     context
                     |> Map.put(:progress, progress)
                     |> Map.put(:notify, notify)
                     |> Map.put(:trace_context, trace_context(request.params))
                     |> Map.put(:method, method)
                     |> Map.put(:transport, Keyword.get(opts, :transport, :core))
                     |> Map.put(
                       :client_request,
                       client_request_callback(
                         runtime.server,
                         context,
                         runtime.opts[:client_request_timeout] || 30_000
                       )
                     )
                     |> Map.put(:subscription_sink, parent)
                     |> Map.put(:subscription_ref, ref)
                     |> Map.put(:owner, parent)
                     |> Map.put(:request_id, id)
                     |> Map.put(:request_extensions, Map.get(request, :extensions, %{}))
                     |> Map.put_new(:protocol_version, raw_version)
                     |> Map.put(:logging_level, request_logging_level(request, context, era))

                   result =
                     try do
                       handle_request(request, task_context, runtime, opts)
                     rescue
                       _error ->
                         {:error,
                          Error.internal(%{
                            "reason" => "handler_failure",
                            "type" => "handler_failure"
                          })}
                     catch
                       :exit, _ -> {:error, Error.internal(%{"reason" => "handler_exit"})}
                       _, _ -> {:error, Error.internal(%{"reason" => "handler_failure"})}
                     end

                   send(parent, {ref, :result, result})

                 {:error, :duplicate_request} ->
                   emit_terminal(
                     :stop,
                     :duplicate_request,
                     request_started,
                     request_metadata
                   )

                   send(
                     parent,
                     {ref, :result,
                      {:error, Error.invalid_request(%{"reason" => "duplicate_id"})}}
                   )

                 {:error, :busy} ->
                   emit_terminal(
                     :stop,
                     :concurrency_limit,
                     request_started,
                     request_metadata
                   )

                   send(
                     parent,
                     {ref, :result,
                      {:error, Error.invalid_params(%{"reason" => "concurrency_limit"})}}
                   )
               end
             end) do
          {:ok, task} ->
            task_monitor = Process.monitor(task)

            requested_timeout =
              Keyword.get(opts, :timeout) || runtime.opts[:request_timeout] || 30_000

            timeout =
              min(requested_timeout, runtime.opts[:max_request_timeout] || 120_000)

            outcome =
              try do
                keepalive_ms = Keyword.get(opts, :keepalive_ms)

                keepalive_timer =
                  if is_integer(keepalive_ms) and keepalive_ms > 0,
                    do: Process.send_after(self(), {ref, :keepalive}, keepalive_ms)

                await_task(
                  ref,
                  task,
                  task_monitor,
                  timeout,
                  on_event,
                  runtime.subscriptions,
                  System.monotonic_time(:millisecond),
                  keepalive_ms,
                  keepalive_timer
                )
              rescue
                _ ->
                  kill_task(task, task_monitor)
                  {:error, Error.internal(%{"reason" => "event_delivery_failure"})}
              catch
                _, _ ->
                  kill_task(task, task_monitor)
                  {:error, Error.internal(%{"reason" => "event_delivery_failure"})}
              end

            if GenServer.call(server, {:unregister_request, principal, id, ref}) == :removed do
              emit_request_terminal(outcome, request_started, request_metadata)
            end

            if request.kind == :notification,
              do: :notification,
              else:
                {id,
                 encode_outcome(
                   id,
                   outcome,
                   Keyword.get(opts, :version, detect_era(request, request.params)),
                   runtime.opts
                 )}

          {:error, _reason} ->
            Telemetry.execute(
              [:request, :start],
              %{system_time: System.system_time()},
              request_metadata
            )

            emit_terminal(:stop, :worker_unavailable, request_started, request_metadata)

            if request.kind == :notification,
              do: :notification,
              else:
                {id,
                 JSONRPC.error_response(
                   id,
                   Error.internal(%{"reason" => "worker_unavailable"})
                 )}
        end
      end
    end
  end

  defp cancellation_notification_allowed?(opts) do
    transport = Keyword.get(opts, :transport, :core)
    version = normalize_era(Keyword.get(opts, :version))
    not (transport == :http and version == @modern)
  end

  def new_session(server, principal, tenant \\ nil, opts \\ []),
    do: GenServer.call(server, {:new_session, principal, tenant, opts})

  def get_session(server, id, principal, tenant \\ nil),
    do: GenServer.call(server, {:get_session, id, principal, tenant})

  def touch_session(server, id), do: GenServer.call(server, {:touch_session, id})
  def delete_session(server, id), do: GenServer.call(server, {:delete_session, id})
  def mark_initialized(server, id), do: GenServer.call(server, {:mark_initialized, id})

  def await_initialized(server, id, principal, tenant, timeout \\ 50),
    do:
      await_initialized_until(
        server,
        id,
        principal,
        tenant,
        System.monotonic_time(:millisecond) + timeout
      )

  @doc "Binds an unnegotiated session to one enabled legacy protocol revision."
  @spec set_session_version(pid() | atom(), binary(), String.t()) ::
          :ok | {:error, :invalid_version}
  def set_session_version(server, id, version),
    do: GenServer.call(server, {:set_session_version, id, version})

  @doc "Returns bounded public counters for sessions, streams, subscriptions, and requests."
  @spec stats(pid() | atom()) :: map()
  def stats(server), do: GenServer.call(server, :stats)

  @doc "Returns normalized options used by the protocol adapters."
  @spec options(pid() | atom()) :: keyword()
  def options(server), do: GenServer.call(server, :options)

  @doc "Consumes one bounded rate-limit token for a principal/category key."
  @spec allow_rate(pid() | atom(), term(), atom()) :: :ok | {:error, :rate_limited}
  def allow_rate(server, key, category), do: GenServer.call(server, {:allow_rate, key, category})

  def cancel_request(server, principal, request_id, owner \\ nil) do
    Telemetry.execute([:cancellation, :request], %{count: 1}, %{
      outcome: :requested,
      correlation_id: telemetry_correlation(request_id)
    })

    GenServer.call(server, {:cancel_request, principal, request_id, owner})
  end

  def publish(server, notification, opts \\ []) do
    case normalize_public_notification(notification) do
      {:ok, notification} ->
        required_scopes = GenServer.call(server, {:notification_scopes, notification})

        result =
          Subscriptions.publish_sync(
            GenServer.call(server, :subscriptions),
            notification,
            Keyword.put(opts, :required_scopes, required_scopes)
          )

        GenServer.cast(server, {:publish_legacy, notification})
        result

      {:error, reason} = error ->
        Telemetry.execute([:notification, :reject], %{count: 1}, %{reason: reason})
        error
    end
  end

  defp normalize_public_notification(%{"type" => type} = notification)
       when type in [
              "toolsListChanged",
              "promptsListChanged",
              "resourcesListChanged",
              "resource",
              "resourceUpdated",
              "resourceSubscriptions"
            ] do
    valid_resource? =
      type not in ["resource", "resourceUpdated", "resourceSubscriptions"] or
        is_binary(notification["uri"] || notification[:uri])

    if valid_resource? and Schema.json_value(notification) == :ok,
      do: {:ok, notification},
      else: {:error, :invalid_notification}
  end

  defp normalize_public_notification(_), do: {:error, :invalid_notification}

  defp publish_catalog_invalidation(server, type) do
    notification =
      case type do
        :tool -> %{"type" => "toolsListChanged"}
        :prompt -> %{"type" => "promptsListChanged"}
        type when type in [:resource, :template] -> %{"type" => "resourcesListChanged"}
        _ -> nil
      end

    if notification do
      Subscriptions.publish_sync(GenServer.call(server, :subscriptions), notification)
      GenServer.cast(server, {:publish_legacy, notification})

      Telemetry.execute([:cache, :invalidation], %{count: 1}, %{
        method: "catalog",
        outcome: to_string(type)
      })
    end

    :ok
  end

  def open_legacy_stream(server, session_id, principal, tenant, sink, authorize \\ nil),
    do:
      GenServer.call(
        server,
        {:open_legacy_stream, session_id, principal, tenant, sink, authorize}
      )

  def close_legacy_stream(server, stream_ref),
    do: GenServer.call(server, {:close_legacy_stream, stream_ref})

  def ack_legacy_stream(server, stream_ref),
    do: GenServer.cast(server, {:ack_legacy_stream, stream_ref})

  @doc "Negotiates one enabled legacy revision and capability map exactly once."
  @spec negotiate_session(pid() | atom(), binary(), term(), term(), String.t(), map()) ::
          :ok | {:error, :invalid_negotiation | :already_negotiated | :not_found}
  def negotiate_session(server, session_id, principal, tenant, version, capabilities),
    do:
      GenServer.call(
        server,
        {:negotiate_session, session_id, principal, tenant, version, capabilities}
      )

  def session_capabilities(server, session_id, principal, tenant),
    do: GenServer.call(server, {:session_capabilities, session_id, principal, tenant})

  @doc "Returns the negotiated minimum legacy log level for an owned session."
  @spec session_logging_level(pid() | atom(), binary(), term(), term()) :: String.t() | nil
  def session_logging_level(server, session_id, principal, tenant),
    do: GenServer.call(server, {:session_logging_level, session_id, principal, tenant})

  @doc "Sets the negotiated minimum legacy log level for an owned session."
  @spec set_session_logging_level(pid() | atom(), binary(), term(), term(), String.t()) ::
          :ok | {:error, :not_found}
  def set_session_logging_level(server, session_id, principal, tenant, level),
    do: GenServer.call(server, {:set_session_logging_level, session_id, principal, tenant, level})

  def deliver_client_response(server, session_id, principal, tenant, response),
    do: GenServer.call(server, {:client_response, session_id, principal, tenant, response})

  def request_client(server, session_id, principal, tenant, method, params, timeout \\ 30_000),
    do: client_request(server, session_id, principal, tenant, method, params, timeout)

  def subscribe_resource(server, session_id, principal, tenant, uri),
    do:
      GenServer.call(
        server,
        {:resource_subscription, :subscribe, session_id, principal, tenant, uri}
      )

  def unsubscribe_resource(server, session_id, principal, tenant, uri),
    do:
      GenServer.call(
        server,
        {:resource_subscription, :unsubscribe, session_id, principal, tenant, uri}
      )

  def close_subscription(server, id, owner \\ nil) do
    try do
      Subscriptions.close(GenServer.call(server, :subscriptions), id, owner)
    catch
      :exit, _ -> :ok
    end
  end

  def cancel_subscription(server, id, owner \\ nil) do
    try do
      Subscriptions.cancel(GenServer.call(server, :subscriptions), id, owner)
    catch
      :exit, _ -> :ok
    end
  end

  def ack_subscription(server, id, owner \\ nil) do
    try do
      Subscriptions.ack(GenServer.call(server, :subscriptions), id, owner)
    catch
      :exit, _ -> :ok
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    normalized_opts = default_opts(opts)
    {:ok, registry} = Registry.start_link([])

    {:ok, task_supervisor} =
      Task.Supervisor.start_link(max_children: normalized_opts[:max_concurrency])

    {:ok, tasks} = Tasks.start_link([])

    {:ok, subscriptions} =
      Subscriptions.start_link(
        max_queue:
          normalized_opts[:subscription_queue_size] || normalized_opts[:max_queue] ||
            @default_stream_queue
      )

    {request_store, request_store_external, request_store_monitor} =
      case normalized_opts[:request_state_store] do
        store when is_pid(store) ->
          {store, true, Process.monitor(store)}

        _ ->
          {:ok, store} =
            RequestState.Store.start_link(
              max_age_ms: normalized_opts[:request_state_ttl] || 120_000
            )

          {store, false, nil}
      end

    sessions = :ets.new(:attesto_mcp_server_sessions, [:set, :private])
    Process.send_after(self(), :cleanup_sessions, 60_000)

    {:ok,
     %__MODULE__{
       registry: registry,
       task_supervisor: task_supervisor,
       tasks: tasks,
       subscriptions: subscriptions,
       opts:
         normalized_opts
         |> put_default_if_nil(:cursor_secret, :crypto.strong_rand_bytes(32))
         |> put_default_if_nil(:request_state_instance, :crypto.strong_rand_bytes(16))
         |> Keyword.put(:request_state_store, request_store),
       request_store: request_store,
       request_store_external: request_store_external,
       request_store_monitor: request_store_monitor,
       sessions: sessions,
       active: %{global: 0, principals: %{}, requests: %{}},
       rate_buckets: %{},
       legacy_streams: %{},
       client_requests: %{},
       definitions: Map.new(@primitive_types, &{&1, %{}})
     }}
  end

  @impl true
  def handle_call(:registry, _from, state), do: {:reply, state.registry, state}
  def handle_call(:subscriptions, _from, state), do: {:reply, state.subscriptions, state}

  def handle_call(:options, _from, state),
    do: {:reply, Keyword.drop(state.opts, @private_option_keys), state}

  def handle_call({:allow_rate, key, category}, _from, state) do
    now = System.monotonic_time(:millisecond)

    case rate_decision(state.opts[:rate_limits], category, key, state.rate_buckets, now) do
      {:ok, buckets} ->
        {:reply, :ok, %{state | rate_buckets: buckets}}

      {:error, buckets} ->
        Telemetry.execute([:rate_limit, :reject], %{count: 1}, %{category: category})
        {:reply, {:error, :rate_limited}, %{state | rate_buckets: buckets}}
    end
  end

  def handle_call({:remember_definition, type, identity, definition}, _from, state)
      when type in @primitive_types do
    definitions = Map.update!(state.definitions, type, &Map.put(&1, identity, definition))
    {:reply, :ok, %{state | definitions: definitions}}
  end

  def handle_call(:stats, _from, state) do
    subscription_stats =
      try do
        Subscriptions.stats(state.subscriptions)
      catch
        _, _ -> %{count: 0, queued: 0}
      end

    {:reply,
     %{
       sessions: :ets.info(state.sessions, :size),
       legacy_streams: map_size(state.legacy_streams),
       client_requests: map_size(state.client_requests),
       active_requests: map_size(state.active.requests),
       active: state.active.global,
       rate_buckets: map_size(state.rate_buckets),
       subscriptions: subscription_stats.count,
       subscription_queue: subscription_stats.queued
     }, state}
  end

  def handle_call({:notification_scopes, notification}, _from, state) do
    {:reply, notification_scopes(state, notification), state}
  end

  def handle_call({:open_legacy_stream, session_id, principal, tenant, sink}, from, state),
    do: handle_call({:open_legacy_stream, session_id, principal, tenant, sink, nil}, from, state)

  def handle_call(
        {:open_legacy_stream, session_id, principal, tenant, sink, authorize},
        _from,
        state
      ) do
    case session_for(state, session_id, principal, tenant, require_initialized: true) do
      {:ok, session} when is_pid(sink) ->
        stream_ref = make_ref()
        monitor = Process.monitor(sink)

        stream = %{
          ref: stream_ref,
          session_id: session_id,
          principal: principal,
          tenant: tenant,
          sink: sink,
          authorize: authorize,
          monitor: monitor,
          opened_sequence: System.unique_integer([:monotonic, :positive]),
          event_id: 0,
          queue_size: 0
        }

        session = %{Session.touch(session) | streams: Map.put(session.streams, stream_ref, true)}
        :ets.insert(state.sessions, {session_id, session})

        {:reply, {:ok, stream_ref}, put_in(state.legacy_streams[stream_ref], stream)}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:close_legacy_stream, stream_ref}, _from, state) do
    {:reply, :ok, remove_legacy_stream(state, stream_ref)}
  end

  def handle_call(
        {:negotiate_session, session_id, principal, tenant, version, capabilities},
        _from,
        state
      ) do
    case session_for(state, session_id, principal, tenant) do
      {:ok, session} ->
        cond do
          version not in @legacy_versions or version not in state.opts[:protocol_versions] or
              not is_map(capabilities) ->
            {:reply, {:error, :invalid_negotiation}, state}

          not is_nil(session.version) or session.initialized ->
            {:reply, {:error, :already_negotiated}, state}

          true ->
            session = %{
              Session.touch(session)
              | version: version,
                client_capabilities: capabilities
            }

            :ets.insert(state.sessions, {session_id, session})
            {:reply, :ok, state}
        end

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:session_capabilities, session_id, principal, tenant}, _from, state) do
    case session_for(state, session_id, principal, tenant) do
      {:ok, session} -> {:reply, session.client_capabilities, state}
      _ -> {:reply, %{}, state}
    end
  end

  def handle_call({:session_logging_level, session_id, principal, tenant}, _from, state) do
    case session_for(state, session_id, principal, tenant) do
      {:ok, session} -> {:reply, session.logging_level, state}
      _ -> {:reply, nil, state}
    end
  end

  def handle_call(
        {:set_session_logging_level, session_id, principal, tenant, level},
        _from,
        state
      )
      when is_binary(level) do
    case session_for(state, session_id, principal, tenant) do
      {:ok, session} ->
        :ets.insert(
          state.sessions,
          {session_id, %{Session.touch(session) | logging_level: level}}
        )

        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:client_response, session_id, principal, tenant, response}, _from, state) do
    id = response_id(response)

    case Enum.find(state.client_requests, fn {_ref, request} ->
           request.id == id and request.session_id == session_id
         end) do
      {request_ref, request} ->
        if session_owned?(state, session_id, principal, tenant) and
             request.principal == principal and request.tenant == tenant do
          case validate_client_response(request.method, response, request.params) do
            {:ok, result} ->
              send(request.waiter, {request_ref, {:response, {:ok, result}}})

              {:reply, :ok, remove_client_request(state, request_ref, request)}

            {:error, {:client_error, _error} = client_error} ->
              send(request.waiter, {request_ref, {:response, {:error, client_error}}})

              {:reply, {:error, client_error}, remove_client_request(state, request_ref, request)}

            {:error, :invalid_response} ->
              send(request.waiter, {request_ref, {:response, {:error, :invalid_response}}})

              {:reply, {:error, :invalid_response},
               remove_client_request(state, request_ref, request)}
          end
        else
          {:reply, {:error, :not_found}, state}
        end

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(
        {:open_client_request, session_id, principal, tenant, method, params, waiter},
        _from,
        state
      ) do
    with {:ok, session} <-
           session_for(state, session_id, principal, tenant, require_initialized: true),
         capability when is_binary(capability) <- client_capability(method),
         true <- Map.has_key?(session.client_capabilities, capability),
         :ok <- validate_client_request_revision(session.version, method, params),
         {:ok, _stream_ref, stream} <-
           newest_live_legacy_stream(state.legacy_streams, session_id) do
      request_ref = make_ref()
      id = "server_" <> Integer.to_string(System.unique_integer([:positive]))
      waiter_monitor = Process.monitor(waiter)

      request = %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => method,
        "params" => params
      }

      next_state = send_legacy_stream(state, stream.ref, request)

      client_request = %{
        id: id,
        session_id: session_id,
        principal: principal,
        tenant: tenant,
        method: method,
        params: params,
        stream_ref: stream.ref,
        waiter: waiter,
        waiter_monitor: waiter_monitor
      }

      {:reply, {:ok, request_ref},
       put_in(next_state.client_requests[request_ref], client_request)}
    else
      false -> {:reply, {:error, :missing_capability}, state}
      nil -> {:reply, {:error, :unsupported}, state}
      {:error, :unsupported} -> {:reply, {:error, :unsupported}, state}
      :stream_not_ready -> {:reply, {:error, :not_ready}, state}
      _ -> {:reply, {:error, :not_ready}, state}
    end
  end

  def handle_call({:expire_client_request, request_ref}, _from, state) do
    case Map.pop(state.client_requests, request_ref) do
      {nil, _requests} ->
        {:reply, :ok, state}

      {request, requests} ->
        send(request.waiter, {request_ref, {:error, :timeout}})
        Process.demonitor(request.waiter_monitor, [:flush])
        {:reply, :ok, %{state | client_requests: requests}}
    end
  end

  def handle_call(
        {:resource_subscription, operation, session_id, principal, tenant, uri},
        _from,
        state
      )
      when operation in [:subscribe, :unsubscribe] and is_binary(uri) do
    case session_for(state, session_id, principal, tenant, require_initialized: true) do
      {:ok, session} ->
        subscriptions =
          case operation do
            :subscribe -> Map.put(session.resource_subscriptions, uri, true)
            :unsubscribe -> Map.delete(session.resource_subscriptions, uri)
          end

        :ets.insert(
          state.sessions,
          {session_id, %{Session.touch(session) | resource_subscriptions: subscriptions}}
        )

        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:runtime, _from, state),
    do:
      {:reply,
       %{
         registry: state.registry,
         task_supervisor: state.task_supervisor,
         tasks: state.tasks,
         subscriptions: state.subscriptions,
         request_store: state.request_store,
         opts: state.opts,
         server: self()
       }, state}

  def handle_call(
        {:acquire_request, principal, id, parent, ref, task, owner, monitor_owner?, started,
         telemetry_metadata},
        _from,
        state
      ) do
    key = {principal, owner || :core, id || {:ref, ref}}
    global_max = state.opts[:max_concurrency]
    per_max = state.opts[:per_principal_concurrency]
    count = Map.get(state.active.principals, principal, 0)

    cond do
      not is_nil(id) and Map.has_key?(state.active.requests, key) ->
        {:reply, {:error, :duplicate_request}, state}

      state.active.global >= global_max or count >= per_max ->
        {:reply, {:error, :busy}, state}

      true ->
        owner_monitor = if monitor_owner?, do: Process.monitor(parent), else: nil
        task_monitor = if monitor_owner?, do: nil, else: Process.monitor(task)

        requests =
          Map.put(state.active.requests, key, %{
            principal: principal,
            id: id,
            parent: parent,
            owner: owner || :core,
            owner_monitor: owner_monitor,
            monitor_owner?: monitor_owner?,
            task_monitor: task_monitor,
            started: started,
            telemetry_metadata: telemetry_metadata,
            ref: ref,
            task: task
          })

        active = %{
          global: state.active.global + 1,
          principals: Map.put(state.active.principals, principal, count + 1),
          requests: requests
        }

        {:reply, :ok, %{state | active: active}}
    end
  end

  def handle_call({:unregister_request, principal, id, ref}, _from, state) do
    key =
      Enum.find_value(state.active.requests, fn {key, request} ->
        if request.principal == principal and request.ref == ref and
             (is_nil(id) or request.id == id),
           do: key
      end)

    case key && state.active.requests[key] do
      %{owner_monitor: owner_monitor, task_monitor: task_monitor} ->
        demonitor_if_present(owner_monitor)
        demonitor_if_present(task_monitor)

        active =
          state.active
          |> Map.put(:requests, Map.delete(state.active.requests, key))
          |> release_active(principal)

        {:reply, :removed, %{state | active: active}}

      _ ->
        {:reply, :missing, state}
    end
  end

  def handle_call({:cancel_request, principal, id}, from, state),
    do: handle_call({:cancel_request, principal, id, nil}, from, state)

  def handle_call({:cancel_request, principal, id, owner}, _from, state) do
    requests =
      Enum.reduce(state.active.requests, state.active.requests, fn
        {{request_principal, request_owner, request_id} = key, request}, acc
        when request_principal == principal and request_id == id ->
          if is_nil(owner) or request_owner == owner do
            if request.monitor_owner? or Process.alive?(request.parent) do
              send(request.parent, {request.ref, :cancelled})
            else
              # A detached legacy HTTP task remains owned by its authenticated
              # session after the response process exits. Mark cancellation
              # before terminating it so the task monitor owns one balanced
              # terminal event and accounting transition.
              Process.exit(request.task, :kill)
            end

            Map.put(acc, key, Map.put(request, :cancel_requested?, true))
          else
            acc
          end

        _entry, acc ->
          acc
      end)

    {:reply, :ok, %{state | active: Map.put(state.active, :requests, requests)}}
  end

  def handle_call({:new_session, principal, tenant}, from, state) do
    handle_call({:new_session, principal, tenant, []}, from, state)
  end

  def handle_call({:new_session, principal, tenant, session_opts}, _from, state) do
    session =
      Session.new(principal, tenant,
        absolute_timeout:
          Keyword.get(session_opts, :absolute_timeout, state.opts[:session_absolute_timeout]),
        idle_timeout: Keyword.get(session_opts, :idle_timeout, state.opts[:session_idle_timeout])
      )

    true = :ets.insert(state.sessions, {session.id, session})
    Telemetry.execute([:session, :open], %{count: 1}, %{transport: :core, outcome: :ok})
    {:reply, {:ok, session}, state}
  end

  def handle_call({:get_session, id, principal, tenant}, _from, state) do
    {result, state} =
      case :ets.lookup(state.sessions, id) do
        [{^id, session}] ->
          cond do
            not Session.valid?(session) ->
              :ets.delete(state.sessions, id)
              Telemetry.execute([:session, :close], %{count: 1}, %{outcome: :expired})

              {{:error, :not_found},
               close_legacy_streams_for_session(state, id, :session_expired)}

            not Session.same_principal?(session, principal) or
                not Session.same_tenant?(session, tenant) ->
              {{:error, :not_found}, state}

            true ->
              {{:ok, Session.touch(session)}, state}
          end

        _ ->
          {{:error, :not_found}, state}
      end

    case result do
      {:ok, session} ->
        :ets.insert(state.sessions, {id, session})

      _ ->
        :ok
    end

    {:reply, result, state}
  end

  def handle_call({:touch_session, id}, _from, state) do
    case :ets.lookup(state.sessions, id) do
      [{^id, session}] -> :ets.insert(state.sessions, {id, Session.touch(session)})
      _ -> :ok
    end

    {:reply, :ok, state}
  end

  def handle_call({:mark_initialized, id}, _from, state) do
    case :ets.lookup(state.sessions, id) do
      [{^id, session}] ->
        :ets.insert(state.sessions, {id, %{Session.touch(session) | initialized: true}})

      _ ->
        :ok
    end

    {:reply, :ok, state}
  end

  def handle_call({:set_session_version, id, version}, _from, state) do
    case :ets.lookup(state.sessions, id) do
      [{^id, session}] ->
        if version in @legacy_versions and version in state.opts[:protocol_versions] and
             (is_nil(session.version) or session.version == version) do
          :ets.insert(state.sessions, {id, %{Session.touch(session) | version: version}})
          {:reply, :ok, state}
        else
          {:reply, {:error, :invalid_version}, state}
        end

      _ ->
        {:reply, {:error, :invalid_version}, state}
    end
  end

  def handle_call({:delete_session, id}, _from, state) do
    existed = :ets.member(state.sessions, id)
    :ets.delete(state.sessions, id)

    if existed, do: Telemetry.execute([:session, :close], %{count: 1}, %{outcome: :deleted})

    {:reply, :ok, close_legacy_streams_for_session(state, id, :session_deleted)}
  end

  @impl true
  def handle_cast({:publish_legacy, notification}, state) do
    {:noreply, publish_legacy(state, notification)}
  end

  def handle_cast({:ack_legacy_stream, stream_ref}, state) do
    state =
      update_in(state.legacy_streams[stream_ref], fn
        nil -> nil
        %{queue_size: queue_size} = stream -> %{stream | queue_size: max(queue_size - 1, 0)}
      end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, pid, reason}, state) do
    if monitor == state.request_store_monitor and pid == state.request_store do
      {:stop, :request_state_store_unavailable, state}
    else
      handle_process_down(monitor, pid, reason, state)
    end
  end

  @impl true
  def handle_info(:cleanup_sessions, state) do
    now = System.system_time(:millisecond)

    expired =
      :ets.foldl(
        fn {id, session}, acc ->
          if Session.valid?(session, now), do: acc, else: [id | acc]
        end,
        [],
        state.sessions
      )

    Enum.each(expired, &:ets.delete(state.sessions, &1))

    if expired != [] do
      Telemetry.execute([:session, :close], %{count: length(expired)}, %{outcome: :expired})
    end

    state =
      Enum.reduce(expired, state, &close_legacy_streams_for_session(&2, &1, :session_expired))

    Process.send_after(self(), :cleanup_sessions, 60_000)
    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, pid, _reason}, state) do
    cond do
      pid == state.registry ->
        case Registry.start_link([]) do
          {:ok, registry} ->
            case restore_registry(registry, state.definitions) do
              :ok ->
                Telemetry.execute([:supervision, :restart], %{count: 1}, %{
                  method: "registry",
                  outcome: :recovered
                })

                {:noreply, %{state | registry: registry}}

              {:error, _reason} ->
                Telemetry.execute([:supervision, :restart], %{count: 1}, %{
                  method: "registry",
                  outcome: :failed
                })

                {:stop, :registry_restore_failed, state}
            end

          {:error, _reason} ->
            {:stop, :registry_restart_failed, state}
        end

      pid == state.task_supervisor ->
        {:ok, task_supervisor} =
          Task.Supervisor.start_link(max_children: state.opts[:max_concurrency])

        Telemetry.execute([:supervision, :restart], %{count: 1}, %{
          method: "task_supervisor",
          outcome: :recovered
        })

        {:noreply, %{state | task_supervisor: task_supervisor}}

      pid == state.tasks ->
        {:ok, tasks} = Tasks.start_link([])

        Telemetry.execute([:supervision, :restart], %{count: 1}, %{
          method: "tasks",
          outcome: :recovered
        })

        {:noreply, %{state | tasks: tasks}}

      pid == state.subscriptions ->
        {:ok, subscriptions} =
          Subscriptions.start_link(
            max_queue:
              state.opts[:subscription_queue_size] || state.opts[:max_queue] ||
                @default_stream_queue
          )

        Telemetry.execute([:supervision, :restart], %{count: 1}, %{
          method: "subscriptions",
          outcome: :recovered
        })

        {:noreply, %{state | subscriptions: subscriptions}}

      pid == state.request_store ->
        if state.request_store_external do
          {:stop, :request_state_store_unavailable, state}
        else
          {:ok, request_store} =
            RequestState.Store.start_link(max_age_ms: state.opts[:request_state_ttl] || 120_000)

          Telemetry.execute([:supervision, :restart], %{count: 1}, %{
            method: "request_state_store",
            outcome: :recovered
          })

          opts =
            state.opts
            |> Keyword.put(:request_state_instance, :crypto.strong_rand_bytes(16))
            |> Keyword.put(:request_state_store, request_store)

          {:noreply, %{state | request_store: request_store, opts: opts}}
        end

      true ->
        {:noreply, state}
    end
  end

  defp handle_process_down(monitor, pid, reason, state) do
    case Enum.find(state.legacy_streams, fn {_ref, stream} -> stream.monitor == monitor end) do
      {stream_ref, _stream} ->
        {:noreply, remove_legacy_stream(state, stream_ref)}

      nil ->
        state =
          Enum.reduce(state.client_requests, state, fn {request_ref, request}, acc ->
            if request.waiter_monitor == monitor or request.waiter == pid do
              %{acc | client_requests: Map.delete(acc.client_requests, request_ref)}
            else
              acc
            end
          end)

        owner_owned =
          Enum.filter(state.active.requests, fn {_key, request} ->
            request.owner_monitor == monitor or
              (request.monitor_owner? and request.parent == pid)
          end)

        task_owned =
          Enum.filter(state.active.requests, fn {_key, request} ->
            request.task_monitor == monitor
          end)

        {state, task_owned} = defer_live_detached_completion(state, task_owned, reason)

        owned = Enum.uniq_by(owner_owned ++ task_owned, &elem(&1, 0))

        if owned == [] do
          {:noreply, state}
        else
          Enum.each(owned, fn {_key, request} ->
            demonitor_if_present(request.owner_monitor)

            if request.task_monitor != monitor do
              demonitor_if_present(request.task_monitor)
            end

            if request in Enum.map(owner_owned, &elem(&1, 1)) and Process.alive?(request.task),
              do: Process.exit(request.task, :kill)
          end)

          principals = Enum.frequencies_by(owned, fn {_key, request} -> request.principal end)

          active =
            Enum.reduce(principals, state.active, fn {principal, count}, active ->
              current = Map.get(active.principals, principal, 0)
              next = max(current - count, 0)

              principals =
                if next == 0,
                  do: Map.delete(active.principals, principal),
                  else: Map.put(active.principals, principal, next)

              %{
                active
                | global: max(active.global - count, 0),
                  principals: principals,
                  requests: Map.drop(active.requests, Enum.map(owned, &elem(&1, 0)))
              }
            end)

          owner_keys = MapSet.new(owner_owned, &elem(&1, 0))

          Enum.each(owned, fn {key, request} ->
            cond do
              MapSet.member?(owner_keys, key) ->
                emit_registered_terminal(request, :exception, :owner_down)

              request[:cancel_requested?] == true ->
                emit_cancellation_stop(request.telemetry_metadata)
                emit_registered_terminal(request, :stop, :cancelled)

              reason == :normal ->
                emit_registered_terminal(request, :stop, :completed)

              true ->
                emit_registered_terminal(request, :exception, :handler_exit)
            end
          end)

          {:noreply, %{state | active: active}}
        end
    end
  end

  defp demonitor_if_present(monitor) when is_reference(monitor),
    do: Process.demonitor(monitor, [:flush])

  defp demonitor_if_present(_monitor), do: :ok

  defp release_active(active, principal) do
    count = max(Map.get(active.principals, principal, 1) - 1, 0)

    principals =
      if count == 0,
        do: Map.delete(active.principals, principal),
        else: Map.put(active.principals, principal, count)

    %{active | global: max(active.global - 1, 0), principals: principals}
  end

  defp defer_live_detached_completion(state, task_owned, :normal) do
    {deferred, ready} =
      Enum.split_with(task_owned, fn {_key, request} ->
        not request.monitor_owner? and Process.alive?(request.parent)
      end)

    requests =
      Enum.reduce(deferred, state.active.requests, fn {key, request}, requests ->
        owner_monitor = Process.monitor(request.parent)

        Map.put(requests, key, %{
          request
          | owner_monitor: owner_monitor,
            task_monitor: nil
        })
      end)

    {%{state | active: Map.put(state.active, :requests, requests)}, ready}
  end

  defp defer_live_detached_completion(state, task_owned, _reason), do: {state, task_owned}

  defp restore_registry(registry, definitions) do
    Enum.reduce_while(@primitive_types, :ok, fn type, :ok ->
      case Enum.reduce_while(definitions[type], :ok, fn {identity, definition}, :ok ->
             case Registry.register(registry, type, identity, definition) do
               :ok -> {:cont, :ok}
               {:error, reason} -> {:halt, {:error, reason}}
             end
           end) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp default_opts(opts) do
    app = Application.get_all_env(:attesto_mcp_server)

    normalized =
      Keyword.merge(app, opts)
      |> merge_rate_limit_defaults()
      |> Keyword.put_new(:protocol_versions, @versions)
      |> Keyword.put_new(:max_concurrency, 64)
      |> Keyword.put_new(:per_principal_concurrency, 16)
      |> Keyword.put_new(:request_timeout, 30_000)
      |> Keyword.put_new(:client_request_timeout, 30_000)
      |> Keyword.put_new(:legacy_initialized_grace_ms, 50)
      |> Keyword.put_new(:max_request_timeout, 120_000)
      |> Keyword.put_new(:request_state_ttl, 120_000)
      |> Keyword.put_new(:stream_keepalive_ms, 15_000)
      |> Keyword.put_new(:max_queue, 128)
      |> Keyword.put_new(:rate_limits, %{
        calls: %{burst: 600, window_ms: 60_000},
        completion: %{burst: 300, window_ms: 60_000},
        subscriptions: %{burst: 100, window_ms: 60_000},
        auth_failures: %{burst: 120, window_ms: 60_000}
      })
      |> Keyword.put(:modern_tasks, false)
      |> Keyword.put(:legacy_tasks, false)

    normalized =
      normalized
      |> put_default_if_nil(:stream_queue_size, normalized[:max_queue])
      |> put_default_if_nil(:subscription_queue_size, normalized[:max_queue])
      |> put_default_if_nil(:legacy_keepalive_ms, normalized[:stream_keepalive_ms])

    validate_startup_options!(normalized)
    validate_rate_limits!(normalized[:rate_limits])
    validate_replica_options!(normalized)

    if not (is_integer(normalized[:request_state_ttl]) and normalized[:request_state_ttl] > 0 and
              normalized[:request_state_ttl] <= 120_000),
       do: raise(ArgumentError, ":request_state_ttl must be between 1 and 120000 milliseconds")

    normalized
  end

  defp put_default_if_nil(opts, key, default) do
    if is_nil(Keyword.get(opts, key)), do: Keyword.put(opts, key, default), else: opts
  end

  defp merge_rate_limit_defaults(opts) do
    defaults = %{
      calls: %{burst: 600, window_ms: 60_000},
      completion: %{burst: 300, window_ms: 60_000},
      subscriptions: %{burst: 100, window_ms: 60_000},
      auth_failures: %{burst: 120, window_ms: 60_000}
    }

    cond do
      not Keyword.has_key?(opts, :rate_limits) ->
        Keyword.put(opts, :rate_limits, defaults)

      opts[:rate_limits] == false ->
        opts

      is_map(opts[:rate_limits]) ->
        Keyword.put(opts, :rate_limits, Map.merge(defaults, opts[:rate_limits]))

      true ->
        opts
    end
  end

  defp validate_startup_options!(opts) do
    unknown = Keyword.keys(opts) -- @allowed_startup_option_keys

    if unknown != [] do
      raise ArgumentError, "unknown server option(s): #{inspect(Enum.uniq(unknown))}"
    end

    positive = [
      :max_concurrency,
      :per_principal_concurrency,
      :max_request_timeout,
      :client_request_timeout,
      :max_queue,
      :stream_queue_size,
      :subscription_queue_size
    ]

    nonnegative = [
      :request_timeout,
      :legacy_initialized_grace_ms,
      :stream_keepalive_ms,
      :legacy_keepalive_ms,
      :session_idle_timeout,
      :session_absolute_timeout,
      :max_body_bytes,
      :max_message_bytes,
      :cursor_ttl,
      :subscription_timeout
    ]

    Enum.each(positive, fn key ->
      case Keyword.get(opts, key) do
        value when is_integer(value) and value > 0 -> :ok
        _ -> raise ArgumentError, "#{key} must be a positive integer"
      end
    end)

    Enum.each(nonnegative, fn key ->
      case Keyword.get(opts, key) do
        nil -> :ok
        value when is_integer(value) and value >= 0 -> :ok
        _ -> raise ArgumentError, "#{key} must be a non-negative integer"
      end
    end)

    page_size = Keyword.get(opts, :page_size)

    if not is_nil(page_size) and not (is_integer(page_size) and page_size in 1..100),
      do: raise(ArgumentError, ":page_size must be between 1 and 100")

    cache_ttl = Keyword.get(opts, :cache_ttl_ms)

    if not is_nil(cache_ttl) and not (is_integer(cache_ttl) and cache_ttl >= 0),
      do: raise(ArgumentError, ":cache_ttl_ms must be a non-negative integer")

    cache_scope = Keyword.get(opts, :cache_scope)

    if not is_nil(cache_scope) and cache_scope not in [:private, :public, "private", "public"],
      do: raise(ArgumentError, ":cache_scope must be :private or :public")

    allow_public_cache = Keyword.get(opts, :allow_public_cache)

    if not is_nil(allow_public_cache) and not is_boolean(allow_public_cache),
      do: raise(ArgumentError, ":allow_public_cache must be boolean")

    versions = Keyword.get(opts, :protocol_versions)

    unless is_list(versions) and versions != [] and
             Enum.uniq(versions) == versions and Enum.all?(versions, &(&1 in @versions)) do
      raise ArgumentError, ":protocol_versions must be a non-empty list of supported versions"
    end

    Enum.each([:server_name, :server_version, :instructions], fn key ->
      case Keyword.get(opts, key) do
        nil -> :ok
        value when is_binary(value) and byte_size(value) > 0 -> :ok
        _ -> raise ArgumentError, "#{key} must be a non-empty string"
      end
    end)

    validate_scope_map!(Keyword.get(opts, :scope_map))
    validate_capabilities!(Keyword.get(opts, :capabilities))

    case Keyword.get(opts, :clustered) do
      nil -> :ok
      value when is_boolean(value) -> :ok
      _ -> raise ArgumentError, ":clustered must be boolean"
    end

    case Keyword.get(opts, :initialize_callback) do
      nil -> :ok
      callback when is_function(callback, 2) -> :ok
      _ -> raise ArgumentError, ":initialize_callback must be a two-argument function"
    end

    case Keyword.get(opts, :request_state_store) do
      nil -> :ok
      store when is_pid(store) -> :ok
      _ -> raise ArgumentError, ":request_state_store must be a supervised pid"
    end

    Enum.each([:cursor_secret, :request_state_secret], fn key ->
      case Keyword.get(opts, key) do
        nil -> :ok
        value when is_binary(value) and byte_size(value) > 0 -> :ok
        _ -> raise ArgumentError, "#{key} must be a non-empty binary"
      end
    end)

    if Keyword.get(opts, :request_timeout) > Keyword.get(opts, :max_request_timeout),
      do: raise(ArgumentError, ":request_timeout cannot exceed :max_request_timeout")

    :ok
  end

  defp validate_scope_map!(nil), do: :ok

  defp validate_scope_map!(scope_map) when is_map(scope_map) do
    valid? =
      Enum.all?(scope_map, fn {method, scopes} ->
        valid_scope_map_key?(method) and is_list(scopes) and
          Enum.all?(scopes, &(is_binary(&1) and byte_size(&1) > 0)) and
          length(scopes) == length(Enum.uniq(scopes))
      end)

    if valid?, do: :ok, else: raise(ArgumentError, ":scope_map values must be lists of scopes")
  end

  defp validate_scope_map!(_), do: raise(ArgumentError, ":scope_map must be a map")

  defp valid_scope_map_key?(key) when is_binary(key), do: byte_size(key) > 0
  defp valid_scope_map_key?(_), do: false

  defp validate_capabilities!(nil), do: :ok

  defp validate_capabilities!(capabilities) when is_map(capabilities) do
    if Schema.json_value(capabilities) == :ok do
      :ok
    else
      raise ArgumentError, ":capabilities must contain only bounded JSON values"
    end
  end

  defp validate_capabilities!(_), do: raise(ArgumentError, ":capabilities must be a JSON map")

  defp validate_replica_options!(opts) do
    if opts[:clustered] == true do
      required = [
        :request_state_secret,
        :cursor_secret,
        :request_state_instance,
        :request_state_store
      ]

      unless Enum.all?(required, fn key ->
               case Keyword.get(opts, key) do
                 value when key == :request_state_store -> is_pid(value)
                 value -> is_binary(value) and byte_size(value) >= 16
               end
             end) do
        raise ArgumentError,
              ":clustered requires shared request_state_secret, cursor_secret, request_state_instance, and request_state_store"
      end
    end
  end

  defp rate_decision(config, category, key, buckets, now) do
    setting = Map.get(config || %{}, category) || Map.get(config || %{}, Atom.to_string(category))

    case normalize_rate_setting(setting) do
      :disabled ->
        {:ok, buckets}

      {:ok, burst, window_ms} ->
        bucket_key = {category, key}

        previous =
          Map.get(buckets, bucket_key, %{
            tokens: burst * 1.0,
            at: now,
            window_ms: window_ms
          })

        elapsed = max(now - previous.at, 0)
        replenished = min(burst * 1.0, previous.tokens + elapsed * burst / window_ms)

        if replenished >= 1.0 do
          updated =
            Map.put(buckets, bucket_key, %{
              tokens: replenished - 1.0,
              at: now,
              window_ms: window_ms,
              expires_at: now + window_ms
            })

          {:ok, prune_rate_buckets(updated, now)}
        else
          updated =
            Map.put(buckets, bucket_key, %{
              tokens: replenished,
              at: now,
              window_ms: window_ms,
              expires_at: now + window_ms
            })

          {:error, prune_rate_buckets(updated, now)}
        end
    end
  end

  defp normalize_rate_setting(nil), do: :disabled
  defp normalize_rate_setting(false), do: :disabled

  defp normalize_rate_setting(setting) when is_map(setting) do
    burst = Map.get(setting, :burst, Map.get(setting, "burst"))
    window = Map.get(setting, :window_ms, Map.get(setting, "window_ms"))

    if is_integer(burst) and burst > 0 and is_integer(window) and window > 0,
      do: {:ok, burst, window},
      else: :disabled
  end

  defp normalize_rate_setting(_), do: :disabled

  defp validate_rate_limits!(false), do: :ok

  defp validate_rate_limits!(settings) when is_map(settings) do
    allowed = [:calls, :completion, :subscriptions, :auth_failures]

    Enum.each(settings, fn {category, setting} ->
      category = if is_binary(category), do: String.to_existing_atom(category), else: category

      if category not in allowed or
           (normalize_rate_setting(setting) == :disabled and setting != false),
         do: raise(ArgumentError, "invalid rate_limits configuration")
    end)
  rescue
    ArgumentError -> reraise(ArgumentError, __STACKTRACE__)
    _ -> raise ArgumentError, "invalid rate_limits configuration"
  end

  defp validate_rate_limits!(_), do: raise(ArgumentError, "rate_limits must be a map")

  defp prune_rate_buckets(buckets, now) do
    live =
      Enum.filter(buckets, fn {_key, bucket} ->
        expiry = bucket[:expires_at] || bucket.at + (bucket[:window_ms] || 0)
        expiry >= now
      end)

    if length(live) <= @max_rate_buckets do
      Map.new(live)
    else
      live
      |> Enum.sort_by(fn {_key, bucket} -> bucket.at end, :desc)
      |> Enum.take(@max_rate_buckets)
      |> Map.new()
    end
  end

  defp await_task(
         ref,
         task,
         task_monitor,
         timeout,
         on_event,
         subscriptions,
         started,
         keepalive_ms,
         keepalive_timer
       ) do
    receive do
      {^ref, :keepalive} ->
        delivery = deliver_event(on_event, :keepalive)

        next_timer =
          if is_integer(keepalive_ms) and keepalive_ms > 0,
            do: Process.send_after(self(), {ref, :keepalive}, keepalive_ms)

        case delivery do
          :ok ->
            await_task(
              ref,
              task,
              task_monitor,
              timeout,
              on_event,
              subscriptions,
              started,
              keepalive_ms,
              next_timer
            )

          {:error, _reason} ->
            stop_after_delivery_failure(task, task_monitor, next_timer, ref)
        end

      {^ref, :progress, delivery_ref, event} ->
        delivery = deliver_event(on_event, event)
        send(task, {ref, :progress_ack, delivery_ref, delivery})

        case delivery do
          :ok ->
            await_task(
              ref,
              task,
              task_monitor,
              timeout,
              on_event,
              subscriptions,
              started,
              keepalive_ms,
              keepalive_timer
            )

          {:error, _reason} ->
            stop_after_delivery_failure(task, task_monitor, keepalive_timer, ref)
        end

      {^ref, :progress, event} ->
        delivery = deliver_event(on_event, event)

        case delivery do
          :ok ->
            await_task(
              ref,
              task,
              task_monitor,
              timeout,
              on_event,
              subscriptions,
              started,
              keepalive_ms,
              keepalive_timer
            )

          {:error, _reason} ->
            stop_after_delivery_failure(task, task_monitor, keepalive_timer, ref)
        end

      {^ref, :progress_error, _reason} ->
        stop_after_delivery_failure(task, task_monitor, keepalive_timer, ref)

      {^ref, :notification, delivery_ref, event} ->
        delivery = deliver_event(on_event, event)
        send(task, {ref, :notification_ack, delivery_ref, delivery})

        case delivery do
          :ok ->
            await_task(
              ref,
              task,
              task_monitor,
              timeout,
              on_event,
              subscriptions,
              started,
              keepalive_ms,
              keepalive_timer
            )

          {:error, _reason} ->
            stop_after_delivery_failure(task, task_monitor, keepalive_timer, ref)
        end

      {:mcp_subscription, ^ref, id, event} ->
        delivery = deliver_event(on_event, event)
        Subscriptions.ack(subscriptions, id)

        case delivery do
          :ok ->
            await_task(
              ref,
              task,
              task_monitor,
              timeout,
              on_event,
              subscriptions,
              started,
              keepalive_ms,
              keepalive_timer
            )

          {:error, _reason} ->
            stop_after_delivery_failure(task, task_monitor, keepalive_timer, ref)
        end

      {^ref, :cancelled} ->
        cancel_keepalive_timer(keepalive_timer, ref)
        kill_task(task, task_monitor)
        {:error, Error.cancelled()}

      {^ref, :result, result} ->
        cancel_keepalive_timer(keepalive_timer, ref)
        reap_task(task_monitor, task)
        result

      {:DOWN, ^task_monitor, :process, ^task, _reason} ->
        cancel_keepalive_timer(keepalive_timer, ref)
        {:error, Error.internal(%{"reason" => "handler_exit"})}
    after
      max(timeout - (System.monotonic_time(:millisecond) - started), 0) ->
        Telemetry.execute([:request, :timeout], %{count: 1}, %{outcome: :timeout})
        cancel_keepalive_timer(keepalive_timer, ref)
        kill_task(task, task_monitor)
        {:error, Error.internal(%{"reason" => "timeout"})}
    end
  end

  defp deliver_event(on_event, event) when is_function(on_event, 1) do
    try do
      case on_event.(event) do
        {:error, reason} -> {:error, reason}
        _ -> :ok
      end
    rescue
      _ -> {:error, :delivery_callback_failed}
    catch
      _, _ -> {:error, :delivery_callback_failed}
    end
  end

  defp deliver_event(_on_event, _event), do: :ok

  defp detached_legacy_delivery(on_event, true) when is_function(on_event, 1) do
    fn event ->
      try do
        case on_event.(event) do
          {:error, _reason} -> :ok
          result -> result
        end
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end
  end

  defp detached_legacy_delivery(on_event, _detached), do: on_event

  defp stop_after_delivery_failure(task, task_monitor, keepalive_timer, ref) do
    Telemetry.execute([:stream, :exception], %{count: 1}, %{
      transport: :core,
      outcome: :delivery_failed
    })

    cancel_keepalive_timer(keepalive_timer, ref)
    kill_task(task, task_monitor)
    {:error, Error.internal(%{"reason" => "event_delivery_failure"})}
  end

  defp cancel_keepalive_timer(nil, _ref), do: :ok

  defp cancel_keepalive_timer(timer, ref) do
    _ = Process.cancel_timer(timer)

    receive do
      {^ref, :keepalive} -> :ok
    after
      0 -> :ok
    end
  end

  defp kill_task(task, task_monitor) do
    Process.unlink(task)
    Process.exit(task, :kill)
    reap_task(task_monitor, task)
  end

  defp reap_task(task_monitor, task) do
    receive do
      {:DOWN, ^task_monitor, :process, ^task, _reason} -> :ok
    after
      5_000 ->
        Process.demonitor(task_monitor, [:flush])
        :ok
    end
  end

  defp progress_callback(_parent, _ref, expected_token, nil) when not is_nil(expected_token),
    do: fn _token, _progress, _total -> {:error, :unsupported} end

  defp progress_callback(parent, ref, expected_token, _on_event) do
    fn token, progress, total ->
      last = Process.get({:mcp_progress, expected_token}, -1)

      valid_total = is_nil(total) or (is_number(total) and total >= progress)

      if not is_nil(expected_token) and token == expected_token and is_number(progress) and
           progress >= last and valid_total do
        Process.put({:mcp_progress, expected_token}, progress)

        params = %{
          "progressToken" => token,
          "progress" => progress
        }

        params = if is_nil(total), do: params, else: Map.put(params, "total", total)

        event = %{
          "jsonrpc" => "2.0",
          "method" => "notifications/progress",
          "params" => params
        }

        # Delivery is performed by the request/transport owner in
        # await_task/8.  Handler tasks must never capture a Plug.Conn or die
        # with the caller when a sink disappears.
        delivery_ref = make_ref()
        send(parent, {ref, :progress, delivery_ref, event})

        result =
          receive do
            {^ref, :progress_ack, ^delivery_ref, delivery} -> delivery
          after
            5_000 -> {:error, :delivery_timeout}
          end

        case result do
          :ok ->
            Telemetry.execute([:progress, :emit], %{count: 1}, %{outcome: :delivered})
            :ok

          {:error, reason} ->
            Telemetry.execute([:progress, :reject], %{count: 1}, %{outcome: :delivery_failed})
            {:error, reason}
        end
      else
        Telemetry.execute([:progress, :reject], %{count: 1}, %{outcome: :rejected})
        {:error, :inactive_or_nonmonotonic_token}
      end
    end
  end

  defp notification_callback(
         _parent,
         _ref,
         nil,
         _era,
         _request,
         _context,
         _limit
       ),
       do: fn _event -> {:error, :unsupported} end

  defp notification_callback(parent, ref, _on_event, era, request, context, limit) do
    fn event ->
      with :ok <- reject_progress_notification(event),
           :ok <- validate_server_notification(event, era),
           :ok <- notification_log_policy(event, era, request, context),
           :ok <- bounded_notification_count(ref, limit) do
        delivery_ref = make_ref()
        send(parent, {ref, :notification, delivery_ref, event})

        receive do
          {^ref, :notification_ack, ^delivery_ref, delivery} -> delivery
        after
          5_000 -> {:error, :delivery_timeout}
        end
      else
        {:error, reason} = error ->
          Telemetry.execute([:notification, :reject], %{count: 1}, %{reason: reason})
          error
      end
    end
  end

  defp reject_progress_notification(%{"method" => "notifications/progress"}),
    do: {:error, :progress_must_use_context_progress}

  defp reject_progress_notification(_event), do: :ok

  defp bounded_notification_count(ref, limit) when is_integer(limit) and limit > 0 do
    key = {:mcp_notification_count, ref}
    count = Process.get(key, 0)

    if count < limit do
      Process.put(key, count + 1)
      :ok
    else
      {:error, :rate_limited}
    end
  end

  defp bounded_notification_count(_ref, _limit), do: {:error, :rate_limited}

  defp request_logging_level(request, _context, @modern) do
    meta = if is_map(request.params), do: Map.get(request.params, "_meta", %{}), else: %{}
    if is_map(meta), do: meta["io.modelcontextprotocol/logLevel"], else: nil
  end

  defp request_logging_level(_request, context, @legacy),
    do: Map.get(context, :logging_level)

  defp request_logging_level(_request, _context, _era), do: nil

  defp enrich_logging_context(context, runtime, @legacy) do
    level =
      case context[:session_id] do
        session_id when is_binary(session_id) ->
          session_logging_level(
            runtime.server,
            session_id,
            principal(context),
            tenant(context)
          )

        _ ->
          nil
      end

    Map.put_new(context, :logging_level, level)
  end

  defp enrich_logging_context(context, _runtime, _era), do: context

  defp validate_server_notification(
         %{"jsonrpc" => "2.0", "method" => method, "params" => params} = event,
         era
       )
       when is_binary(method) and is_map(params) do
    cond do
      Map.has_key?(event, "id") or Map.has_key?(event, "result") or Map.has_key?(event, "error") ->
        {:error, :notification_envelope}

      method not in notification_methods(era) ->
        {:error, :notification_method}

      Schema.json_value(event) != :ok ->
        {:error, :notification_not_json}

      method == "notifications/message" ->
        validate_log_params(params)

      method == "notifications/progress" ->
        validate_progress_params(params)

      method in [
        "notifications/tools/list_changed",
        "notifications/prompts/list_changed",
        "notifications/resources/list_changed"
      ] ->
        validate_catalog_notification_params(params)

      method == "notifications/resources/updated" ->
        validate_resource_updated_notification_params(params)

      true ->
        {:error, :notification_params}
    end
  end

  defp validate_server_notification(_event, _era), do: {:error, :invalid_notification}

  defp notification_methods(@modern),
    do: [
      "notifications/message",
      "notifications/progress",
      "notifications/tools/list_changed",
      "notifications/prompts/list_changed",
      "notifications/resources/list_changed",
      "notifications/resources/updated"
    ]

  defp notification_methods(@legacy),
    do: [
      "notifications/message",
      "notifications/progress",
      "notifications/tools/list_changed",
      "notifications/prompts/list_changed",
      "notifications/resources/list_changed",
      "notifications/resources/updated"
    ]

  defp notification_methods(_), do: []

  defp validate_log_params(params) do
    allowed = ["level", "logger", "data", "_meta"]

    cond do
      not Enum.all?(Map.keys(params), &is_binary/1) ->
        {:error, :log_params_keys}

      not Enum.all?(Map.keys(params), &(&1 in allowed)) ->
        {:error, :log_params_keys}

      not is_binary(params["level"]) or params["level"] not in @log_levels ->
        {:error, :log_level_invalid}

      Map.has_key?(params, "logger") and
          not (is_binary(params["logger"]) and byte_size(params["logger"]) <= 256) ->
        {:error, :log_logger_invalid}

      not Map.has_key?(params, "data") or Schema.json_value(params["data"]) != :ok ->
        {:error, :log_data_invalid}

      Map.has_key?(params, "_meta") and
          (not is_map(params["_meta"]) or Schema.json_value(params["_meta"]) != :ok) ->
        {:error, :log_meta_invalid}

      true ->
        :ok
    end
  end

  defp validate_catalog_notification_params(params) when is_map(params) do
    if Enum.all?(Map.keys(params), &(&1 == "_meta")) and
         (not Map.has_key?(params, "_meta") or
            (is_map(params["_meta"]) and Schema.json_value(params["_meta"]) == :ok)),
       do: :ok,
       else: {:error, :notification_params}
  end

  defp validate_resource_updated_notification_params(params) when is_map(params) do
    uri = params["uri"]

    if is_binary(uri) and byte_size(uri) in 1..4_096 and String.valid?(uri) and
         Enum.all?(Map.keys(params), &(&1 in ["uri", "_meta"])) and
         (not Map.has_key?(params, "_meta") or
            (is_map(params["_meta"]) and Schema.json_value(params["_meta"]) == :ok)),
       do: :ok,
       else: {:error, :notification_params}
  end

  defp validate_progress_params(params) do
    token = params["progressToken"]
    progress = params["progress"]
    total = params["total"]

    if (is_binary(token) or is_integer(token)) and is_number(progress) and progress >= 0 and
         (is_nil(total) or (is_number(total) and total >= progress)) and
         Schema.json_value(params) == :ok,
       do: :ok,
       else: {:error, :progress_invalid}
  end

  defp notification_log_policy(event, @modern, request, context) do
    logging_enabled? =
      case Map.get(context, :server_capabilities, %{}) do
        capabilities when is_map(capabilities) -> is_map(Map.get(capabilities, "logging"))
        _ -> false
      end

    if event["method"] == "notifications/message" and not logging_enabled? do
      {:error, :logging_disabled}
    else
      if event["method"] == "notifications/message" do
        meta = if is_map(request.params), do: Map.get(request.params, "_meta", %{}), else: %{}

        case is_map(meta) && meta["io.modelcontextprotocol/logLevel"] do
          level when level in @log_levels ->
            if log_level_at_or_above?(event["params"]["level"], level),
              do: :ok,
              else: {:error, :log_filtered}

          _ ->
            {:error, :logging_disabled}
        end
      else
        :ok
      end
    end
  end

  defp notification_log_policy(event, @legacy, _request, context) do
    if event["method"] == "notifications/message" do
      case Map.get(context, :logging_level) do
        level when level in @log_levels ->
          if log_level_at_or_above?(event["params"]["level"], level),
            do: :ok,
            else: {:error, :log_filtered}

        _ ->
          {:error, :logging_disabled}
      end
    else
      :ok
    end
  end

  defp notification_log_policy(_event, _era, _request, _context), do: {:error, :logging_disabled}

  defp log_level_at_or_above?(actual, minimum) do
    Enum.find_index(@log_levels, &(&1 == actual)) >=
      Enum.find_index(@log_levels, &(&1 == minimum))
  end

  defp client_request_callback(server, context, timeout) do
    fn method, params ->
      request_client(
        server,
        Map.get(context, :session_id),
        principal(context),
        tenant(context),
        method,
        params,
        timeout
      )
    end
  end

  defp client_request(server, session_id, principal, tenant, method, params, timeout)
       when is_binary(session_id) and is_binary(method) and is_map(params) and
              is_integer(timeout) and timeout > 0 do
    ready_deadline = System.monotonic_time(:millisecond) + min(timeout, 1_000)

    case open_client_request_when_ready(
           server,
           session_id,
           principal,
           tenant,
           method,
           params,
           ready_deadline
         ) do
      {:ok, request_ref} ->
        receive do
          {^request_ref, {:response, {:ok, result}}} -> {:ok, result}
          {^request_ref, {:response, {:error, reason}}} -> {:error, reason}
          {^request_ref, {:error, reason}} -> {:error, reason}
        after
          timeout ->
            GenServer.call(server, {:expire_client_request, request_ref})
            {:error, :timeout}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp client_request(_server, _session_id, _principal, _tenant, _method, _params, _timeout),
    do: {:error, :invalid_request}

  defp open_client_request_when_ready(
         server,
         session_id,
         principal,
         tenant,
         method,
         params,
         deadline
       ) do
    result =
      GenServer.call(
        server,
        {:open_client_request, session_id, principal, tenant, method, params, self()}
      )

    if result == {:error, :not_ready} and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(10)

      open_client_request_when_ready(
        server,
        session_id,
        principal,
        tenant,
        method,
        params,
        deadline
      )
    else
      result
    end
  end

  defp validate_client_response(method, response, params) when is_map(response) do
    kind = response[:kind] || response["kind"]
    result = response[:result] || response["result"]
    error = response[:error] || response["error"]

    cond do
      kind not in [:response, "response"] ->
        {:error, :invalid_response}

      is_map(error) and is_nil(result) and valid_client_error?(error) ->
        {:error, {:client_error, error}}

      is_nil(error) and valid_client_result?(method, result, params) ->
        {:ok, result}

      true ->
        {:error, :invalid_response}
    end
  end

  defp validate_client_response(_method, _response, _params), do: {:error, :invalid_response}

  defp valid_client_error?(error) when is_map(error) do
    is_integer(error[:code] || error["code"]) and
      is_binary(error[:message] || error["message"])
  end

  defp valid_client_result?("elicitation/create", result, params) when is_map(result) do
    action = result["action"] || result[:action]
    content = result["content"] || result[:content]

    action in ["accept", "decline", "cancel"] and
      if(params["mode"] == "url",
        do: not Map.has_key?(result, "content"),
        else: action != "accept" or is_map(content)
      )
  end

  defp valid_client_result?("sampling/createMessage", result, _params) when is_map(result) do
    role = result["role"] || result[:role]
    content = result["content"] || result[:content]
    model = result["model"] || result[:model]
    stop_reason = result["stopReason"] || result[:stopReason]

    role == "assistant" and valid_sampling_content?(content) and is_binary(model) and
      (is_nil(stop_reason) or is_binary(stop_reason))
  end

  defp valid_client_result?("roots/list", result, _params) when is_map(result) do
    roots = result["roots"] || result[:roots]

    is_list(roots) and Enum.all?(roots, &valid_client_root?/1)
  end

  defp valid_client_result?(_, _, _), do: false

  defp valid_client_root?(root) when is_map(root) do
    uri = root["uri"] || root[:uri]
    name = root["name"] || root[:name]

    is_binary(uri) and String.starts_with?(uri, "file://") and
      (is_nil(name) or is_binary(name))
  end

  defp valid_client_root?(_), do: false

  defp session_for(state, session_id, principal, tenant, opts \\ []) do
    require_initialized = Keyword.get(opts, :require_initialized, false)

    case :ets.lookup(state.sessions, session_id) do
      [{^session_id, session}] ->
        if Session.valid?(session) and Session.same_principal?(session, principal) and
             Session.same_tenant?(session, tenant) and
             (not require_initialized or session.initialized),
           do: {:ok, session},
           else: {:error, :not_found}

      _ ->
        {:error, :not_found}
    end
  end

  defp await_initialized_until(server, id, principal, tenant, deadline) do
    case get_session(server, id, principal, tenant) do
      {:ok, %{initialized: true}} ->
        :ok

      {:ok, _session} ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining > 0 do
          Process.sleep(min(remaining, 5))
          await_initialized_until(server, id, principal, tenant, deadline)
        else
          {:error, :not_initialized}
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp session_owned?(state, session_id, principal, tenant),
    do: match?({:ok, _}, session_for(state, session_id, principal, tenant))

  defp response_id(%{id: id}), do: id
  defp response_id(%{"id" => id}), do: id
  defp response_id(_), do: nil

  defp remove_client_request(state, request_ref, request) do
    Process.demonitor(request.waiter_monitor, [:flush])
    %{state | client_requests: Map.delete(state.client_requests, request_ref)}
  end

  defp remove_legacy_stream(state, stream_ref) do
    case Map.pop(state.legacy_streams, stream_ref) do
      {nil, _streams} ->
        state

      {stream, streams} ->
        Process.demonitor(stream.monitor, [:flush])

        case :ets.lookup(state.sessions, stream.session_id) do
          [{session_id, session}] when session_id == stream.session_id ->
            :ets.insert(
              state.sessions,
              {stream.session_id, %{session | streams: Map.delete(session.streams, stream_ref)}}
            )

          _ ->
            :ok
        end

        {client_requests, _} =
          Enum.reduce(state.client_requests, {%{}, []}, fn {request_ref, request},
                                                           {acc, removed} ->
            if request.stream_ref == stream_ref do
              send(request.waiter, {request_ref, {:error, :stream_closed}})
              Process.demonitor(request.waiter_monitor, [:flush])
              {acc, [request_ref | removed]}
            else
              {Map.put(acc, request_ref, request), removed}
            end
          end)

        %{state | legacy_streams: streams, client_requests: client_requests}
    end
  end

  defp newest_live_legacy_stream(streams, session_id) do
    case streams
         |> Enum.filter(fn {_ref, stream} ->
           stream.session_id == session_id and Process.alive?(stream.sink)
         end)
         |> Enum.max_by(
           fn {_ref, stream} -> stream.opened_sequence end,
           fn -> nil end
         ) do
      nil -> :stream_not_ready
      {stream_ref, stream} -> {:ok, stream_ref, stream}
    end
  end

  defp close_legacy_streams_for_session(state, session_id, reason) do
    refs =
      state.legacy_streams
      |> Enum.filter(fn {_ref, stream} -> stream.session_id == session_id end)
      |> Enum.map(&elem(&1, 0))

    Enum.each(refs, fn ref ->
      case state.legacy_streams[ref] do
        %{sink: sink} -> send(sink, {:mcp_legacy_close, ref, reason})
        _ -> :ok
      end
    end)

    Enum.reduce(refs, state, &remove_legacy_stream(&2, &1))
  end

  defp publish_legacy(state, notification) do
    event = legacy_event(notification)

    state.legacy_streams
    |> Enum.group_by(fn {_ref, stream} -> stream.session_id end)
    |> Enum.reduce(state, fn {session_id, streams}, acc ->
      case :ets.lookup(acc.sessions, session_id) do
        [{^session_id, session}] ->
          if Session.valid?(session) and legacy_event_allowed?(event, session) do
            required_scopes = legacy_event_required_scopes(acc, event)

            case Enum.find(streams, fn {_ref, stream} ->
                   Process.alive?(stream.sink) and
                     legacy_authorized?(stream, event, required_scopes)
                 end) do
              {stream_ref, _stream} -> send_legacy_stream(acc, stream_ref, event)
              nil -> acc
            end
          else
            if Session.valid?(session),
              do: acc,
              else: close_legacy_streams_for_session(acc, session_id, :session_expired)
          end

        _ ->
          close_legacy_streams_for_session(acc, session_id, :session_expired)
      end
    end)
  end

  defp send_legacy_stream(state, stream_ref, message) do
    queue_limit = stream_queue_limit(state)

    case state.legacy_streams[stream_ref] do
      %{sink: sink, event_id: event_id, queue_size: queue_size} = stream ->
        if queue_size < queue_limit do
          next_id = event_id + 1
          send(sink, {:mcp_legacy_event, stream_ref, next_id, message})

          put_in(state.legacy_streams[stream_ref], %{
            stream
            | event_id: next_id,
              queue_size: queue_size + 1
          })
        else
          send(sink, {:mcp_legacy_close, stream_ref, :backpressure})
          remove_legacy_stream(state, stream_ref)
        end

      %{sink: sink} ->
        send(sink, {:mcp_legacy_close, stream_ref, :backpressure})
        remove_legacy_stream(state, stream_ref)

      _ ->
        state
    end
  end

  defp legacy_authorized?(%{authorize: authorize} = stream, event, required_scopes)
       when is_function(authorize, 1) do
    authorize.(%{
      principal: stream.principal,
      tenant: stream.tenant,
      event: event,
      required_scopes: required_scopes
    }) == true
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp legacy_authorized?(_, _event, _required_scopes), do: true

  defp legacy_event_required_scopes(state, %{
         "method" => "notifications/resources/updated",
         "params" => params
       })
       when is_map(params) do
    uri = resource_uri(params)
    definition_scopes = resource_definition_scopes(state, uri)
    Enum.uniq([AttestoMCP.Scopes.resources_read() | definition_scopes])
  end

  defp legacy_event_required_scopes(_state, %{"method" => method})
       when method == "notifications/tools/list_changed",
       do: [AttestoMCP.Scopes.tools_read()]

  defp legacy_event_required_scopes(_state, %{"method" => method})
       when method == "notifications/prompts/list_changed",
       do: [AttestoMCP.Scopes.prompts_read()]

  defp legacy_event_required_scopes(_state, %{"method" => method})
       when method == "notifications/resources/list_changed",
       do: [AttestoMCP.Scopes.resources_read()]

  defp legacy_event_required_scopes(_state, _event), do: []

  defp resource_definition_scopes(_state, nil), do: []

  defp resource_definition_scopes(state, uri) when is_binary(uri) do
    resources = Map.values(Map.get(state.definitions, :resource, %{}))
    templates = Map.values(Map.get(state.definitions, :template, %{}))

    exact =
      Enum.find_value(resources, [], fn definition ->
        if definition[:uri] == uri, do: definition[:required_scopes] || [], else: nil
      end)

    if exact != [] do
      exact
    else
      Enum.find_value(templates, [], fn definition ->
        case match_uri_template(definition[:uri_template], uri) do
          {:ok, _params} -> definition[:required_scopes] || []
          _ -> nil
        end
      end)
    end
  rescue
    _ -> []
  end

  defp notification_scopes(state, %{"type" => type} = notification)
       when type in ["resource", "resourceUpdated", "resourceSubscriptions"] do
    uri = notification["uri"] || notification[:uri]
    Enum.uniq([AttestoMCP.Scopes.resources_read() | resource_definition_scopes(state, uri)])
  end

  defp notification_scopes(_state, _notification), do: []

  defp stream_queue_limit(state),
    do: state.opts[:stream_queue_size] || state.opts[:max_queue] || @default_stream_queue

  defp legacy_event(%{"jsonrpc" => "2.0", "method" => _method} = event), do: event

  defp legacy_event(%{"type" => type} = event) do
    {method, params} =
      case to_string(type) do
        "resourcesListChanged" ->
          {"notifications/resources/list_changed", notification_meta(event)}

        "resource" ->
          {"notifications/resources/updated", Map.delete(event, "type")}

        "resourceUpdated" ->
          {"notifications/resources/updated", Map.delete(event, "type")}

        "toolsListChanged" ->
          {"notifications/tools/list_changed", notification_meta(event)}

        "promptsListChanged" ->
          {"notifications/prompts/list_changed", notification_meta(event)}

        _ ->
          {"notifications/message", Map.delete(event, "type")}
      end

    %{"jsonrpc" => "2.0", "method" => method, "params" => params}
  end

  defp legacy_event(event) when is_map(event),
    do: %{"jsonrpc" => "2.0", "method" => "notifications/message", "params" => event}

  defp legacy_event(_),
    do: %{"jsonrpc" => "2.0", "method" => "notifications/message", "params" => %{}}

  defp notification_meta(event) when is_map(event) do
    case event["_meta"] || event[:_meta] do
      meta when is_map(meta) -> %{"_meta" => meta}
      _ -> %{}
    end
  end

  defp legacy_event_allowed?(
         %{"method" => "notifications/resources/updated", "params" => params},
         session
       ),
       do: resource_uri(params) in Map.keys(session.resource_subscriptions)

  defp legacy_event_allowed?(_event, _session), do: true

  defp resource_uri(params) when is_map(params),
    do: params["uri"] || params[:uri] || get_in(params, ["resource", "uri"])

  defp resource_uri(_), do: nil

  defp client_capability("sampling/createMessage"), do: "sampling"
  defp client_capability("elicitation/create"), do: "elicitation"
  defp client_capability("roots/list"), do: "roots"
  defp client_capability(_), do: nil

  defp validate_client_request_revision(
         @legacy_2025_06_18,
         "elicitation/create",
         %{"mode" => _mode}
       ),
       do: {:error, :unsupported}

  defp validate_client_request_revision(@legacy_2025_06_18, "sampling/createMessage", params) do
    if Map.has_key?(params, "tools") or Map.has_key?(params, "toolChoice"),
      do: {:error, :unsupported},
      else: :ok
  end

  defp validate_client_request_revision(_version, _method, _params), do: :ok

  defp encode_outcome(id, {:ok, result}, @modern, opts) when is_map(result) do
    result = stamp_server_info(result, opts)

    if Map.has_key?(result, "resultType") do
      case Schema.validate_modern_result(result) do
        :ok -> JSONRPC.response(id, result)
        _ -> JSONRPC.error_response(id, Error.internal(%{"reason" => "invalid_result"}))
      end
    else
      JSONRPC.error_response(id, Error.internal(%{"reason" => "invalid_result"}))
    end
  end

  defp encode_outcome(id, {:ok, result}, _era, _opts), do: JSONRPC.response(id, result)

  defp encode_outcome(id, {:error, %Error{} = error}, _era, _opts) do
    Telemetry.execute([:protocol, :error], %{count: 1}, %{
      status: error.http_status,
      outcome: error.code,
      correlation_id: telemetry_correlation(id)
    })

    JSONRPC.error_response(id, error)
  end

  defp encode_outcome(id, {:error, _reason}, _era, _opts),
    do: JSONRPC.error_response(id, Error.internal(%{"reason" => "internal_error"}))

  defp stamp_server_info(result, opts) do
    meta = Map.get(result, "_meta", %{})
    authored = if is_map(meta), do: Map.get(meta, "io.modelcontextprotocol/serverInfo"), else: nil
    info = if valid_server_info?(authored), do: authored, else: server_info(opts)

    meta =
      if is_map(meta),
        do: Map.put(meta, "io.modelcontextprotocol/serverInfo", info),
        else: %{"io.modelcontextprotocol/serverInfo" => info}

    Map.put(result, "_meta", meta)
  end

  defp valid_server_info?(%{"name" => name, "version" => version})
       when is_binary(name) and is_binary(version),
       do: name != "" and version != ""

  defp valid_server_info?(_), do: false

  defp outcome_kind({:ok, _}), do: :ok
  defp outcome_kind({:error, %Error{code: code}}), do: code
  defp outcome_kind(_), do: :error

  defp request_telemetry_metadata(method, id, opts) do
    %{
      method: method,
      transport: Keyword.get(opts, :transport, :core),
      protocol_version: Keyword.get(opts, :version),
      correlation_id: telemetry_correlation(id)
    }
  end

  defp emit_request_terminal(
         {:error, %Error{data: %{"reason" => "handler_exit"}}},
         started,
         metadata
       ),
       do: emit_terminal(:exception, :handler_exit, started, metadata)

  defp emit_request_terminal({:error, %Error{code: -32800}}, started, metadata) do
    emit_cancellation_stop(metadata)
    emit_terminal(:stop, :cancelled, started, metadata)
  end

  defp emit_request_terminal(outcome, started, metadata),
    do: emit_terminal(:stop, outcome_kind(outcome), started, metadata)

  defp emit_registered_terminal(request, event, outcome),
    do: emit_terminal(event, outcome, request.started, request.telemetry_metadata)

  defp emit_cancellation_stop(metadata) do
    Telemetry.execute(
      [:cancellation, :stop],
      %{count: 1},
      %{outcome: :cancelled, correlation_id: metadata[:correlation_id]}
    )
  end

  defp emit_terminal(event, outcome, started, metadata) do
    Telemetry.execute(
      [:request, event],
      %{duration: max(System.monotonic_time() - started, 0)},
      Map.put(metadata, :outcome, outcome)
    )
  end

  defp telemetry_correlation(id) when is_binary(id), do: "string:" <> id
  defp telemetry_correlation(id) when is_integer(id), do: "integer:" <> Integer.to_string(id)
  defp telemetry_correlation(_id), do: nil

  defp handle_request(
         %{kind: :notification, method: "notifications/cancelled", params: params},
         context,
         runtime,
         _opts
       ) do
    cancel_request(
      runtime.server,
      principal(context),
      params["requestId"] || params["request_id"],
      context[:owner]
    )

    {:ok, nil}
  end

  defp handle_request(
         %{kind: :notification, method: "notifications/cancelled"},
         _context,
         _runtime,
         _opts
       ),
       do: {:ok, nil}

  defp handle_request(%{kind: :notification, method: _method}, _context, _runtime, _opts),
    do: {:ok, nil}

  defp handle_request(%{kind: :response}, _context, _runtime, _opts),
    do: {:error, Error.invalid_request(%{"reason" => "client_response_not_allowed"})}

  defp handle_request(
         %{kind: :request, method: method, params: params} = request,
         context,
         runtime,
         opts
       ) do
    era = request_era(opts, request, params)

    with :ok <- validate_request_params_shape(params),
         :ok <- validate_legacy_initialize_request(method, era, params),
         :ok <- validate_era(era, params, runtime.opts),
         :ok <- validate_protocol_binding(method, era, context, opts),
         :ok <- validate_trace_context(params),
         :ok <- authorization(method, context, runtime.opts, era) do
      dispatch_method(era, method, params, context, runtime, opts)
    end
  end

  defp request_era(opts, request, params) do
    case Keyword.fetch(opts, :version) do
      {:ok, version} -> normalize_era(version)
      :error -> detect_era(request, params)
    end
  end

  defp normalize_era(version) when version in @legacy_versions, do: @legacy
  defp normalize_era(era), do: era

  defp detect_era(%{method: "initialize"}, params) do
    case if(is_map(params),
           do: get_in(params, ["_meta", "io.modelcontextprotocol/protocolVersion"]),
           else: nil
         ) do
      @modern -> @modern
      _ -> @legacy
    end
  end

  defp detect_era(_, params) do
    meta = if is_map(params), do: Map.get(params, "_meta", %{}), else: %{}

    if is_map(meta), do: meta["io.modelcontextprotocol/protocolVersion"] || @modern, else: @modern
  end

  defp validate_request_params_shape(params) when is_map(params) do
    meta = Map.get(params, "_meta", %{})
    progress = if is_map(meta), do: meta["progressToken"], else: :invalid

    cond do
      not is_map(meta) ->
        {:error, Error.invalid_params(%{"reason" => "meta_must_be_object"})}

      not is_nil(progress) and not (is_binary(progress) or is_integer(progress)) ->
        {:error, Error.invalid_params(%{"reason" => "progress_token_invalid"})}

      Map.has_key?(meta, "io.modelcontextprotocol/logLevel") and
          meta["io.modelcontextprotocol/logLevel"] not in @log_levels ->
        {:error, Error.invalid_params(%{"reason" => "invalid_log_level"})}

      true ->
        :ok
    end
  end

  defp validate_request_params_shape(_),
    do: {:error, Error.invalid_params(%{"reason" => "params_must_be_object"})}

  defp validate_era(@modern, params, runtime_opts) do
    meta = Map.get(params, "_meta", %{})
    version = if is_map(meta), do: meta["io.modelcontextprotocol/protocolVersion"], else: nil
    caps = if is_map(meta), do: meta["io.modelcontextprotocol/clientCapabilities"], else: nil

    cond do
      is_nil(version) ->
        {:error, Error.invalid_params(%{"reason" => "protocolVersion_required"})}

      version != @modern or version not in runtime_opts[:protocol_versions] ->
        {:error, Error.unsupported_version(version, runtime_opts[:protocol_versions])}

      not is_map(caps) ->
        {:error, Error.invalid_params(%{"reason" => "clientCapabilities_required"})}

      true ->
        :ok
    end
  end

  defp validate_era(@legacy, _params, _opts), do: :ok

  defp validate_era(version, _params, runtime_opts),
    do: {:error, Error.unsupported_version(version, runtime_opts[:protocol_versions])}

  defp validate_protocol_binding("initialize", @legacy, _context, _opts), do: :ok

  defp validate_protocol_binding(
         "ping",
         @legacy,
         %{session_id: session_id, legacy_session_state: :unnegotiated},
         opts
       )
       when is_binary(session_id) do
    if Keyword.get(opts, :version) == @legacy,
      do: :ok,
      else: {:error, Error.invalid_request(%{"reason" => "negotiated_version_mismatch"})}
  end

  defp validate_protocol_binding(_method, @legacy, %{session_id: session_id} = context, opts)
       when is_binary(session_id) do
    negotiated = context[:protocol_version]

    if negotiated in @legacy_versions and Keyword.get(opts, :version) == negotiated,
      do: :ok,
      else: {:error, Error.invalid_request(%{"reason" => "negotiated_version_mismatch"})}
  end

  defp validate_protocol_binding(_method, _era, _context, _opts), do: :ok

  defp validate_legacy_initialize_request("initialize", era, params)
       when era == @legacy and is_map(params) do
    client_info = params["clientInfo"]
    capabilities = params["capabilities"]

    if is_binary(params["protocolVersion"]) and is_map(capabilities) and
         valid_legacy_capabilities?(capabilities) and valid_client_info?(client_info),
       do: :ok,
       else: {:error, Error.invalid_params(%{"reason" => "invalid_initialize_params"})}
  end

  defp validate_legacy_initialize_request("initialize", era, _params)
       when era == @legacy,
       do: {:error, Error.invalid_params(%{"reason" => "invalid_initialize_params"})}

  defp validate_legacy_initialize_request(_method, _era, _params), do: :ok

  defp valid_client_info?(%{"name" => name, "version" => version})
       when is_binary(name) and is_binary(version),
       do: name != "" and version != ""

  defp valid_client_info?(_), do: false

  defp valid_legacy_capabilities?(capabilities) when is_map(capabilities) do
    known = [
      "experimental",
      "logging",
      "prompts",
      "resources",
      "roots",
      "sampling",
      "elicitation",
      "tools",
      "completions"
    ]

    Schema.json_value(capabilities) == :ok and
      Enum.all?(capabilities, fn {key, value} ->
        is_binary(key) and
          (key not in known or is_map(value))
      end) and
      Enum.all?(["listChanged", "subscribe"], fn key ->
        case get_in(capabilities, ["resources", key]) do
          nil -> true
          value -> is_boolean(value)
        end
      end)
  end

  defp authorization(method, context, opts, _era) do
    scope_map = Map.get(context, :scope_map, opts[:scope_map] || %{}) || %{}
    required = Map.get(scope_map, method, [])
    granted = Map.get(context, :scopes, Map.get(context, "scopes", [])) || []

    if not scopes_grant?(required, granted) do
      {:error, Error.insufficient_scope(required)}
    else
      :ok
    end
  end

  defp validate_trace_context(params) when is_map(params) do
    meta = Map.get(params, "_meta", %{})

    Enum.reduce_while(["traceparent", "tracestate", "baggage"], :ok, fn key, :ok ->
      case Map.fetch(meta, key) do
        :error ->
          {:cont, :ok}

        {:ok, value} when is_binary(value) and byte_size(value) <= @max_trace_state_bytes ->
          if key == "traceparent" and not valid_traceparent?(value),
            do: {:halt, {:error, Error.invalid_params(%{"reason" => "invalid_traceparent"})}},
            else: {:cont, :ok}

        {:ok, _value} ->
          {:halt, {:error, Error.invalid_params(%{"reason" => "invalid_trace_context"})}}
      end
    end)
  end

  defp valid_traceparent?(value) do
    case Regex.run(@traceparent_pattern, value, capture: :all_but_first) do
      [trace_id, parent_id, _flags] ->
        trace_id != String.duplicate("0", 32) and parent_id != String.duplicate("0", 16)

      _ ->
        false
    end
  end

  defp trace_context(params) when is_map(params) do
    params
    |> Map.get("_meta", %{})
    |> Map.take(["traceparent", "tracestate", "baggage"])
  end

  defp trace_context(_params), do: %{}

  defp dispatch_method(@modern, "server/discover", _params, context, runtime, _opts) do
    result = %{
      "supportedVersions" => runtime.opts[:protocol_versions],
      "capabilities" => capabilities(runtime.opts),
      "resultType" => "complete",
      "ttlMs" => cache_ttl(runtime.opts),
      "cacheScope" => cache_scope(runtime.opts, context),
      "_meta" => %{"io.modelcontextprotocol/serverInfo" => server_info(runtime.opts)}
    }

    {:ok, maybe_put_instructions(result, runtime.opts[:instructions])}
  end

  defp dispatch_method(era, "initialize", params, context, runtime, _opts) when era == @legacy do
    requested = List.wrap(params["protocolVersion"] || @legacy)
    supported = Enum.filter(@legacy_versions, &(&1 in runtime.opts[:protocol_versions]))
    selected = Enum.find(supported, &(&1 in requested))

    if is_binary(selected) and lifecycle_initialize_allowed?(runtime.opts, context, params) do
      negotiated =
        if is_binary(context[:session_id]) do
          negotiate_session(
            runtime.server,
            context[:session_id],
            principal(context),
            tenant(context),
            selected,
            params["capabilities"]
          )
        else
          :ok
        end

      case negotiated do
        :ok ->
          result = %{
            "protocolVersion" => selected,
            "capabilities" => legacy_capabilities(runtime.opts),
            "serverInfo" => server_info(runtime.opts)
          }

          {:ok, maybe_put_instructions(result, runtime.opts[:instructions])}

        {:error, :already_negotiated} ->
          {:error, Error.invalid_request(%{"reason" => "initialize_session_rejected"})}

        {:error, _reason} ->
          {:error, Error.internal(%{"reason" => "initialize_session_rejected"})}
      end
    else
      if is_binary(selected),
        do: {:error, Error.internal(%{"reason" => "initialize_rejected"})},
        else:
          {:error,
           Error.unsupported_version(
             List.first(requested),
             if(supported == [], do: runtime.opts[:protocol_versions], else: supported)
           )}
    end
  end

  defp dispatch_method(@modern, method, params, context, runtime, opts),
    do: dispatch_modern(method, params, context, runtime, opts)

  defp dispatch_method(@legacy, method, params, context, runtime, opts),
    do: dispatch_legacy(method, params, context, runtime, opts)

  defp maybe_put_instructions(result, instructions) when is_binary(instructions),
    do: Map.put(result, "instructions", instructions)

  defp maybe_put_instructions(result, _instructions), do: result

  defp dispatch_modern("tools/list", params, context, runtime, _opts),
    do: list_result(runtime.registry, :tool, params, context, @modern, "tools", runtime.opts)

  defp dispatch_modern("resources/list", params, context, runtime, _opts),
    do:
      list_result(
        runtime.registry,
        :resource,
        params,
        context,
        @modern,
        "resources",
        runtime.opts
      )

  defp dispatch_modern("resources/templates/list", params, context, runtime, _opts),
    do:
      list_result(
        runtime.registry,
        :template,
        params,
        context,
        @modern,
        "resourceTemplates",
        runtime.opts
      )

  defp dispatch_modern("prompts/list", params, context, runtime, _opts),
    do: list_result(runtime.registry, :prompt, params, context, @modern, "prompts", runtime.opts)

  defp dispatch_modern("tools/call", params, context, runtime, opts),
    do: call_tool(params, context, runtime, opts, @modern)

  defp dispatch_modern("resources/read", params, context, runtime, opts),
    do: read_resource(params, context, runtime, opts, @modern)

  defp dispatch_modern("prompts/get", params, context, runtime, opts),
    do: get_prompt(params, context, runtime, opts, @modern)

  defp dispatch_modern("completion/complete", params, context, runtime, _opts),
    do: complete(params, context, runtime, @modern)

  defp dispatch_modern("subscriptions/listen", params, context, runtime, _opts),
    do: listen(params, context, runtime)

  defp dispatch_modern("tasks/get", params, context, runtime, _opts),
    do: task_get(params, context, runtime, @modern)

  defp dispatch_modern("tasks/update", params, context, runtime, _opts),
    do: task_update(params, context, runtime, @modern)

  defp dispatch_modern("tasks/cancel", params, context, runtime, _opts),
    do: task_cancel(params, context, runtime, @modern)

  defp dispatch_modern(method, _params, _context, _runtime, _opts)
       when method in ["tasks/list", "tasks/result"],
       do: {:error, Error.method_not_found(method)}

  defp dispatch_modern(method, _params, _context, _runtime, _opts),
    do: {:error, Error.method_not_found(method)}

  defp dispatch_legacy("ping", _params, _context, _runtime, _opts), do: {:ok, %{}}

  defp dispatch_legacy("logging/setLevel", params, context, runtime, _opts),
    do: set_logging_level(params, context, runtime)

  defp dispatch_legacy("resources/subscribe", params, context, runtime, _opts),
    do: resource_subscription(params, context, runtime, :subscribe)

  defp dispatch_legacy("resources/unsubscribe", params, context, runtime, _opts),
    do: resource_subscription(params, context, runtime, :unsubscribe)

  defp dispatch_legacy("tools/list", params, context, runtime, _opts),
    do: list_result(runtime.registry, :tool, params, context, @legacy, "tools", runtime.opts)

  defp dispatch_legacy("resources/list", params, context, runtime, _opts),
    do:
      list_result(
        runtime.registry,
        :resource,
        params,
        context,
        @legacy,
        "resources",
        runtime.opts
      )

  defp dispatch_legacy("resources/templates/list", params, context, runtime, _opts),
    do:
      list_result(
        runtime.registry,
        :template,
        params,
        context,
        @legacy,
        "resourceTemplates",
        runtime.opts
      )

  defp dispatch_legacy("prompts/list", params, context, runtime, _opts),
    do: list_result(runtime.registry, :prompt, params, context, @legacy, "prompts", runtime.opts)

  defp dispatch_legacy("tools/call", params, context, runtime, opts),
    do: call_tool(params, context, runtime, opts, @legacy)

  defp dispatch_legacy("resources/read", params, context, runtime, opts),
    do: read_resource(params, context, runtime, opts, @legacy)

  defp dispatch_legacy("prompts/get", params, context, runtime, opts),
    do: get_prompt(params, context, runtime, opts, @legacy)

  defp dispatch_legacy("completion/complete", params, context, runtime, _opts),
    do: complete(params, context, runtime, @legacy)

  defp dispatch_legacy("tasks/get", params, context, runtime, _opts),
    do: task_get(params, context, runtime, @legacy)

  defp dispatch_legacy("tasks/result", params, context, runtime, _opts),
    do: task_get(params, context, runtime, @legacy)

  defp dispatch_legacy("tasks/cancel", params, context, runtime, _opts),
    do: task_cancel(params, context, runtime, @legacy)

  defp dispatch_legacy(method, _params, _context, _runtime, _opts),
    do: {:error, Error.method_not_found(method, 200)}

  defp lifecycle_initialize_allowed?(opts, context, params) do
    case opts[:initialize_callback] do
      nil ->
        true

      callback when is_function(callback, 2) ->
        try do
          callback.(context, params) == :ok
        rescue
          _ -> false
        catch
          _, _ -> false
        end

      callback when is_function(callback, 1) ->
        try do
          callback.(context) == :ok
        rescue
          _ -> false
        catch
          _, _ -> false
        end

      _ ->
        false
    end
  end

  defp set_logging_level(%{"level" => level}, context, runtime) when level in @log_levels do
    case context[:session_id] do
      session_id when is_binary(session_id) ->
        case set_session_logging_level(
               runtime.server,
               session_id,
               principal(context),
               tenant(context),
               level
             ) do
          :ok ->
            {:ok, %{}}

          {:error, :not_found} ->
            {:error, Error.invalid_request(%{"reason" => "session_not_found"})}
        end

      _ ->
        {:ok, %{}}
    end
  end

  defp set_logging_level(_params, _context, _runtime),
    do: {:error, Error.invalid_params(%{"reason" => "invalid_log_level"})}

  defp resource_subscription(%{"uri" => uri}, context, runtime, operation)
       when is_binary(uri) do
    result =
      case operation do
        :subscribe ->
          subscribe_resource(
            runtime.server,
            context[:session_id],
            principal(context),
            tenant(context),
            uri
          )

        :unsubscribe ->
          unsubscribe_resource(
            runtime.server,
            context[:session_id],
            principal(context),
            tenant(context),
            uri
          )
      end

    case result do
      :ok -> {:ok, %{}}
      _ -> {:error, Error.invalid_params(%{"reason" => "session_not_found"})}
    end
  end

  defp resource_subscription(_params, _context, _runtime, _operation),
    do: {:error, Error.invalid_params(%{"reason" => "uri_required"})}

  defp list_result(registry, type, params, context, era, key, opts) do
    values = Registry.list(registry, type) |> Enum.filter(&visible?(&1, context))
    page = page(values, params["cursor"], context, era, opts, registry)

    if page[:error] do
      {:error, page.error}
    else
      definitions =
        Enum.map(page.items, &public_definition(type, &1, context[:protocol_version]))

      if Schema.json_value(definitions) == :ok do
        result = %{key => definitions}
        result = if era == @modern, do: Map.put(result, "resultType", "complete"), else: result

        {:ok, result |> maybe_put_cursor(page.cursor) |> maybe_cache(era, opts, context)}
      else
        {:error, Error.internal(%{"reason" => "invalid_catalog"})}
      end
    end
  end

  defp page(values, nil, context, era, opts, registry) do
    page_size = page_size(opts)
    cursor_opts = cursor_options(values, context, era, opts, registry, page_size)

    %{
      items: Enum.take(values, page_size),
      cursor:
        if(length(values) > page_size,
          do: Cursor.issue(page_size, principal(context), era, cursor_opts)
        )
    }
  end

  defp page(values, cursor, context, era, opts, registry) do
    page_size = page_size(opts)
    cursor_opts = cursor_options(values, context, era, opts, registry, page_size)

    case Cursor.verify(cursor, principal(context), era, cursor_opts) do
      {:ok, position} when is_integer(position) ->
        %{
          items: values |> Enum.drop(position) |> Enum.take(page_size),
          cursor:
            if(position + page_size < length(values),
              do: Cursor.issue(position + page_size, principal(context), era, cursor_opts)
            )
        }

      _ ->
        %{items: [], cursor: nil, error: Error.invalid_params(%{"reason" => "invalid_cursor"})}
    end
  end

  defp cursor_options(values, context, era, opts, registry, page_size) do
    [
      secret: opts[:cursor_secret],
      ttl: opts[:cursor_ttl],
      tenant: tenant(context),
      scopes: Map.get(context, :scopes, Map.get(context, "scopes", [])) || [],
      visibility: Enum.map(values, & &1.identity),
      revision: Registry.revision(registry),
      page_size: page_size,
      version: era
    ]
  end

  defp page_size(opts),
    do:
      if(is_integer(opts[:page_size]) and opts[:page_size] in 1..100,
        do: opts[:page_size],
        else: 100
      )

  defp maybe_put_cursor(result, nil), do: result
  defp maybe_put_cursor(result, position), do: Map.put(result, "nextCursor", position)

  defp maybe_cache(result, @modern, opts, context),
    do: Map.merge(result, cache_fields(opts, context))

  defp maybe_cache(result, _, _, _), do: result

  defp call_tool(params, context, runtime, opts, era) do
    name = params["name"]
    arguments = params["arguments"] || %{}
    salient = Map.drop(params, ["requestState", "inputResponses"])
    operation = %{"tool" => name}

    with true <- is_binary(name) and is_map(arguments),
         :ok <- require_task_capability(params, runtime.opts, era),
         {:ok, state_payload} <-
           verify_retry_state(
             params,
             context,
             era,
             "tools/call",
             salient,
             operation,
             runtime.opts
           ),
         :ok <- validate_input_responses(state_payload, params),
         :ok <- consume_retry_state(state_payload, runtime.opts) do
      call_tool_validated(
        params,
        context,
        runtime,
        opts,
        era,
        name,
        Map.merge(arguments, input_responses(params, state_payload)),
        salient,
        operation
      )
    else
      false -> {:error, Error.invalid_params(%{"reason" => "tool_arguments_invalid"})}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp verify_retry_state(
         %{"requestState" => state} = params,
         context,
         era,
         method,
         salient,
         operation,
         opts
       )
       when is_binary(state) and era == @modern do
    case RequestState.verify_payload(
           state,
           principal(context),
           tenant(context),
           era,
           method,
           salient,
           secret: opts[:request_state_secret],
           instance: opts[:request_state_instance],
           store: opts[:request_state_store],
           request_id: context[:request_id],
           operation_identity: operation,
           responses: input_responses(params),
           consume: false
         ) do
      {:ok, payload} -> {:ok, payload}
      _ -> {:error, Error.invalid_params(%{"reason" => "invalid_request_state"})}
    end
  end

  defp verify_retry_state(
         %{"requestState" => _},
         _context,
         _era,
         _method,
         _salient,
         _operation,
         _opts
       ),
       do: {:error, Error.invalid_params(%{"reason" => "invalid_request_state"})}

  defp verify_retry_state(_, _context, _era, _method, _salient, _operation, _opts), do: {:ok, nil}

  defp input_responses(%{"inputResponses" => responses}) when is_map(responses), do: responses
  defp input_responses(_), do: %{}

  defp input_responses(%{"inputResponses" => _}, nil), do: %{}
  defp input_responses(_params, nil), do: %{}

  defp input_responses(params, %{"k" => keys}), do: Map.take(input_responses(params), keys)
  defp input_responses(params, _), do: input_responses(params)

  defp consume_retry_state(nil, _opts), do: :ok

  defp consume_retry_state(payload, opts) do
    if RequestState.consume_payload(payload, store: opts[:request_state_store]),
      do: :ok,
      else: {:error, Error.invalid_params(%{"reason" => "invalid_request_state"})}
  end

  defp validate_input_responses(nil, params) do
    if Map.has_key?(params, "inputResponses"),
      do: {:error, Error.invalid_params(%{"reason" => "request_state_required"})},
      else: :ok
  end

  defp validate_input_responses(%{"q" => input_types}, params) when is_map(input_types) do
    responses = input_responses(params)

    Enum.reduce_while(input_types, :ok, fn {key, method}, :ok ->
      case Map.fetch(responses, key) do
        {:ok, response} ->
          if valid_input_response?(method, response), do: {:cont, :ok}, else: {:halt, :invalid}

        :error ->
          {:halt, :invalid}
      end
    end)
    |> case do
      :ok -> :ok
      :invalid -> {:error, Error.invalid_params(%{"reason" => "invalid_input_response"})}
    end
  end

  defp validate_input_responses(_payload, _params), do: :ok

  defp valid_input_response?("elicitation/create:url", response) when is_map(response) do
    response["action"] in ["accept", "decline", "cancel"] and
      not Map.has_key?(response, "content")
  end

  defp valid_input_response?("elicitation/create", response) when is_map(response) do
    action = response["action"]

    action in ["accept", "decline", "cancel"] and
      (action != "accept" or is_map(response["content"]))
  end

  defp valid_input_response?(%{"method" => "elicitation/create", "params" => params}, response)
       when is_map(response) and is_map(params) do
    action = response["action"]

    action in ["accept", "decline", "cancel"] and
      case {params["mode"] || "form", action} do
        {"url", _} ->
          not Map.has_key?(response, "content")

        {"form", "accept"} ->
          is_map(response["content"]) and
            Schema.validate(response["content"], params["requestedSchema"]) == :ok

        {"form", _} ->
          true

        _ ->
          false
      end
  end

  defp valid_input_response?("sampling/createMessage", response) when is_map(response) do
    response["role"] == "assistant" and valid_sampling_content?(response["content"]) and
      is_binary(response["model"]) and
      (is_nil(response["stopReason"]) or is_binary(response["stopReason"]))
  end

  defp valid_input_response?(%{"method" => "sampling/createMessage"}, response),
    do: valid_input_response?("sampling/createMessage", response)

  defp valid_input_response?("roots/list", response) when is_map(response) do
    is_list(response["roots"]) and Enum.all?(response["roots"], &valid_root_response?/1)
  end

  defp valid_input_response?(%{"method" => "roots/list"}, response),
    do: valid_input_response?("roots/list", response)

  defp valid_input_response?(_, _), do: false

  defp valid_sampling_content?(content) when is_map(content), do: valid_content_item?(content)

  defp valid_sampling_content?(content) when is_list(content),
    do: Enum.all?(content, &valid_content_item?/1)

  defp valid_sampling_content?(_), do: false

  defp valid_root_response?(%{"uri" => uri} = root) when is_binary(uri) do
    String.starts_with?(uri, "file://") and (is_nil(root["name"]) or is_binary(root["name"]))
  end

  defp valid_root_response?(_), do: false

  defp normalize_input_requests(input) do
    with {:ok, input} <- canonical_wire_value(input) do
      cond do
        is_map(input) and Map.has_key?(input, "method") ->
          normalize_input_entries([{"input_1", input}])

        is_map(input) ->
          input
          |> Enum.sort_by(fn {key, _value} -> key end)
          |> normalize_input_entries()

        is_list(input) ->
          input
          |> Enum.with_index(1)
          |> Enum.map(fn {value, index} -> {"input_#{index}", value} end)
          |> normalize_input_entries()

        true ->
          {:error, :invalid_input_requests}
      end
    else
      _ -> {:error, :invalid_input_requests}
    end
  end

  defp normalize_input_entries(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {key, request}, {:ok, acc} ->
      with true <- is_binary(key) and byte_size(key) in 1..128,
           {:ok, request} <- normalize_input_request(request),
           false <- Map.has_key?(acc, key) do
        {:cont, {:ok, Map.put(acc, key, request)}}
      else
        _ -> {:halt, {:error, :invalid_input_requests}}
      end
    end)
  end

  defp normalize_input_request(request) when is_map(request) do
    with {:ok, request} <- canonical_wire_value(request),
         method when method in ["elicitation/create", "sampling/createMessage", "roots/list"] <-
           request["method"],
         params when is_map(params) <- Map.get(request, "params", %{}),
         :ok <- validate_input_request_json(method, params),
         true <- valid_input_request_params?(method, params) do
      {:ok, %{"method" => method, "params" => params}}
    else
      _ -> {:error, :invalid_input_request}
    end
  end

  defp normalize_input_request(_), do: {:error, :invalid_input_request}

  defp valid_input_request_params?("elicitation/create", params) do
    message = params["message"]
    mode = params["mode"] || "form"

    is_binary(message) and byte_size(message) in 1..10_000 and
      ((mode == "form" and valid_requested_schema?(params["requestedSchema"])) or
         (mode == "url" and is_binary(params["url"]) and
            Schema.validate(params["url"], %{"type" => "string", "format" => "uri"}) == :ok))
  end

  defp valid_input_request_params?("sampling/createMessage", params) do
    is_list(params["messages"]) and
      Enum.all?(params["messages"], fn message ->
        is_map(message) and message["role"] in ["user", "assistant"] and
          valid_sampling_content?(message["content"])
      end)
  end

  defp valid_input_request_params?("roots/list", _params), do: true

  defp valid_requested_schema?(schema) when is_map(schema) do
    properties = schema["properties"] || %{}
    required = schema["required"] || []

    Schema.validate_schema(schema) == :ok and schema["type"] == "object" and
      is_map(properties) and is_list(required) and
      Enum.all?(required, &(is_binary(&1) and Map.has_key?(properties, &1))) and
      Enum.all?(properties, fn {name, property} ->
        is_binary(name) and valid_requested_property_schema?(property)
      end)
  end

  defp valid_requested_schema?(_), do: false

  defp valid_requested_property_schema?(schema) when is_map(schema) do
    schema["type"] in ["string", "number", "integer", "boolean"] and
      Schema.validate_schema(schema) == :ok and
      not Map.has_key?(schema, "properties") and not Map.has_key?(schema, "items")
  end

  defp valid_requested_property_schema?(_), do: false

  defp validate_input_request_json(_method, params) when is_map(params) do
    if json_value?(params), do: :ok, else: {:error, :invalid_input_request}
  end

  defp require_input_capabilities(params, requests) do
    capabilities = get_in(params, ["_meta", "io.modelcontextprotocol/clientCapabilities"]) || %{}

    {supported, missing} =
      Enum.split_with(requests, fn {_key, %{"method" => method}} ->
        capability = input_capability(method)
        Map.has_key?(capabilities, capability)
      end)

    cond do
      supported != [] ->
        {:ok, Map.new(supported)}

      missing == [] ->
        {:ok, %{}}

      true ->
        required =
          missing
          |> Enum.map(fn {_key, %{"method" => method}} -> {input_capability(method), %{}} end)
          |> Map.new()

        {:error, Error.missing_capability(%{"requiredCapabilities" => required})}
    end
  end

  defp input_capability("elicitation/create"), do: "elicitation"
  defp input_capability("sampling/createMessage"), do: "sampling"
  defp input_capability("roots/list"), do: "roots"

  defp input_request_types(requests) do
    Map.new(requests, fn {key, %{"method" => method, "params" => params}} ->
      {key, %{"method" => method, "params" => params}}
    end)
  end

  defp modern_result(result) do
    case {Schema.json_value(result), Schema.validate_modern_result(result)} do
      {:ok, :ok} -> {:ok, result}
      _ -> {:error, Error.internal(%{"reason" => "invalid_modern_result"})}
    end
  end

  defp call_tool_validated(
         params,
         context,
         runtime,
         opts,
         era,
         name,
         arguments,
         salient,
         operation
       ) do
    case Registry.list(runtime.registry, :tool)
         |> Enum.find(&(&1.name == name and visible?(&1, context))) do
      nil ->
        {:error, Error.invalid_params(%{"reason" => "unknown_tool", "name" => name})}

      tool ->
        with :ok <- Schema.validate(arguments, tool.input_schema),
             result <- invoke(tool.handler, arguments, context, opts) do
          case result do
            {:input_required, input} when era == @modern ->
              with {:ok, requests} <- normalize_input_requests(input),
                   {:ok, requests} <- require_input_capabilities(params, requests) do
                state =
                  RequestState.issue(
                    principal(context),
                    tenant(context),
                    era,
                    "tools/call",
                    salient,
                    secret: runtime.opts[:request_state_secret],
                    instance: runtime.opts[:request_state_instance],
                    ttl: runtime.opts[:request_state_ttl],
                    request_id: context[:request_id],
                    operation_identity: operation,
                    input_keys: Map.keys(requests),
                    input_types: input_request_types(requests)
                  )

                Telemetry.execute([:mrtr, :round], %{count: 1}, %{method: "tools/call"})

                modern_result(%{
                  "resultType" => "input_required",
                  "inputRequests" => requests,
                  "requestState" => state
                })
              else
                {:error, :invalid_input_requests} ->
                  {:error, Error.invalid_params(%{"reason" => "invalid_input_requests"})}

                {:error, %Error{} = error} ->
                  {:error, error}
              end

            {:ok, output_value} ->
              output = normalize_tool_result(output_value)
              output = if era == @legacy, do: legacy_tool_result(output), else: output
              output = filter_tool_result_revision(output, context[:protocol_version])

              output =
                if tool.output_schema && Map.has_key?(output, "structuredContent"),
                  do: validate_output(output, tool.output_schema),
                  else: output

              if valid_tool_result?(output) do
                {:ok,
                 Map.merge(
                   output,
                   if(era == @modern, do: %{"resultType" => "complete"}, else: %{})
                 )}
              else
                {:ok,
                 %{
                   "content" => [%{"type" => "text", "text" => "tool output was invalid"}],
                   "isError" => true,
                   "resultType" => if(era == @modern, do: "complete", else: nil)
                 }
                 |> drop_nil()}
              end

            {:error, %Error{} = error} ->
              {:error, error}

            {:error, _reason} ->
              {:ok,
               %{
                 "content" => [%{"type" => "text", "text" => "tool execution failed"}],
                 "isError" => true,
                 "resultType" => if(era == @modern, do: "complete", else: nil)
               }
               |> drop_nil()}
          end
        else
          {:error, %Error{} = error} ->
            {:error, error}

          {:error, _reason} ->
            {:error, Error.invalid_params(%{"reason" => "tool_arguments_invalid"})}
        end
    end
  end

  defp read_resource(params, context, runtime, _opts, era) do
    uri = params["uri"]
    salient = Map.drop(params, ["requestState", "inputResponses"])
    operation = %{"resource" => uri}

    with {:ok, state_payload} <-
           verify_retry_state(
             params,
             context,
             era,
             "resources/read",
             salient,
             operation,
             runtime.opts
           ),
         :ok <- validate_input_responses(state_payload, params),
         :ok <- consume_retry_state(state_payload, runtime.opts) do
      read_resource_validated(
        params,
        context,
        runtime,
        era,
        uri,
        salient,
        operation,
        state_payload
      )
    end
  end

  defp read_resource_validated(
         params,
         context,
         runtime,
         era,
         uri,
         salient,
         operation,
         state_payload
       ) do
    if is_binary(uri) and safe_uri?(uri) do
      case locate_resource(runtime.registry, uri, context) do
        nil ->
          {:error,
           if(era == @modern,
             do: Error.invalid_params(%{"uri" => uri}),
             else: Error.legacy_resource_not_found(uri)
           )}

        {resource, template_params} ->
          case invoke(
                 resource.handler,
                 Map.merge(
                   %{uri: uri, params: template_params},
                   input_responses(params, state_payload)
                 ),
                 context,
                 []
               ) do
            {:input_required, input} when era == @modern ->
              with {:ok, requests} <- normalize_input_requests(input),
                   {:ok, requests} <- require_input_capabilities(params, requests) do
                request_state =
                  RequestState.issue(
                    principal(context),
                    tenant(context),
                    era,
                    "resources/read",
                    salient,
                    secret: runtime.opts[:request_state_secret],
                    instance: runtime.opts[:request_state_instance],
                    ttl: runtime.opts[:request_state_ttl],
                    request_id: context[:request_id],
                    operation_identity: operation,
                    input_keys: Map.keys(requests),
                    input_types: input_request_types(requests)
                  )

                Telemetry.execute([:mrtr, :round], %{count: 1}, %{method: "resources/read"})

                modern_result(%{
                  "resultType" => "input_required",
                  "inputRequests" => requests,
                  "requestState" => request_state
                })
              else
                {:error, :invalid_input_requests} ->
                  {:error, Error.invalid_params(%{"reason" => "invalid_input_requests"})}

                {:error, %Error{} = error} ->
                  {:error, error}
              end

            {:ok, content} ->
              normalized = normalize_resource_contents(content)

              normalized =
                if era == @legacy, do: Map.delete(normalized, "resultType"), else: normalized

              normalized =
                filter_resource_result_revision(normalized, context[:protocol_version])

              if valid_resource_result?(normalized) do
                {:ok,
                 Map.merge(
                   normalized,
                   if(era == @modern,
                     do:
                       Map.merge(
                         %{"resultType" => "complete"},
                         cache_fields(runtime.opts, context)
                       ),
                     else: %{}
                   )
                 )}
              else
                {:error, Error.internal(%{"reason" => "invalid_resource_result"})}
              end

            {:error, _reason} ->
              {:error, Error.internal(%{"reason" => "resource_handler_failure"})}
          end
      end
    else
      {:error, Error.invalid_params(%{"reason" => "unsafe_resource_uri"})}
    end
  end

  defp locate_resource(registry, uri, context) do
    case Registry.list(registry, :resource)
         |> Enum.find(&(&1.uri == uri and visible?(&1, context))) do
      nil ->
        Registry.list(registry, :template)
        |> Enum.find_value(fn template ->
          if visible?(template, context) do
            case match_uri_template(template.uri_template, uri) do
              {:ok, params} -> {template, params}
              :error -> nil
            end
          end
        end)

      resource ->
        {resource, %{}}
    end
  end

  # URI-template matching is deliberately bounded and only accepts layouts that
  # the registration validator declares supported. A reverse matcher must not
  # guess when a query key is ambiguous or when decoding changes path safety.
  defp match_uri_template(template, uri) when is_binary(template) and is_binary(uri) do
    if String.valid?(template) and String.valid?(uri) and
         byte_size(uri) <= @max_template_uri_bytes do
      case Regex.run(~r/\{([^{}]+)\}/, template, capture: :all_but_first) do
        [expression] -> match_single_template(template, uri, expression)
        _ -> :error
      end
    else
      :error
    end
  rescue
    _ -> :error
  end

  defp match_single_template(template, uri, expression) do
    marker = "{" <> expression <> "}"

    case String.split(template, marker, parts: 2) do
      [prefix, suffix] ->
        with true <- String.starts_with?(uri, prefix),
             remainder <- binary_part(uri, byte_size(prefix), byte_size(uri) - byte_size(prefix)),
             true <- suffix == "" or String.ends_with?(remainder, suffix),
             value <-
               if(suffix == "", do: remainder, else: remove_template_suffix(remainder, suffix)),
             {:ok, operator, specs} <- parse_template_expression(expression) do
          if operator == ?? do
            match_query_template(prefix, value, specs)
          else
            match_path_template(value, operator, specs)
          end
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp remove_template_suffix(value, suffix) do
    binary_part(value, 0, byte_size(value) - byte_size(suffix))
  end

  defp parse_template_expression(expression) when is_binary(expression) do
    {operator, variables} =
      case expression do
        <<operator, rest::binary>> when operator in [?+, ??] -> {operator, rest}
        _ -> {nil, expression}
      end

    specs = String.split(variables, ",", trim: false)

    parsed_specs = Enum.map(specs, &parse_template_varspec/1)

    if variables != "" and Enum.all?(parsed_specs, &is_map/1) do
      {:ok, operator, parsed_specs}
    else
      :error
    end
  end

  defp parse_template_varspec(spec) when is_binary(spec) do
    {base, explode} =
      if String.ends_with?(spec, "*"),
        do: {String.trim_trailing(spec, "*"), true},
        else: {spec, false}

    case Regex.run(~r/^([A-Za-z][A-Za-z0-9_.]*)(?::([1-9][0-9]{0,3}))?$/, base,
           capture: :all_but_first
         ) do
      [name] -> %{name: name, prefix: nil, explode: explode}
      [name, prefix] -> %{name: name, prefix: String.to_integer(prefix), explode: explode}
      _ -> :error
    end
  end

  defp parse_template_varspec(_), do: :error

  defp match_path_template(value, operator, [spec]) when operator in [nil, ?+] do
    if value == "" or byte_size(value) > @max_template_value_bytes or
         (operator == nil and String.contains?(value, ["/", "?", "#"])) do
      :error
    else
      with {:ok, decoded} <- strict_template_decode(value, :path),
           false <- unsafe_template_value?(decoded),
           true <- prefix_length_ok?(decoded, spec.prefix) do
        {:ok, %{spec.name => decoded}}
      else
        _ -> :error
      end
    end
  end

  defp match_path_template(_value, _operator, _specs), do: :error

  defp prefix_length_ok?(_value, nil), do: true
  defp prefix_length_ok?(value, prefix), do: String.length(value) <= prefix

  defp match_query_template(_prefix, query, specs) do
    with true <- String.starts_with?(query, "?") or String.starts_with?(query, "&"),
         raw_query <- binary_part(query, 1, byte_size(query) - 1),
         {:ok, pairs} <- parse_template_query(raw_query),
         {:ok, parsed} <- decode_query_pairs(pairs),
         {:ok, values} <- query_values(parsed, specs) do
      {:ok, values}
    else
      _ -> :error
    end
  end

  defp parse_template_query(raw_query)
       when is_binary(raw_query) and byte_size(raw_query) <= @max_template_uri_bytes do
    if raw_query == "" do
      :error
    else
      pairs = String.split(raw_query, "&", trim: false)

      if length(pairs) > @max_template_query_pairs or Enum.any?(pairs, &(&1 == "")) do
        :error
      else
        Enum.reduce_while(pairs, {:ok, []}, fn pair, {:ok, acc} ->
          case String.split(pair, "=", parts: 2) do
            [key, value] when key != "" -> {:cont, {:ok, [{key, value} | acc]}}
            _ -> {:halt, :error}
          end
        end)
        |> case do
          {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
          :error -> :error
        end
      end
    end
  end

  defp parse_template_query(_), do: :error

  defp decode_query_pairs(pairs) do
    Enum.reduce_while(pairs, {:ok, []}, fn {key, value}, {:ok, acc} ->
      with {:ok, key} <- strict_template_decode(key, :query),
           {:ok, value} <- strict_template_decode(value, :query),
           false <- unsafe_template_value?(key) or unsafe_template_value?(value) do
        {:cont, {:ok, [{key, value} | acc]}}
      else
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      :error -> :error
    end
  end

  defp query_values(pairs, specs) do
    if Enum.any?(specs, & &1.explode) do
      query_exploded_values(pairs, specs)
    else
      allowed = MapSet.new(specs, & &1.name)

      if Enum.all?(pairs, fn {key, _value} -> MapSet.member?(allowed, key) end) and
           unique_query_keys?(pairs) do
        {:ok, Map.new(pairs)}
      else
        :error
      end
    end
  end

  defp query_exploded_values(pairs, [%{name: name, explode: true}]) do
    cond do
      Enum.all?(pairs, fn {key, _value} -> key == name end) ->
        {:ok, %{name => Enum.map(pairs, &elem(&1, 1))}}

      Enum.any?(pairs, fn {key, _value} -> key == name end) ->
        :error

      unique_query_keys?(pairs) ->
        {:ok, %{name => Map.new(pairs)}}

      true ->
        :error
    end
  end

  defp query_exploded_values(_pairs, _specs), do: :error

  defp unique_query_keys?(pairs) do
    keys = Enum.map(pairs, &elem(&1, 0))
    length(keys) == MapSet.size(MapSet.new(keys))
  end

  defp strict_template_decode(value, mode) when is_binary(value) do
    if byte_size(value) > @max_template_value_bytes or
         Regex.match?(~r/%(?![0-9A-Fa-f]{2})/, value) do
      :error
    else
      source = if mode == :query, do: String.replace(value, "+", " "), else: value

      try do
        decoded = URI.decode(source)

        if String.valid?(decoded) and byte_size(decoded) <= @max_template_value_bytes do
          {:ok, decoded}
        else
          :error
        end
      rescue
        _ -> :error
      end
    end
  end

  defp strict_template_decode(_value, _mode), do: :error

  defp unsafe_template_value?(value),
    do: String.contains?(value, ["..", "\\", "\u0000", "\r", "\n"])

  defp get_prompt(params, context, runtime, _opts, era) do
    name = params["name"]
    arguments = params["arguments"] || %{}
    salient = Map.drop(params, ["requestState", "inputResponses"])
    operation = %{"prompt" => name}

    with true <- is_binary(name) and is_map(arguments),
         {:ok, state_payload} <-
           verify_retry_state(
             params,
             context,
             era,
             "prompts/get",
             salient,
             operation,
             runtime.opts
           ),
         :ok <- validate_input_responses(state_payload, params),
         :ok <- consume_retry_state(state_payload, runtime.opts) do
      case Registry.list(runtime.registry, :prompt)
           |> Enum.filter(&(&1.name == name and visible?(&1, context))) do
        [] ->
          {:error, Error.invalid_params(%{"name" => name})}

        [prompt | _] ->
          prompt_arguments = Map.merge(arguments, input_responses(params, state_payload))

          input_keys = if is_map(state_payload), do: Map.get(state_payload, "k", []), else: []

          case invoke_prompt(prompt, name, prompt_arguments, context, input_keys) do
            {:input_required, input} when era == @modern ->
              with {:ok, requests} <- normalize_input_requests(input),
                   {:ok, requests} <- require_input_capabilities(params, requests) do
                request_state =
                  RequestState.issue(
                    principal(context),
                    tenant(context),
                    era,
                    "prompts/get",
                    salient,
                    secret: runtime.opts[:request_state_secret],
                    instance: runtime.opts[:request_state_instance],
                    ttl: runtime.opts[:request_state_ttl],
                    request_id: context[:request_id],
                    operation_identity: operation,
                    input_keys: Map.keys(requests),
                    input_types: input_request_types(requests)
                  )

                Telemetry.execute([:mrtr, :round], %{count: 1}, %{method: "prompts/get"})

                modern_result(%{
                  "resultType" => "input_required",
                  "inputRequests" => requests,
                  "requestState" => request_state
                })
              else
                {:error, :invalid_input_requests} ->
                  {:error, Error.invalid_params(%{"reason" => "invalid_input_requests"})}

                {:error, %Error{} = error} ->
                  {:error, error}
              end

            {:ok, content} ->
              normalized = normalize_prompt_messages(content)

              normalized =
                if era == @legacy, do: Map.delete(normalized, "resultType"), else: normalized

              normalized = filter_prompt_result_revision(normalized, context[:protocol_version])

              if valid_prompt_result?(normalized) do
                {:ok,
                 Map.merge(
                   normalized,
                   if(era == @modern,
                     do:
                       Map.merge(
                         %{"resultType" => "complete"},
                         cache_fields(runtime.opts, context)
                       ),
                     else: %{}
                   )
                 )}
              else
                {:error, Error.internal(%{"reason" => "invalid_prompt_result"})}
              end

            {:error, %Error{} = error} ->
              {:error, error}

            {:error, _reason} ->
              {:error, Error.internal(%{"reason" => "prompt_handler_failure"})}
          end
      end
    else
      false -> {:error, Error.invalid_params(%{"reason" => "prompt_arguments_invalid"})}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp complete(params, context, runtime, era) do
    ref = params["ref"]
    argument = params["argument"]
    value = if is_map(argument), do: argument["value"], else: nil
    completion_context = params["context"]
    entries = Registry.list(runtime.registry, :completion) |> Enum.filter(&visible?(&1, context))

    cond do
      not valid_completion_ref_request?(ref) ->
        {:error, Error.invalid_params(%{"reason" => "completion_ref_required"})}

      not valid_completion_argument?(argument) ->
        {:error, Error.invalid_params(%{"reason" => "completion_argument_required"})}

      not valid_completion_context?(completion_context) ->
        {:error, Error.invalid_params(%{"reason" => "completion_context_invalid"})}

      true ->
        case Enum.find(entries, &completion_matches?(&1, ref)) do
          nil ->
            {:error, Error.invalid_params(%{"reason" => "unknown_completion_ref"})}

          entry ->
            completion_result(
              entry,
              ref,
              argument,
              value,
              completion_context || %{},
              context,
              era
            )
        end
    end
  end

  defp completion_result(entry, ref, argument, value, completion_context, context, era) do
    case invoke(
           entry.handler,
           %{ref: ref, argument: argument, value: value, context: completion_context},
           context,
           []
         ) do
      {:ok, result} ->
        result = canonical_output(result)
        {values, supplied_total, supplied_more} = completion_values(result)
        values = if is_list(values), do: Enum.uniq(values), else: values

        if is_list(values) and Enum.all?(values, &is_binary/1) and
             valid_completion_metadata?(supplied_total, supplied_more) and
             (is_nil(supplied_total) or supplied_total >= length(values)) do
          emitted = Enum.take(values, 100)
          total = supplied_total || length(values)
          has_more = supplied_more == true or total > length(emitted)

          response = %{
            "completion" => %{"values" => emitted, "total" => total, "hasMore" => has_more}
          }

          {:ok,
           if(era == @modern, do: Map.put(response, "resultType", "complete"), else: response)}
        else
          {:error, Error.internal(%{"reason" => "invalid_completion_result"})}
        end

      {:error, _reason} ->
        {:error, Error.internal(%{"reason" => "completion_handler_failure"})}

      _ ->
        {:error, Error.internal(%{"reason" => "invalid_completion_result"})}
    end
  end

  defp completion_values(%{"completion" => completion}) when is_map(completion),
    do: {completion["values"], completion["total"], completion["hasMore"]}

  defp completion_values(result) when is_map(result),
    do: {result["values"] || result[:values], result["total"], result["hasMore"]}

  defp completion_values(result), do: {result, nil, nil}

  defp valid_completion_metadata?(total, more) do
    (is_nil(total) or (is_integer(total) and total >= 0)) and
      (is_nil(more) or is_boolean(more))
  end

  defp completion_matches?(entry, ref) do
    registered = entry[:ref] || entry["ref"] || entry[:reference] || entry["reference"]

    is_map(registered) and is_map(ref) and registered["type"] == ref["type"] and
      case ref["type"] do
        "ref/prompt" -> registered["name"] == ref["name"]
        "ref/resource" -> registered["uri"] == ref["uri"]
        _ -> false
      end
  end

  defp valid_completion_ref_request?(%{"type" => "ref/prompt", "name" => name})
       when is_binary(name),
       do: name != ""

  defp valid_completion_ref_request?(%{"type" => "ref/resource", "uri" => uri})
       when is_binary(uri),
       do: safe_uri?(uri)

  defp valid_completion_ref_request?(_), do: false

  defp valid_completion_argument?(%{"name" => name, "value" => value})
       when is_binary(name) and is_binary(value),
       do: name != ""

  defp valid_completion_argument?(_), do: false

  defp valid_completion_context?(nil), do: true

  defp valid_completion_context?(context) when is_map(context) do
    case Map.get(context, "arguments") do
      nil ->
        true

      arguments when is_map(arguments) ->
        Enum.all?(arguments, fn {key, value} -> is_binary(key) and is_binary(value) end)

      _ ->
        false
    end
  end

  defp valid_completion_context?(_), do: false

  defp invoke_prompt(prompt, name, arguments, context, input_keys) do
    case validate_prompt_call_arguments(prompt.arguments, arguments, input_keys) do
      :ok ->
        invoke(prompt.handler, %{name: name, arguments: arguments}, context, [])

      {:error, _reason} ->
        {:error, Error.invalid_params(%{"reason" => "invalid_prompt_arguments"})}
    end
  end

  defp listen(params, context, runtime) do
    notifications = params["notifications"]

    if is_map(notifications) and map_size(notifications) > 0 and
         is_request_id(context[:request_id]) do
      case Subscriptions.open(
             runtime.subscriptions,
             principal(context),
             tenant(context),
             context[:request_id],
             notifications,
             context[:subscription_sink] || self(),
             context[:subscription_ref],
             context[:subscription_authorize]
           ) do
        {:ok, id} ->
          modern_result(%{
            "resultType" => "complete",
            "_meta" => %{"io.modelcontextprotocol/subscriptionId" => id}
          })

        {:error, _reason} ->
          {:error, Error.invalid_params(%{"reason" => "notifications_filter_invalid"})}
      end
    else
      {:error, Error.invalid_params(%{"reason" => "notifications_filter_required"})}
    end
  end

  defp is_request_id(id), do: is_binary(id) or is_integer(id)

  defp task_get(_params, _context, _runtime, era),
    do: {:error, Error.method_not_found("tasks/get", if(era == @modern, do: 404, else: 200))}

  defp task_cancel(_params, _context, _runtime, era),
    do: {:error, Error.method_not_found("tasks/cancel", if(era == @modern, do: 404, else: 200))}

  defp task_update(_params, _context, _runtime, era),
    do: {:error, Error.method_not_found("tasks/update", if(era == @modern, do: 404, else: 200))}

  defp require_task_capability(_params, _opts, _era), do: :ok

  defp visible?(definition, context) do
    required = definition[:required_scopes] || []
    scopes = Map.get(context, :scopes, Map.get(context, "scopes", [])) || []
    scopes_grant?(required, scopes) and authorize_callback(definition[:authorize], context)
  end

  defp scopes_grant?([], _granted), do: true

  defp scopes_grant?(required, granted) when is_list(required) and is_list(granted) do
    catalog = Attesto.Scope.new_catalog(required)
    Attesto.Scope.grants_all?(catalog, granted, required)
  rescue
    _ -> false
  end

  defp scopes_grant?(_, _), do: false

  defp authorize_callback(nil, _), do: true

  defp authorize_callback(callback, context) do
    result =
      cond do
        is_function(callback, 1) ->
          callback.(context)

        is_tuple(callback) and tuple_size(callback) == 2 ->
          apply(elem(callback, 0), elem(callback, 1), [context])

        is_tuple(callback) and tuple_size(callback) == 3 ->
          apply(elem(callback, 0), elem(callback, 1), elem(callback, 2) ++ [context])

        true ->
          false
      end

    result == true
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp public_definition(:tool, item) do
    %{
      "name" => item.name,
      "description" => item.description,
      "inputSchema" => item.input_schema,
      "annotations" => item.annotations
    }
    |> maybe_map_put("outputSchema", item.output_schema)
    |> maybe_map_put("title", item[:title] || item["title"])
    |> maybe_map_put("icons", item[:icons] || item["icons"])
    |> maybe_map_put("_meta", item[:_meta] || item["_meta"])
  end

  defp public_definition(:resource, item) do
    %{"uri" => item.uri, "name" => item.name, "annotations" => item.annotations}
    |> maybe_map_put("description", item[:description])
    |> maybe_map_put("mimeType", item.mime_type)
    |> maybe_map_put("title", item[:title] || item["title"])
    |> maybe_map_put("size", item[:size] || item["size"])
    |> maybe_map_put("icons", item[:icons] || item["icons"])
    |> maybe_map_put("_meta", item[:_meta] || item["_meta"])
  end

  defp public_definition(:template, item) do
    %{
      "uriTemplate" => item.uri_template,
      "name" => item.name,
      "description" => item.description,
      "annotations" => item.annotations
    }
    |> maybe_map_put("mimeType", item[:mime_type])
    |> maybe_map_put("title", item[:title] || item["title"])
    |> maybe_map_put("icons", item[:icons] || item["icons"])
    |> maybe_map_put("_meta", item[:_meta] || item["_meta"])
  end

  defp public_definition(:prompt, item) do
    %{
      "name" => item.name,
      "description" => item.description,
      "arguments" => item.arguments
    }
    |> maybe_map_put("title", item[:title] || item["title"])
    |> maybe_map_put("icons", item[:icons] || item["icons"])
    |> maybe_map_put("_meta", item[:_meta] || item["_meta"])
  end

  defp public_definition(type, item, @legacy_2025_06_18),
    do: type |> public_definition(item) |> Map.delete("icons")

  defp public_definition(type, item, _version), do: public_definition(type, item)

  defp invoke(nil, _params, context, _opts),
    do: invoke_with_telemetry(fn -> {:error, :missing_handler} end, context)

  defp invoke(fun, params, context, _opts) when is_function(fun, 2),
    do: invoke_with_telemetry(fn -> fun.(params, context) end, context)

  defp invoke(fun, params, context, _opts) when is_function(fun, 1),
    do: invoke_with_telemetry(fn -> fun.(params) end, context)

  defp invoke({module, function}, params, context, _opts),
    do: invoke_with_telemetry(fn -> apply(module, function, [params, context]) end, context)

  defp invoke({module, function, args}, params, context, _opts),
    do:
      invoke_with_telemetry(fn -> apply(module, function, [params, context | args]) end, context)

  defp invoke(_, _, context, _),
    do: invoke_with_telemetry(fn -> {:error, :invalid_handler} end, context)

  defp invoke_with_telemetry(callback, context) do
    Telemetry.span(
      :handler,
      %{
        method: Map.get(context, :method, "handler"),
        transport: Map.get(context, :transport, :core),
        correlation_id: telemetry_correlation(Map.get(context, :request_id))
      },
      fn ->
        result = normalize_handler_result(callback.())
        {result, %{outcome: handler_outcome(result)}}
      end
    )
  end

  defp handler_outcome({:ok, _}), do: :ok
  defp handler_outcome({:input_required, _}), do: :input_required
  defp handler_outcome({:error, _}), do: :error

  defp normalize_handler_result({:ok, value}), do: {:ok, value}
  defp normalize_handler_result({:input_required, value}), do: {:input_required, value}
  defp normalize_handler_result({:error, reason}), do: {:error, reason}
  defp normalize_handler_result(value), do: {:ok, value}

  defp normalize_tool_result(%{} = result) do
    case canonical_wire_value(result) do
      {:ok, %{"content" => _} = normalized} -> normalized
      {:ok, normalized} -> normalize_structured_tool_value(normalized)
      _ -> result
    end
  end

  defp normalize_tool_result(result) when is_binary(result),
    do: %{"content" => [%{"type" => "text", "text" => result}], "isError" => false}

  defp normalize_tool_result(result) when is_number(result) or is_boolean(result),
    do: %{
      "structuredContent" => result,
      "content" => [%{"type" => "text", "text" => to_string(result)}],
      "isError" => false
    }

  defp normalize_tool_result(result) when is_nil(result),
    do: %{
      "structuredContent" => nil,
      "content" => [%{"type" => "text", "text" => ""}],
      "isError" => false
    }

  defp normalize_tool_result(result),
    do: %{
      "structuredContent" => result,
      "content" => [%{"type" => "text", "text" => "structured output"}],
      "isError" => false
    }

  defp normalize_structured_tool_value(value),
    do: %{
      "structuredContent" => value,
      "content" => [%{"type" => "text", "text" => "structured output"}],
      "isError" => false
    }

  # The 2025 contract permits structuredContent only as an object.  Keep the
  # value available without emitting the modern-era scalar form.
  defp legacy_tool_result(%{"structuredContent" => value} = result) when not is_map(value),
    do: result |> Map.delete("resultType") |> Map.put("structuredContent", %{"value" => value})

  defp legacy_tool_result(result) when is_map(result), do: Map.delete(result, "resultType")

  defp normalize_resource_contents(value) do
    value = canonical_output(value)

    cond do
      is_map(value) and Map.has_key?(value, "contents") -> value
      is_list(value) -> %{"contents" => value}
      true -> %{"contents" => [value]}
    end
  end

  defp normalize_prompt_messages(value) do
    value = canonical_output(value)

    cond do
      is_map(value) and Map.has_key?(value, "messages") -> value
      is_list(value) -> %{"messages" => value}
      true -> %{"messages" => [value]}
    end
  end

  defp filter_tool_result_revision(result, @legacy_2025_06_18) when is_map(result) do
    map_list_field(result, "content", &filter_content_revision/1)
  end

  defp filter_tool_result_revision(result, _version), do: result

  defp filter_resource_result_revision(result, @legacy_2025_06_18) when is_map(result) do
    map_list_field(result, "contents", &drop_icons/1)
  end

  defp filter_resource_result_revision(result, _version), do: result

  defp filter_prompt_result_revision(result, @legacy_2025_06_18) when is_map(result) do
    map_list_field(result, "messages", fn
      %{"content" => content} = message ->
        Map.put(message, "content", filter_content_revision(content))

      message ->
        message
    end)
  end

  defp filter_prompt_result_revision(result, _version), do: result

  defp filter_content_revision(%{"type" => "resource_link"} = item), do: drop_icons(item)

  defp filter_content_revision(%{"type" => "resource", "resource" => resource} = item)
       when is_map(resource),
       do: Map.put(item, "resource", drop_icons(resource))

  defp filter_content_revision(item), do: item

  defp drop_icons(item) when is_map(item), do: Map.delete(item, "icons")
  defp drop_icons(item), do: item

  defp map_list_field(result, key, mapper) do
    case result[key] do
      values when is_list(values) -> Map.put(result, key, Enum.map(values, mapper))
      _ -> result
    end
  end

  defp valid_tool_result?(%{"content" => content} = result) when is_list(content) do
    json_value?(result) and
      is_boolean(Map.get(result, "isError", false)) and
      json_value?(Map.get(result, "structuredContent")) and
      Enum.all?(content, &valid_content_item?/1)
  end

  defp valid_tool_result?(_), do: false

  defp valid_resource_result?(%{"contents" => contents}) when is_list(contents),
    do: Enum.all?(contents, &valid_resource_entry?/1)

  defp valid_resource_result?(_), do: false

  defp valid_prompt_result?(%{"messages" => messages}) when is_list(messages) do
    json_value?(messages) and
      Enum.all?(messages, fn
        %{"role" => role, "content" => content}
        when role in ["user", "assistant"] ->
          valid_content_item?(content)

        _ ->
          false
      end)
  end

  defp valid_prompt_result?(_), do: false

  defp valid_content_item?(%{"type" => "text", "text" => text} = item) when is_binary(text),
    do: json_value?(item) and optional_annotations(item, "annotations")

  defp valid_content_item?(%{"type" => type, "data" => data, "mimeType" => mime} = item)
       when type in ["image", "audio"] and is_binary(data) and is_binary(mime),
       do:
         json_value?(item) and valid_base64?(data) and mime != "" and
           optional_annotations(item, "annotations")

  defp valid_content_item?(%{"type" => "resource_link", "uri" => uri, "name" => name} = item)
       when is_binary(uri) and is_binary(name),
       do:
         json_value?(item) and safe_uri?(uri) and optional_binary(item, "name") and
           optional_binary(item, "description") and optional_binary(item, "mimeType") and
           optional_annotations(item, "annotations")

  defp valid_content_item?(%{"type" => "resource", "resource" => resource} = item)
       when is_map(resource),
       do:
         json_value?(item) and optional_annotations(item, "annotations") and
           valid_resource_item?(resource)

  defp valid_content_item?(_), do: false

  defp valid_resource_item?(resource) when is_map(resource) do
    if not json_value?(resource) do
      false
    else
      if is_list(resource["contents"]) do
        Enum.all?(resource["contents"], &valid_resource_content?/1)
      else
        valid_resource_content?(resource)
      end
    end
  end

  defp valid_resource_content?(resource) when is_map(resource) do
    uri = resource["uri"]
    text = resource["text"]
    blob = resource["blob"]

    not Map.has_key?(resource, "contents") and is_binary(uri) and safe_uri?(uri) and
      is_nil(text) != is_nil(blob) and
      optional_binary(resource, "mimeType") and valid_optional_annotations(resource) and
      ((is_binary(text) and is_nil(blob)) or (is_binary(blob) and valid_base64?(blob)))
  end

  defp valid_resource_content?(_), do: false

  defp optional_binary(map, key) when is_map(map) do
    is_nil(Map.get(map, key)) or is_binary(Map.get(map, key))
  end

  defp optional_annotations(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      :error -> true
      {:ok, value} -> valid_annotations?(value)
    end
  end

  defp valid_optional_annotations(map) when is_map(map),
    do: optional_annotations(map, "annotations")

  defp valid_annotations?(value) when is_map(value) do
    json_value?(value) and
      (is_nil(value["audience"]) or
         (is_list(value["audience"]) and
            Enum.all?(value["audience"], &(&1 in ["user", "assistant"])))) and
      (is_nil(value["priority"]) or
         (is_number(value["priority"]) and value["priority"] >= 0 and value["priority"] <= 1)) and
      (is_nil(value["lastModified"]) or is_binary(value["lastModified"])) and
      Enum.all?(["readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint"], fn key ->
        not Map.has_key?(value, key) or is_boolean(value[key])
      end)
  end

  defp valid_annotations?(_), do: false

  defp json_value?(value), do: Schema.json_value(value) == :ok

  defp valid_resource_entry?(item), do: valid_resource_content?(item)

  defp valid_base64?(value) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, decoded} -> Base.encode64(decoded) == value
      :error -> false
    end
  rescue
    _ -> false
  end

  defp validate_prompt_call_arguments(definitions, arguments, input_keys)
       when is_list(definitions) and is_map(arguments) do
    allowed =
      definitions
      |> Enum.map(fn argument -> argument[:name] || argument["name"] end)
      |> MapSet.new()

    required =
      definitions
      |> Enum.filter(fn argument -> argument[:required] || argument["required"] end)
      |> Enum.map(fn argument -> argument[:name] || argument["name"] end)

    missing = Enum.reject(required, &Map.has_key?(arguments, &1))

    unknown =
      arguments
      |> Map.keys()
      |> Enum.reject(&(MapSet.member?(allowed, &1) or &1 in input_keys))

    invalid_values =
      Enum.any?(arguments, fn {key, value} ->
        not is_binary(key) or
          (key not in input_keys and not is_binary(value))
      end)

    cond do
      missing != [] -> {:error, {:missing, missing}}
      unknown != [] -> {:error, {:unknown, unknown}}
      invalid_values -> {:error, :invalid_argument_values}
      true -> :ok
    end
  end

  defp validate_prompt_call_arguments(_, _, _), do: {:error, :invalid_arguments}

  defp validate_output(output, schema) do
    case Schema.validate(output["structuredContent"], schema) do
      :ok ->
        output

      _ ->
        %{
          "content" => [%{"type" => "text", "text" => "tool output failed outputSchema"}],
          "isError" => true
        }
    end
  end

  defp safe_uri?(uri) do
    if is_binary(uri) and String.valid?(uri) and
         not String.contains?(uri, ["..", "\\", "\u0000", "\r", "\n"]) do
      try do
        parsed = URI.parse(uri)
        scheme = parsed.scheme
        host = parsed.host && String.downcase(parsed.host)

        valid_scheme? = is_binary(scheme) and byte_size(scheme) > 0
        safe_host? = host not in ["localhost", "127.0.0.1", "::1", "0.0.0.0"]

        (valid_scheme? or String.starts_with?(uri, "/")) and
          is_nil(parsed.userinfo) and safe_host?
      rescue
        _ -> false
      end
    else
      false
    end
  end

  defp capabilities(opts) do
    base = opts[:capabilities] || %{}

    base
    |> put_capability_defaults("tools", %{"listChanged" => true})
    |> put_capability_defaults("resources", %{"listChanged" => true})
    |> put_capability_defaults("prompts", %{"listChanged" => true})
    |> put_capability_defaults("completions", %{})
    |> remove_task_extensions()
  end

  defp legacy_capabilities(opts) do
    base = capabilities(opts)
    resources = Map.get(base, "resources", %{}) |> Map.put("subscribe", true)

    base
    |> Map.put("resources", resources)
    |> Map.put("logging", %{})
  end

  defp put_capability_defaults(capabilities, key, defaults) do
    current = Map.get(capabilities, key, Map.get(capabilities, String.to_atom(key), %{}))

    if is_map(current) do
      Map.put(capabilities, key, Map.merge(defaults, normalize_capability_map(current)))
    else
      Map.put(capabilities, key, defaults)
    end
  end

  defp normalize_capability_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Map.new()
  end

  defp remove_task_extensions(map) do
    extensions = Map.get(map, "extensions", Map.get(map, :extensions, %{}))

    if is_map(extensions) do
      extensions =
        extensions
        |> Map.delete("io.modelcontextprotocol/tasks")
        |> Map.delete(:"io.modelcontextprotocol/tasks")

      if map_size(extensions) == 0 do
        Map.delete(Map.delete(map, "extensions"), :extensions)
      else
        map
        |> Map.delete(:extensions)
        |> Map.put("extensions", extensions)
      end
    else
      Map.delete(Map.delete(map, "extensions"), :extensions)
    end
  end

  defp server_info(opts),
    do: %{
      "name" => opts[:server_name] || "attesto_mcp_server",
      "version" => opts[:server_version] || "0.9.0"
    }

  defp cache_ttl(opts), do: max(opts[:cache_ttl_ms] || 30_000, 0)

  defp cache_scope(opts, context) do
    if opts[:cache_scope] == "public" and opts[:allow_public_cache] == true and
         Map.get(context, :public_catalog, false) == true,
       do: "public",
       else: "private"
  end

  defp cache_fields(opts, context) do
    scope = cache_scope(opts, context)
    Telemetry.execute([:cache, :choice], %{count: 1}, %{outcome: scope})
    %{"ttlMs" => cache_ttl(opts), "cacheScope" => scope}
  end

  defp principal(context),
    do: Map.get(context, :principal, Map.get(context, "principal", "anonymous"))

  defp tenant(context), do: Map.get(context, :tenant, Map.get(context, "tenant"))

  # Handler-produced protocol objects may use atom keys, but every value that
  # reaches a wire encoder must be a bounded JSON value.  Canonicalize only
  # keys (never arbitrary terms) and reject collisions such as :method plus
  # "method" rather than silently dropping one of them.
  defp canonical_wire_value(value) do
    case canonical_wire_value_bounded(value, 0, @max_output_nodes, 0) do
      {:ok, normalized, _left, _used} -> {:ok, normalized}
      error -> error
    end
  end

  defp canonical_wire_value_bounded(_value, depth, nodes, bytes)
       when depth > @max_output_depth or nodes <= 0 or bytes > @max_output_bytes,
       do: {:error, :not_json}

  defp canonical_wire_value_bounded(value, depth, nodes, bytes) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}, nodes - 1, bytes + 1}, fn {key, nested},
                                                                  {:ok, acc, left, used} ->
      with {:ok, key} <- canonical_wire_key(key),
           key_bytes <- byte_size(key),
           true <- used + key_bytes <= @max_output_bytes,
           {:ok, nested, left, used} <-
             canonical_wire_value_bounded(nested, depth + 1, left, used + key_bytes),
           false <- Map.has_key?(acc, key) do
        {:cont, {:ok, Map.put(acc, key, nested), left, used}}
      else
        _ -> {:halt, {:error, :not_json}}
      end
    end)
    |> case do
      {:ok, normalized, left, used} -> {:ok, normalized, left, used}
      error -> error
    end
  end

  defp canonical_wire_value_bounded(value, depth, nodes, bytes) when is_list(value) do
    Enum.reduce_while(value, {:ok, [], nodes - 1, bytes + 1}, fn item, {:ok, acc, left, used} ->
      case canonical_wire_value_bounded(item, depth + 1, left, used) do
        {:ok, item, left, used} -> {:cont, {:ok, [item | acc], left, used}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items, left, used} -> {:ok, Enum.reverse(items), left, used}
      error -> error
    end
  end

  defp canonical_wire_value_bounded(value, _depth, nodes, bytes)
       when is_binary(value) do
    if String.valid?(value) and bytes + byte_size(value) <= @max_output_bytes,
      do: {:ok, value, nodes - 1, bytes + byte_size(value)},
      else: {:error, :not_json}
  end

  defp canonical_wire_value_bounded(value, _depth, nodes, bytes) when is_integer(value) do
    scalar_bytes = byte_size(Integer.to_string(value))

    if bytes + scalar_bytes <= @max_output_bytes,
      do: {:ok, value, nodes - 1, bytes + scalar_bytes},
      else: {:error, :not_json}
  end

  defp canonical_wire_value_bounded(value, _depth, nodes, bytes)
       when is_boolean(value) or is_nil(value),
       do: {:ok, value, nodes - 1, bytes + 1}

  defp canonical_wire_value_bounded(value, _depth, nodes, bytes) when is_float(value) do
    if value == value and value <= 1.7976931348623157e308 and
         value >= -1.7976931348623157e308,
       do: {:ok, value, nodes - 1, bytes + 8},
       else: {:error, :not_json}
  end

  defp canonical_wire_value_bounded(_value, _depth, _nodes, _bytes), do: {:error, :not_json}

  defp canonical_wire_key(key) when is_binary(key), do: {:ok, key}
  defp canonical_wire_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp canonical_wire_key(_), do: {:error, :not_json}

  defp canonical_output(value) do
    case canonical_wire_value(value) do
      {:ok, normalized} -> normalized
      _ -> value
    end
  end

  defp drop_nil(map), do: Enum.reject(map, fn {_k, v} -> is_nil(v) end) |> Map.new()
  defp maybe_map_put(map, _key, nil), do: map
  defp maybe_map_put(map, key, value), do: Map.put(map, key, value)
end
