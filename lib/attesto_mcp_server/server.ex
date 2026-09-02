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
    HostCallback,
    JSONRPC,
    Output,
    Registry,
    RequestState,
    Result,
    Schema,
    ScopeMap,
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
    :request_store_external,
    :session_store
  ]
  @max_trace_state_bytes 4096
  @max_template_uri_bytes 4_096
  @max_template_value_bytes 2_048
  @max_template_query_pairs 32
  @max_template_expressions 16
  @max_template_variables 32
  @max_template_expression_bytes 128
  @max_template_match_steps 65_536
  @max_template_match_work 8_388_608
  @max_template_match_candidates 1_000
  @max_notifications_per_request 128
  @max_resource_subscription_uri_bytes 4_096
  @max_resource_subscriptions_per_session 128
  @max_rate_buckets 10_000
  @cluster_notification_version 2
  @legacy_cluster_notification_version 1
  @session_close_message_version 1
  @max_session_close_ids 128
  @max_session_close_key_bytes 256
  @max_session_cleanup_keys 1_000
  @max_active_session_page_size 1_000
  @session_close_reasons [:session_deleted, :session_expired]
  @max_cluster_resource_scope_sets 8
  @max_cluster_resource_scopes 128
  @max_cluster_scope_bytes 256
  @max_cluster_scopes_bytes 8_192
  @max_cluster_combined_scope_sets 64
  @max_cluster_combined_scope_memberships 2_048
  @max_cluster_combined_scope_bytes 131_072
  @log_levels ["debug", "info", "notice", "warning", "error", "critical", "alert", "emergency"]
  @traceparent_pattern ~r/^00-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})$/
  @primitive_types [:tool, :resource, :template, :prompt, :completion]
  @session_pg_scope AttestoMCP.Server.SessionCluster
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
    :max_json_bytes,
    :output_canonicalization,
    :tool_argument_keys,
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
    :default_scopes,
    :registrations,
    :session_store,
    :session_namespace,
    :session_clustered,
    :telemetry_metadata,
    :exception_reporter,
    :handler_task_init,
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
    :session_store_module,
    :session_store,
    :session_store_external,
    :session_store_monitor,
    :session_namespace,
    :session_cluster_group,
    :active,
    :rate_buckets,
    :legacy_streams,
    :client_requests,
    :definitions,
    :catalog_revision
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

  @doc "Returns a child spec whose id follows the optional registered server name."
  @spec child_spec(server_opts()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    id =
      case Keyword.get(opts, :name) do
        nil -> __MODULE__
        name when is_atom(name) -> name
        _other -> raise ArgumentError, ":name must be an atom when present"
      end

    %{
      id: id,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }
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
  def register(server, type, identity, definition),
    do: register_all(server, [{type, identity, definition}])

  @doc "Registers a bounded primitive batch atomically and coalesces catalog invalidations."
  @spec register_all(pid() | atom(), [Registry.registration()]) :: :ok | {:error, term()}
  def register_all(server, registrations) when is_list(registrations),
    do: GenServer.call(server, {:register_all, registrations})

  def register_all(_server, _registrations), do: {:error, :invalid_registrations}

  @doc "Atomically replaces the complete primitive catalog from one bounded batch."
  @spec replace_catalog(pid() | atom(), [Registry.registration()]) :: :ok | {:error, term()}
  def replace_catalog(server, registrations) when is_list(registrations),
    do: GenServer.call(server, {:replace_catalog, registrations})

  def replace_catalog(_server, _registrations), do: {:error, :invalid_registrations}

  @doc "Returns a deterministic registry snapshot."
  @spec snapshot(pid() | atom()) :: map()
  def snapshot(server), do: Registry.snapshot(GenServer.call(server, :registry))

  @doc "Dispatch one decoded request and return a correlated response/result."
  @spec dispatch(pid() | atom(), map(), context(), keyword()) :: term()
  def dispatch(server, request, context \\ %{}, opts \\ []) do
    runtime = GenServer.call(server, :runtime)
    id = Map.get(request, :id)
    method = Map.get(request, :method, "")
    principal = principal(context)

    if request.kind == :notification and method == "notifications/cancelled" and
         cancellation_notification_allowed?(opts) do
      request_id =
        get_in(request, [:params, "requestId"]) || get_in(request, [:params, "request_id"])

      cancel_request(server, principal, request_id, Keyword.get(opts, :owner))
      cancel_subscription(server, request_id, Keyword.get(opts, :owner) || self())

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

        request_metadata =
          request_telemetry_metadata(method, id, Keyword.merge(runtime.opts, opts))

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
                   progress_token = metadata_value(request.params, "progressToken")
                   progress = progress_callback(parent, ref, progress_token, on_event)

                   notification_context =
                     Map.put(context, :max_json_bytes, runtime.opts[:max_json_bytes])

                   notify =
                     notification_callback(
                       parent,
                       ref,
                       on_event,
                       era,
                       request,
                       notification_context,
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
                     |> Map.put(:max_json_bytes, runtime.opts[:max_json_bytes])
                     |> Map.put(
                       :output_canonicalization,
                       runtime.opts[:output_canonicalization]
                     )
                     |> Map.put(:tool_argument_keys, runtime.opts[:tool_argument_keys])
                     |> Map.put(:request_extensions, Map.get(request, :extensions, %{}))
                     |> Map.put_new(:protocol_version, raw_version)
                     |> Map.put(:logging_level, request_logging_level(request, context, era))
                     |> Map.put(:telemetry_metadata, runtime.opts[:telemetry_metadata])
                     |> Map.put(:exception_reporter, runtime.opts[:exception_reporter])

                   result =
                     try do
                       with :ok <-
                              run_handler_task_init(
                                runtime.opts[:handler_task_init],
                                parent,
                                task_context,
                                request_metadata,
                                runtime.opts[:exception_reporter]
                              ) do
                         handle_request(request, task_context, runtime, opts)
                       else
                         {:error, _reason} ->
                           {:error,
                            Error.internal(%{
                              "reason" => "handler_task_init_failure",
                              "type" => "handler_failure"
                            })}
                       end
                     catch
                       kind, reason ->
                         Telemetry.report_exception(
                           runtime.opts[:exception_reporter],
                           :request,
                           kind,
                           reason,
                           __STACKTRACE__,
                           request_metadata
                         )

                         {:error,
                          Error.internal(%{
                            "reason" => "handler_failure",
                            "type" => "handler_failure"
                          })}
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

  @doc false
  def peek_session(server, id, principal, tenant \\ nil),
    do: GenServer.call(server, {:peek_session, id, principal, tenant})

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
        System.monotonic_time(:millisecond) + timeout,
        true
      )

  @doc false
  def await_initialized_without_touch(server, id, principal, tenant, timeout \\ 50),
    do:
      await_initialized_until(
        server,
        id,
        principal,
        tenant,
        System.monotonic_time(:millisecond) + timeout,
        false
      )

  @doc "Binds an unnegotiated session to one enabled legacy protocol revision."
  @spec set_session_version(pid() | atom(), binary(), String.t()) ::
          :ok | {:error, :invalid_version | :session_store_unavailable}
  def set_session_version(server, id, version),
    do: GenServer.call(server, {:set_session_version, id, version})

  @doc "Returns bounded public counters for sessions, streams, subscriptions, and requests."
  @spec stats(pid() | atom()) :: map()
  def stats(server), do: GenServer.call(server, :stats)

  @doc "Returns one bounded page of active legacy session IDs for operator tooling."
  @spec active_session_ids(pid() | atom(), keyword()) ::
          {:ok, %{session_ids: [String.t()], next_cursor: String.t() | nil}}
          | {:error, :invalid_options | :session_store_unavailable | :unsupported}
  def active_session_ids(server, opts \\ []) do
    with {:ok, cursor, limit} <- normalize_active_session_page_options(opts) do
      GenServer.call(server, {:active_session_ids, cursor, limit})
    end
  end

  defp normalize_active_session_page_options(opts) when is_list(opts) do
    keys = if Keyword.keyword?(opts), do: Keyword.keys(opts), else: []

    if Keyword.keyword?(opts) and Enum.all?(keys, &(&1 in [:cursor, :limit])) and
         length(keys) == length(Enum.uniq(keys)) do
      cursor = Keyword.get(opts, :cursor)
      limit = Keyword.get(opts, :limit, 100)

      if (is_nil(cursor) or valid_active_session_cursor?(cursor)) and is_integer(limit) and
           limit in 1..@max_active_session_page_size,
         do: {:ok, cursor, limit},
         else: {:error, :invalid_options}
    else
      {:error, :invalid_options}
    end
  end

  defp normalize_active_session_page_options(_opts), do: {:error, :invalid_options}

  defp valid_active_session_cursor?(value) do
    is_binary(value) and byte_size(value) in 1..@max_session_close_key_bytes and
      String.valid?(value) and :binary.match(value, <<0>>) == :nomatch
  end

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

  @spec publish(pid() | atom(), map(), keyword()) :: :ok | {:error, atom()}
  def publish(server, notification, opts \\ []) do
    runtime = GenServer.call(server, :runtime)

    with {:ok, notification} <- normalize_public_notification(notification, runtime.opts),
         {:ok, opts} <- normalize_public_notification_opts(opts) do
      GenServer.call(server, {:publish_notification, notification, opts})
    else
      {:error, reason} = error ->
        Telemetry.execute([:notification, :reject], %{count: 1}, %{reason: reason})
        error
    end
  end

  defp normalize_public_notification_opts([]), do: {:ok, []}

  defp normalize_public_notification_opts([{:authorize, authorize}] = opts)
       when is_function(authorize, 1),
       do: {:ok, opts}

  defp normalize_public_notification_opts(_opts), do: {:error, :invalid_options}

  defp normalize_public_notification(%{"type" => type} = notification, opts)
       when type in [
              "toolsListChanged",
              "promptsListChanged",
              "resourcesListChanged",
              "resource",
              "resourceUpdated",
              "resourceSubscriptions"
            ] do
    params = Map.delete(notification, "type")

    budget_opts = json_budget_opts(opts)

    valid_params? =
      if type in ["resource", "resourceUpdated", "resourceSubscriptions"],
        do: validate_resource_updated_notification_params(params, budget_opts) == :ok,
        else: validate_catalog_notification_params(params, budget_opts) == :ok

    if valid_params? and Schema.json_value(notification, budget_opts) == :ok,
      do: {:ok, notification},
      else: {:error, :invalid_notification}
  end

  defp normalize_public_notification(_, _opts), do: {:error, :invalid_notification}

  defp publish_catalog_invalidation_state(state, type) do
    notification = catalog_notification(type)

    if notification do
      state = publish_notification_local(state, notification, [], :local, [[]])
      broadcast_cluster_notification(state, notification, [], [])

      state_telemetry(state, [:cache, :invalidation], %{count: 1}, %{
        method: "catalog",
        outcome: to_string(type)
      })

      state
    else
      state
    end
  catch
    _kind, _reason -> state
  end

  defp catalog_notification(:tool), do: %{"type" => "toolsListChanged"}
  defp catalog_notification(:prompt), do: %{"type" => "promptsListChanged"}

  defp catalog_notification(type) when type in [:resource, :template],
    do: %{"type" => "resourcesListChanged"}

  defp catalog_notification(_type), do: nil

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
          :ok
          | {:error,
             :invalid_negotiation
             | :already_negotiated
             | :not_found
             | :session_store_unavailable}
  def negotiate_session(server, session_id, principal, tenant, version, capabilities),
    do:
      GenServer.call(
        server,
        {:negotiate_session, session_id, principal, tenant, version, capabilities}
      )

  @spec session_capabilities(pid() | atom(), binary(), term(), term()) ::
          map() | {:error, :session_store_unavailable}
  def session_capabilities(server, session_id, principal, tenant),
    do: GenServer.call(server, {:session_capabilities, session_id, principal, tenant})

  @doc "Returns the negotiated minimum legacy log level for an owned session."
  @spec session_logging_level(pid() | atom(), binary(), term(), term()) ::
          String.t() | nil | {:error, :session_store_unavailable}
  def session_logging_level(server, session_id, principal, tenant),
    do: GenServer.call(server, {:session_logging_level, session_id, principal, tenant})

  @doc "Sets the negotiated minimum legacy log level for an owned session."
  @spec set_session_logging_level(pid() | atom(), binary(), term(), term(), String.t()) ::
          :ok | {:error, :not_found | :session_store_unavailable}
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

  def close_subscription(server, id), do: close_subscription(server, id, self())

  def close_subscription(server, id, owner) do
    try do
      Subscriptions.close(GenServer.call(server, :subscriptions), id, owner)
    catch
      :exit, _ -> :ok
    end
  end

  def cancel_subscription(server, id), do: cancel_subscription(server, id, self())

  def cancel_subscription(server, id, owner) do
    try do
      Subscriptions.cancel(GenServer.call(server, :subscriptions), id, owner)
    catch
      :exit, _ -> :ok
    end
  end

  def ack_subscription(server, id), do: ack_subscription(server, id, self())

  def ack_subscription(server, id, owner) do
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

    {:ok, registry} =
      Registry.start_link(max_json_bytes: normalized_opts[:max_json_bytes])

    normalized_registrations =
      case Registry.register_all(registry, normalized_opts[:registrations] || []) do
        {:ok, registrations} ->
          registrations

        {:error, reason} ->
          raise ArgumentError, ":registrations are invalid: #{inspect(reason)}"
      end

    {:ok, task_supervisor} =
      Task.Supervisor.start_link(max_children: normalized_opts[:max_concurrency])

    {:ok, tasks} = Tasks.start_link([])

    {:ok, subscriptions} =
      Subscriptions.start_link(
        max_queue:
          normalized_opts[:subscription_queue_size] || normalized_opts[:max_queue] ||
            @default_stream_queue,
        telemetry_metadata: normalized_opts[:telemetry_metadata]
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

    {session_store_module, session_store, session_store_external, session_store_monitor,
     session_namespace, session_cluster_group} = setup_session_store(normalized_opts)

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
       session_store_module: session_store_module,
       session_store: session_store,
       session_store_external: session_store_external,
       session_store_monitor: session_store_monitor,
       session_namespace: session_namespace,
       session_cluster_group: session_cluster_group,
       active: %{global: 0, principals: %{}, requests: %{}},
       rate_buckets: %{},
       legacy_streams: %{},
       client_requests: %{},
       catalog_revision: Registry.revision(registry),
       definitions:
         remember_definitions(
           Map.new(@primitive_types, &{&1, %{}}),
           normalized_registrations
         )
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
       sessions: session_count(state),
       legacy_streams: map_size(state.legacy_streams),
       client_requests: map_size(state.client_requests),
       active_requests: map_size(state.active.requests),
       active: state.active.global,
       rate_buckets: map_size(state.rate_buckets),
       subscriptions: subscription_stats.count,
       subscription_queue: subscription_stats.queued
     }, state}
  end

  def handle_call({:active_session_ids, cursor, limit}, _from, state) do
    if function_exported?(state.session_store_module, :list_active_keys, 4) do
      case safe_session_store_call(state, :list_active_keys, [
             state.session_namespace,
             cursor,
             limit
           ]) do
        {:ok, %{keys: keys, next_cursor: next_cursor}} ->
          if valid_active_session_page?(keys, next_cursor, cursor, limit) and
               Enum.all?(keys, fn {namespace, _id} -> namespace == state.session_namespace end) do
            {:reply,
             {:ok, %{session_ids: Enum.map(keys, &elem(&1, 1)), next_cursor: next_cursor}}, state}
          else
            {:reply, session_store_unavailable(state, :list_active_keys), state}
          end

        {:error, :session_store_unavailable} = error ->
          {:reply, error, state}
      end
    else
      {:reply, {:error, :unsupported}, state}
    end
  end

  def handle_call({:notification_scopes, notification}, _from, state) do
    {:reply, notification_scopes(state, notification), state}
  end

  def handle_call({:publish_notification, notification, opts}, _from, state) do
    case local_notification_scope_sets(state, notification) do
      {:ok, local_scope_sets} ->
        state =
          publish_notification_local(
            state,
            notification,
            opts,
            :local,
            local_scope_sets
          )

        broadcast_cluster_notification(state, notification, opts, local_scope_sets)
        {:reply, :ok, state}

      {:error, :template_match_budget_exhausted} ->
        template_match_budget_exhausted(:notification)
        {:reply, {:error, :template_match_budget_exhausted}, state}

      {:error, reason} ->
        Telemetry.execute([:notification, :reject], %{count: 1}, %{reason: reason})
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:register_all, registrations}, _from, state) do
    case Registry.register_all(state.registry, registrations) do
      {:ok, normalized} ->
        definitions = remember_definitions(state.definitions, normalized)

        state = %{
          state
          | definitions: definitions,
            catalog_revision: state.catalog_revision + length(normalized)
        }

        state =
          normalized
          |> registration_invalidations()
          |> Enum.reduce(state, &publish_catalog_invalidation_state(&2, &1))

        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:replace_catalog, registrations}, _from, state) do
    case Registry.replace_all(state.registry, registrations) do
      {:ok, definitions, affected_types} ->
        state = %{
          state
          | definitions: definitions,
            catalog_revision:
              if(affected_types == [],
                do: state.catalog_revision,
                else: state.catalog_revision + 1
              )
        }

        state =
          affected_types
          |> catalog_invalidations()
          |> Enum.reduce(state, &publish_catalog_invalidation_state(&2, &1))

        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:open_legacy_stream, session_id, principal, tenant, sink}, from, state),
    do: handle_call({:open_legacy_stream, session_id, principal, tenant, sink, nil}, from, state)

  def handle_call(
        {:open_legacy_stream, session_id, principal, tenant, sink, authorize},
        _from,
        state
      ) do
    case session_for(state, session_id, principal, tenant, require_initialized: true) do
      {:ok, _session} when is_pid(sink) ->
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

        case update_session(state, session_id, fn current ->
               if Session.same_principal?(current, principal) and
                    Session.same_tenant?(current, tenant),
                  do: {:ok, Session.touch(current)},
                  else: {:error, :not_found}
             end) do
          {:ok, _session} ->
            {:reply, {:ok, stream_ref}, put_in(state.legacy_streams[stream_ref], stream)}

          {:error, :session_store_unavailable} ->
            Process.demonitor(monitor, [:flush])
            {:reply, {:error, :session_store_unavailable}, state}

          _ ->
            Process.demonitor(monitor, [:flush])
            {:reply, {:error, :not_found}, state}
        end

      {:error, :session_store_unavailable} ->
        {:reply, {:error, :session_store_unavailable}, state}

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
            result =
              update_session(state, session_id, fn current ->
                cond do
                  not Session.same_principal?(current, principal) or
                      not Session.same_tenant?(current, tenant) ->
                    {:error, :not_found}

                  not is_nil(current.version) or current.initialized ->
                    {:error, :already_negotiated}

                  true ->
                    {:ok,
                     %{
                       Session.touch(current)
                       | version: version,
                         client_capabilities: capabilities
                     }}
                end
              end)

            case result do
              {:ok, _session} ->
                {:reply, :ok, state}

              {:error, :already_negotiated} ->
                {:reply, {:error, :already_negotiated}, state}

              {:error, :session_store_unavailable} ->
                {:reply, {:error, :session_store_unavailable}, state}

              _ ->
                {:reply, {:error, :not_found}, state}
            end
        end

      {:error, :session_store_unavailable} ->
        {:reply, {:error, :session_store_unavailable}, state}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:session_capabilities, session_id, principal, tenant}, _from, state) do
    case session_for(state, session_id, principal, tenant) do
      {:ok, session} ->
        {:reply, session.client_capabilities, state}

      {:error, :session_store_unavailable} ->
        {:reply, {:error, :session_store_unavailable}, state}

      _ ->
        {:reply, %{}, state}
    end
  end

  def handle_call({:session_logging_level, session_id, principal, tenant}, _from, state) do
    case session_for(state, session_id, principal, tenant) do
      {:ok, session} ->
        {:reply, session.logging_level, state}

      {:error, :session_store_unavailable} ->
        {:reply, {:error, :session_store_unavailable}, state}

      _ ->
        {:reply, nil, state}
    end
  end

  def handle_call(
        {:set_session_logging_level, session_id, principal, tenant, level},
        _from,
        state
      )
      when is_binary(level) do
    case session_for(state, session_id, principal, tenant) do
      {:ok, _session} ->
        case update_session(state, session_id, fn current ->
               if Session.same_principal?(current, principal) and
                    Session.same_tenant?(current, tenant),
                  do: {:ok, %{Session.touch(current) | logging_level: level}},
                  else: {:error, :not_found}
             end) do
          {:ok, _session} ->
            {:reply, :ok, state}

          {:error, :session_store_unavailable} ->
            {:reply, {:error, :session_store_unavailable}, state}

          _ ->
            {:reply, {:error, :not_found}, state}
        end

      {:error, :session_store_unavailable} ->
        {:reply, {:error, :session_store_unavailable}, state}

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
        case session_owned?(state, session_id, principal, tenant) do
          :ok when request.principal == principal and request.tenant == tenant ->
            case validate_client_response(request.method, response, request.params, state.opts) do
              {:ok, result} ->
                send(request.waiter, {request_ref, {:response, {:ok, result}}})

                {:reply, :ok, remove_client_request(state, request_ref, request)}

              {:error, {:client_error, _error} = client_error} ->
                send(request.waiter, {request_ref, {:response, {:error, client_error}}})

                {:reply, {:error, client_error},
                 remove_client_request(state, request_ref, request)}

              {:error, :invalid_response} ->
                send(request.waiter, {request_ref, {:response, {:error, :invalid_response}}})

                {:reply, {:error, :invalid_response},
                 remove_client_request(state, request_ref, request)}
            end

          :session_store_unavailable ->
            {:reply, {:error, :session_store_unavailable}, state}

          _ ->
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
      false ->
        {:reply, {:error, :missing_capability}, state}

      nil ->
        {:reply, {:error, :unsupported}, state}

      {:error, :unsupported} ->
        {:reply, {:error, :unsupported}, state}

      {:error, :session_store_unavailable} ->
        {:reply, {:error, :session_store_unavailable}, state}

      :stream_not_ready ->
        {:reply, {:error, :not_ready}, state}

      _ ->
        {:reply, {:error, :not_ready}, state}
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
      {:ok, _session} ->
        with :ok <- validate_resource_subscription_uri(uri) do
          result =
            update_session(state, session_id, fn current ->
              if Session.same_principal?(current, principal) and
                   Session.same_tenant?(current, tenant) do
                with {:ok, current_subscriptions} <-
                       update_resource_subscriptions(
                         operation,
                         current.resource_subscriptions,
                         uri
                       ) do
                  {:ok,
                   %{
                     Session.touch(current)
                     | resource_subscriptions: current_subscriptions
                   }}
                end
              else
                {:error, :not_found}
              end
            end)

          case result do
            {:ok, _session} -> {:reply, :ok, state}
            {:error, reason} -> {:reply, {:error, reason}, state}
          end
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, :session_store_unavailable} ->
        {:reply, {:error, :session_store_unavailable}, state}

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
    case session_timeout_values(session_opts, state.opts) do
      {:ok, absolute_timeout, idle_timeout} ->
        session =
          Session.new(principal, tenant,
            absolute_timeout: absolute_timeout,
            idle_timeout: idle_timeout
          )

        case save_session(state, session) do
          :ok ->
            state_telemetry(
              state,
              [:session, :open],
              %{count: 1},
              %{transport: :core, outcome: :ok}
            )

            {:reply, {:ok, session}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get_session, id, principal, tenant}, _from, state) do
    {result, state} = lookup_session(state, id, principal, tenant, true)
    {:reply, result, state}
  end

  def handle_call({:peek_session, id, principal, tenant}, _from, state) do
    {result, state} = lookup_session(state, id, principal, tenant, false)
    {:reply, result, state}
  end

  def handle_call({:touch_session, id}, _from, state) do
    case touch_session_record(state, id) do
      {:ok, _session} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:mark_initialized, id}, _from, state) do
    case update_session(state, id, fn session ->
           {:ok, %{Session.touch(session) | initialized: true}}
         end) do
      {:ok, _session} -> {:reply, :ok, state}
      {:error, :not_found} -> {:reply, :ok, state}
      {:error, :unknown_record_version} -> {:reply, :ok, state}
      {:error, :binding_unavailable} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:set_session_version, id, version}, _from, state) do
    if version in @legacy_versions and version in state.opts[:protocol_versions] do
      case update_session(state, id, fn session ->
             if is_nil(session.version) or session.version == version,
               do: {:ok, %{Session.touch(session) | version: version}},
               else: {:error, :invalid_version}
           end) do
        {:ok, _session} ->
          {:reply, :ok, state}

        {:error, :session_store_unavailable} ->
          {:reply, {:error, :session_store_unavailable}, state}

        _ ->
          {:reply, {:error, :invalid_version}, state}
      end
    else
      {:reply, {:error, :invalid_version}, state}
    end
  end

  def handle_call({:delete_session, id}, _from, state) do
    case load_session(state, id) do
      {:ok, _session} ->
        delete_loaded_session(state, id, true)

      {:error, reason}
      when reason in [:not_found, :invalid_session_record, :unknown_record_version] ->
        # Deletion remains idempotent and also removes physically retained
        # expired or corrupt rows that are no longer loadable as sessions.
        # An explicit deletion request may also remove a future-version row;
        # ordinary ownership lookups never take this branch.
        delete_loaded_session(state, id, false)

      {:error, :binding_unavailable} ->
        # Explicit deletion remains idempotent and intentionally destructive,
        # even when this node cannot restore the persisted binding.
        delete_loaded_session(state, id, false)

      {:error, :session_store_unavailable} ->
        # Do not issue a second adapter call after an unavailable load. This
        # avoids reporting success from a different result and keeps the
        # failure event one-per-call.
        {:reply, {:error, :session_store_unavailable}, state}
    end
  end

  def handle_call(_request, _from, state), do: {:reply, {:error, :unsupported}, state}

  defp delete_loaded_session(state, id, existed) do
    case delete_session_record(state, id) do
      :ok ->
        if existed,
          do: state_telemetry(state, [:session, :close], %{count: 1}, %{outcome: :deleted})

        state = close_legacy_streams_for_session(state, id, :session_deleted)
        broadcast_session_close(state, :session_deleted, [id])
        {:reply, :ok, state}

      {:error, :session_store_unavailable} ->
        {:reply, {:error, :session_store_unavailable}, state}
    end
  end

  @impl true
  def handle_cast({:publish_legacy, notification}, state) do
    case local_notification_scope_sets(state, notification) do
      {:ok, local_scope_sets} ->
        {:noreply, publish_legacy(state, notification, local_scope_sets)}

      {:error, :template_match_budget_exhausted} ->
        template_match_budget_exhausted(:notification)
        {:noreply, state}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  def handle_cast({:cluster_publish, envelope}, state) do
    case cluster_notification(envelope, state.opts) do
      {:ok, notification, opts, publisher_scope_sets} ->
        case local_notification_scope_sets(state, notification) do
          {:ok, local_scope_sets} ->
            {:noreply,
             publish_notification_local(
               state,
               notification,
               opts,
               publisher_scope_sets,
               local_scope_sets
             )}

          {:error, :template_match_budget_exhausted} ->
            template_match_budget_exhausted(:notification)
            {:noreply, state}

          {:error, _reason} ->
            {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_cast({:cluster_publish, notification, opts}, state) do
    # Older peers did not send publisher resource scopes. Keep their validated
    # catalog invalidations working, but never guess at authorization metadata
    # for resource notifications.
    case normalize_public_notification(notification, state.opts) do
      {:ok, notification} ->
        with false <- resource_notification?(notification),
             {:ok, opts} <- validate_cluster_notification_opts(opts) do
          {:noreply, publish_notification_local(state, notification, opts, [], [[]])}
        else
          _ -> {:noreply, state}
        end

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  def handle_cast({:cluster_session_close, envelope}, state) do
    case cluster_session_close(envelope, state) do
      {:ok, reason, ids} ->
        {:noreply, Enum.reduce(ids, state, &close_legacy_streams_for_session(&2, &1, reason))}

      :error ->
        {:noreply, state}
    end
  end

  def handle_cast({:ack_legacy_stream, stream_ref}, state) do
    state =
      update_in(state.legacy_streams[stream_ref], fn
        nil -> nil
        %{queue_size: queue_size} = stream -> %{stream | queue_size: max(queue_size - 1, 0)}
      end)

    {:noreply, state}
  end

  def handle_cast(_request, state), do: {:noreply, state}

  def handle_info({:DOWN, monitor, :process, pid, reason}, state) do
    cond do
      monitor == state.request_store_monitor and pid == state.request_store ->
        {:stop, :request_state_store_unavailable, state}

      monitor == state.session_store_monitor and pid == state.session_store ->
        {:stop, :session_store_unavailable, state}

      true ->
        handle_process_down(monitor, pid, reason, state)
    end
  end

  @impl true
  def handle_info(:cleanup_sessions, state) do
    state_telemetry(
      state,
      [:session_store, :cleanup, :start],
      %{system_time: System.system_time()},
      %{}
    )

    cleanup_started = System.monotonic_time()

    {expired, cleanup_outcome} =
      case cleanup_session_records(state) do
        {:ok, expired} -> {expired, :success}
        {:error, :session_store_unavailable} -> {[], :unavailable}
      end

    state_telemetry(
      state,
      [:session_store, :cleanup, :stop],
      %{
        duration: max(System.monotonic_time() - cleanup_started, 0),
        count: length(expired)
      },
      %{outcome: cleanup_outcome}
    )

    if expired != [] do
      state_telemetry(
        state,
        [:session, :close],
        %{count: length(expired)},
        %{outcome: :expired}
      )
    end

    state =
      Enum.reduce(expired, state, &close_legacy_streams_for_session(&2, &1, :session_expired))

    broadcast_session_close(state, :session_expired, expired)

    Process.send_after(self(), :cleanup_sessions, 60_000)
    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, pid, _reason}, state) do
    cond do
      pid == state.registry ->
        case Registry.start_link(max_json_bytes: state.opts[:max_json_bytes]) do
          {:ok, registry} ->
            case restore_registry(registry, state.definitions, state.catalog_revision) do
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
                @default_stream_queue,
            telemetry_metadata: state.opts[:telemetry_metadata]
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

      pid == state.session_store ->
        {:stop, :session_store_unavailable, state}

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def format_status(%{state: %__MODULE__{} = state} = status) do
    %{status | state: %{state | opts: Keyword.drop(state.opts, @private_option_keys)}}
  end

  def format_status(status), do: status

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

  defp restore_registry(registry, definitions, revision) do
    registrations =
      Enum.flat_map(@primitive_types, fn type ->
        Enum.map(definitions[type], fn {identity, definition} ->
          {type, identity, Map.delete(definition, :identity)}
        end)
      end)

    Registry.restore_all(registry, registrations, revision)
  end

  defp remember_definitions(definitions, registrations) do
    Enum.reduce(registrations, definitions, fn {type, identity, definition}, acc ->
      Map.update!(acc, type, &Map.put(&1, identity, definition))
    end)
  end

  defp registration_invalidations(registrations) do
    affected = MapSet.new(registrations, fn {type, _identity, _definition} -> type end)

    catalog_invalidations(affected)
  end

  defp catalog_invalidations(affected) do
    affected = MapSet.new(affected)

    [
      if(MapSet.member?(affected, :tool), do: :tool),
      if(MapSet.member?(affected, :prompt), do: :prompt),
      if(MapSet.member?(affected, :resource) or MapSet.member?(affected, :template),
        do: :resource
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp setup_session_store(opts) do
    namespace =
      case Keyword.get(opts, :session_namespace) do
        value when is_binary(value) -> value
        nil -> default_session_namespace(opts)
      end

    {module, store, external?} =
      case Keyword.get(opts, :session_store) do
        nil ->
          {:ok, store} = AttestoMCP.Server.SessionStore.ETS.start_link([])
          {AttestoMCP.Server.SessionStore.ETS, store, false}

        {module, store} when is_atom(module) ->
          validate_session_store_adapter!(module)
          {module, store, true}
      end

    monitor = if external? and is_pid(store), do: Process.monitor(store)

    group =
      if opts[:session_clustered] == true do
        ensure_pg_started!()
        group = {:attesto_mcp_server_sessions, namespace}
        :ok = :pg.join(@session_pg_scope, group, self())
        group
      end

    {module, store, external?, monitor, namespace, group}
  end

  defp default_session_namespace(opts) do
    case Keyword.get(opts, :name) || Keyword.get(opts, :server_name) do
      nil -> "default"
      value when is_atom(value) -> Atom.to_string(value)
      value when is_binary(value) and value != "" -> value
      _ -> "default"
    end
  end

  defp validate_session_store_adapter!(module) do
    callbacks = [
      save: 3,
      load: 2,
      delete: 2,
      list_active: 1,
      update_ttl: 3,
      update: 3,
      cleanup_expired: 1
    ]

    unless Code.ensure_loaded?(module) and
             Enum.all?(callbacks, fn {function, arity} ->
               function_exported?(module, function, arity)
             end) do
      raise ArgumentError, ":session_store module must implement AttestoMCP.Server.SessionStore"
    end
  end

  defp validate_session_store_namespace!(opts) do
    case Keyword.get(opts, :session_store) do
      {module, store} when module == AttestoMCP.Server.SessionStore.Ecto ->
        namespace = Keyword.get(opts, :session_namespace) || default_session_namespace(opts)

        unless Code.ensure_loaded?(module) and function_exported?(module, :namespace_matches?, 2) and
                 apply(module, :namespace_matches?, [store, namespace]) do
          raise ArgumentError,
                ":session_store must be a valid Ecto handle whose namespace matches :session_namespace"
        end

      _other ->
        :ok
    end
  end

  defp ensure_pg_started! do
    case :pg.start_link(@session_pg_scope) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
      other -> raise "cannot start cluster session registry: #{inspect(other)}"
    end
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
      |> Keyword.put_new(:max_json_bytes, Schema.default_instance_bytes())
      |> Keyword.put_new(:output_canonicalization, :strict)
      |> Keyword.put_new(:tool_argument_keys, :strings)
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

    normalized = normalize_cache_scope_option(normalized)

    normalized =
      normalized
      |> put_default_if_nil(:stream_queue_size, normalized[:max_queue])
      |> put_default_if_nil(:subscription_queue_size, normalized[:max_queue])
      |> put_default_if_nil(:legacy_keepalive_ms, normalized[:stream_keepalive_ms])
      |> put_default_if_nil(:session_idle_timeout, 1_800_000)
      |> put_default_if_nil(:session_absolute_timeout, 86_400_000)

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

  defp normalize_cache_scope_option(opts) do
    case Keyword.get(opts, :cache_scope) do
      :private -> Keyword.put(opts, :cache_scope, "private")
      :public -> Keyword.put(opts, :cache_scope, "public")
      _ -> opts
    end
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

  defp session_timeout_values(session_opts, opts) when is_list(session_opts) do
    if Keyword.keyword?(session_opts) do
      absolute_timeout =
        Keyword.get(session_opts, :absolute_timeout, opts[:session_absolute_timeout])

      idle_timeout = Keyword.get(session_opts, :idle_timeout, opts[:session_idle_timeout])

      cond do
        not Session.valid_timeout?(absolute_timeout) ->
          {:error, {:invalid_session_timeout, :absolute_timeout}}

        not Session.valid_timeout?(idle_timeout) ->
          {:error, {:invalid_session_timeout, :idle_timeout}}

        true ->
          {:ok, absolute_timeout, idle_timeout}
      end
    else
      {:error, {:invalid_session_timeout, :options}}
    end
  end

  defp session_timeout_values(_session_opts, _opts),
    do: {:error, {:invalid_session_timeout, :options}}

  defp validate_startup_options!(opts) do
    unknown = Keyword.keys(opts) -- @allowed_startup_option_keys

    if unknown != [] do
      raise ArgumentError, "unknown server option(s): #{inspect(Enum.uniq(unknown))}"
    end

    case Keyword.get(opts, :name) do
      nil -> :ok
      name when is_atom(name) -> :ok
      _other -> raise ArgumentError, ":name must be an atom when present"
    end

    positive = [
      :max_concurrency,
      :per_principal_concurrency,
      :max_request_timeout,
      :client_request_timeout,
      :max_queue,
      :stream_queue_size,
      :subscription_queue_size,
      :session_idle_timeout,
      :session_absolute_timeout
    ]

    nonnegative = [
      :request_timeout,
      :legacy_initialized_grace_ms,
      :stream_keepalive_ms,
      :legacy_keepalive_ms,
      :cursor_ttl,
      :subscription_timeout
    ]

    Enum.each(positive, fn key ->
      case Keyword.get(opts, key) do
        value when key in [:session_idle_timeout, :session_absolute_timeout] ->
          unless Session.valid_timeout?(value) do
            raise ArgumentError,
                  "#{key} must be between 1 and #{Session.max_timeout_ms()} milliseconds"
          end

        value when is_integer(value) and value > 0 ->
          :ok

        _ ->
          raise ArgumentError, "#{key} must be a positive integer"
      end
    end)

    Enum.each(nonnegative, fn key ->
      case Keyword.get(opts, key) do
        nil -> :ok
        value when is_integer(value) and value >= 0 -> :ok
        _ -> raise ArgumentError, "#{key} must be a non-negative integer"
      end
    end)

    json_budget = Keyword.fetch!(opts, :max_json_bytes)

    unless is_integer(json_budget) and json_budget >= Schema.min_allowed_instance_bytes() and
             json_budget <= Schema.max_allowed_instance_bytes() do
      raise ArgumentError,
            ":max_json_bytes must be between #{Schema.min_allowed_instance_bytes()} and #{Schema.max_allowed_instance_bytes()} bytes"
    end

    unless opts[:output_canonicalization] in [:strict, :json, :jason],
      do:
        raise(
          ArgumentError,
          ":output_canonicalization must be :strict, :json, or :jason"
        )

    unless opts[:tool_argument_keys] in [:strings, :atoms],
      do: raise(ArgumentError, ":tool_argument_keys must be :strings or :atoms")

    Enum.each([:max_body_bytes, :max_message_bytes], fn key ->
      case Keyword.get(opts, key) do
        nil ->
          :ok

        value when is_integer(value) and value > 0 ->
          if value > json_budget do
            raise ArgumentError,
                  "#{key} cannot exceed the #{json_budget}-byte JSON value budget"
          end

        _ ->
          raise ArgumentError, "#{key} must be a positive integer"
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
    validate_default_scopes!(Keyword.get(opts, :default_scopes))

    validate_capabilities!(
      Keyword.get(opts, :capabilities),
      Keyword.fetch!(opts, :max_json_bytes)
    )

    Telemetry.validate_trusted_metadata!(Keyword.get(opts, :telemetry_metadata))

    Enum.each([{:exception_reporter, 1}, {:handler_task_init, 2}], fn {key, arity} ->
      case Keyword.get(opts, key) do
        nil ->
          :ok

        callback ->
          unless HostCallback.valid?(callback, arity),
            do: raise(ArgumentError, "#{key} must be a supported #{arity}-argument callback")
      end
    end)

    case Keyword.get(opts, :clustered) do
      nil -> :ok
      value when is_boolean(value) -> :ok
      _ -> raise ArgumentError, ":clustered must be boolean"
    end

    case Keyword.get(opts, :session_clustered) do
      nil -> :ok
      value when is_boolean(value) -> :ok
      _ -> raise ArgumentError, ":session_clustered must be boolean"
    end

    case Keyword.get(opts, :session_namespace) do
      nil ->
        :ok

      value when is_binary(value) ->
        unless valid_session_close_key?(value),
          do:
            raise(
              ArgumentError,
              ":session_namespace must be a non-empty valid UTF-8 string up to 256 bytes without NUL bytes"
            )

      _ ->
        raise ArgumentError,
              ":session_namespace must be a non-empty valid UTF-8 string up to 256 bytes without NUL bytes"
    end

    case Keyword.get(opts, :session_store) do
      nil -> :ok
      {module, _store} when is_atom(module) -> validate_session_store_adapter!(module)
      _ -> raise ArgumentError, ":session_store must be a {module, store} adapter tuple"
    end

    validate_session_store_namespace!(opts)

    if opts[:session_clustered] == true and
         (is_nil(opts[:session_store]) or is_nil(opts[:session_namespace])) do
      raise ArgumentError,
            ":session_clustered requires an explicit shared :session_store and :session_namespace"
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

    if opts[:session_clustered] == true and
         not (is_binary(opts[:cursor_secret]) and byte_size(opts[:cursor_secret]) >= 16) do
      raise ArgumentError,
            ":session_clustered requires an explicit shared :cursor_secret of at least 16 bytes (32 bytes recommended)"
    end

    if Keyword.get(opts, :request_timeout) > Keyword.get(opts, :max_request_timeout),
      do: raise(ArgumentError, ":request_timeout cannot exceed :max_request_timeout")

    :ok
  end

  defp validate_scope_map!(scope_map), do: ScopeMap.validate!(scope_map)

  defp validate_default_scopes!(nil), do: :ok

  defp validate_default_scopes!(scopes) when is_list(scopes) and scopes != [] do
    unless length(scopes) == length(Enum.uniq(scopes)) and
             Enum.all?(scopes, &(is_binary(&1) and byte_size(&1) in 1..256)) do
      raise ArgumentError, ":default_scopes must be a non-empty list of unique scopes"
    end
  end

  defp validate_default_scopes!(_scopes),
    do: raise(ArgumentError, ":default_scopes must be a non-empty list of unique scopes")

  defp validate_capabilities!(nil, _max_bytes), do: :ok

  defp validate_capabilities!(capabilities, max_bytes) when is_map(capabilities) do
    if Schema.json_value(capabilities, max_bytes: max_bytes) == :ok do
      :ok
    else
      raise ArgumentError, ":capabilities must contain only bounded JSON values"
    end
  end

  defp validate_capabilities!(_, _max_bytes),
    do: raise(ArgumentError, ":capabilities must be a JSON map")

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
        Subscriptions.ack(subscriptions, id, self())

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
           :ok <- validate_server_notification(event, era, context),
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

  defp enrich_logging_context(context, _runtime, @legacy)
       when is_map_key(context, :logging_level),
       do: context

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

    case level do
      {:error, :session_store_unavailable} ->
        Map.put(context, :session_store_unavailable, true)

      level ->
        Map.put_new(context, :logging_level, level)
    end
  end

  defp enrich_logging_context(context, _runtime, _era), do: context

  defp validate_server_notification(
         %{"jsonrpc" => "2.0", "method" => method, "params" => params} = event,
         era,
         context
       )
       when is_binary(method) and is_map(params) do
    cond do
      Map.has_key?(event, "id") or Map.has_key?(event, "result") or Map.has_key?(event, "error") ->
        {:error, :notification_envelope}

      method not in notification_methods(era) ->
        {:error, :notification_method}

      Schema.json_value(event, json_budget_opts(context)) != :ok ->
        {:error, :notification_not_json}

      method == "notifications/message" ->
        validate_log_params(params, json_budget_opts(context))

      method == "notifications/progress" ->
        validate_progress_params(params, json_budget_opts(context))

      method in [
        "notifications/tools/list_changed",
        "notifications/prompts/list_changed",
        "notifications/resources/list_changed"
      ] ->
        validate_catalog_notification_params(params, json_budget_opts(context))

      method == "notifications/resources/updated" ->
        validate_resource_updated_notification_params(params, json_budget_opts(context))

      true ->
        {:error, :notification_params}
    end
  end

  defp validate_server_notification(_event, _era, _context),
    do: {:error, :invalid_notification}

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

  defp validate_log_params(params, opts) do
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

      not Map.has_key?(params, "data") or Schema.json_value(params["data"], opts) != :ok ->
        {:error, :log_data_invalid}

      Map.has_key?(params, "_meta") and
          (not is_map(params["_meta"]) or Schema.json_value(params["_meta"], opts) != :ok) ->
        {:error, :log_meta_invalid}

      true ->
        :ok
    end
  end

  defp validate_catalog_notification_params(params, opts) when is_map(params) do
    if Enum.all?(Map.keys(params), &(&1 == "_meta")) and
         (not Map.has_key?(params, "_meta") or
            (is_map(params["_meta"]) and Schema.json_value(params["_meta"], opts) == :ok)),
       do: :ok,
       else: {:error, :notification_params}
  end

  defp validate_resource_updated_notification_params(params, opts) when is_map(params) do
    uri = Map.get(params, "uri")

    if is_binary(uri) and byte_size(uri) in 1..4_096 and String.valid?(uri) and
         Enum.all?(Map.keys(params), &(&1 in ["uri", "_meta"])) and
         (not Map.has_key?(params, "_meta") or
            (is_map(params["_meta"]) and Schema.json_value(params["_meta"], opts) == :ok)),
       do: :ok,
       else: {:error, :notification_params}
  end

  defp validate_progress_params(params, opts) do
    token = params["progressToken"]
    progress = params["progress"]
    total = params["total"]

    if (is_binary(token) or is_integer(token)) and is_number(progress) and progress >= 0 and
         (is_nil(total) or (is_number(total) and total >= progress)) and
         Schema.json_value(params, opts) == :ok,
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

  defp validate_client_response(method, response, params, opts) when is_map(response) do
    kind = response[:kind] || response["kind"]
    result = response[:result] || response["result"]
    error = response[:error] || response["error"]

    cond do
      not is_nil(result) and Schema.json_value(result, json_budget_opts(opts)) != :ok ->
        {:error, :invalid_response}

      not is_nil(error) and Schema.json_value(error, json_budget_opts(opts)) != :ok ->
        {:error, :invalid_response}

      kind not in [:response, "response"] ->
        {:error, :invalid_response}

      is_map(error) and is_nil(result) and valid_client_error?(error) ->
        {:error, {:client_error, error}}

      is_nil(error) and valid_client_result?(method, result, params, opts) ->
        {:ok, result}

      true ->
        {:error, :invalid_response}
    end
  end

  defp validate_client_response(_method, _response, _params, _opts),
    do: {:error, :invalid_response}

  defp valid_client_error?(error) when is_map(error) do
    is_integer(error[:code] || error["code"]) and
      is_binary(error[:message] || error["message"])
  end

  defp valid_client_result?("elicitation/create", result, params, _opts) when is_map(result) do
    action = result["action"] || result[:action]
    content = result["content"] || result[:content]

    action in ["accept", "decline", "cancel"] and
      if(params["mode"] == "url",
        do: not Map.has_key?(result, "content"),
        else: action != "accept" or is_map(content)
      )
  end

  defp valid_client_result?("sampling/createMessage", result, _params, opts)
       when is_map(result) do
    role = result["role"] || result[:role]
    content = result["content"] || result[:content]
    model = result["model"] || result[:model]
    stop_reason = result["stopReason"] || result[:stopReason]

    role == "assistant" and valid_sampling_content?(content, opts) and is_binary(model) and
      (is_nil(stop_reason) or is_binary(stop_reason))
  end

  defp valid_client_result?("roots/list", result, _params, _opts) when is_map(result) do
    roots = result["roots"] || result[:roots]

    is_list(roots) and Enum.all?(roots, &valid_client_root?/1)
  end

  defp valid_client_result?(_, _, _, _), do: false

  defp valid_client_root?(root) when is_map(root) do
    uri = root["uri"] || root[:uri]
    name = root["name"] || root[:name]

    is_binary(uri) and String.starts_with?(uri, "file://") and
      (is_nil(name) or is_binary(name))
  end

  defp valid_client_root?(_), do: false

  defp session_for(state, session_id, principal, tenant, opts \\ []) do
    require_initialized = Keyword.get(opts, :require_initialized, false)

    case load_session(state, session_id) do
      {:ok, session} ->
        if Session.valid?(session) and Session.same_principal?(session, principal) and
             Session.same_tenant?(session, tenant) and
             (not require_initialized or session.initialized),
           do: {:ok, session},
           else: {:error, :not_found}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :invalid_session_record} ->
        case discard_invalid_session_record(state, session_id) do
          {:ok, _outcome} -> {:error, :not_found}
          {:error, :session_store_unavailable} -> {:error, :session_store_unavailable}
        end

      {:error, :unknown_record_version} ->
        # A rolling deployment may encounter a record written by a newer
        # node. It is unavailable to this node, but must remain durable.
        {:error, :not_found}

      {:error, :binding_unavailable} ->
        {:error, :not_found}

      {:error, :session_store_unavailable} ->
        {:error, :session_store_unavailable}
    end
  end

  defp lookup_session(state, id, principal, tenant, touch?) do
    case load_session(state, id) do
      {:ok, session} ->
        cond do
          not Session.valid?(session) ->
            case discard_invalid_session_record(state, id) do
              {:ok, :discarded} ->
                state_telemetry(state, [:session, :close], %{count: 1}, %{outcome: :expired})

                {{:error, :not_found},
                 close_legacy_streams_for_session(state, id, :session_expired)}

              {:ok, :preserved} ->
                {{:error, :not_found}, state}

              {:error, :session_store_unavailable} ->
                {{:error, :session_store_unavailable}, state}
            end

          not Session.same_principal?(session, principal) or
              not Session.same_tenant?(session, tenant) ->
            {{:error, :not_found}, state}

          not touch? ->
            {{:ok, session}, state}

          true ->
            case update_session(state, id, fn current ->
                   if Session.same_principal?(current, principal) and
                        Session.same_tenant?(current, tenant),
                      do: {:ok, Session.touch(current)},
                      else: {:error, :not_found}
                 end) do
              {:ok, updated} ->
                {{:ok, updated}, state}

              {:error, :session_store_unavailable} ->
                {{:error, :session_store_unavailable}, state}

              _ ->
                {{:error, :not_found}, state}
            end
        end

      {:error, :invalid_session_record} ->
        case discard_invalid_session_record(state, id) do
          {:ok, :discarded} ->
            {{:error, :not_found}, close_legacy_streams_for_session(state, id, :session_expired)}

          {:ok, :preserved} ->
            {{:error, :not_found}, state}

          {:error, :session_store_unavailable} ->
            {{:error, :session_store_unavailable}, state}
        end

      {:error, :unknown_record_version} ->
        # Do not let a rolling deployment turn a newer durable record into a
        # deletion merely because this node cannot deserialize it yet.
        {{:error, :not_found}, state}

      {:error, :binding_unavailable} ->
        {{:error, :not_found}, state}

      {:error, :session_store_unavailable} ->
        {{:error, :session_store_unavailable}, state}

      _ ->
        {{:error, :not_found}, state}
    end
  end

  defp session_key(state, id), do: {state.session_namespace, id}

  defp load_session(state, id) when is_binary(id) do
    case safe_session_store_call(state, :load, [session_key(state, id)]) do
      {:ok, record} when is_map(record) ->
        case Session.from_record(record) do
          {:ok, %{id: ^id} = session} ->
            {:ok, session}

          {:ok, _session} ->
            {:error, :invalid_session_record}

          {:error, :unknown_record_version} ->
            {:error, :unknown_record_version}

          {:error, :binding_unavailable} ->
            {:error, :binding_unavailable}

          {:error, _reason} ->
            {:error, :invalid_session_record}
        end

      :not_found ->
        {:error, :not_found}

      {:error, _reason} ->
        {:error, :session_store_unavailable}

      _ ->
        {:error, :session_store_unavailable}
    end
  end

  defp load_session(_state, _id), do: {:error, :not_found}

  defp save_session(state, %Session{} = session) do
    case Session.to_record(session) do
      {:ok, record} ->
        case safe_session_store_call(state, :save, [session_key(state, session.id), record]) do
          :ok -> :ok
          _ -> {:error, :session_store_unavailable}
        end

      {:error, reason}
      when reason in [
             :nonportable_binding,
             :binding_too_large,
             :record_too_large,
             :invalid_session_timeout
           ] ->
        {:error, reason}
    end
  end

  defp update_session(state, id, updater) when is_binary(id) and is_function(updater, 1) do
    semantic_error_ref = make_ref()

    result =
      safe_session_store_call(
        state,
        :update,
        [
          session_key(state, id),
          fn record -> apply_session_update(record, updater, semantic_error_ref) end
        ],
        semantic_error_ref
      )

    case result do
      {:ok, record} ->
        case Session.from_record(record) do
          {:ok, %{id: ^id} = session} -> {:ok, session}
          {:ok, _session} -> session_store_unavailable(state, :update)
          {:error, :unknown_record_version} -> {:error, :unknown_record_version}
          {:error, :binding_unavailable} -> {:error, :binding_unavailable}
          {:error, _reason} -> session_store_unavailable(state, :update)
        end

      :not_found ->
        {:error, :not_found}

      {:error, {:server_session_update, ^semantic_error_ref, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :session_store_unavailable}
    end
  end

  defp apply_session_update(record, updater, semantic_error_ref) do
    try do
      case Session.from_record(record) do
        {:ok, session} ->
          with true <- Session.valid?(session),
               {:ok, updated} <- updater.(session),
               {:ok, updated_record} <- Session.to_record(updated) do
            {:ok, Map.merge(record, updated_record)}
          else
            false ->
              :delete

            {:error, reason} ->
              {:error, {:server_session_update, semantic_error_ref, reason}}
          end

        {:error, :unknown_record_version} ->
          # Preserve records written by a newer node. The caller receives a
          # private semantic error and can turn it into neutral not-found;
          # the adapter must not interpret it as a deletion request.
          {:error, {:server_session_update, semantic_error_ref, :unknown_record_version}}

        {:error, :binding_unavailable} ->
          {:error, {:server_session_update, semantic_error_ref, :binding_unavailable}}

        {:error, _reason} ->
          :delete
      end
    catch
      _kind, _reason ->
        {:error, {:server_session_update, semantic_error_ref, :update_failed}}
    end
  end

  defp touch_session_record(state, id) when is_binary(id) do
    now = System.system_time(:millisecond)

    case safe_session_store_call(state, :update_ttl, [session_key(state, id), now]) do
      {:ok, record} when is_map(record) ->
        case Session.from_record(record) do
          {:ok, %{id: ^id} = session} ->
            if session.last_seen >= now,
              do: {:ok, session},
              else: session_store_unavailable(state, :update_ttl)

          {:error, :unknown_record_version} ->
            {:error, :not_found}

          {:error, :binding_unavailable} ->
            {:error, :not_found}

          _ ->
            session_store_unavailable(state, :update_ttl)
        end

      :not_found ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :session_store_unavailable}
    end
  end

  defp touch_session_record(_state, _id), do: {:error, :not_found}

  defp delete_session_record(state, id) do
    safe_session_store_call(state, :delete, [session_key(state, id)])
  end

  defp discard_invalid_session_record(state, id) when is_binary(id) do
    result =
      safe_session_store_call(
        state,
        :update,
        [
          session_key(state, id),
          fn record ->
            case Session.from_record(record) do
              {:error, :unknown_record_version} ->
                {:ok, record}

              {:error, :binding_unavailable} ->
                # A binding may refer to an atom that is intentionally not
                # loaded on this node. Keep the durable record for a node
                # that can resolve it; it is not malformed data.
                {:ok, record}

              {:ok, %{id: ^id} = session} ->
                if Session.valid?(session), do: {:ok, record}, else: :delete

              {:ok, _session} ->
                :delete

              {:error, _reason} ->
                :delete
            end
          end
        ]
      )

    case result do
      :not_found ->
        {:ok, :discarded}

      {:ok, record} when is_map(record) ->
        {:ok, :preserved}

      {:error, :session_store_unavailable} ->
        {:error, :session_store_unavailable}

      _ ->
        {:error, :session_store_unavailable}
    end
  end

  defp discard_invalid_session_record(_state, _id), do: {:ok, :discarded}

  defp session_count(state) do
    if function_exported?(state.session_store_module, :count_active, 1) do
      case safe_session_store_call(state, :count_active, []) do
        {:ok, count} when is_integer(count) and count >= 0 -> count
        _ -> 0
      end
    else
      case safe_session_store_call(state, :list_active, []) do
        {:ok, records} when is_list(records) ->
          Enum.count(records, fn
            {{namespace, _id}, _record} -> namespace == state.session_namespace
            _ -> false
          end)

        _ ->
          0
      end
    end
  end

  defp cleanup_session_records(state) do
    case safe_session_store_call(state, :cleanup_expired, []) do
      {:ok, keys} when is_list(keys) ->
        {:ok,
         Enum.flat_map(keys, fn
           {namespace, id} when namespace == state.session_namespace -> [id]
           _ -> []
         end)}

      {:error, :session_store_unavailable} ->
        {:error, :session_store_unavailable}
    end
  end

  defp safe_session_store_call(state, function, arguments),
    do: safe_session_store_call(state, function, arguments, nil)

  defp safe_session_store_call(state, function, arguments, semantic_error_ref) do
    result =
      try do
        state.session_store_module
        |> apply(function, [state.session_store | arguments])
        |> normalize_session_store_result(function, semantic_error_ref)
      catch
        _kind, _reason -> {:error, :session_store_unavailable}
      end

    if session_store_failure?(result) do
      state_telemetry(
        state,
        [:session_store, :failure],
        %{count: 1},
        %{source: function, outcome: :unavailable}
      )
    end

    result
  end

  defp normalize_session_store_result(result, function, semantic_error_ref) do
    result =
      case result do
        # Only updater errors created by this server carry application
        # semantics. Adapter-owned error terms are private implementation
        # details and always cross the server boundary as one neutral outage.
        # The per-call reference prevents an adapter from forging that
        # privileged internal result tag.
        {:error, {:server_session_update, ^semantic_error_ref, _reason}} = error
        when is_reference(semantic_error_ref) ->
          error

        {:error, _reason} ->
          {:error, :session_store_unavailable}

        result ->
          result
      end

    if valid_session_store_result?(function, result),
      do: result,
      else: {:error, :session_store_unavailable}
  end

  defp valid_session_store_result?(function, :ok) when function in [:save, :delete], do: true
  defp valid_session_store_result?(:load, :not_found), do: true

  defp valid_session_store_result?(function, :not_found) when function in [:update, :update_ttl],
    do: true

  defp valid_session_store_result?(function, {:ok, value})
       when function in [:load, :update, :update_ttl] do
    is_map(value)
  end

  defp valid_session_store_result?(function, {:ok, value})
       when function == :list_active,
       do: is_list(value) and Enum.all?(value, &valid_active_session_entry?/1)

  defp valid_session_store_result?(function, {:ok, value})
       when function == :cleanup_expired,
       do: valid_session_cleanup_keys?(value, 0)

  defp valid_session_store_result?(:count_active, {:ok, value}),
    do: is_integer(value) and value >= 0

  defp valid_session_store_result?(
         :list_active_keys,
         {:ok, %{keys: keys, next_cursor: next_cursor}}
       ) do
    if is_list(keys) and length(keys) <= @max_active_session_page_size and
         Enum.all?(keys, &valid_active_session_page_key?/1) do
      ids = Enum.map(keys, &elem(&1, 1))

      ids == Enum.sort(ids) and ids == Enum.uniq(ids) and
        (is_nil(next_cursor) or (ids != [] and next_cursor == List.last(ids)))
    else
      false
    end
  end

  defp valid_session_store_result?(_function, {:error, _reason}), do: true
  defp valid_session_store_result?(_function, _result), do: false

  defp valid_session_cleanup_keys?([], count) when count <= @max_session_cleanup_keys, do: true

  defp valid_session_cleanup_keys?([key | rest], count)
       when count < @max_session_cleanup_keys,
       do: valid_session_key?(key) and valid_session_cleanup_keys?(rest, count + 1)

  defp valid_session_cleanup_keys?(_keys, _count), do: false

  defp session_store_failure?({:error, {:server_session_update, ref, _reason}})
       when is_reference(ref),
       do: false

  defp session_store_failure?({:error, _reason}), do: true
  defp session_store_failure?(_result), do: false

  defp valid_active_session_entry?({key, record}) when is_map(record),
    do: valid_session_key?(key)

  defp valid_active_session_entry?(_entry), do: false

  defp valid_active_session_page_key?({namespace, id}),
    do: valid_active_session_cursor?(namespace) and valid_active_session_cursor?(id)

  defp valid_active_session_page_key?(_key), do: false

  defp valid_active_session_page?(keys, next_cursor, cursor, limit) do
    ids = Enum.map(keys, &elem(&1, 1))

    length(keys) <= limit and
      (is_nil(cursor) or Enum.all?(ids, &(&1 > cursor))) and
      (is_nil(next_cursor) or
         (ids != [] and next_cursor > (cursor || "") and next_cursor == List.last(ids)))
  end

  defp valid_session_key?({namespace, id}) when is_binary(namespace) and is_binary(id), do: true
  defp valid_session_key?(_key), do: false

  defp session_store_unavailable(state, function) do
    state_telemetry(
      state,
      [:session_store, :failure],
      %{count: 1},
      %{source: function, outcome: :unavailable}
    )

    {:error, :session_store_unavailable}
  end

  defp publish_notification_local(
         state,
         notification,
         opts,
         publisher_scope_sets,
         local_scope_sets
       ) do
    with {:ok, required_scope_sets} <-
           required_notification_scope_sets(local_scope_sets, publisher_scope_sets) do
      required_scopes = List.first(required_scope_sets) || []

      notification_opts =
        opts
        |> safe_notification_opts()
        |> Keyword.put(:required_scope_sets, required_scope_sets)
        |> Keyword.put(:required_scopes, required_scopes)

      :ok =
        Subscriptions.publish(
          state.subscriptions,
          notification,
          notification_opts
        )

      publish_legacy(
        state,
        notification,
        required_scope_sets,
        notification_authorizer(notification_opts)
      )
    else
      :error -> state
    end
  end

  defp broadcast_cluster_notification(
         %{session_cluster_group: nil},
         _notification,
         _opts,
         _publisher_scope_sets
       ),
       do: :ok

  defp broadcast_cluster_notification(state, notification, opts, publisher_scope_sets) do
    message =
      if resource_notification?(notification) do
        case cluster_notification_envelope(notification, opts, publisher_scope_sets) do
          {:ok, envelope} -> {:cluster_publish, envelope}
          :error -> nil
        end
      else
        # Fixed-scope catalog invalidations remain compatible with older peers.
        {:cluster_publish, notification, cluster_notification_opts(opts)}
      end

    if message do
      state.session_cluster_group
      |> then(&:pg.get_members(@session_pg_scope, &1))
      |> Enum.each(fn
        pid when pid != self() -> GenServer.cast(pid, message)
        _pid -> :ok
      end)
    end

    :ok
  catch
    _kind, _reason -> :ok
  end

  defp broadcast_session_close(%{session_cluster_group: nil}, _reason, _ids), do: :ok

  defp broadcast_session_close(state, reason, ids) do
    with true <- valid_session_close_key?(state.session_namespace),
         true <- reason in @session_close_reasons,
         {:ok, ids} <- normalize_session_close_ids(ids) do
      ids
      |> Enum.chunk_every(@max_session_close_ids)
      |> Enum.each(fn chunk ->
        envelope = %{
          version: @session_close_message_version,
          namespace: state.session_namespace,
          reason: reason,
          ids: chunk
        }

        state.session_cluster_group
        |> then(&:pg.get_members(@session_pg_scope, &1))
        |> Enum.each(fn
          pid when is_pid(pid) and pid != self() ->
            GenServer.cast(pid, {:cluster_session_close, envelope})

          _pid ->
            :ok
        end)
      end)
    end

    :ok
  catch
    _kind, _reason -> :ok
  end

  defp cluster_session_close(
         %{
           version: @session_close_message_version,
           namespace: namespace,
           reason: reason,
           ids: ids
         } = envelope,
         state
       )
       when map_size(envelope) == 4 do
    with true <- namespace == state.session_namespace,
         true <- valid_session_close_key?(namespace),
         true <- reason in @session_close_reasons,
         {:ok, ids} <- normalize_session_close_ids(ids, @max_session_close_ids) do
      {:ok, reason, ids}
    else
      _ -> :error
    end
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp cluster_session_close(_envelope, _state), do: :error

  defp normalize_session_close_ids(ids, max \\ nil)

  defp normalize_session_close_ids(ids, max) when is_list(ids) do
    with true <- proper_list_within_limit?(ids, max),
         {:ok, ids} <- collect_session_close_ids(ids, %{}, []) do
      {:ok, ids}
    else
      _ -> :error
    end
  rescue
    _exception -> :error
  end

  defp normalize_session_close_ids(_ids, _max), do: :error

  defp proper_list_within_limit?(ids, nil) do
    ids != []
  end

  defp proper_list_within_limit?(ids, max) when is_integer(max) and max > 0 do
    bounded_proper_list?(ids, max, 0)
  end

  defp proper_list_within_limit?(_ids, _max), do: false

  defp bounded_proper_list?([], _max, count) when count > 0, do: true

  defp bounded_proper_list?([_head | tail], max, count) when count < max,
    do: bounded_proper_list?(tail, max, count + 1)

  defp bounded_proper_list?([_head | _tail], _max, _count), do: false
  defp bounded_proper_list?(_improper, _max, _count), do: false

  defp collect_session_close_ids([], _seen, collected), do: {:ok, Enum.reverse(collected)}

  defp collect_session_close_ids([id | rest], seen, collected) do
    if valid_session_close_key?(id) do
      if Map.has_key?(seen, id) do
        collect_session_close_ids(rest, seen, collected)
      else
        collect_session_close_ids(rest, Map.put(seen, id, true), [id | collected])
      end
    else
      :error
    end
  end

  defp valid_session_close_key?(value) do
    is_binary(value) and byte_size(value) in 1..@max_session_close_key_bytes and
      String.valid?(value) and :binary.match(value, <<0>>) == :nomatch
  end

  defp await_initialized_until(server, id, principal, tenant, deadline, touch?) do
    session =
      if touch?,
        do: get_session(server, id, principal, tenant),
        else: peek_session(server, id, principal, tenant)

    case session do
      {:ok, %{initialized: true}} ->
        :ok

      {:ok, _session} ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining > 0 do
          Process.sleep(min(remaining, 5))
          await_initialized_until(server, id, principal, tenant, deadline, touch?)
        else
          {:error, :not_initialized}
        end

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :session_store_unavailable} ->
        {:error, :session_store_unavailable}
    end
  end

  defp session_owned?(state, session_id, principal, tenant) do
    case session_for(state, session_id, principal, tenant) do
      {:ok, _session} -> :ok
      {:error, :session_store_unavailable} -> :session_store_unavailable
      _ -> :not_found
    end
  end

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

  defp publish_legacy(state, notification, required_resource_scope_sets),
    do: publish_legacy(state, notification, required_resource_scope_sets, nil)

  defp publish_legacy(
         state,
         notification,
         required_resource_scope_sets,
         notification_authorizer
       ) do
    event = legacy_event(notification)

    with {:ok, required_scope_sets} <-
           legacy_event_required_scope_sets(event, required_resource_scope_sets) do
      state.legacy_streams
      |> Enum.group_by(fn {_ref, stream} -> stream.session_id end)
      |> Enum.reduce(state, fn {session_id, streams}, acc ->
        case load_session(acc, session_id) do
          {:ok, session} ->
            if Session.valid?(session) and legacy_event_allowed?(event, session) do
              case Enum.find(streams, fn {_ref, stream} ->
                     Process.alive?(stream.sink) and
                       legacy_authorized?(
                         stream,
                         event,
                         required_scope_sets,
                         notification_authorizer
                       )
                   end) do
                {stream_ref, _stream} -> send_legacy_stream(acc, stream_ref, event)
                nil -> acc
              end
            else
              if Session.valid?(session),
                do: acc,
                else: close_legacy_streams_for_session(acc, session_id, :session_expired)
            end

          {:error, :session_store_unavailable} ->
            acc

          {:error, :unknown_record_version} ->
            # Keep the durable row for a newer node. This node cannot safely
            # decide whether the session is valid or expired.
            acc

          {:error, :binding_unavailable} ->
            # Keep the durable row and its live stream for a node that can
            # resolve the persisted binding.
            acc

          {:error, :invalid_session_record} ->
            # A store may have returned a structurally invalid row before a
            # newer node replaced it. Re-check under the store's update lock;
            # a preserved future record must not close the live stream.
            case discard_invalid_session_record(acc, session_id) do
              {:ok, :discarded} ->
                close_legacy_streams_for_session(acc, session_id, :session_expired)

              {:ok, :preserved} ->
                acc

              {:error, :session_store_unavailable} ->
                acc
            end

          _ ->
            close_legacy_streams_for_session(acc, session_id, :session_expired)
        end
      end)
    else
      :error -> state
    end
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

  defp legacy_authorized?(stream, event, required_scope_sets, notification_authorizer)
       when is_map(stream) do
    required_scopes = List.first(required_scope_sets) || []

    context = %{
      principal: stream.principal,
      tenant: stream.tenant,
      event: event,
      required_scopes: required_scopes,
      required_scope_sets: required_scope_sets
    }

    [stream[:authorize], notification_authorizer]
    |> Enum.filter(&is_function(&1, 1))
    |> Enum.all?(&(&1.(context) == true))
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp legacy_event_required_scope_sets(
         %{"method" => "notifications/resources/updated"},
         required_scope_sets
       )
       when is_list(required_scope_sets) and required_scope_sets != [],
       do: {:ok, required_scope_sets}

  defp legacy_event_required_scope_sets(
         %{"method" => "notifications/resources/updated"},
         _required_scope_sets
       ),
       do: :error

  defp legacy_event_required_scope_sets(%{"method" => method}, _required_scope_sets)
       when method == "notifications/tools/list_changed",
       do: {:ok, [[AttestoMCP.Scopes.tools_read()]]}

  defp legacy_event_required_scope_sets(%{"method" => method}, _required_scope_sets)
       when method == "notifications/prompts/list_changed",
       do: {:ok, [[AttestoMCP.Scopes.prompts_read()]]}

  defp legacy_event_required_scope_sets(%{"method" => method}, _required_scope_sets)
       when method == "notifications/resources/list_changed",
       do: {:ok, [[AttestoMCP.Scopes.resources_read()]]}

  defp legacy_event_required_scope_sets(_event, _required_scope_sets), do: {:ok, [[]]}

  defp resolve_resource_definition_scope_sets(_state, uri) when not is_binary(uri), do: :error

  defp resolve_resource_definition_scope_sets(state, uri) when is_binary(uri) do
    Telemetry.execute(
      [:uri_template, :scope_resolution],
      %{count: 1},
      %{source: :resource_notification}
    )

    resources =
      state.definitions
      |> Map.get(:resource, %{})
      |> Map.values()
      |> Enum.sort_by(& &1[:identity])

    case Enum.find(resources, &(&1[:uri] == uri)) do
      definition when is_map(definition) ->
        definition_scope_sets(definition)

      nil ->
        templates =
          state.definitions
          |> Map.get(:template, %{})
          |> Map.values()
          |> Enum.sort_by(& &1[:identity])

        {result, _budget} =
          Enum.reduce_while(
            templates,
            {{:ok, [[]]}, new_template_match_budget()},
            fn definition, {_result, budget} ->
              case match_uri_template(definition[:uri_template], uri, budget) do
                {:ok, _params, budget} ->
                  {:halt, {definition_scope_sets(definition), budget}}

                {:error, budget} ->
                  {:cont, {{:ok, [[]]}, budget}}

                {:exhausted, budget} ->
                  {:halt, {{:error, :template_match_budget_exhausted}, budget}}
              end
            end
          )

        result
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp definition_scope_sets(definition) when is_map(definition) do
    case Registry.scope_sets(definition) do
      scope_sets when is_list(scope_sets) and scope_sets != [] -> {:ok, scope_sets}
      _ -> :error
    end
  end

  defp definition_scope_sets(_definition), do: :error

  defp notification_scopes(state, %{"type" => type} = notification)
       when type in ["resource", "resourceUpdated", "resourceSubscriptions"] do
    case local_notification_scope_sets(state, notification) do
      {:ok, [required_scopes | _]} -> required_scopes
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_notification}
    end
  end

  defp notification_scopes(_state, _notification), do: []

  defp local_notification_scope_sets(state, notification) do
    if resource_notification?(notification) do
      case resolve_resource_definition_scope_sets(state, resource_notification_uri(notification)) do
        {:ok, definition_scope_sets} ->
          case prepend_scope_to_sets(
                 AttestoMCP.Scopes.resources_read(),
                 definition_scope_sets
               ) do
            {:ok, scope_sets} -> {:ok, scope_sets}
            :error -> :error
          end

        {:error, :template_match_budget_exhausted} = error ->
          error

        :error ->
          {:error, :invalid_notification}
      end
    else
      {:ok, [[]]}
    end
  end

  defp required_notification_scope_sets(local_scope_sets, publisher_scope_sets)
       when is_list(local_scope_sets) and local_scope_sets != [] do
    case publisher_scope_sets do
      :local -> {:ok, local_scope_sets}
      [] -> {:ok, local_scope_sets}
      scope_sets -> conjoin_cluster_scope_sets(scope_sets, local_scope_sets)
    end
  end

  defp required_notification_scope_sets(_local_scope_sets, _publisher_scope_sets), do: :error

  defp prepend_scope_to_sets(scope, scope_sets)
       when is_binary(scope) and is_list(scope_sets) and scope_sets != [] do
    scope_sets = Enum.map(scope_sets, &ordered_uniq([scope | &1]))

    if Enum.all?(scope_sets, &is_list/1), do: {:ok, scope_sets}, else: :error
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp prepend_scope_to_sets(_scope, _scope_sets), do: :error

  defp resource_notification?(%{"type" => type})
       when type in ["resource", "resourceUpdated", "resourceSubscriptions"],
       do: true

  defp resource_notification?(%{type: type})
       when type in ["resource", "resourceUpdated", "resourceSubscriptions"],
       do: true

  defp resource_notification?(_notification), do: false

  defp resource_notification_uri(notification) when is_map(notification),
    do: notification["uri"] || notification[:uri]

  defp ordered_uniq(values) when is_list(values) do
    values
    |> Enum.reduce({[], MapSet.new()}, fn value, {result, seen} ->
      if MapSet.member?(seen, value),
        do: {result, seen},
        else: {[value | result], MapSet.put(seen, value)}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp conjoin_cluster_scope_sets(publisher_scope_sets, local_scope_sets) do
    with {:ok, publisher_scope_sets} <-
           validate_cluster_resource_scope_sets(publisher_scope_sets),
         {:ok, local_scope_sets} <- validate_cluster_resource_scope_sets(local_scope_sets) do
      combined =
        for publisher_scopes <- publisher_scope_sets,
            local_scopes <- local_scope_sets do
          ordered_uniq(publisher_scopes ++ local_scopes)
        end
        |> dedupe_scope_sets()

      validate_combined_cluster_scope_sets(combined)
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp dedupe_scope_sets(scope_sets) do
    scope_sets
    |> Enum.reduce({[], MapSet.new()}, fn scopes, {result, seen} ->
      key = Enum.sort(scopes)

      if MapSet.member?(seen, key),
        do: {result, seen},
        else: {[scopes | result], MapSet.put(seen, key)}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp cluster_notification_envelope(notification, opts, publisher_scope_sets) do
    with {:ok, resource_scope_sets} <-
           cluster_resource_scope_set_metadata(notification, publisher_scope_sets) do
      {:ok,
       %{
         version: @cluster_notification_version,
         notification: notification,
         opts: cluster_notification_opts(opts),
         resource_scope_sets: resource_scope_sets
       }}
    end
  end

  defp cluster_notification(
         %{
           version: @cluster_notification_version,
           notification: notification,
           opts: opts,
           resource_scope_sets: resource_scope_sets
         } = envelope,
         budget_opts
       )
       when map_size(envelope) == 4 do
    with {:ok, notification} <- normalize_public_notification(notification, budget_opts),
         {:ok, opts} <- validate_cluster_notification_opts(opts),
         {:ok, resource_scope_sets} <-
           cluster_resource_scope_set_metadata(notification, resource_scope_sets) do
      {:ok, notification, opts, resource_scope_sets}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp cluster_notification(
         %{
           version: @legacy_cluster_notification_version,
           notification: notification,
           opts: opts,
           resource_scopes: resource_scopes
         } = envelope,
         budget_opts
       )
       when map_size(envelope) == 4 do
    with {:ok, notification} <- normalize_public_notification(notification, budget_opts),
         {:ok, opts} <- validate_cluster_notification_opts(opts),
         {:ok, resource_scopes} <-
           legacy_cluster_resource_scope_metadata(notification, resource_scopes) do
      {:ok, notification, opts, [resource_scopes]}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp cluster_notification(_envelope, _budget_opts), do: :error

  defp cluster_resource_scope_set_metadata(notification, scope_sets) do
    if resource_notification?(notification) do
      validate_cluster_resource_scope_sets(scope_sets)
    else
      :error
    end
  end

  defp legacy_cluster_resource_scope_metadata(notification, scopes) do
    if resource_notification?(notification) do
      with {:ok, scopes} <- validate_cluster_resource_scopes(scopes),
           true <- List.first(scopes) == AttestoMCP.Scopes.resources_read() do
        {:ok, scopes}
      else
        _ -> :error
      end
    else
      :error
    end
  end

  defp validate_cluster_resource_scope_sets(scope_sets),
    do:
      validate_cluster_scope_sets(
        scope_sets,
        @max_cluster_resource_scope_sets,
        @max_cluster_resource_scopes,
        @max_cluster_scopes_bytes
      )

  defp validate_combined_cluster_scope_sets(scope_sets),
    do:
      validate_cluster_scope_sets(
        scope_sets,
        @max_cluster_combined_scope_sets,
        @max_cluster_combined_scope_memberships,
        @max_cluster_combined_scope_bytes
      )

  defp validate_cluster_scope_sets(scope_sets, max_sets, max_memberships, max_bytes) do
    collect_cluster_scope_sets(
      scope_sets,
      0,
      0,
      0,
      %{},
      [],
      max_sets,
      max_memberships,
      max_bytes
    )
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp collect_cluster_scope_sets(
         [],
         count,
         _memberships,
         _bytes,
         _seen,
         scope_sets,
         _max_sets,
         _max_memberships,
         _max_bytes
       )
       when count > 0,
       do: {:ok, Enum.reverse(scope_sets)}

  defp collect_cluster_scope_sets(
         [scopes | rest],
         count,
         memberships,
         bytes,
         seen,
         scope_sets,
         max_sets,
         max_memberships,
         max_bytes
       )
       when count < max_sets do
    with {:ok, scopes} <- validate_cluster_resource_scopes(scopes),
         true <- List.first(scopes) == AttestoMCP.Scopes.resources_read(),
         next_memberships <- memberships + length(scopes),
         true <- next_memberships <= max_memberships,
         next_bytes <- bytes + Enum.sum(Enum.map(scopes, &byte_size/1)),
         true <- next_bytes <= max_bytes,
         key <- Enum.sort(scopes),
         false <- Map.has_key?(seen, key) do
      collect_cluster_scope_sets(
        rest,
        count + 1,
        next_memberships,
        next_bytes,
        Map.put(seen, key, true),
        [scopes | scope_sets],
        max_sets,
        max_memberships,
        max_bytes
      )
    else
      _ -> :error
    end
  end

  defp collect_cluster_scope_sets(
         _scope_sets,
         _count,
         _memberships,
         _bytes,
         _seen,
         _collected,
         _max_sets,
         _max_memberships,
         _max_bytes
       ),
       do: :error

  defp validate_cluster_resource_scopes(scopes) do
    with {:ok, scopes} <-
           collect_cluster_resource_scopes(scopes, 0, 0, %{}, []),
         true <- Attesto.Scope.valid_list?(scopes, allow_empty?: true) do
      {:ok, scopes}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp collect_cluster_resource_scopes([], _count, _bytes, _seen, scopes),
    do: {:ok, Enum.reverse(scopes)}

  defp collect_cluster_resource_scopes(
         [scope | rest],
         count,
         bytes,
         seen,
         scopes
       )
       when count < @max_cluster_resource_scopes do
    scope_bytes = if is_binary(scope), do: byte_size(scope), else: 0
    next_bytes = bytes + scope_bytes

    cond do
      not is_binary(scope) or scope_bytes not in 1..@max_cluster_scope_bytes ->
        :error

      next_bytes > @max_cluster_scopes_bytes ->
        :error

      Map.has_key?(seen, scope) ->
        :error

      true ->
        copied_scope = :binary.copy(scope)

        collect_cluster_resource_scopes(
          rest,
          count + 1,
          next_bytes,
          Map.put(seen, copied_scope, true),
          [copied_scope | scopes]
        )
    end
  end

  defp collect_cluster_resource_scopes(_scopes, _count, _bytes, _seen, _collected),
    do: :error

  defp safe_notification_opts(opts) do
    case normalize_public_notification_opts(opts) do
      {:ok, opts} -> opts
      {:error, _reason} -> []
    end
  end

  defp notification_authorizer(opts) do
    case Keyword.get(opts, :authorize) do
      authorize when is_function(authorize, 1) -> authorize
      _ -> nil
    end
  end

  defp cluster_notification_opts(opts), do: safe_notification_opts(opts)

  defp validate_cluster_notification_opts(opts) do
    case normalize_public_notification_opts(opts) do
      {:ok, opts} -> {:ok, opts}
      {:error, _reason} -> :error
    end
  end

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

        "resourceSubscriptions" ->
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
    budget_opts = json_budget_opts(opts)
    result = stamp_server_info(result, opts)

    with {:ok, result} <- canonical_wire_value(result, budget_opts),
         true <- Map.has_key?(result, "resultType"),
         :ok <- Schema.validate_modern_result(result, budget_opts) do
      JSONRPC.response(id, result)
    else
      _ -> JSONRPC.error_response(id, Error.internal(%{"reason" => "invalid_result"}))
    end
  end

  defp encode_outcome(id, {:ok, _result}, @modern, _opts),
    do: JSONRPC.error_response(id, Error.internal(%{"reason" => "invalid_result"}))

  defp encode_outcome(id, {:ok, result}, _era, opts) do
    budget_opts = json_budget_opts(opts)

    case canonical_wire_value(result, budget_opts) do
      {:ok, result} ->
        if Schema.json_value(result, budget_opts) == :ok,
          do: JSONRPC.response(id, result),
          else: JSONRPC.error_response(id, Error.internal(%{"reason" => "invalid_result"}))

      _ ->
        JSONRPC.error_response(id, Error.internal(%{"reason" => "invalid_result"}))
    end
  end

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
      method: Telemetry.protocol_method(method),
      transport: Keyword.get(opts, :transport, :core),
      protocol_version: Keyword.get(opts, :version),
      correlation_id: telemetry_correlation(id),
      server: Keyword.get(opts, :server_name),
      telemetry_metadata: Keyword.get(opts, :telemetry_metadata)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp state_telemetry(state, event, measurements, metadata) do
    metadata =
      metadata
      |> Map.put(:server, state.opts[:server_name])
      |> Map.put(:telemetry_metadata, state.opts[:telemetry_metadata])

    Telemetry.execute(event, measurements, metadata)
  end

  defp run_handler_task_init(nil, _caller, _context, _metadata, _reporter), do: :ok

  defp run_handler_task_init(callback, caller, context, metadata, reporter) do
    try do
      case HostCallback.invoke(callback, [caller, context]) do
        :ok ->
          :ok

        other ->
          Telemetry.report_exception(
            reporter,
            :handler_task_init,
            :error,
            {:invalid_return, other},
            [],
            metadata
          )

          {:error, :invalid_return}
      end
    catch
      kind, reason ->
        Telemetry.report_exception(
          reporter,
          :handler_task_init,
          kind,
          reason,
          __STACKTRACE__,
          metadata
        )

        {:error, :exception}
    end
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
         :ok <- validate_legacy_initialize_request(method, era, params, runtime.opts),
         :ok <- validate_era(era, params, runtime.opts),
         :ok <- validate_trace_context(params),
         :ok <- authorization(method, context, runtime.opts, era) do
      if context[:session_store_unavailable] == true do
        {:error, Error.session_store_unavailable()}
      else
        with :ok <- validate_protocol_binding(method, era, context, opts) do
          dispatch_method(era, method, params, context, runtime, opts)
        end
      end
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
    case metadata_value(params, "io.modelcontextprotocol/protocolVersion") do
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

  defp validate_legacy_initialize_request("initialize", era, params, opts)
       when era == @legacy and is_map(params) do
    client_info = params["clientInfo"]
    capabilities = params["capabilities"]

    if is_binary(params["protocolVersion"]) and is_map(capabilities) and
         valid_legacy_capabilities?(capabilities, opts) and valid_client_info?(client_info),
       do: :ok,
       else: {:error, Error.invalid_params(%{"reason" => "invalid_initialize_params"})}
  end

  defp validate_legacy_initialize_request("initialize", era, _params, _opts)
       when era == @legacy,
       do: {:error, Error.invalid_params(%{"reason" => "invalid_initialize_params"})}

  defp validate_legacy_initialize_request(_method, _era, _params, _opts), do: :ok

  defp valid_client_info?(%{"name" => name, "version" => version})
       when is_binary(name) and is_binary(version),
       do: name != "" and version != ""

  defp valid_client_info?(_), do: false

  defp valid_legacy_capabilities?(capabilities, opts) when is_map(capabilities) do
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

    Schema.json_value(capabilities, json_budget_opts(opts)) == :ok and
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

    required =
      cond do
        Map.get(context, :definition_scope_policy) == true ->
          []

        match?(scopes when is_list(scopes) and scopes != [], Map.get(scope_map, method)) ->
          Map.get(scope_map, method)

        is_list(Map.get(context, :default_scopes, opts[:default_scopes])) ->
          Map.get(context, :default_scopes, opts[:default_scopes]) || []

        true ->
          []
      end

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
    |> metadata()
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

        {:error, :session_store_unavailable} ->
          {:error, Error.session_store_unavailable()}

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

  defp dispatch_modern("tools/list", params, context, runtime, opts),
    do:
      list_result(
        runtime.registry,
        :tool,
        params,
        context,
        @modern,
        "tools",
        list_options(runtime.opts, opts)
      )

  defp dispatch_modern("resources/list", params, context, runtime, opts),
    do:
      list_result(
        runtime.registry,
        :resource,
        params,
        context,
        @modern,
        "resources",
        list_options(runtime.opts, opts)
      )

  defp dispatch_modern("resources/templates/list", params, context, runtime, opts),
    do:
      list_result(
        runtime.registry,
        :template,
        params,
        context,
        @modern,
        "resourceTemplates",
        list_options(runtime.opts, opts)
      )

  defp dispatch_modern("prompts/list", params, context, runtime, opts),
    do:
      list_result(
        runtime.registry,
        :prompt,
        params,
        context,
        @modern,
        "prompts",
        list_options(runtime.opts, opts)
      )

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

  defp dispatch_legacy("tools/list", params, context, runtime, opts),
    do:
      list_result(
        runtime.registry,
        :tool,
        params,
        context,
        @legacy,
        "tools",
        list_options(runtime.opts, opts)
      )

  defp dispatch_legacy("resources/list", params, context, runtime, opts),
    do:
      list_result(
        runtime.registry,
        :resource,
        params,
        context,
        @legacy,
        "resources",
        list_options(runtime.opts, opts)
      )

  defp dispatch_legacy("resources/templates/list", params, context, runtime, opts),
    do:
      list_result(
        runtime.registry,
        :template,
        params,
        context,
        @legacy,
        "resourceTemplates",
        list_options(runtime.opts, opts)
      )

  defp dispatch_legacy("prompts/list", params, context, runtime, opts),
    do:
      list_result(
        runtime.registry,
        :prompt,
        params,
        context,
        @legacy,
        "prompts",
        list_options(runtime.opts, opts)
      )

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

          {:error, :session_store_unavailable} ->
            {:error, Error.session_store_unavailable()}
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
      :ok ->
        {:ok, %{}}

      {:error, :invalid_uri} ->
        {:error, Error.invalid_params(%{"reason" => "invalid_resource_uri"})}

      {:error, :limit_reached} ->
        {:error, Error.invalid_params(%{"reason" => "resource_subscription_limit"})}

      {:error, :session_store_unavailable} ->
        {:error, Error.session_store_unavailable()}

      _ ->
        {:error, Error.invalid_params(%{"reason" => "session_not_found"})}
    end
  end

  defp resource_subscription(_params, _context, _runtime, _operation),
    do: {:error, Error.invalid_params(%{"reason" => "uri_required"})}

  defp validate_resource_subscription_uri(uri)
       when is_binary(uri) and byte_size(uri) in 1..@max_resource_subscription_uri_bytes do
    if String.valid?(uri) and not String.contains?(uri, ["\u0000", "\r", "\n"]),
      do: :ok,
      else: {:error, :invalid_uri}
  end

  defp validate_resource_subscription_uri(_uri), do: {:error, :invalid_uri}

  defp update_resource_subscriptions(:subscribe, subscriptions, uri) do
    cond do
      Map.has_key?(subscriptions, uri) ->
        {:ok, subscriptions}

      map_size(subscriptions) >= @max_resource_subscriptions_per_session ->
        {:error, :limit_reached}

      true ->
        {:ok, Map.put(subscriptions, :binary.copy(uri), true)}
    end
  end

  defp update_resource_subscriptions(:unsubscribe, subscriptions, uri),
    do: {:ok, Map.delete(subscriptions, uri)}

  defp metadata(params) when is_map(params) do
    case Map.get(params, "_meta") do
      metadata when is_map(metadata) -> metadata
      _ -> %{}
    end
  end

  defp metadata(_params), do: %{}
  defp metadata_value(params, key), do: Map.get(metadata(params), key)

  defp list_result(registry, type, params, context, era, key, opts) do
    values = Registry.list(registry, type) |> Enum.filter(&definition_visible?(&1, context, opts))
    page = page(values, params["cursor"], context, era, opts, type)

    if page[:error] do
      {:error, page.error}
    else
      definitions =
        Enum.map(page.items, &public_definition(type, &1, context[:protocol_version]))

      if Schema.json_value(definitions, json_budget_opts(opts)) == :ok do
        result = %{key => definitions}
        result = if era == @modern, do: Map.put(result, "resultType", "complete"), else: result

        {:ok, result |> maybe_put_cursor(page.cursor) |> maybe_cache(era, opts, context)}
      else
        {:error, Error.internal(%{"reason" => "invalid_catalog"})}
      end
    end
  end

  defp list_options(runtime_opts, dispatch_opts) do
    case Keyword.get(dispatch_opts, :definition_authorizer) do
      authorizer when is_function(authorizer, 1) ->
        Keyword.put(runtime_opts, :definition_authorizer, authorizer)

      _ ->
        runtime_opts
    end
  end

  defp page(values, nil, context, era, opts, type) do
    page_size = page_size(opts)
    cursor_opts = cursor_options(values, context, era, opts, page_size, type)

    %{
      items: Enum.take(values, page_size),
      cursor:
        if(length(values) > page_size,
          do: Cursor.issue(page_size, principal(context), era, cursor_opts)
        )
    }
  end

  defp page(values, cursor, context, era, opts, type) do
    page_size = page_size(opts)
    cursor_opts = cursor_options(values, context, era, opts, page_size, type)

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

  defp cursor_options(values, context, era, opts, page_size, type) do
    [
      secret: opts[:cursor_secret],
      ttl: opts[:cursor_ttl],
      catalog: type,
      tenant: tenant(context),
      scopes: Map.get(context, :scopes, Map.get(context, "scopes", [])) || [],
      visibility: Enum.map(values, & &1.identity),
      catalog_digest: Cursor.catalog_digest(values),
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
         {:ok, selected_definition} <-
           authorize_selected_tool(runtime.registry, name, context, opts),
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
         :ok <- validate_input_responses(state_payload, params, runtime.opts),
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
        operation,
        selected_definition
      )
    else
      false -> {:error, Error.invalid_params(%{"reason" => "tool_arguments_invalid"})}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp authorize_selected_tool(registry, name, context, opts) do
    if is_function(Keyword.get(opts, :definition_authorizer), 1) and is_binary(name) do
      case Registry.list(registry, :tool) |> Enum.find(&(&1.name == name)) do
        nil ->
          {:error, Error.invalid_params(%{"reason" => "unknown_tool", "name" => name})}

        tool ->
          if definition_visible?(tool, context, opts),
            do: {:ok, tool},
            else: {:error, Error.invalid_params(%{"reason" => "unknown_tool", "name" => name})}
      end
    else
      {:ok, :none}
    end
  rescue
    _ -> {:error, Error.invalid_params(%{"reason" => "unknown_tool", "name" => name})}
  end

  defp authorize_selected_resource(registry, uri, context, opts, era) do
    cond do
      not is_binary(uri) or not safe_uri?(uri) ->
        {:ok, :none}

      true ->
        snapshot = Registry.snapshot(registry)

        resources =
          snapshot
          |> Map.get(:resource, %{})
          |> Map.values()
          |> Enum.sort_by(& &1.identity)

        selected_policy? = is_function(Keyword.get(opts, :definition_authorizer), 1)

        candidate =
          case Enum.find(resources, fn resource ->
                 resource.uri == uri and (selected_policy? or visible?(resource, context))
               end) do
            resource when is_map(resource) ->
              {:ok, {resource, %{}}}

            nil ->
              templates =
                snapshot
                |> Map.get(:template, %{})
                |> Map.values()
                |> Enum.sort_by(& &1.identity)

              find_resource_template(
                templates,
                uri,
                context,
                selected_policy?,
                new_template_match_budget()
              )
          end

        case candidate do
          {:ok, nil} when selected_policy? ->
            {:error, unknown_resource_error(uri, era)}

          {:ok, nil} ->
            {:ok, :none}

          {:ok, {resource, _template_params} = selected} when selected_policy? ->
            if definition_visible?(resource, context, opts),
              do: {:ok, selected},
              else: {:error, unknown_resource_error(uri, era)}

          {:ok, selected} ->
            {:ok, selected}

          {:error, :template_match_budget_exhausted} ->
            template_match_budget_exhausted(:resource_read)

            {:error,
             Error.internal(%{
               "reason" => "uri_template_match_budget_exhausted",
               "type" => "resource_match_limit"
             })}
        end
    end
  rescue
    _ -> {:error, unknown_resource_error(uri, era)}
  end

  defp find_resource_template(templates, uri, context, selected_policy?, budget) do
    {result, _budget} =
      Enum.reduce_while(templates, {{:ok, nil}, budget}, fn template, {_result, budget} ->
        if selected_policy? or visible?(template, context) do
          case match_uri_template(template.uri_template, uri, budget) do
            {:ok, params, budget} ->
              {:halt, {{:ok, {template, params}}, budget}}

            {:error, budget} ->
              {:cont, {{:ok, nil}, budget}}

            {:exhausted, budget} ->
              {:halt, {{:error, :template_match_budget_exhausted}, budget}}
          end
        else
          {:cont, {{:ok, nil}, budget}}
        end
      end)

    result
  end

  defp unknown_resource_error(uri, @modern), do: Error.invalid_params(%{"uri" => uri})
  defp unknown_resource_error(uri, _era), do: Error.legacy_resource_not_found(uri)

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

  defp validate_input_responses(nil, params, _opts) do
    if Map.has_key?(params, "inputResponses"),
      do: {:error, Error.invalid_params(%{"reason" => "request_state_required"})},
      else: :ok
  end

  defp validate_input_responses(%{"q" => input_types}, params, opts)
       when is_map(input_types) do
    responses = input_responses(params)

    Enum.reduce_while(input_types, :ok, fn {key, method}, :ok ->
      case Map.fetch(responses, key) do
        {:ok, response} ->
          if valid_input_response?(method, response, opts),
            do: {:cont, :ok},
            else: {:halt, :invalid}

        :error ->
          {:halt, :invalid}
      end
    end)
    |> case do
      :ok -> :ok
      :invalid -> {:error, Error.invalid_params(%{"reason" => "invalid_input_response"})}
    end
  end

  defp validate_input_responses(_payload, _params, _opts), do: :ok

  defp valid_input_response?("elicitation/create:url", response, _opts) when is_map(response) do
    response["action"] in ["accept", "decline", "cancel"] and
      not Map.has_key?(response, "content")
  end

  defp valid_input_response?("elicitation/create", response, _opts) when is_map(response) do
    action = response["action"]

    action in ["accept", "decline", "cancel"] and
      (action != "accept" or is_map(response["content"]))
  end

  defp valid_input_response?(
         %{"method" => "elicitation/create", "params" => params},
         response,
         opts
       )
       when is_map(response) and is_map(params) do
    action = response["action"]

    action in ["accept", "decline", "cancel"] and
      case {params["mode"] || "form", action} do
        {"url", _} ->
          not Map.has_key?(response, "content")

        {"form", "accept"} ->
          is_map(response["content"]) and
            Schema.validate(
              response["content"],
              params["requestedSchema"],
              json_budget_opts(opts)
            ) == :ok

        {"form", _} ->
          true

        _ ->
          false
      end
  end

  defp valid_input_response?("sampling/createMessage", response, opts) when is_map(response) do
    response["role"] == "assistant" and valid_sampling_content?(response["content"], opts) and
      is_binary(response["model"]) and
      (is_nil(response["stopReason"]) or is_binary(response["stopReason"]))
  end

  defp valid_input_response?(%{"method" => "sampling/createMessage"}, response, opts),
    do: valid_input_response?("sampling/createMessage", response, opts)

  defp valid_input_response?("roots/list", response, _opts) when is_map(response) do
    is_list(response["roots"]) and Enum.all?(response["roots"], &valid_root_response?/1)
  end

  defp valid_input_response?(%{"method" => "roots/list"}, response, opts),
    do: valid_input_response?("roots/list", response, opts)

  defp valid_input_response?(_, _, _), do: false

  defp valid_sampling_content?(content, opts) when is_map(content),
    do: valid_content_item?(content, opts)

  defp valid_sampling_content?(content, opts) when is_list(content),
    do: Enum.all?(content, &valid_content_item?(&1, opts))

  defp valid_sampling_content?(_, _opts), do: false

  defp valid_root_response?(%{"uri" => uri} = root) when is_binary(uri) do
    String.starts_with?(uri, "file://") and (is_nil(root["name"]) or is_binary(root["name"]))
  end

  defp valid_root_response?(_), do: false

  defp normalize_input_requests(input, opts) do
    budget_opts = json_budget_opts(opts)

    with {:ok, input} <- canonical_wire_value(input, budget_opts) do
      cond do
        is_map(input) and Map.has_key?(input, "method") ->
          normalize_input_entries([{"input_1", input}], budget_opts)

        is_map(input) ->
          input
          |> Enum.sort_by(fn {key, _value} -> key end)
          |> normalize_input_entries(budget_opts)

        is_list(input) ->
          input
          |> Enum.with_index(1)
          |> Enum.map(fn {value, index} -> {"input_#{index}", value} end)
          |> normalize_input_entries(budget_opts)

        true ->
          {:error, :invalid_input_requests}
      end
    else
      _ -> {:error, :invalid_input_requests}
    end
  end

  defp normalize_input_entries(entries, opts) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {key, request}, {:ok, acc} ->
      with true <- is_binary(key) and byte_size(key) in 1..128,
           {:ok, request} <- normalize_input_request(request, opts),
           false <- Map.has_key?(acc, key) do
        {:cont, {:ok, Map.put(acc, key, request)}}
      else
        _ -> {:halt, {:error, :invalid_input_requests}}
      end
    end)
  end

  defp normalize_input_request(request, opts) when is_map(request) do
    with {:ok, request} <- canonical_wire_value(request, json_budget_opts(opts)),
         method when method in ["elicitation/create", "sampling/createMessage", "roots/list"] <-
           request["method"],
         params when is_map(params) <- Map.get(request, "params", %{}),
         :ok <- validate_input_request_json(method, params, opts),
         true <- valid_input_request_params?(method, params, opts) do
      {:ok, %{"method" => method, "params" => params}}
    else
      _ -> {:error, :invalid_input_request}
    end
  end

  defp normalize_input_request(_, _opts), do: {:error, :invalid_input_request}

  defp valid_input_request_params?("elicitation/create", params, opts) do
    message = params["message"]
    mode = params["mode"] || "form"

    is_binary(message) and byte_size(message) in 1..10_000 and
      ((mode == "form" and valid_requested_schema?(params["requestedSchema"], opts)) or
         (mode == "url" and is_binary(params["url"]) and
            Schema.validate(
              params["url"],
              %{"type" => "string", "format" => "uri"},
              json_budget_opts(opts)
            ) == :ok))
  end

  defp valid_input_request_params?("sampling/createMessage", params, opts) do
    is_list(params["messages"]) and
      Enum.all?(params["messages"], fn message ->
        is_map(message) and message["role"] in ["user", "assistant"] and
          valid_sampling_content?(message["content"], opts)
      end)
  end

  defp valid_input_request_params?("roots/list", _params, _opts), do: true

  defp valid_requested_schema?(schema, opts) when is_map(schema) do
    properties = schema["properties"] || %{}
    required = schema["required"] || []

    Schema.validate_schema(schema, json_budget_opts(opts)) == :ok and schema["type"] == "object" and
      is_map(properties) and is_list(required) and
      Enum.all?(required, &(is_binary(&1) and Map.has_key?(properties, &1))) and
      Enum.all?(properties, fn {name, property} ->
        is_binary(name) and valid_requested_property_schema?(property, opts)
      end)
  end

  defp valid_requested_schema?(_, _opts), do: false

  defp valid_requested_property_schema?(schema, opts) when is_map(schema) do
    schema["type"] in ["string", "number", "integer", "boolean"] and
      Schema.validate_schema(schema, json_budget_opts(opts)) == :ok and
      not Map.has_key?(schema, "properties") and not Map.has_key?(schema, "items")
  end

  defp valid_requested_property_schema?(_, _opts), do: false

  defp validate_input_request_json(_method, params, opts) when is_map(params) do
    if json_value?(params, opts), do: :ok, else: {:error, :invalid_input_request}
  end

  defp require_input_capabilities(params, requests) do
    capabilities =
      case metadata_value(params, "io.modelcontextprotocol/clientCapabilities") do
        value when is_map(value) -> value
        _ -> %{}
      end

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

  defp modern_result(result, opts) do
    budget_opts = json_budget_opts(opts)

    case Schema.validate_modern_result(result, budget_opts) do
      :ok -> {:ok, result}
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
         operation,
         selected_definition
       ) do
    tool =
      case selected_definition do
        definition when is_map(definition) ->
          definition

        _ ->
          Enum.find(
            Registry.list(runtime.registry, :tool),
            &(&1.name == name and visible?(&1, context))
          )
      end

    case tool do
      nil ->
        {:error, Error.invalid_params(%{"reason" => "unknown_tool", "name" => name})}

      tool when is_map(tool) ->
        handler_context = handler_identity_context(context, :tool, tool)

        with :ok <-
               Schema.validate(arguments, tool.input_schema,
                 max_bytes: runtime.opts[:max_json_bytes]
               ),
             handler_arguments <-
               handler_tool_arguments(
                 arguments,
                 tool.input_schema,
                 runtime.opts[:tool_argument_keys],
                 tool.handler
               ),
             result <-
               invoke(
                 tool.handler,
                 handler_arguments,
                 handler_context,
                 opts
               ) do
          case result do
            {:input_required, input} when era == @modern ->
              with {:ok, requests} <- normalize_input_requests(input, runtime.opts),
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

                modern_result(
                  %{
                    "resultType" => "input_required",
                    "inputRequests" => requests,
                    "requestState" => state
                  },
                  runtime.opts
                )
              else
                {:error, :invalid_input_requests} ->
                  {:error, Error.invalid_params(%{"reason" => "invalid_input_requests"})}

                {:error, %Error{} = error} ->
                  {:error, error}
              end

            {:ok, output_value} ->
              output = normalize_tool_result(output_value, runtime.opts, handler_context)
              output = if era == @legacy, do: legacy_tool_result(output), else: output
              output = filter_tool_result_revision(output, context[:protocol_version])

              output =
                if not is_nil(tool.output_schema),
                  do: validate_output(output, tool.output_schema, runtime.opts),
                  else: output

              if valid_tool_result?(output, runtime.opts) do
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

            {:error, reason} ->
              {:ok, tool_error_result(reason, era)}
          end
        else
          {:error, %Error{} = error} ->
            {:error, error}

          {:error, _reason} ->
            {:error, Error.invalid_params(%{"reason" => "tool_arguments_invalid"})}
        end
    end
  end

  defp read_resource(params, context, runtime, opts, era) do
    uri = params["uri"]
    salient = Map.drop(params, ["requestState", "inputResponses"])
    operation = %{"resource" => uri}

    with {:ok, selected_definition} <-
           authorize_selected_resource(runtime.registry, uri, context, opts, era),
         {:ok, state_payload} <-
           verify_retry_state(
             params,
             context,
             era,
             "resources/read",
             salient,
             operation,
             runtime.opts
           ),
         :ok <- validate_input_responses(state_payload, params, runtime.opts),
         :ok <- consume_retry_state(state_payload, runtime.opts) do
      read_resource_validated(
        params,
        context,
        runtime,
        era,
        uri,
        salient,
        operation,
        state_payload,
        selected_definition
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
         state_payload,
         selected_definition
       ) do
    if is_binary(uri) and safe_uri?(uri) do
      resolved_resource =
        case selected_definition do
          {resource, template_params} -> {resource, template_params}
          _ -> nil
        end

      case resolved_resource do
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
                 handler_identity_context(
                   context,
                   if(resource[:uri_template] || resource["uri_template"],
                     do: :template,
                     else: :resource
                   ),
                   resource
                 ),
                 []
               ) do
            {:input_required, input} when era == @modern ->
              with {:ok, requests} <- normalize_input_requests(input, runtime.opts),
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

                modern_result(
                  %{
                    "resultType" => "input_required",
                    "inputRequests" => requests,
                    "requestState" => request_state
                  },
                  runtime.opts
                )
              else
                {:error, :invalid_input_requests} ->
                  {:error, Error.invalid_params(%{"reason" => "invalid_input_requests"})}

                {:error, %Error{} = error} ->
                  {:error, error}
              end

            {:ok, content} ->
              normalized = normalize_resource_contents(content, runtime.opts)

              normalized =
                if era == @legacy, do: Map.delete(normalized, "resultType"), else: normalized

              normalized =
                filter_resource_result_revision(normalized, context[:protocol_version])

              if valid_resource_result?(normalized, runtime.opts) do
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

            {:error, reason} ->
              {:error, application_error(reason, %{"reason" => "resource_handler_failure"})}
          end
      end
    else
      {:error, Error.invalid_params(%{"reason" => "unsafe_resource_uri"})}
    end
  end

  # URI-template matching is deliberately bounded and only accepts layouts that
  # the registration validator declares supported. For a supported path, a
  # delimiter inside a valid capture is resolved by the bounded matcher below;
  # query keys remain exact and decoding never relaxes path-safety checks.
  defp match_uri_template(template, uri, budget)
       when is_binary(template) and is_binary(uri) and is_map(budget) do
    with {:ok, budget} <- reserve_template_match_candidate(budget),
         {:ok, budget} <-
           consume_template_match_work(budget, byte_size(template) + byte_size(uri) + 1) do
      match_uri_template_with_budget(template, uri, budget)
    else
      {:exhausted, budget} -> {:exhausted, budget}
    end
  rescue
    _ -> {:error, budget}
  end

  defp match_uri_template(_template, _uri, budget), do: {:error, budget}

  defp match_uri_template_with_budget(template, uri, budget) do
    if String.valid?(template) and String.valid?(uri) and
         byte_size(uri) <= @max_template_uri_bytes do
      case template_parts(template) do
        {:ok, parts} ->
          expressions = for {:expression, expression} <- parts, do: expression

          cond do
            expressions == [] or length(expressions) > @max_template_expressions ->
              {:error, budget}

            length(expressions) > @max_template_variables ->
              {:error, budget}

            Enum.any?(expressions, &(byte_size(&1) > @max_template_expression_bytes)) ->
              {:error, budget}

            not template_literal_boundaries_match?(parts, uri) ->
              {:error, budget}

            length(expressions) == 1 ->
              with {:ok, budget} <- consume_template_match_work(budget, byte_size(uri)) do
                case match_single_template(template, uri, hd(expressions)) do
                  {:ok, params} -> {:ok, params, budget}
                  :error -> {:error, budget}
                end
              else
                {:exhausted, budget} -> {:exhausted, budget}
              end

            true ->
              with {:ok, budget} <-
                     consume_template_match_work(
                       budget,
                       multi_template_setup_work(parts, uri)
                     ) do
                match_multi_path_template(parts, uri, expressions, budget)
              else
                {:exhausted, budget} -> {:exhausted, budget}
              end
          end

        :error ->
          {:error, budget}
      end
    else
      {:error, budget}
    end
  rescue
    _ -> {:error, budget}
  end

  defp new_template_match_budget do
    %{work: @max_template_match_work, candidates: @max_template_match_candidates}
  end

  defp template_literal_boundaries_match?(parts, uri)
       when is_list(parts) and is_binary(uri) do
    literals = for {:literal, literal} <- parts, do: literal
    prefix = List.first(literals) || ""
    suffix = List.last(literals) || ""

    String.starts_with?(uri, prefix) and
      (suffix == "" or String.ends_with?(uri, suffix))
  end

  defp reserve_template_match_candidate(%{candidates: candidates} = budget)
       when is_integer(candidates) and candidates > 0,
       do: {:ok, %{budget | candidates: candidates - 1}}

  defp reserve_template_match_candidate(budget), do: {:exhausted, exhaust_match_budget(budget)}

  defp consume_template_match_work(%{work: remaining} = budget, work)
       when is_integer(remaining) and is_integer(work) and work >= 0 and remaining >= work,
       do: {:ok, %{budget | work: remaining - work}}

  defp consume_template_match_work(budget, _work),
    do: {:exhausted, exhaust_match_budget(budget)}

  defp exhaust_match_budget(%{work: _work} = budget), do: %{budget | work: 0}
  defp exhaust_match_budget(budget), do: budget

  defp template_match_budget_exhausted(operation) do
    Telemetry.execute(
      [:uri_template, :budget_exhausted],
      %{count: 1},
      %{source: operation, outcome: :rejected}
    )
  end

  defp multi_template_setup_work(parts, uri) do
    literals = for {:literal, literal} <- parts, do: literal
    uri_bytes = byte_size(uri)
    delimiter_scan_work = uri_bytes * max(length(Enum.uniq(literals)), 1)
    terminal_window_bytes = min(uri_bytes, @max_template_value_bytes)

    terminal_source =
      binary_part(uri, uri_bytes - terminal_window_bytes, terminal_window_bytes)

    terminal_scan_work =
      if String.contains?(terminal_source, "%") or not ascii_binary?(terminal_source) do
        div(terminal_window_bytes * (terminal_window_bytes + 1), 2)
      else
        terminal_window_bytes
      end

    uri_bytes + delimiter_scan_work + terminal_scan_work
  rescue
    _ -> @max_template_match_work
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

  defp template_parts(template) when is_binary(template) do
    matches = Regex.scan(~r/\{([^{}]+)\}/, template, return: :index)

    if matches == [] do
      :error
    else
      build_template_parts(template, matches, 0, [])
    end
  rescue
    _ -> :error
  end

  defp build_template_parts(template, [], offset, acc) do
    suffix_size = byte_size(template) - offset

    if suffix_size >= 0 do
      literal = binary_part(template, offset, suffix_size)

      if String.contains?(literal, ["{", "}"]) do
        :error
      else
        {:ok, Enum.reverse([{:literal, literal} | acc])}
      end
    else
      :error
    end
  end

  defp build_template_parts(
         template,
         [[{start, length}, {expression_start, expression_length}] | rest],
         offset,
         acc
       )
       when start >= offset and expression_start >= start and expression_length >= 1 do
    literal_length = start - offset
    literal = binary_part(template, offset, literal_length)
    expression = binary_part(template, expression_start, expression_length)

    if String.contains?(literal, ["{", "}"]) do
      :error
    else
      build_template_parts(
        template,
        rest,
        start + length,
        [{:expression, expression}, {:literal, literal} | acc]
      )
    end
  rescue
    _ -> :error
  end

  defp build_template_parts(_template, _matches, _offset, _acc), do: :error

  defp match_multi_path_template(parts, uri, expressions, budget) do
    if multi_path_layout?(parts, expressions) do
      literals = for {:literal, literal} <- parts, do: literal
      delimiter_positions = template_delimiter_positions(uri, literals)

      with {:ok, parsed_expressions} <- parse_path_template_expressions(expressions),
           ascii_uri <- ascii_binary?(uri),
           terminal_starts <-
             terminal_capture_positions(uri, List.last(parsed_expressions), List.last(literals)),
           true <- terminal_starts != MapSet.new(),
           true <- literal_at?(uri, 0, hd(literals)) do
        {result, _memo, budget, _steps} =
          match_multi_path_expressions(
            literals,
            parsed_expressions,
            uri,
            0,
            byte_size(hd(literals)),
            delimiter_positions,
            path_remaining_bounds(literals, length(parsed_expressions)),
            terminal_starts,
            ascii_uri,
            %{},
            budget,
            0
          )

        case result do
          {:ok, params, position} when position == byte_size(uri) -> {:ok, params, budget}
          :exhausted -> {:exhausted, budget}
          _ -> {:error, budget}
        end
      else
        _ -> {:error, budget}
      end
    else
      {:error, budget}
    end
  end

  defp multi_path_layout?(parts, expressions) do
    literals = for {:literal, literal} <- parts, do: literal

    length(expressions) <= @max_template_expressions and
      length(expressions) <= @max_template_variables and
      length(literals) == length(expressions) + 1 and
      Enum.all?(expressions, &single_path_expression?/1) and
      no_adjacent_path_expressions?(literals)
  end

  defp single_path_expression?(expression) do
    case parse_template_expression(expression) do
      {:ok, operator, [_spec]} when operator in [nil, ?+] -> true
      _ -> false
    end
  end

  defp no_adjacent_path_expressions?(literals) do
    last_index = length(literals) - 1

    literals
    |> Enum.with_index()
    |> Enum.all?(fn
      {_literal, 0} -> true
      {_literal, index} when index == last_index -> true
      {literal, _index} -> literal != ""
    end)
  end

  # A delimiter can occur inside an expanded value. We therefore try every
  # bounded delimiter position from the URI suffix inward and memoize every
  # {expression, position} suffix decision. Suffix-first ordering also avoids
  # mistaking a delimiter encoded inside one grapheme for the separator before
  # the next expression. This is a finite dynamic-programming matcher: URI
  # input is capped above, each state is evaluated once, and remaining-length
  # and terminal-capture indexes discard impossible splits before decoding
  # them. The candidate budget is a final fail-closed guard.
  defp parse_path_template_expressions(expressions) do
    parsed =
      Enum.map(expressions, fn expression ->
        case parse_template_expression(expression) do
          {:ok, operator, [spec]} when operator in [nil, ?+] -> {:ok, {operator, spec}}
          _ -> :error
        end
      end)

    if Enum.all?(parsed, &match?({:ok, _}, &1)),
      do: {:ok, Enum.map(parsed, fn {:ok, value} -> value end)},
      else: :error
  end

  defp path_remaining_bounds(literals, expression_count)
       when is_list(literals) and is_integer(expression_count) and expression_count > 0 do
    Enum.map(0..(expression_count - 1), fn expression_index ->
      future_expression_count = expression_count - expression_index - 1

      future_literal_bytes =
        literals
        |> Enum.drop(expression_index + 2)
        |> Enum.reduce(0, fn literal, total -> total + byte_size(literal) end)

      {
        future_expression_count + future_literal_bytes,
        future_expression_count * @max_template_value_bytes + future_literal_bytes
      }
    end)
  end

  defp path_remaining_bounds(_literals, _expression_count), do: []

  defp terminal_capture_positions(uri, {operator, spec}, delimiter)
       when is_binary(uri) and is_binary(delimiter) and operator in [nil, ?+] do
    terminal_position = byte_size(uri) - byte_size(delimiter)

    if terminal_position >= 1 and literal_at?(uri, terminal_position, delimiter) do
      lower_position = max(terminal_position - @max_template_value_bytes, 0)

      if String.contains?(
           binary_part(uri, lower_position, terminal_position - lower_position),
           "%"
         ) do
        Enum.reduce(lower_position..(terminal_position - 1), MapSet.new(), fn position,
                                                                              positions ->
          value = binary_part(uri, position, terminal_position - position)

          case decode_path_template_value(value, operator, spec) do
            {:ok, _decoded} -> MapSet.put(positions, position)
            :error -> positions
          end
        end)
      else
        plain_terminal_capture_positions(
          uri,
          lower_position,
          terminal_position,
          operator,
          spec
        )
      end
    else
      MapSet.new()
    end
  rescue
    _ -> MapSet.new()
  end

  defp terminal_capture_positions(_uri, _expression, _delimiter), do: MapSet.new()

  defp plain_path_capture_valid?(value, operator, spec) when is_binary(value) do
    value != "" and byte_size(value) <= @max_template_value_bytes and
      (operator == ?+ or not String.contains?(value, ["/", "?", "#"])) and
      not unsafe_template_value?(value) and prefix_length_ok?(value, spec.prefix)
  end

  defp plain_terminal_capture_positions(uri, lower_position, terminal_position, operator, spec) do
    source = binary_part(uri, lower_position, terminal_position - lower_position)
    unsafe_offset = last_plain_unsafe_offset(source, operator)
    lower_position = max(lower_position, lower_position + unsafe_offset + 1)

    if lower_position >= terminal_position do
      MapSet.new()
    else
      case spec.prefix do
        nil ->
          MapSet.new(lower_position..(terminal_position - 1))

        prefix when is_integer(prefix) ->
          if ascii_binary?(source) do
            lower_position = max(lower_position, terminal_position - prefix)

            if lower_position < terminal_position,
              do: MapSet.new(lower_position..(terminal_position - 1)),
              else: MapSet.new()
          else
            Enum.reduce(lower_position..(terminal_position - 1), MapSet.new(), fn position,
                                                                                  positions ->
              value = binary_part(uri, position, terminal_position - position)

              if plain_path_capture_valid?(value, operator, spec),
                do: MapSet.put(positions, position),
                else: positions
            end)
          end
      end
    end
  end

  defp ascii_binary?(value) when is_binary(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(&(&1 < 128))
  end

  defp last_plain_unsafe_offset(source, operator) when is_binary(source) do
    last_offset = byte_size(source) - 1

    if last_offset >= 0 do
      Enum.reduce(0..last_offset, -1, fn offset, latest ->
        byte = :binary.at(source, offset)
        next_byte = if offset < last_offset, do: :binary.at(source, offset + 1), else: nil

        unsafe_separator = operator == nil and byte in [?/, ??, ?#]
        unsafe_byte = byte in [?\\, 0, ?\r, ?\n]
        unsafe_dot_pair = byte == ?. and next_byte == ?.

        if unsafe_separator or unsafe_byte or unsafe_dot_pair, do: offset, else: latest
      end)
    else
      -1
    end
  end

  defp match_multi_path_expressions(
         literals,
         expressions,
         uri,
         expression_index,
         position,
         delimiter_positions,
         remaining_bounds,
         terminal_starts,
         ascii_uri,
         memo,
         budget,
         steps
       ) do
    key = {expression_index, position}

    case Map.fetch(memo, key) do
      {:ok, result} ->
        {result, memo, budget, steps}

      :error ->
        {result, memo, budget, steps} =
          if expression_index == length(expressions) do
            if position == byte_size(uri) do
              {{:ok, %{}, position}, memo, budget, steps}
            else
              {:error, memo, budget, steps}
            end
          else
            {operator, spec} = Enum.at(expressions, expression_index)
            delimiter = Enum.at(literals, expression_index + 1)

            try_multi_path_candidates(
              candidate_positions_from(
                delimiter_positions,
                uri,
                delimiter,
                position,
                expression_index,
                length(expressions),
                spec,
                remaining_bounds,
                terminal_starts,
                ascii_uri
              ),
              delimiter,
              operator,
              spec,
              literals,
              expressions,
              uri,
              expression_index,
              position,
              delimiter_positions,
              remaining_bounds,
              terminal_starts,
              ascii_uri,
              memo,
              budget,
              steps
            )
          end

        {result, Map.put(memo, key, result), budget, steps}
    end
  rescue
    _ -> {:error, memo, budget, steps}
  end

  defp try_multi_path_candidates(
         [],
         _delimiter,
         _operator,
         _spec,
         _literals,
         _expressions,
         _uri,
         _expression_index,
         _position,
         _delimiter_positions,
         _remaining_bounds,
         _terminal_starts,
         _ascii_uri,
         memo,
         budget,
         steps
       ),
       do: {:error, memo, budget, steps}

  defp try_multi_path_candidates(
         [offset | rest],
         delimiter,
         operator,
         spec,
         literals,
         expressions,
         uri,
         expression_index,
         position,
         delimiter_positions,
         remaining_bounds,
         terminal_starts,
         ascii_uri,
         memo,
         budget,
         steps
       ) do
    if steps >= @max_template_match_steps do
      {:exhausted, memo, exhaust_match_budget(budget), steps}
    else
      case consume_template_match_work(budget, 1) do
        {:ok, budget} ->
          steps = steps + 1
          value = binary_part(uri, position, offset)

          case decode_path_template_value(value, operator, spec) do
            {:ok, decoded} ->
              next_position = position + offset + byte_size(delimiter)

              {result, memo, budget, steps} =
                match_multi_path_expressions(
                  literals,
                  expressions,
                  uri,
                  expression_index + 1,
                  next_position,
                  delimiter_positions,
                  remaining_bounds,
                  terminal_starts,
                  ascii_uri,
                  memo,
                  budget,
                  steps
                )

              case result do
                {:ok, params, final_position} ->
                  {{:ok, Map.put(params, spec.name, decoded), final_position}, memo, budget,
                   steps}

                :exhausted ->
                  {:exhausted, memo, budget, steps}

                :error ->
                  try_multi_path_candidates(
                    rest,
                    delimiter,
                    operator,
                    spec,
                    literals,
                    expressions,
                    uri,
                    expression_index,
                    position,
                    delimiter_positions,
                    remaining_bounds,
                    terminal_starts,
                    ascii_uri,
                    memo,
                    budget,
                    steps
                  )
              end

            :error ->
              try_multi_path_candidates(
                rest,
                delimiter,
                operator,
                spec,
                literals,
                expressions,
                uri,
                expression_index,
                position,
                delimiter_positions,
                remaining_bounds,
                terminal_starts,
                ascii_uri,
                memo,
                budget,
                steps
              )
          end

        {:exhausted, budget} ->
          {:exhausted, memo, budget, steps}
      end
    end
  rescue
    _ -> {:error, memo, budget, steps}
  end

  defp template_delimiter_positions(uri, literals) when is_binary(uri) and is_list(literals) do
    literals
    |> Enum.uniq()
    |> Map.new(fn
      "" -> {"", [byte_size(uri)]}
      delimiter -> {delimiter, delimiter_positions(uri, delimiter)}
    end)
  end

  defp template_delimiter_positions(_uri, _literals), do: %{}

  defp delimiter_positions(uri, delimiter)
       when is_binary(uri) and is_binary(delimiter) and delimiter != "" do
    max_position = byte_size(uri) - byte_size(delimiter)

    if max_position >= 0 do
      for position <- 0..max_position, literal_at?(uri, position, delimiter), do: position
    else
      []
    end
  rescue
    _ -> []
  end

  defp delimiter_positions(_uri, _delimiter), do: []

  defp candidate_positions_from(
         delimiter_positions,
         uri,
         delimiter,
         position,
         expression_index,
         expression_count,
         spec,
         remaining_bounds,
         terminal_starts,
         ascii_uri
       )
       when is_map(delimiter_positions) and is_binary(uri) and is_integer(position) and
              position >= 0 and is_integer(expression_index) and expression_index >= 0 and
              is_integer(expression_count) and expression_count > expression_index and
              is_list(remaining_bounds) and is_struct(terminal_starts, MapSet) and
              is_boolean(ascii_uri) do
    {min_remaining, max_remaining} = Enum.at(remaining_bounds, expression_index)
    delimiter_bytes = byte_size(delimiter)
    uri_bytes = byte_size(uri)

    max_possible_capture_bytes =
      min(
        @max_template_value_bytes,
        max(uri_bytes - delimiter_bytes - min_remaining - position, 0)
      )

    percent_in_capture_window? =
      max_possible_capture_bytes > 0 and
        :binary.match(uri, "%", scope: {position, max_possible_capture_bytes}) != :nomatch

    ascii_capture_window? =
      ascii_uri or
        ascii_binary?(binary_part(uri, position, max_possible_capture_bytes))

    raw_prefix_pruning_safe? = ascii_capture_window? and not percent_in_capture_window?

    max_capture_bytes =
      case {raw_prefix_pruning_safe?, spec.prefix} do
        # Prefixes count decoded graphemes, so a raw-byte bound is sound only
        # for unescaped ASCII in this capture's possible byte window. Percent
        # escapes can form arbitrarily many combining codepoints in one
        # grapheme cluster.
        {true, prefix} when is_integer(prefix) ->
          min(@max_template_value_bytes, prefix)

        _ ->
          @max_template_value_bytes
      end

    lower_position = max(position + 1, uri_bytes - delimiter_bytes - max_remaining)

    upper_position =
      min(
        position + max_capture_bytes,
        uri_bytes - delimiter_bytes - min_remaining
      )

    positions =
      delimiter_positions
      |> Map.get(delimiter, [])
      |> Enum.drop_while(&(&1 < lower_position))
      |> Enum.take_while(&(&1 <= upper_position))

    positions =
      if expression_index == expression_count - 2 do
        Enum.filter(positions, fn candidate ->
          MapSet.member?(terminal_starts, candidate + delimiter_bytes)
        end)
      else
        positions
      end

    positions
    |> Enum.reverse()
    |> Enum.map(&(&1 - position))
  end

  defp candidate_positions_from(
         _delimiter_positions,
         _uri,
         _delimiter,
         _position,
         _expression_index,
         _expression_count,
         _spec,
         _remaining_bounds,
         _terminal_starts,
         _ascii_uri
       ),
       do: []

  defp literal_at?(uri, position, literal)
       when is_binary(uri) and is_integer(position) and position >= 0 and is_binary(literal) do
    position + byte_size(literal) <= byte_size(uri) and
      binary_part(uri, position, byte_size(literal)) == literal
  rescue
    _ -> false
  end

  defp decode_path_template_value(value, operator, spec) do
    if value == "" or byte_size(value) > @max_template_value_bytes or
         (operator == nil and String.contains?(value, ["/", "?", "#"])) do
      :error
    else
      with {:ok, decoded} <- strict_template_decode(value, :path),
           false <- unsafe_template_value?(decoded),
           false <- operator == nil and String.contains?(decoded, ["/", "?", "#"]),
           true <- prefix_length_ok?(decoded, spec.prefix) do
        {:ok, decoded}
      else
        _ -> :error
      end
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
           false <- operator == nil and String.contains?(decoded, ["/", "?", "#"]),
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
         (String.contains?(value, "%") and Regex.match?(~r/%(?![0-9A-Fa-f]{2})/, value)) do
      :error
    else
      source = if mode == :query, do: String.replace(value, "+", " "), else: value

      try do
        decoded = if String.contains?(source, "%"), do: URI.decode(source), else: source

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
         :ok <- validate_input_responses(state_payload, params, runtime.opts),
         :ok <- consume_retry_state(state_payload, runtime.opts) do
      case Registry.list(runtime.registry, :prompt)
           |> Enum.filter(&(&1.name == name and visible?(&1, context))) do
        [] ->
          {:error, Error.invalid_params(%{"name" => name})}

        [prompt | _] ->
          prompt_arguments = Map.merge(arguments, input_responses(params, state_payload))

          input_keys = if is_map(state_payload), do: Map.get(state_payload, "k", []), else: []

          case invoke_prompt(
                 prompt,
                 name,
                 prompt_arguments,
                 handler_identity_context(context, :prompt, prompt),
                 input_keys
               ) do
            {:input_required, input} when era == @modern ->
              with {:ok, requests} <- normalize_input_requests(input, runtime.opts),
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

                modern_result(
                  %{
                    "resultType" => "input_required",
                    "inputRequests" => requests,
                    "requestState" => request_state
                  },
                  runtime.opts
                )
              else
                {:error, :invalid_input_requests} ->
                  {:error, Error.invalid_params(%{"reason" => "invalid_input_requests"})}

                {:error, %Error{} = error} ->
                  {:error, error}
              end

            {:ok, content} ->
              normalized = normalize_prompt_messages(content, runtime.opts)

              normalized =
                if era == @legacy, do: Map.delete(normalized, "resultType"), else: normalized

              normalized = filter_prompt_result_revision(normalized, context[:protocol_version])

              if valid_prompt_result?(normalized, runtime.opts) do
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

            {:error, reason} ->
              {:error, application_error(reason, %{"reason" => "prompt_handler_failure"})}
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
              era,
              runtime.opts
            )
        end
    end
  end

  defp completion_result(entry, ref, argument, value, completion_context, context, era, opts) do
    budget_opts = json_budget_opts(opts)

    case invoke(
           entry.handler,
           %{ref: ref, argument: argument, value: value, context: completion_context},
           handler_identity_context(context, :completion, entry),
           []
         ) do
      {:ok, result} ->
        with {:ok, result} <- canonical_wire_value(result, budget_opts),
             {values, supplied_total, supplied_more} <- completion_values(result),
             true <- is_list(values) and Enum.all?(values, &is_binary/1),
             values <- Enum.uniq(values),
             true <- valid_completion_metadata?(supplied_total, supplied_more),
             true <- is_nil(supplied_total) or supplied_total >= length(values) do
          emitted = Enum.take(values, 100)
          total = supplied_total || length(values)
          has_more = supplied_more == true or total > length(emitted)

          response = %{
            "completion" => %{"values" => emitted, "total" => total, "hasMore" => has_more}
          }

          {:ok,
           if(era == @modern, do: Map.put(response, "resultType", "complete"), else: response)}
        else
          _ -> {:error, Error.internal(%{"reason" => "invalid_completion_result"})}
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
          modern_result(
            %{
              "resultType" => "complete",
              "_meta" => %{"io.modelcontextprotocol/subscriptionId" => id}
            },
            runtime.opts
          )

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
    scopes = Map.get(context, :scopes, Map.get(context, "scopes", [])) || []

    scope_sets_grant?(Registry.scope_sets(definition), scopes) and
      authorize_callback(definition[:authorize], context)
  end

  defp definition_visible?(definition, context, opts) do
    definition_authorized?(definition, opts) and visible?(definition, context)
  end

  # HTTP definition policies provide this callback only after the request has
  # authenticated through the prepared ProtectResource boundary. Keep the
  # callback beside the selected definition and before handler invocation so a
  # denied definition has the same neutral result as an unknown one.
  defp definition_authorized?(definition, opts) do
    case Keyword.get(opts, :definition_authorizer) do
      authorizer when is_function(authorizer, 1) ->
        definition
        |> Registry.scope_sets()
        |> Enum.any?(fn required ->
          try do
            authorizer.(required) == :ok
          rescue
            _ -> false
          catch
            _, _ -> false
          end
        end)

      _ ->
        true
    end
  end

  defp scope_sets_grant?(scope_sets, granted)
       when is_list(scope_sets) and scope_sets != [] and is_list(granted),
       do: Enum.any?(scope_sets, &scopes_grant?(&1, granted))

  defp scope_sets_grant?(_scope_sets, _granted), do: false

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

  defp handler_identity_context(context, type, definition) do
    context
    |> Map.put(:primitive_type, type)
    |> Map.put(:primitive_identity, definition[:identity] || definition["identity"])
  end

  defp invoke_with_telemetry(callback, context) do
    Telemetry.span(
      :handler,
      %{
        method: Telemetry.protocol_method(Map.get(context, :method, "handler")),
        transport: Map.get(context, :transport, :core),
        correlation_id: telemetry_correlation(Map.get(context, :request_id)),
        primitive_type: Map.get(context, :primitive_type),
        primitive_identity: Map.get(context, :primitive_identity),
        telemetry_metadata: Map.get(context, :telemetry_metadata)
      },
      fn ->
        result = normalize_handler_result(callback.())
        {result, %{outcome: handler_outcome(result)}}
      end,
      exception_reporter: Map.get(context, :exception_reporter)
    )
  end

  defp handler_outcome({:ok, _}), do: :ok
  defp handler_outcome({:input_required, _}), do: :input_required
  defp handler_outcome({:error, _}), do: :error

  defp tool_error_result(reason, era) do
    {message, code} = client_error_fields(reason, "tool execution failed")

    %{
      "content" => [%{"type" => "text", "text" => message}],
      "isError" => true,
      "_meta" => if(is_binary(code), do: %{"io.attesto/errorCode" => code}),
      "resultType" => if(era == @modern, do: "complete")
    }
    |> drop_nil()
  end

  defp application_error(reason, fallback_data) do
    case client_error_fields(reason, nil) do
      {message, code} when is_binary(message) -> Error.application(message, code)
      _private -> Error.internal(fallback_data)
    end
  end

  defp client_error_fields(%Result.ClientError{message: message, code: code}, fallback) do
    if Result.valid_message?(message) and Result.valid_code?(code),
      do: {message, code},
      else: {fallback, nil}
  end

  defp client_error_fields(_reason, fallback), do: {fallback, nil}

  defp normalize_handler_result({:ok, value}), do: {:ok, value}
  defp normalize_handler_result({:input_required, value}), do: {:input_required, value}
  defp normalize_handler_result({:error, reason}), do: {:error, reason}
  defp normalize_handler_result(value), do: {:ok, value}

  defp handler_tool_arguments(arguments, schema, :atoms, handler) do
    _ = ensure_handler_module_loaded(handler)
    Schema.atomize_property_keys(arguments, schema)
  end

  defp handler_tool_arguments(arguments, _schema, _mode, _handler), do: arguments

  # `String.to_existing_atom/1` can only see atoms introduced by loaded BEAM
  # modules.  An MFA or external function capture may point at a module that
  # is available on the code path but has not been loaded yet; load it before
  # converting schema-declared argument keys. Anonymous/local functions are
  # deliberately left alone so this preparation has no effect on them.
  defp ensure_handler_module_loaded({module, _function}) when is_atom(module),
    do: ensure_module_loaded(module)

  defp ensure_handler_module_loaded({module, _function, _args}) when is_atom(module),
    do: ensure_module_loaded(module)

  defp ensure_handler_module_loaded(fun) when is_function(fun) do
    case :erlang.fun_info(fun, :type) do
      {:type, :external} ->
        case :erlang.fun_info(fun, :module) do
          {:module, module} when is_atom(module) -> ensure_module_loaded(module)
          _other -> :ok
        end

      _local_or_other ->
        :ok
    end
  end

  defp ensure_handler_module_loaded(_handler), do: :ok

  defp ensure_module_loaded(module) do
    _ = Code.ensure_loaded(module)
    :ok
  end

  defp normalize_tool_result(result, opts, context) do
    case Output.canonicalize_detailed(result, output_canonicalization_opts(opts)) do
      {:ok, normalized} ->
        normalize_canonical_tool_result(normalized)

      {:error, %Output.CanonicalizationError{} = error} ->
        report_output_canonicalization_error(error, context)
        %{}
    end
  end

  defp normalize_canonical_tool_result(%{"content" => _} = result), do: result

  defp normalize_canonical_tool_result(result) when is_map(result),
    do: normalize_structured_tool_value(result)

  defp normalize_canonical_tool_result(result) when is_binary(result),
    do: %{"content" => [%{"type" => "text", "text" => result}], "isError" => false}

  defp normalize_canonical_tool_result(result) when is_number(result) or is_boolean(result),
    do: %{
      "structuredContent" => result,
      "content" => [%{"type" => "text", "text" => to_string(result)}],
      "isError" => false
    }

  defp normalize_canonical_tool_result(result) when is_nil(result),
    do: %{
      "structuredContent" => nil,
      "content" => [%{"type" => "text", "text" => ""}],
      "isError" => false
    }

  defp normalize_canonical_tool_result(result),
    do: %{
      "structuredContent" => result,
      "content" => [%{"type" => "text", "text" => "structured output"}],
      "isError" => false
    }

  defp report_output_canonicalization_error(error, context) do
    Telemetry.report_exception(
      Map.get(context, :exception_reporter),
      :output_canonicalization,
      :error,
      error,
      [],
      %{
        method: Telemetry.protocol_method(Map.get(context, :method, "tools/call")),
        transport: Map.get(context, :transport, :core),
        correlation_id: telemetry_correlation(Map.get(context, :request_id)),
        primitive_type: Map.get(context, :primitive_type),
        primitive_identity: Map.get(context, :primitive_identity),
        telemetry_metadata: Map.get(context, :telemetry_metadata)
      }
    )
  end

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

  defp normalize_resource_contents(value, opts) do
    value = canonical_output(value, json_budget_opts(opts))

    cond do
      is_map(value) and Map.has_key?(value, "contents") -> value
      is_list(value) -> %{"contents" => value}
      true -> %{"contents" => [value]}
    end
  end

  defp normalize_prompt_messages(value, opts) do
    value = canonical_output(value, json_budget_opts(opts))

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

  defp valid_tool_result?(result, opts),
    do: match?({:ok, _}, Output.normalize_tool_result(result, json_budget_opts(opts)))

  defp valid_resource_result?(result, opts),
    do: match?({:ok, _}, Output.normalize_resource_result(result, json_budget_opts(opts)))

  defp valid_prompt_result?(result, opts),
    do: match?({:ok, _}, Output.normalize_prompt_result(result, json_budget_opts(opts)))

  defp valid_content_item?(item, opts),
    do: match?({:ok, _}, Output.normalize_content_item(item, json_budget_opts(opts)))

  defp json_value?(value, opts),
    do: Schema.json_value(value, json_budget_opts(opts)) == :ok

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

  defp validate_output(output, schema, opts) do
    with {:ok, structured_content} when is_map(structured_content) <-
           Map.fetch(output, "structuredContent"),
         :ok <- Schema.validate(structured_content, schema, json_budget_opts(opts)) do
      output
    else
      _ ->
        %{
          "content" => [%{"type" => "text", "text" => "tool output failed outputSchema"}],
          "isError" => true
        }
    end
  end

  defp safe_uri?(uri), do: Output.safe_uri?(uri)

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
      "version" => opts[:server_version] || application_version()
    }

  defp application_version do
    _ = Application.load(:attesto_mcp_server)

    case Application.spec(:attesto_mcp_server, :vsn) do
      nil -> "0.0.0"
      version -> to_string(version)
    end
  end

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

  # Handlers and definition policy receive the complete loaded principal in
  # `context.principal`. Internal ownership, isolation, cursor, and accounting
  # operations use the separately derived stable binding when a transport
  # supplies one.
  defp principal(context) do
    Map.get(
      context,
      :principal_binding,
      Map.get(
        context,
        "principal_binding",
        Map.get(context, :principal, Map.get(context, "principal", "anonymous"))
      )
    )
  end

  defp tenant(context), do: Map.get(context, :tenant, Map.get(context, "tenant"))

  defp json_budget_opts(opts) when is_list(opts) do
    max_bytes =
      Keyword.get(
        opts,
        :max_json_bytes,
        Keyword.get(opts, :max_bytes, Schema.default_instance_bytes())
      )

    [max_bytes: max_bytes]
  end

  defp json_budget_opts(opts) when is_map(opts) do
    [
      max_bytes:
        Map.get(
          opts,
          :max_json_bytes,
          Schema.default_instance_bytes()
        )
    ]
  end

  defp json_budget_opts(_opts), do: [max_bytes: Schema.default_instance_bytes()]

  defp output_canonicalization_opts(opts) do
    Keyword.put(
      json_budget_opts(opts),
      :output_canonicalization,
      Keyword.get(opts, :output_canonicalization, :strict)
    )
  end

  # Handler-produced protocol objects may use atom keys, but every value that
  # reaches a wire encoder must be a bounded JSON value.  Canonicalize only
  # keys (never arbitrary terms) and reject collisions such as :method plus
  # "method" rather than silently dropping one of them.
  defp canonical_wire_value(value, opts),
    do: Output.canonicalize(value, json_budget_opts(opts))

  defp canonical_output(value, opts) do
    case canonical_wire_value(value, opts) do
      {:ok, normalized} -> normalized
      _ -> value
    end
  end

  defp drop_nil(map), do: Enum.reject(map, fn {_k, v} -> is_nil(v) end) |> Map.new()
  defp maybe_map_put(map, _key, nil), do: map
  defp maybe_map_put(map, key, value), do: Map.put(map, key, value)
end
