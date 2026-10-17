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
    CachePolicy,
    Cursor,
    Error,
    Handlers,
    HostCallback,
    Implementation,
    JSONRPC,
    Options,
    Output,
    Presentation,
    Protocol,
    Registry,
    RequestMeta,
    RequestRunner,
    RequestState,
    Result,
    Retry,
    Schema,
    ScopeMap,
    ScopePolicy,
    Session,
    Stores,
    Subscriptions,
    Tasks,
    Telemetry,
    UriTemplate
  }

  @modern "2026-07-28"
  @legacy "2025-11-25"
  @legacy_2025_06_18 "2025-06-18"
  @legacy_versions [@legacy, @legacy_2025_06_18]
  @default_stream_queue 128
  @max_trace_state_bytes 4096
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
  @cache_hint_fields ["ttlMs", "cacheScope"]
  @session_pg_scope AttestoMCP.Server.SessionCluster
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
    :url_elicitation_store_module,
    :url_elicitation_store,
    :url_elicitation_store_external,
    :url_elicitation_store_monitor,
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

  @doc false
  @spec selected_tool_definition(pid() | atom(), String.t(), context(), function() | nil) ::
          {:ok, Registry.definition()} | {:error, Error.t()}
  def selected_tool_definition(server, name, context, definition_authorizer \\ nil) do
    opts =
      if is_function(definition_authorizer, 1),
        do: [definition_authorizer: definition_authorizer],
        else: []

    authorize_selected_tool(GenServer.call(server, :registry), name, context, opts)
  end

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
            Protocol.era(request, version: Keyword.get(opts, :version)) == @legacy

        monitor_owner? = not detached_legacy?

        on_event = RequestRunner.detached_delivery(on_event, detached_legacy?)
        raw_version = Keyword.get(opts, :version, Protocol.version(request, default: @modern))
        era = request_era(opts, request, request.params)

        context =
          context
          |> Map.put_new(:server_capabilities, capabilities(runtime.opts))
          |> Map.put_new(:protocol_version, raw_version)
          |> enrich_logging_context(runtime, era)

        case RequestRunner.start(runtime.task_supervisor, fn ->
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
                   progress_token = Protocol.metadata_value(request.params, "progressToken")
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
            requested_timeout =
              Keyword.get(opts, :timeout) || runtime.opts[:request_timeout] || 30_000

            timeout =
              min(requested_timeout, runtime.opts[:max_request_timeout] || 120_000)

            outcome =
              RequestRunner.await(
                ref,
                task,
                timeout,
                on_event,
                runtime.subscriptions,
                Keyword.get(opts, :keepalive_ms)
              )

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
                   Keyword.get(opts, :version, Protocol.version(request, default: @modern)),
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
    version = Protocol.era(%{}, version: Keyword.get(opts, :version))
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

  @doc false
  def url_elicitation_store(server) do
    GenServer.call(server, :url_elicitation_store)
  catch
    _kind, _reason -> {:error, :store_unavailable}
  end

  @doc "Consumes one bounded rate-limit token for a principal/category key."
  @spec allow_rate(pid() | atom(), term(), atom()) :: :ok | {:error, :rate_limited}
  def allow_rate(server, key, category), do: GenServer.call(server, {:allow_rate, key, category})

  @doc false
  @spec refund_rate(pid() | atom(), term(), atom()) :: :ok
  def refund_rate(server, key, category),
    do: GenServer.call(server, {:refund_rate, key, category})

  @doc false
  @spec rate_available?(pid() | atom(), term(), atom()) :: :ok | {:error, :rate_limited}
  def rate_available?(server, key, category),
    do: GenServer.call(server, {:rate_available, key, category})

  def cancel_request(server, principal, request_id, owner \\ nil) do
    Telemetry.execute([:cancellation, :request], %{count: 1}, %{
      outcome: :requested,
      correlation_id: Telemetry.correlation(request_id)
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
    scope_sets = catalog_scope_sets(type)

    if notification do
      state = publish_notification_local(state, notification, [], :local, scope_sets)
      broadcast_cluster_notification(state, notification, [], scope_sets)

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

  defp catalog_scope_sets(:tool), do: [[AttestoMCP.Scopes.tools_read()]]
  defp catalog_scope_sets(:prompt), do: [[AttestoMCP.Scopes.prompts_read()]]

  defp catalog_scope_sets(type) when type in [:resource, :template],
    do: [[AttestoMCP.Scopes.resources_read()]]

  defp catalog_scope_sets(_type), do: [[]]

  def open_legacy_stream(
        server,
        session_id,
        principal,
        tenant,
        sink,
        authorize \\ nil,
        scopes \\ []
      ),
      do:
        GenServer.call(
          server,
          {:open_legacy_stream, session_id, principal, tenant, sink, authorize, scopes}
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

  @doc """
  Returns the negotiated client capabilities for an owned session.

  Returns an empty map when the session does not exist or the principal or
  tenant does not own it. A session-store failure remains distinguishable from
  a missing session.
  """
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
    normalized_opts = Options.normalize(opts)

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
     session_namespace, session_cluster_group} = Stores.setup_session(normalized_opts)

    {url_elicitation_store_module, url_elicitation_store, url_elicitation_store_external,
     url_elicitation_store_monitor} = Stores.setup_url_elicitation(normalized_opts)

    Process.send_after(self(), :cleanup_sessions, 60_000)

    {:ok,
     %__MODULE__{
       registry: registry,
       task_supervisor: task_supervisor,
       tasks: tasks,
       subscriptions: subscriptions,
       opts:
         normalized_opts
         |> Options.put_default_if_nil(:cursor_secret, :crypto.strong_rand_bytes(32))
         |> Options.put_default_if_nil(:request_state_instance, :crypto.strong_rand_bytes(16))
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
       url_elicitation_store_module: url_elicitation_store_module,
       url_elicitation_store: url_elicitation_store,
       url_elicitation_store_external: url_elicitation_store_external,
       url_elicitation_store_monitor: url_elicitation_store_monitor,
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
    do: {:reply, Options.public(state.opts), state}

  def handle_call(:url_elicitation_store, _from, state) do
    {:reply,
     %{
       module: state.url_elicitation_store_module,
       store: state.url_elicitation_store,
       namespace: state.session_namespace,
       max_json_bytes: state.opts[:max_json_bytes] || Schema.default_instance_bytes()
     }, state}
  end

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

  def handle_call({:refund_rate, key, category}, _from, state) do
    now = System.monotonic_time(:millisecond)
    buckets = refund_rate(state.opts[:rate_limits], category, key, state.rate_buckets, now)
    {:reply, :ok, %{state | rate_buckets: buckets}}
  end

  def handle_call({:rate_available, key, category}, _from, state) do
    now = System.monotonic_time(:millisecond)

    {:reply, rate_available(state.opts[:rate_limits], category, key, state.rate_buckets, now),
     state}
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
       rate_buckets: rate_bucket_count(state.rate_buckets),
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
        UriTemplate.report_budget_exhausted(:notification)
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
    do:
      handle_call(
        {:open_legacy_stream, session_id, principal, tenant, sink, nil, []},
        from,
        state
      )

  def handle_call(
        {:open_legacy_stream, session_id, principal, tenant, sink, authorize},
        from,
        state
      ),
      do:
        handle_call(
          {:open_legacy_stream, session_id, principal, tenant, sink, authorize, []},
          from,
          state
        )

  def handle_call(
        {:open_legacy_stream, session_id, principal, tenant, sink, authorize, scopes},
        _from,
        state
      ) do
    with {:ok, scopes} <- ScopePolicy.normalize_scopes(scopes),
         {:ok, _session} <-
           session_for(state, session_id, principal, tenant, require_initialized: true) do
      stream_count =
        Enum.count(state.legacy_streams, fn {_ref, stream} ->
          stream.session_id == session_id
        end)

      cond do
        not is_pid(sink) ->
          {:reply, {:error, :not_found}, state}

        stream_count >= state.opts[:max_legacy_streams_per_session] ->
          {:reply, {:error, :stream_limit}, state}

        true ->
          stream_ref = make_ref()
          monitor = Process.monitor(sink)

          stream = %{
            ref: stream_ref,
            session_id: session_id,
            principal: principal,
            tenant: tenant,
            sink: sink,
            authorize: authorize,
            scopes: scopes,
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
      end
    else
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
    case Options.session_timeouts(session_opts, state.opts) do
      {:ok, absolute_timeout, idle_timeout} ->
        with :ok <- Session.validate_binding(principal),
             :ok <- Session.validate_binding(tenant) do
          session =
            Session.new(principal, tenant,
              absolute_timeout: absolute_timeout,
              idle_timeout: idle_timeout
            )

          case save_new_session(state, session) do
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
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
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
        UriTemplate.report_budget_exhausted(:notification)
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
            UriTemplate.report_budget_exhausted(:notification)
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

      monitor == state.url_elicitation_store_monitor and pid == state.url_elicitation_store ->
        {:stop, :url_elicitation_store_unavailable, state}

      true ->
        handle_process_down(monitor, pid, reason, state)
    end
  end

  @impl true
  def handle_info(:cleanup_sessions, state) do
    now = System.monotonic_time(:millisecond)
    state = %{state | rate_buckets: prune_rate_buckets(state.rate_buckets, now)}

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

    state_telemetry(
      state,
      [:url_elicitation_store, :cleanup, :start],
      %{system_time: System.system_time()},
      %{}
    )

    url_cleanup_started = System.monotonic_time()

    {url_expired, url_cleanup_outcome} =
      case cleanup_url_elicitation_records(state) do
        {:ok, expired_ids} -> {expired_ids, :success}
        {:error, :url_elicitation_store_unavailable} -> {[], :unavailable}
      end

    state_telemetry(
      state,
      [:url_elicitation_store, :cleanup, :stop],
      %{
        duration: max(System.monotonic_time() - url_cleanup_started, 0),
        count: length(url_expired)
      },
      %{outcome: url_cleanup_outcome}
    )

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
    %{status | state: %{state | opts: Options.redacted(state.opts)}}
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

  defp rate_decision(config, category, key, buckets, now) do
    setting = Map.get(config || %{}, category) || Map.get(config || %{}, Atom.to_string(category))

    case normalize_rate_setting(setting) do
      :disabled ->
        {:ok, buckets}

      {:ok, burst, window_ms} ->
        bucket_key = normalize_rate_key(category, key)

        buckets =
          if rate_bucket_present?(buckets, category, bucket_key) do
            buckets
          else
            make_rate_bucket_room(buckets, category)
          end

        previous =
          get_rate_bucket(buckets, category, bucket_key) ||
            %{
              tokens: burst * 1.0,
              at: now,
              window_ms: window_ms
            }

        elapsed = max(now - previous.at, 0)
        replenished = min(burst * 1.0, previous.tokens + elapsed * burst / window_ms)

        cond do
          replenished >= 1.0 ->
            {:ok,
             put_rate_bucket(buckets, category, bucket_key, %{
               tokens: replenished - 1.0,
               at: now,
               window_ms: window_ms,
               expires_at: now + window_ms
             })}

          true ->
            {:error,
             put_rate_bucket(buckets, category, bucket_key, %{
               tokens: replenished,
               at: now,
               window_ms: window_ms,
               expires_at: now + window_ms
             })}
        end
    end
  end

  defp refund_rate(config, category, key, buckets, now) do
    setting = Map.get(config || %{}, category) || Map.get(config || %{}, Atom.to_string(category))

    case normalize_rate_setting(setting) do
      :disabled ->
        buckets

      {:ok, burst, window_ms} ->
        bucket_key = normalize_rate_key(category, key)

        case get_rate_bucket(buckets, category, bucket_key) do
          nil ->
            buckets

          previous ->
            elapsed = max(now - previous.at, 0)
            replenished = min(burst * 1.0, previous.tokens + elapsed * burst / window_ms)
            refunded = min(burst * 1.0, replenished + 1.0)

            if refunded >= burst do
              delete_rate_bucket(buckets, category, bucket_key)
            else
              put_rate_bucket(buckets, category, bucket_key, %{
                tokens: refunded,
                at: now,
                window_ms: window_ms,
                expires_at: now + window_ms
              })
            end
        end
    end
  end

  defp rate_available(config, category, key, buckets, now) do
    setting = Map.get(config || %{}, category) || Map.get(config || %{}, Atom.to_string(category))

    case normalize_rate_setting(setting) do
      :disabled ->
        :ok

      {:ok, burst, window_ms} ->
        bucket_key = normalize_rate_key(category, key)

        case get_rate_bucket(buckets, category, bucket_key) do
          nil ->
            :ok

          previous ->
            elapsed = max(now - previous.at, 0)
            replenished = min(burst * 1.0, previous.tokens + elapsed * burst / window_ms)
            if replenished >= 1.0, do: :ok, else: {:error, :rate_limited}
        end
    end
  end

  # Authentication-failure limits protect a network boundary. Treat one IPv6
  # /64 as one source so rotating interface identifiers cannot allocate a new
  # live bucket per failed signature verification.
  defp normalize_rate_key(category, {:ip, {a, b, c, d, _e, _f, _g, _h}})
       when category in [:auth_checks, :auth_failures],
       do: {:ip, {a, b, c, d, 0, 0, 0, 0}}

  defp normalize_rate_key(_category, key), do: key

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

  defp prune_rate_buckets(buckets, now) do
    Enum.reduce(buckets, %{}, fn {category, category_buckets}, acc ->
      active =
        Map.filter(category_buckets, fn {_key, bucket} ->
          rate_bucket_expiry(bucket) >= now
        end)

      if map_size(active) == 0, do: acc, else: Map.put(acc, category, active)
    end)
  end

  # Buckets are grouped by their small, fixed set of categories. At the hard
  # cap, choosing the largest category is bounded by that set and a map
  # iterator removes one member without scanning or sorting the 10,000 keys.
  # Prefer the incoming category on a tie so repeated churn stays there.
  defp make_rate_bucket_room(buckets, incoming_category) do
    if rate_bucket_count(buckets) < @max_rate_buckets do
      buckets
    else
      buckets
      |> most_populous_rate_category(incoming_category)
      |> then(&evict_rate_bucket(buckets, &1))
    end
  end

  defp most_populous_rate_category(buckets, incoming_category) do
    incoming_count = buckets |> Map.get(incoming_category, %{}) |> map_size()

    Enum.reduce(buckets, {incoming_category, incoming_count}, fn {category, category_buckets},
                                                                 {selected, selected_count} ->
      count = map_size(category_buckets)
      if count > selected_count, do: {category, count}, else: {selected, selected_count}
    end)
    |> elem(0)
  end

  defp evict_rate_bucket(buckets, category) do
    category_buckets = Map.get(buckets, category, %{})

    case :maps.next(:maps.iterator(category_buckets)) do
      {key, _bucket, _iterator} -> delete_rate_bucket(buckets, category, key)
      :none -> buckets
    end
  end

  defp rate_bucket_count(buckets) do
    Enum.reduce(buckets, 0, fn {_category, category_buckets}, total ->
      total + map_size(category_buckets)
    end)
  end

  defp rate_bucket_present?(buckets, category, key) do
    buckets |> Map.get(category, %{}) |> Map.has_key?(key)
  end

  defp get_rate_bucket(buckets, category, key) do
    buckets |> Map.get(category, %{}) |> Map.get(key)
  end

  defp put_rate_bucket(buckets, category, key, bucket) do
    Map.update(buckets, category, %{key => bucket}, &Map.put(&1, key, bucket))
  end

  defp delete_rate_bucket(buckets, category, key) do
    case Map.get(buckets, category) do
      nil ->
        buckets

      category_buckets ->
        remaining = Map.delete(category_buckets, key)

        if map_size(remaining) == 0,
          do: Map.delete(buckets, category),
          else: Map.put(buckets, category, remaining)
    end
  end

  defp rate_bucket_expiry(bucket),
    do: bucket[:expires_at] || bucket.at + (bucket[:window_ms] || 0)

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
        # RequestRunner. Handler tasks must never capture a Plug.Conn or die
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

  defp valid_sampling_content?(content, opts) when is_map(content),
    do: valid_content_item?(content, opts)

  defp valid_sampling_content?(content, opts) when is_list(content),
    do: Enum.all?(content, &valid_content_item?(&1, opts))

  defp valid_sampling_content?(_content, _opts), do: false

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

  defp save_new_session(state, %Session{} = session) do
    if function_exported?(state.session_store_module, :save_below_principal_limit, 4) do
      with {:ok, record} <- Session.to_record(session) do
        case safe_session_store_call(state, :save_below_principal_limit, [
               session_key(state, session.id),
               record,
               state.opts[:max_sessions_per_principal]
             ]) do
          :ok -> :ok
          :limit_reached -> {:error, :session_limit}
          _other -> {:error, :session_store_unavailable}
        end
      end
    else
      with {:ok, count} <- principal_session_count(state, session.principal),
           true <- count < state.opts[:max_sessions_per_principal] do
        save_session(state, session)
      else
        false -> {:error, :session_limit}
        {:error, _reason} = error -> error
      end
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
    cond do
      function_exported?(state.session_store_module, :count_active, 2) ->
        case safe_session_store_call(state, :count_active, [state.session_namespace]) do
          {:ok, count} when is_integer(count) and count >= 0 -> count
          _ -> 0
        end

      function_exported?(state.session_store_module, :count_active, 1) ->
        case safe_session_store_call(state, :count_active, []) do
          {:ok, count} when is_integer(count) and count >= 0 -> count
          _ -> 0
        end

      true ->
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

  defp principal_session_count(state, principal) do
    cond do
      function_exported?(state.session_store_module, :count_active_for_principal, 3) ->
        case safe_session_store_call(state, :count_active_for_principal, [
               state.session_namespace,
               principal
             ]) do
          {:ok, count} when is_integer(count) and count >= 0 -> {:ok, count}
          {:error, :session_store_unavailable} = error -> error
        end

      function_exported?(state.session_store_module, :count_active_for_principal, 2) ->
        case safe_session_store_call(state, :count_active_for_principal, [principal]) do
          {:ok, count} when is_integer(count) and count >= 0 -> {:ok, count}
          {:error, :session_store_unavailable} = error -> error
        end

      true ->
        with {:ok, encoded_principal} <- Session.encode_binding_for_store(principal),
             {:ok, records} when is_list(records) <-
               safe_session_store_call(state, :list_active, []) do
          {:ok,
           Enum.count(records, fn
             {{namespace, _id}, %{"principal" => ^encoded_principal}} ->
               namespace == state.session_namespace

             _entry ->
               false
           end)}
        else
          _ -> {:error, :session_store_unavailable}
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

  defp cleanup_url_elicitation_records(state) do
    now_ms = System.system_time(:millisecond)

    case safe_url_elicitation_store_call(state, :cleanup_expired, [now_ms]) do
      {:ok, ids} when is_list(ids) and length(ids) <= 1_000 ->
        valid_ids =
          Enum.filter(ids, fn id ->
            is_binary(id) and byte_size(id) in 1..256 and String.valid?(id) and
              :binary.match(id, <<0>>) == :nomatch
          end)

        if length(valid_ids) == length(ids) do
          {:ok, valid_ids}
        else
          state_telemetry(
            state,
            [:url_elicitation_store, :failure],
            %{count: 1},
            %{source: :cleanup_expired, outcome: :unavailable}
          )

          {:error, :url_elicitation_store_unavailable}
        end

      {:error, :url_elicitation_store_unavailable} ->
        {:error, :url_elicitation_store_unavailable}

      _other ->
        state_telemetry(
          state,
          [:url_elicitation_store, :failure],
          %{count: 1},
          %{source: :cleanup_expired, outcome: :unavailable}
        )

        {:error, :url_elicitation_store_unavailable}
    end
  end

  defp safe_url_elicitation_store_call(state, function, arguments) do
    result =
      try do
        apply(state.url_elicitation_store_module, function, [
          state.url_elicitation_store | arguments
        ])
      catch
        _kind, _reason -> {:error, :url_elicitation_store_unavailable}
      end

    case result do
      {:ok, _val} ->
        result

      :not_found ->
        result

      {:error, reason} when reason in [:expired, :consumed, :foreign] ->
        result

      _failure ->
        state_telemetry(
          state,
          [:url_elicitation_store, :failure],
          %{count: 1},
          %{source: function, outcome: :unavailable}
        )

        {:error, :url_elicitation_store_unavailable}
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
  defp valid_session_store_result?(:save_below_principal_limit, :ok), do: true
  defp valid_session_store_result?(:save_below_principal_limit, :limit_reached), do: true
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

  defp valid_session_store_result?(:count_active_for_principal, {:ok, value}),
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

    ScopePolicy.scope_sets_grant?(required_scope_sets, stream[:scopes] || []) and
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
            {{:ok, [[]]}, UriTemplate.new_budget()},
            fn definition, {_result, budget} ->
              case UriTemplate.match(definition[:uri_template], uri, budget) do
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
      case notification do
        %{"type" => "toolsListChanged"} -> {:ok, catalog_scope_sets(:tool)}
        %{"type" => "promptsListChanged"} -> {:ok, catalog_scope_sets(:prompt)}
        %{"type" => "resourcesListChanged"} -> {:ok, catalog_scope_sets(:resource)}
        _ -> {:ok, [[]]}
      end
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
      correlation_id: Telemetry.correlation(id)
    })

    JSONRPC.error_response(id, error)
  end

  defp encode_outcome(id, {:error, _reason}, _era, _opts),
    do: JSONRPC.error_response(id, Error.internal(%{"reason" => "internal_error"}))

  # Handler-authored implementation information is kept only when every field
  # is a valid MCP `Implementation` field; anything else is replaced by the
  # configured value rather than passed through unchecked.
  defp stamp_server_info(result, opts) do
    meta = Map.get(result, "_meta", %{})
    authored = if is_map(meta), do: Map.get(meta, "io.modelcontextprotocol/serverInfo"), else: nil
    info = Implementation.resolve_authored(authored, server_info(opts))

    meta =
      if is_map(meta),
        do: Map.put(meta, "io.modelcontextprotocol/serverInfo", info),
        else: %{"io.modelcontextprotocol/serverInfo" => info}

    Map.put(result, "_meta", meta)
  end

  defp outcome_kind({:ok, _}), do: :ok
  defp outcome_kind({:error, %Error{code: code}}), do: code
  defp outcome_kind(_), do: :error

  defp request_telemetry_metadata(method, id, opts) do
    %{
      method: Telemetry.protocol_method(method),
      transport: Keyword.get(opts, :transport, :core),
      protocol_version: Keyword.get(opts, :version),
      correlation_id: Telemetry.correlation(id),
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
         {:ok, request_meta} <- request_meta_snapshot(params, runtime.opts),
         :ok <- validate_legacy_initialize_request(method, era, params, runtime.opts),
         :ok <- validate_era(era, params, runtime.opts),
         :ok <- validate_trace_context(params),
         :ok <- authorization(method, params, context, runtime.opts) do
      # The snapshot replaces any caller-supplied value. It is client input and
      # stays separate from the verified identity and host context fields.
      context = Map.put(context, :request_meta, request_meta)

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
    request = Map.put(request, :params, params)

    case Keyword.fetch(opts, :version) do
      {:ok, version} -> Protocol.era(request, version: version)
      :error -> Protocol.version(request, default: @modern)
    end
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

  defp request_meta_snapshot(params, opts) do
    case RequestMeta.snapshot(params, opts) do
      {:ok, meta} -> {:ok, meta}
      {:error, reason} -> {:error, Error.invalid_params(%{"reason" => Atom.to_string(reason)})}
    end
  end

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

  defp authorization(method, params, context, opts) do
    scope_map = Map.get(context, :scope_map, opts[:scope_map] || %{}) || %{}
    default_scopes = Map.get(context, :default_scopes, opts[:default_scopes])
    subscription_scopes = Map.get(context, :subscription_scopes, opts[:subscription_scopes])

    required =
      cond do
        Map.get(context, :definition_scope_policy) == true ->
          []

        Map.get(context, :http_scope_policy_resolved) == true ->
          case Map.get(scope_map, method) do
            scopes when is_list(scopes) -> scopes
            _other -> []
          end

        Map.get(context, :transport, :core) == :http ->
          ScopeMap.required_http_scopes(
            method,
            params,
            scope_map,
            default_scopes,
            subscription_scopes
          )

        match?(scopes when is_list(scopes) and scopes != [], Map.get(scope_map, method)) ->
          Map.get(scope_map, method)

        is_list(default_scopes) ->
          default_scopes

        true ->
          []
      end

    granted = Map.get(context, :scopes, Map.get(context, "scopes", [])) || []

    if not ScopePolicy.scopes_grant?(required, granted) do
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
    with {:ok, instructions} <- Presentation.instructions(runtime.opts, context) do
      hints =
        cache_hints("server/discover", runtime.opts, context,
          invariant?: true,
          personalized?: Presentation.dynamic_instructions?(runtime.opts)
        )

      result =
        %{
          "supportedVersions" => runtime.opts[:protocol_versions],
          "capabilities" => capabilities(runtime.opts),
          "resultType" => "complete",
          "_meta" => %{"io.modelcontextprotocol/serverInfo" => server_info(runtime.opts)}
        }
        |> Map.merge(hints)
        |> maybe_put_instructions(instructions)

      {:ok, result}
    end
  end

  defp dispatch_method(era, "initialize", params, context, runtime, opts) when era == @legacy do
    requested = List.wrap(params["protocolVersion"] || @legacy)
    supported = Enum.filter(@legacy_versions, &(&1 in runtime.opts[:protocol_versions]))
    selected = Enum.find(supported, &(&1 in requested))

    if is_binary(selected) and lifecycle_initialize_allowed?(runtime.opts, context, params) do
      # Build and size-check the complete reply before negotiating. A failed
      # instructions provider or an oversized reply leaves the session
      # unnegotiated, so a later valid initialize can still succeed.
      with {:ok, instructions} <- Presentation.instructions(runtime.opts, context),
           result =
             maybe_put_instructions(
               %{
                 "protocolVersion" => selected,
                 "capabilities" => legacy_capabilities(runtime.opts),
                 "serverInfo" => Implementation.for_revision(server_info(runtime.opts), selected)
               },
               instructions
             ),
           :ok <- legacy_initialize_fits(result, context, runtime.opts, opts) do
        initialize_negotiated(result, selected, params, context, runtime)
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
    do: dispatch_revision(@modern, method, params, context, runtime, opts)

  defp dispatch_method(@legacy, method, params, context, runtime, opts),
    do: dispatch_revision(@legacy, method, params, context, runtime, opts)

  defp initialize_negotiated(result, selected, params, context, runtime) do
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
        {:ok, result}

      {:error, :already_negotiated} ->
        {:error, Error.invalid_request(%{"reason" => "initialize_session_rejected"})}

      {:error, :session_store_unavailable} ->
        {:error, Error.session_store_unavailable()}

      {:error, _reason} ->
        {:error, Error.internal(%{"reason" => "initialize_session_rejected"})}
    end
  end

  defp legacy_initialize_fits(result, context, runtime_opts, dispatch_opts) do
    budget_opts = json_budget_opts(runtime_opts)

    with {:ok, wire} <- canonical_wire_value(result, budget_opts),
         :ok <- Schema.json_value(wire, budget_opts),
         true <-
           response_frame_fits?(
             context[:request_id],
             wire,
             Keyword.get(dispatch_opts, :max_response_bytes)
           ) do
      :ok
    else
      _ -> {:error, Error.internal(%{"reason" => "invalid_result"})}
    end
  end

  # Stdio frames have their own output ceiling, which can be smaller than the
  # server's JSON budget. The newline delimiter is part of the frame.
  defp response_frame_fits?(_id, _result, nil), do: true

  defp response_frame_fits?(id, result, max_bytes) when is_integer(max_bytes) do
    case Jason.encode(JSONRPC.response(id, result)) do
      {:ok, encoded} -> byte_size(encoded) + 1 <= max_bytes
      _ -> false
    end
  end

  defp maybe_put_instructions(result, instructions) when is_binary(instructions),
    do: Map.put(result, "instructions", instructions)

  defp maybe_put_instructions(result, _instructions), do: result

  @list_methods %{
    "tools/list" => {:tool, "tools"},
    "resources/list" => {:resource, "resources"},
    "resources/templates/list" => {:template, "resourceTemplates"},
    "prompts/list" => {:prompt, "prompts"}
  }

  defp dispatch_revision(era, method, params, context, runtime, opts)
       when is_map_key(@list_methods, method) do
    {type, result_key} = Map.fetch!(@list_methods, method)

    list_result(
      runtime.registry,
      type,
      params,
      context,
      era,
      result_key,
      list_options(runtime.opts, opts)
    )
  end

  defp dispatch_revision(era, "tools/call", params, context, runtime, opts),
    do: call_tool(params, context, runtime, opts, era)

  defp dispatch_revision(era, "resources/read", params, context, runtime, opts),
    do: read_resource(params, context, runtime, opts, era)

  defp dispatch_revision(era, "prompts/get", params, context, runtime, opts),
    do: get_prompt(params, context, runtime, opts, era)

  defp dispatch_revision(era, "completion/complete", params, context, runtime, _opts),
    do: complete(params, context, runtime, era)

  defp dispatch_revision(era, "tasks/get", params, context, runtime, _opts),
    do: task_get(params, context, runtime, era)

  defp dispatch_revision(era, "tasks/cancel", params, context, runtime, _opts),
    do: task_cancel(params, context, runtime, era)

  defp dispatch_revision(@modern, "subscriptions/listen", params, context, runtime, _opts),
    do: listen(params, context, runtime)

  defp dispatch_revision(@modern, "tasks/update", params, context, runtime, _opts),
    do: task_update(params, context, runtime, @modern)

  defp dispatch_revision(@legacy, "ping", _params, _context, _runtime, _opts),
    do: {:ok, %{}}

  defp dispatch_revision(@legacy, "logging/setLevel", params, context, runtime, _opts),
    do: set_logging_level(params, context, runtime)

  defp dispatch_revision(@legacy, "resources/subscribe", params, context, runtime, _opts),
    do: resource_subscription(params, context, runtime, :subscribe)

  defp dispatch_revision(@legacy, "resources/unsubscribe", params, context, runtime, _opts),
    do: resource_subscription(params, context, runtime, :unsubscribe)

  defp dispatch_revision(@legacy, "tasks/result", params, context, runtime, _opts),
    do: task_get(params, context, runtime, @legacy)

  defp dispatch_revision(@legacy, method, _params, _context, _runtime, _opts),
    do: {:error, Error.method_not_found(method, 200)}

  defp dispatch_revision(@modern, method, _params, _context, _runtime, _opts),
    do: {:error, Error.method_not_found(method)}

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

  defp list_result(registry, type, params, context, era, key, opts) do
    registered = Registry.list(registry, type)
    values = Enum.filter(registered, &definition_visible?(&1, context, opts))
    version = context[:protocol_version]

    # Visibility is decided first; presentation only sees visible tools. When
    # descriptors are customized or exported differently, the complete
    # exported catalog is fingerprinted before paging.
    with {:ok, exported} <- export_catalog(type, values, version, context, opts) do
      # One scope applies to every page of a list request and is decided
      # without looking at the cursor; continuations are bound to it.
      hints =
        if era == @modern do
          cache_hints(list_method(type), opts, context,
            invariant?:
              length(values) <= page_size(opts) and
                Enum.all?(registered, &unrestricted_definition?(&1, opts)),
            personalized?: type == :tool and Presentation.dynamic_tools?(opts)
          )
        end

      binding = [
        presentation_digest: exported && Cursor.catalog_digest(exported),
        cache_scope: if(hints && hints["cacheScope"] == "public", do: "public")
      ]

      page = page(values, params["cursor"], context, era, opts, type, binding)

      if page[:error] do
        {:error, page.error}
      else
        definitions =
          case exported do
            nil -> Enum.map(page.items, &public_definition(type, &1, version))
            exported -> exported |> Enum.drop(page.start) |> Enum.take(length(page.items))
          end

        if Schema.json_value(definitions, json_budget_opts(opts)) == :ok do
          result = %{key => definitions}

          result =
            if era == @modern,
              do:
                result
                |> Map.put("resultType", "complete")
                |> Map.merge(page_cache_hints(hints, page.cursor, opts)),
              else: result

          {:ok, maybe_put_cursor(result, page.cursor)}
        else
          {:error, Error.internal(%{"reason" => "invalid_catalog"})}
        end
      end
    end
  end

  defp list_method(:tool), do: "tools/list"
  defp list_method(:resource), do: "resources/list"
  defp list_method(:template), do: "resources/templates/list"
  defp list_method(:prompt), do: "prompts/list"

  # A page that carries a continuation cursor is never fresher than that
  # cursor, which the server stops accepting once its lifetime ends.
  defp page_cache_hints(hints, nil, _opts), do: hints

  defp page_cache_hints(hints, _cursor, opts),
    do: Map.update!(hints, "ttlMs", &min(&1, cursor_lifetime_ms(opts)))

  defp cursor_lifetime_ms(opts) do
    case opts[:cursor_ttl] do
      ttl when is_integer(ttl) and ttl > 0 -> ttl
      _default -> 300_000
    end
  end

  defp export_catalog(:tool, values, version, context, opts) do
    if Presentation.dynamic_tools?(opts) or export_schema_dialect?(opts, version) do
      with {:ok, descriptors} <-
             values
             |> Enum.map(&public_definition(:tool, &1))
             |> Presentation.tools(opts, context) do
        {:ok,
         Enum.map(descriptors, fn descriptor ->
           descriptor
           |> maybe_export_schema_dialect(version, opts)
           |> revision_descriptor(version)
         end)}
      end
    else
      {:ok, nil}
    end
  end

  defp export_catalog(_type, _values, _version, _context, _opts), do: {:ok, nil}

  # The 2025-06-18 Tool type has no `$schema` member, so the explicit dialect
  # is exported only for revisions that define it.
  defp export_schema_dialect?(opts, version),
    do: opts[:export_schema_dialect] == true and version in [@modern, @legacy]

  defp maybe_export_schema_dialect(descriptor, version, opts) do
    if export_schema_dialect?(opts, version) do
      descriptor
      |> update_existing("inputSchema", &Schema.export_dialect/1)
      |> update_existing("outputSchema", &Schema.export_dialect/1)
    else
      descriptor
    end
  end

  defp update_existing(map, key, fun) do
    case Map.fetch(map, key) do
      {:ok, value} -> Map.put(map, key, fun.(value))
      :error -> map
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

  defp page(values, nil, context, era, opts, type, binding) do
    page_size = page_size(opts)
    cursor_opts = cursor_options(values, context, era, opts, page_size, type, binding)

    %{
      start: 0,
      items: Enum.take(values, page_size),
      cursor:
        if(length(values) > page_size,
          do: Cursor.issue(page_size, principal(context), era, cursor_opts)
        )
    }
  end

  defp page(values, cursor, context, era, opts, type, binding) do
    page_size = page_size(opts)
    cursor_opts = cursor_options(values, context, era, opts, page_size, type, binding)

    case Cursor.verify(cursor, principal(context), era, cursor_opts) do
      {:ok, position} when is_integer(position) ->
        %{
          start: position,
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

  defp cursor_options(values, context, era, opts, page_size, type, binding) do
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
    ] ++ binding
  end

  defp page_size(opts), do: opts[:page_size] || 100

  defp maybe_put_cursor(result, nil), do: result
  defp maybe_put_cursor(result, position), do: Map.put(result, "nextCursor", position)

  defp call_tool(params, context, runtime, opts, era) do
    name = params["name"]
    arguments = params["arguments"] || %{}
    salient = Retry.salient(params)
    operation = %{"tool" => name}

    with true <- is_binary(name) and is_map(arguments),
         :ok <- require_task_capability(params, runtime.opts, era),
         {:ok, state_payload} <-
           Retry.verify(
             params,
             retry_binding(context, era),
             "tools/call",
             salient,
             operation,
             runtime.opts
           ),
         {:ok, selected_definition} <-
           authorize_selected_tool(runtime.registry, name, context, opts),
         :ok <-
           Retry.reject_retry_collisions(
             state_payload,
             tool_argument_names(selected_definition.input_schema, arguments)
           ),
         :ok <- Retry.validate_responses(state_payload, params, runtime.opts),
         {:ok, handler_arguments} <-
           prepare_tool_handler_arguments(
             arguments,
             Retry.responses(params, state_payload),
             selected_definition,
             runtime
           ),
         :ok <- Retry.consume(state_payload, runtime.opts) do
      call_tool_validated(
        params,
        context,
        runtime,
        opts,
        era,
        arguments,
        handler_arguments,
        salient,
        operation,
        selected_definition
      )
      |> restrict_tool_retry_hints(state_payload, era)
    else
      false ->
        {:error, Error.invalid_params(%{"reason" => "tool_arguments_invalid"})}

      {:missing_inputs, payload, requests} ->
        recover_missing_inputs(
          payload,
          requests,
          params,
          context,
          runtime,
          era,
          "tools/call",
          salient,
          operation
        )

      {:error, :invalid_input_requests} ->
        {:error, Error.invalid_params(%{"reason" => "invalid_input_requests"})}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp authorize_selected_tool(registry, name, context, opts) do
    selected_policy? = is_function(Keyword.get(opts, :definition_authorizer), 1)

    candidate =
      registry
      |> Registry.candidates(:tool, name)
      |> Enum.find(&(selected_policy? or visible?(&1, context)))

    case candidate do
      nil ->
        {:error, Error.invalid_params(%{"reason" => "unknown_tool", "name" => name})}

      tool ->
        if not selected_policy? or definition_visible?(tool, context, opts),
          do: {:ok, tool},
          else: {:error, Error.invalid_params(%{"reason" => "unknown_tool", "name" => name})}
    end
  rescue
    _ -> {:error, Error.invalid_params(%{"reason" => "unknown_tool", "name" => name})}
  end

  defp authorize_selected_resource(registry, uri, context, opts, era) do
    cond do
      not is_binary(uri) or not safe_uri?(uri) ->
        {:ok, :none}

      true ->
        selected_policy? = is_function(Keyword.get(opts, :definition_authorizer), 1)

        candidate =
          case Enum.find(Registry.candidates(registry, :resource, uri), fn resource ->
                 selected_policy? or visible?(resource, context)
               end) do
            resource when is_map(resource) ->
              {:ok, {resource, %{}}}

            nil ->
              find_resource_template(
                Registry.list(registry, :template),
                uri,
                context,
                selected_policy?,
                UriTemplate.new_budget()
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
            UriTemplate.report_budget_exhausted(:resource_read)

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
          case UriTemplate.match(template.uri_template, uri, budget) do
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

  defp recover_missing_inputs(
         payload,
         requests,
         params,
         context,
         runtime,
         era,
         method,
         salient,
         operation
       ) do
    with :ok <- recovery_operation_visible(runtime, method, operation, context) do
      Retry.recover(
        payload,
        requests,
        params,
        retry_binding(context, era),
        method,
        salient,
        operation,
        runtime.opts
      )
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  # Tool/resource visibility is checked before validating retry answers. Prompt lookup
  # normally happens afterward, so recovery must apply that same gate here.
  defp recovery_operation_visible(runtime, "prompts/get", %{"prompt" => name}, context) do
    if Enum.any?(
         Registry.list(runtime.registry, :prompt),
         &(&1.name == name and visible?(&1, context))
       ),
       do: :ok,
       else: {:error, Error.invalid_params(%{"name" => name})}
  end

  defp recovery_operation_visible(_runtime, _method, _operation, _context), do: :ok

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
         _opts,
         era,
         arguments,
         handler_arguments,
         salient,
         operation,
         tool
       )
       when is_map(tool) do
    handler_context = Handlers.identity_context(context, :tool, tool)

    case Handlers.invoke(
           tool.handler,
           handler_arguments,
           handler_context
         ) do
      {:input_required, input} when era == @modern ->
        Retry.issue(
          input,
          params,
          retry_binding(context, era),
          "tools/call",
          salient,
          operation,
          runtime.opts,
          tool_argument_names(tool.input_schema, arguments)
        )

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
  end

  defp prepare_tool_handler_arguments(arguments, responses, tool, runtime) do
    case Schema.validate(arguments, tool.input_schema, schema_validation_opts(runtime.opts)) do
      :ok ->
        with :ok <-
               Retry.reject_collisions(
                 Map.keys(responses),
                 tool_argument_names(tool.input_schema, arguments)
               ) do
          {:ok,
           arguments
           |> Map.merge(responses)
           |> Handlers.tool_arguments(
             tool.input_schema,
             runtime.opts[:tool_argument_keys],
             tool.handler
           )}
        end

      _ ->
        {:error, Error.invalid_params(%{"reason" => "tool_arguments_invalid"})}
    end
  end

  defp tool_argument_names(%{"properties" => properties}, arguments)
       when is_map(properties) and is_map(arguments) do
    Enum.uniq(Map.keys(arguments) ++ Map.keys(properties))
  end

  defp tool_argument_names(_schema, arguments) when is_map(arguments), do: Map.keys(arguments)

  defp read_resource(params, context, runtime, opts, era) do
    uri = params["uri"]
    salient = Retry.salient(params)
    operation = %{"resource" => uri}

    with true <- is_binary(uri) and safe_uri?(uri),
         {:ok, selected_definition} <-
           authorize_selected_resource(runtime.registry, uri, context, opts, era),
         {:ok, state_payload} <-
           Retry.verify(
             params,
             retry_binding(context, era),
             "resources/read",
             salient,
             operation,
             runtime.opts
           ),
         :ok <- Retry.validate_responses(state_payload, params, runtime.opts),
         :ok <- Retry.consume(state_payload, runtime.opts) do
      read_resource_validated(
        params,
        context,
        runtime,
        era,
        uri,
        salient,
        operation,
        state_payload,
        selected_definition,
        list_options(runtime.opts, opts)
      )
    else
      false ->
        {:error, Error.invalid_params(%{"reason" => "unsafe_resource_uri"})}

      {:missing_inputs, payload, requests} ->
        recover_missing_inputs(
          payload,
          requests,
          params,
          context,
          runtime,
          era,
          "resources/read",
          salient,
          operation
        )

      {:error, %Error{} = error} ->
        {:error, error}
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
         selected_definition,
         policy_opts
       ) do
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
        case Handlers.invoke(
               resource.handler,
               Map.merge(
                 %{uri: uri, params: template_params},
                 Retry.responses(params, state_payload)
               ),
               Handlers.identity_context(
                 context,
                 if(resource[:uri_template] || resource["uri_template"],
                   do: :template,
                   else: :resource
                 ),
                 resource
               )
             ) do
          {:input_required, input} when era == @modern ->
            Retry.issue(
              input,
              params,
              retry_binding(context, era),
              "resources/read",
              salient,
              operation,
              runtime.opts
            )

          {:ok, content} ->
            normalized = normalize_resource_contents(content, runtime.opts)

            normalized =
              if era == @legacy,
                do: Map.drop(normalized, ["resultType" | @cache_hint_fields]),
                else: normalized

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
                       resource_cache_hints(
                         resource,
                         normalized,
                         state_payload,
                         context,
                         policy_opts
                       )
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
  end

  # Granular policies let valid handler hints shorten freshness or select a
  # private scope. Retried results and caller-dependent definitions are
  # constrained by CachePolicy regardless of configuration.
  defp resource_cache_hints(resource, normalized, state_payload, context, opts) do
    cache_hints("resources/read", opts, context,
      definition: resource,
      definition_type: if(resource[:uri_template], do: :template, else: :resource),
      retry?: not is_nil(state_payload),
      invariant?: unrestricted_definition?(resource, opts),
      personalized?: personalized_resource_metadata?(normalized, opts),
      handler_hints: Map.take(normalized, @cache_hint_fields)
    )
  end

  # The final result stamp preserves valid authored identity. Treat a different
  # authored identity or arbitrary handler metadata as potentially personalized
  # before selecting hints, so private TTL/token constraints apply together.
  defp personalized_resource_metadata?(result, opts) do
    configured = server_info(opts)

    metadata_personalized? =
      case Map.get(result, "_meta", %{}) do
        meta when is_map(meta) ->
          {authored, extra} = Map.pop(meta, "io.modelcontextprotocol/serverInfo")

          map_size(extra) > 0 or
            Implementation.resolve_authored(authored, configured) != configured

        _invalid ->
          true
      end

    metadata_personalized? or
      Enum.any?(Map.get(result, "contents", []), fn content ->
        Map.get(content, "_meta", %{}) != %{}
      end)
  end

  # Tool calls do not define standard cache hints. Retain permitted authored
  # extras on ordinary calls, but never advertise caching for an answered retry.
  defp restrict_tool_retry_hints({:ok, result}, state, @modern) when not is_nil(state),
    do: {:ok, Map.drop(result, @cache_hint_fields)}

  defp restrict_tool_retry_hints(outcome, _state, _era), do: outcome

  defp get_prompt(params, context, runtime, opts, era) do
    name = params["name"]
    arguments = params["arguments"] || %{}
    salient = Retry.salient(params)
    operation = %{"prompt" => name}

    with true <- is_binary(name) and is_map(arguments),
         {:ok, state_payload} <-
           Retry.verify(
             params,
             retry_binding(context, era),
             "prompts/get",
             salient,
             operation,
             runtime.opts
           ),
         :ok <- Retry.reject_retry_collisions(state_payload, Map.keys(arguments)),
         :ok <- Retry.validate_responses(state_payload, params, runtime.opts) do
      case Registry.list(runtime.registry, :prompt)
           |> Enum.filter(&(&1.name == name and visible?(&1, context))) do
        [] ->
          {:error, Error.invalid_params(%{"name" => name})}

        [prompt | _] ->
          with {:ok, prompt_arguments, input_keys} <-
                 prepare_prompt_handler_arguments(
                   prompt,
                   arguments,
                   Retry.responses(params, state_payload),
                   state_payload
                 ),
               :ok <- Retry.consume(state_payload, runtime.opts) do
            case invoke_prompt(
                   prompt,
                   name,
                   prompt_arguments,
                   Handlers.identity_context(context, :prompt, prompt),
                   input_keys
                 ) do
              {:input_required, input} when era == @modern ->
                Retry.issue(
                  input,
                  params,
                  retry_binding(context, era),
                  "prompts/get",
                  salient,
                  operation,
                  runtime.opts,
                  prompt_argument_names(prompt.arguments)
                )

              {:ok, content} ->
                normalized = normalize_prompt_messages(content, runtime.opts)

                normalized =
                  if era == @legacy,
                    do: Map.drop(normalized, ["resultType" | @cache_hint_fields]),
                    else: normalized

                normalized = filter_prompt_result_revision(normalized, context[:protocol_version])

                # prompts/get is not a standard cacheable operation. It keeps the
                # 2.3 extra fields from the global setting, with the same retry
                # and caller-independence constraints as the standard results.
                if valid_prompt_result?(normalized, runtime.opts) do
                  {:ok,
                   Map.merge(
                     normalized,
                     if(era == @modern,
                       do:
                         Map.merge(
                           %{"resultType" => "complete"},
                           cache_hints("prompts/get", runtime.opts, context,
                             standard?: false,
                             retry?: not is_nil(state_payload),
                             invariant?:
                               unrestricted_definition?(
                                 prompt,
                                 list_options(runtime.opts, opts)
                               )
                           )
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
      end
    else
      false ->
        {:error, Error.invalid_params(%{"reason" => "prompt_arguments_invalid"})}

      {:missing_inputs, payload, requests} ->
        recover_missing_inputs(
          payload,
          requests,
          params,
          context,
          runtime,
          era,
          "prompts/get",
          salient,
          operation
        )

      {:error, :invalid_input_requests} ->
        {:error, Error.invalid_params(%{"reason" => "invalid_input_requests"})}

      {:error, %Error{} = error} ->
        {:error, error}
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

    case Handlers.invoke(
           entry.handler,
           %{ref: ref, argument: argument, value: value, context: completion_context},
           Handlers.identity_context(context, :completion, entry)
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
        Handlers.invoke(prompt.handler, %{name: name, arguments: arguments}, context)

      {:error, _reason} ->
        {:error, Error.invalid_params(%{"reason" => "invalid_prompt_arguments"})}
    end
  end

  defp prepare_prompt_handler_arguments(prompt, arguments, responses, state_payload) do
    input_keys = Retry.input_keys(state_payload)

    with :ok <- Retry.reject_collisions(input_keys, prompt_argument_names(prompt.arguments)),
         :ok <- validate_prompt_call_arguments(prompt.arguments, arguments, []) do
      {:ok, Map.merge(arguments, responses), input_keys}
    else
      {:error, :invalid_input_requests} ->
        {:error, Error.invalid_params(%{"reason" => "invalid_input_requests"})}

      {:error, _reason} ->
        {:error, Error.invalid_params(%{"reason" => "invalid_prompt_arguments"})}
    end
  end

  defp prompt_argument_names(definitions) when is_list(definitions) do
    Enum.map(definitions, fn argument -> argument[:name] || argument["name"] end)
  end

  defp prompt_argument_names(_), do: []

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
             context[:subscription_authorize],
             Map.get(context, :scopes, Map.get(context, "scopes", [])) || []
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

    ScopePolicy.scope_sets_grant?(Registry.scope_sets(definition), scopes) and
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

  defp public_definition(type, item, version),
    do: type |> public_definition(item) |> revision_descriptor(version)

  defp revision_descriptor(descriptor, @legacy_2025_06_18), do: Map.delete(descriptor, "icons")
  defp revision_descriptor(descriptor, _version), do: descriptor

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
        correlation_id: Telemetry.correlation(Map.get(context, :request_id)),
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
         :ok <- Schema.validate(structured_content, schema, schema_validation_opts(opts)) do
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

  # The implementation value is resolved once at startup and reused for
  # discovery, result stamps, and legacy initialization.
  defp server_info(opts), do: opts[:server_implementation] || Implementation.build(opts)

  defp cache_hints(method, opts, context, fields) do
    {hints, source} =
      %{method: method, opts: opts, context: context}
      |> Map.merge(Map.new(fields))
      |> CachePolicy.resolve()

    Telemetry.execute([:cache, :choice], %{count: 1}, %{
      method: Telemetry.protocol_method(method),
      outcome: hints["cacheScope"],
      source: source
    })

    hints
  end

  # A definition is caller-independent only when nothing about the caller can
  # hide it: no scope clause, no `authorize` callback, and no HTTP definition
  # policy for this dispatch.
  defp unrestricted_definition?(definition, opts) do
    is_nil(Keyword.get(opts, :definition_authorizer)) and
      Registry.scope_sets(definition) == [[]] and is_nil(definition[:authorize])
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

  defp retry_binding(context, era) do
    %{
      principal: principal(context),
      tenant: tenant(context),
      era: era,
      request_id: context[:request_id]
    }
  end

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

  defp schema_validation_opts(opts) do
    Keyword.put(json_budget_opts(opts), :formats, Keyword.get(opts, :schema_formats, true))
  end

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
