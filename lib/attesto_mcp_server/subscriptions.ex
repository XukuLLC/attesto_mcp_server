defmodule AttestoMCP.Server.Subscriptions do
  @moduledoc "Bounded, principal/tenant-bound modern subscription registry."
  use GenServer

  alias AttestoMCP.Server.Telemetry

  @max_queue 128
  @max_resource_uri_bytes 4_096
  @max_resource_uris 128

  @typedoc "Modern subscription category flags and resource URI filters."
  @type filter :: %{optional(String.t()) => boolean() | [String.t()]}

  @doc "Starts the bounded subscription registry."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  # The legacy arity remains useful to callers of the transport-neutral core. Modern
  # subscriptions always use the explicit request id arity below.
  @doc "Opens a subscription and sends an acknowledgment to the sink first."
  @spec open(pid(), term(), term(), term(), pid(), term(), (map() -> boolean()) | nil) ::
          {:ok, term()} | {:error, term()}
  def open(pid, principal, tenant, filter, sink \\ self(), tag \\ nil, authorize \\ nil),
    do: GenServer.call(pid, {:open, nil, principal, tenant, filter, sink, tag, authorize})

  def open(pid, principal, tenant, id, filter, sink, tag, authorize),
    do: GenServer.call(pid, {:open, id, principal, tenant, filter, sink, tag, authorize})

  @doc "Publishes a filtered notification with authorization rechecks."
  @spec publish(pid(), map(), keyword()) :: :ok
  def publish(pid, notification, opts \\ []),
    do: GenServer.cast(pid, {:publish, notification, opts})

  @doc "Publishes synchronously, completing after all current subscriptions are enqueued."
  @spec publish_sync(pid(), map(), keyword()) :: :ok
  def publish_sync(pid, notification, opts \\ []),
    do: GenServer.call(pid, {:publish_sync, notification, opts})

  @doc "Acknowledges one delivered event and releases queue capacity."
  @spec ack(pid(), term()) :: :ok
  def ack(pid, id), do: GenServer.cast(pid, {:ack, id, self()})

  @doc "Returns bounded public counters for active subscriptions and queued events."
  @spec stats(pid()) :: %{count: non_neg_integer(), queued: non_neg_integer()}
  def stats(pid), do: GenServer.call(pid, :stats)

  @doc "Gracefully closes one subscription."
  @spec close(pid(), term()) :: :ok
  def close(pid, id), do: GenServer.call(pid, {:close, id, self()})

  @spec close(pid(), term(), pid() | nil) :: :ok
  def close(pid, id, owner), do: GenServer.call(pid, {:close, id, owner})

  @doc "Cancels one subscription without affecting its peers."
  @spec cancel(pid(), term()) :: :ok
  def cancel(pid, id), do: GenServer.call(pid, {:cancel, id, self()})

  @spec cancel(pid(), term(), pid() | nil) :: :ok
  def cancel(pid, id, owner), do: GenServer.call(pid, {:cancel, id, owner})

  @spec ack(pid(), term(), pid() | nil) :: :ok
  def ack(pid, id, owner), do: GenServer.cast(pid, {:ack, id, owner})

  @impl true
  def init(opts), do: {:ok, %{subscriptions: %{}, opts: opts, seq: 0}}

  @impl true
  def handle_call(
        {:open, requested_id, principal, tenant, filter, sink, tag, authorize},
        _from,
        state
      ) do
    with {:ok, filter} <- normalize_filter(filter),
         {:ok, id, state} <- choose_id(requested_id, sink, state),
         true <- is_pid(sink) do
      monitor = Process.monitor(sink)

      subscription = %{
        id: id,
        principal: principal,
        tenant: tenant,
        filter: filter,
        sink: sink,
        tag: tag,
        authorize: authorize,
        monitor: monitor,
        queue_size: 0,
        overflowed: false
      }

      send(sink, {:mcp_subscription, tag, id, acknowledgement(id, filter)})
      telemetry(state, [:subscription, :open], %{count: 1}, %{transport: :core})
      {:reply, {:ok, id}, put_in(state, [:subscriptions, {sink, id}], subscription)}
    else
      _ -> {:reply, {:error, :invalid_filter}, state}
    end
  end

  def handle_call({:publish_sync, notification, opts}, _from, state),
    do: {:reply, :ok, publish_state(state, notification, opts)}

  def handle_call(:stats, _from, state) do
    queued =
      Enum.reduce(state.subscriptions, 0, fn {_id, sub}, total -> total + sub.queue_size end)

    {:reply, %{count: map_size(state.subscriptions), queued: queued}, state}
  end

  def handle_call({:close, id, owner}, {caller, _tag}, state) do
    telemetry(state, [:subscription, :close], %{count: 1}, %{transport: :core})

    key = find_key(state, id, owner)

    case state.subscriptions[key] do
      %{sink: sink} when is_pid(sink) and sink != caller ->
        send(sink, {:mcp_subscription_close, id})

      _ ->
        :ok
    end

    {:reply, :ok, remove(state, key)}
  end

  def handle_call({:cancel, id, owner}, {caller, _tag}, state) do
    key = find_key(state, id, owner)

    case state.subscriptions[key] do
      %{sink: sink} when is_pid(sink) and sink != caller ->
        send(sink, {:mcp_subscription_cancel, id})

      _ ->
        :ok
    end

    {:reply, :ok, remove(state, key)}
  end

  @impl true
  def handle_cast({:ack, id, owner}, state) do
    key = find_key(state, id, owner)

    state =
      case key do
        nil ->
          state

        key ->
          update_in(state.subscriptions[key], fn
            nil ->
              nil

            %{queue_size: size} = subscription ->
              next_size = max(size - 1, 0)

              %{
                subscription
                | queue_size: next_size,
                  overflowed:
                    if(next_size < (state.opts[:max_queue] || @max_queue),
                      do: false,
                      else: subscription.overflowed
                    )
              }
          end)
      end

    {:noreply, state}
  end

  def handle_cast({:publish, notification, opts}, state) do
    {:noreply, publish_state(state, notification, opts)}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    ids =
      state.subscriptions
      |> Enum.filter(fn {_id, sub} -> sub.monitor == monitor end)
      |> Enum.map(&elem(&1, 0))

    {:noreply, Enum.reduce(ids, state, &remove(&2, &1))}
  end

  defp choose_id(nil, sink, state) when is_pid(sink), do: choose_generated_id(sink, state)

  defp choose_id(id, sink, state) when is_binary(id) and is_pid(sink) do
    id = :binary.copy(id)

    if Map.has_key?(state.subscriptions, {sink, id}),
      do: {:error, :duplicate},
      else: {:ok, id, state}
  end

  defp choose_id(id, sink, state) when is_integer(id) and is_pid(sink) do
    if Map.has_key?(state.subscriptions, {sink, id}),
      do: {:error, :duplicate},
      else: {:ok, id, state}
  end

  defp choose_id(_, _sink, _state), do: {:error, :invalid_id}

  defp choose_generated_id(sink, state) do
    id = "sub_" <> Integer.to_string(state.seq + 1)
    state = %{state | seq: state.seq + 1}

    if Map.has_key?(state.subscriptions, {sink, id}),
      do: choose_generated_id(sink, state),
      else: {:ok, id, state}
  end

  defp normalize_filter(filter) when is_map(filter) do
    keys = [
      "toolsListChanged",
      "promptsListChanged",
      "resourcesListChanged",
      "resourceSubscriptions"
    ]

    if Enum.any?(Map.keys(filter), &(not allowed_filter_key?(&1, keys))) do
      {:error, :unknown_filter}
    else
      with {:ok, tools} <- boolean_value(filter, "toolsListChanged"),
           {:ok, prompts} <- boolean_value(filter, "promptsListChanged"),
           {:ok, resources} <- boolean_value(filter, "resourcesListChanged"),
           {:ok, resource_subscriptions} <- resource_filter(filter) do
        result = %{
          "toolsListChanged" => tools,
          "promptsListChanged" => prompts,
          "resourcesListChanged" => resources,
          "resourceSubscriptions" => resource_subscriptions
        }

        if tools or prompts or resources or resource_subscriptions != [],
          do: {:ok, result},
          else: {:error, :empty_filter}
      else
        _ -> {:error, :invalid_filter}
      end
    end
  end

  defp normalize_filter(_), do: {:error, :invalid_filter}

  defp allowed_filter_key?(key, keys) when is_binary(key), do: key in keys
  defp allowed_filter_key?(key, keys) when is_atom(key), do: Atom.to_string(key) in keys
  defp allowed_filter_key?(_key, _keys), do: false

  defp boolean_value(filter, key) do
    case Map.fetch(filter, key) do
      {:ok, value} when is_boolean(value) ->
        {:ok, value}

      {:ok, _value} ->
        :error

      :error ->
        case Map.fetch(filter, atom_key(key)) do
          {:ok, value} when is_boolean(value) -> {:ok, value}
          {:ok, _value} -> :error
          :error -> {:ok, false}
        end
    end
  end

  defp atom_key("toolsListChanged"), do: :toolsListChanged
  defp atom_key("promptsListChanged"), do: :promptsListChanged
  defp atom_key("resourcesListChanged"), do: :resourcesListChanged
  defp atom_key("resourceSubscriptions"), do: :resourceSubscriptions

  defp resource_filter(filter) do
    value = Map.get(filter, "resourceSubscriptions", Map.get(filter, :resourceSubscriptions, []))

    if is_list(value) do
      case Enum.reduce_while(value, {[], %{}}, fn uri, {uris, seen} ->
             cond do
               not valid_resource_uri?(uri) ->
                 {:halt, :error}

               Map.has_key?(seen, uri) ->
                 {:cont, {uris, seen}}

               map_size(seen) >= @max_resource_uris ->
                 {:halt, :error}

               true ->
                 uri = :binary.copy(uri)
                 {:cont, {[uri | uris], Map.put(seen, uri, true)}}
             end
           end) do
        {uris, _seen} -> {:ok, Enum.reverse(uris)}
        :error -> :error
      end
    else
      :error
    end
  end

  defp valid_resource_uri?(uri)
       when is_binary(uri) and byte_size(uri) in 1..@max_resource_uri_bytes do
    String.valid?(uri) and not String.contains?(uri, ["\u0000", "\r", "\n"])
  end

  defp valid_resource_uri?(_uri), do: false

  defp deliver(state, id, subscription, notification, opts) do
    event = event_for(notification, id)
    current_authorizer = Keyword.get(opts, :authorize)
    authorizers = Enum.reject([subscription.authorize, current_authorizer], &is_nil/1)
    required_scopes = List.wrap(opts[:required_scopes])
    required_scope_sets = notification_scope_sets(opts, required_scopes)

    allowed =
      matches?(subscription.filter, event) and
        Enum.all?(
          authorizers,
          &authorized?(&1, %{
            principal: subscription.principal,
            tenant: subscription.tenant,
            event: event,
            required_scopes: required_scopes,
            required_scope_sets: required_scope_sets
          })
        )

    cond do
      not allowed ->
        if matches?(subscription.filter, event),
          do:
            telemetry(state, [:subscription, :suppressed], %{count: 1}, %{
              reason: :authorization,
              transport: :core
            })

        state

      subscription.queue_size >= (state.opts[:max_queue] || @max_queue) ->
        if not subscription.overflowed do
          send(subscription.sink, {:mcp_subscription_backpressure, id})
        end

        telemetry(state, [:subscription, :backpressure], %{count: 1}, %{transport: :core})
        put_in(state, [:subscriptions, {subscription.sink, id}, :overflowed], true)

      true ->
        send(subscription.sink, {:mcp_subscription, subscription.tag, id, event})

        put_in(
          state,
          [:subscriptions, {subscription.sink, id}, :queue_size],
          subscription.queue_size + 1
        )
    end
  end

  defp publish_state(state, notification, opts) do
    Enum.reduce(state.subscriptions, state, fn {_key, subscription}, acc ->
      deliver(acc, subscription.id, subscription, notification, opts)
    end)
  end

  defp notification_scope_sets(opts, required_scopes) do
    case Keyword.get(opts, :required_scope_sets) do
      scope_sets when is_list(scope_sets) and scope_sets != [] -> scope_sets
      _ -> [required_scopes]
    end
  end

  defp telemetry(state, event, measurements, metadata) do
    Telemetry.execute(
      event,
      measurements,
      Map.put(metadata, :telemetry_metadata, state.opts[:telemetry_metadata])
    )
  end

  defp authorized?(authorized, context) when is_function(authorized, 1) do
    authorized.(context) == true
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp authorized?(_, _), do: true

  defp matches?(filter, %{"method" => method, "params" => params}) do
    key = category_for(method)

    cond do
      key in ["toolsListChanged", "promptsListChanged", "resourcesListChanged"] ->
        filter[key] == true

      key == "resourceSubscriptions" ->
        uris = filter["resourceSubscriptions"]
        uris != [] and resource_uri(params) in uris

      true ->
        false
    end
  end

  defp matches?(_, _), do: false

  defp category_for("notifications/tools/list_changed"), do: "toolsListChanged"
  defp category_for("notifications/prompts/list_changed"), do: "promptsListChanged"
  defp category_for("notifications/resources/list_changed"), do: "resourcesListChanged"
  defp category_for("notifications/resources/updated"), do: "resourceSubscriptions"
  defp category_for(_), do: nil

  defp resource_uri(params) when is_map(params) do
    if is_struct(params) do
      nil
    else
      direct = Map.get(params, "uri") || Map.get(params, :uri)
      resource = Map.get(params, "resource") || Map.get(params, :resource)

      direct ||
        if is_map(resource) and not is_struct(resource) do
          Map.get(resource, "uri") || Map.get(resource, :uri)
        end
    end
  end

  defp resource_uri(_), do: nil

  defp event_for(%{"method" => method, "params" => params}, id)
       when is_binary(method) and is_map(params) do
    if valid_metadata_object?(params),
      do:
        put_subscription_meta(%{"jsonrpc" => "2.0", "method" => method, "params" => params}, id),
      else: %{}
  end

  defp event_for(%{"method" => method}, _id) when is_binary(method), do: %{}

  defp event_for(%{method: method, params: params}, id)
       when is_binary(method) and is_map(params) do
    if valid_metadata_object?(params),
      do: event_for(%{"method" => method, "params" => params}, id),
      else: %{}
  end

  defp event_for(%{method: method}, _id) when is_binary(method), do: %{}

  defp event_for(notification, id) when is_map(notification) do
    if valid_metadata_object?(notification),
      do: event_for_type(notification, id),
      else: %{}
  end

  defp event_for(_, _), do: %{}

  defp event_for_type(notification, id) do
    {method, params} =
      case notification_type(notification) do
        "toolsListChanged" ->
          {"notifications/tools/list_changed", notification_meta(notification)}

        "promptsListChanged" ->
          {"notifications/prompts/list_changed", notification_meta(notification)}

        "resourcesListChanged" ->
          {"notifications/resources/list_changed", notification_meta(notification)}

        "resourceSubscriptions" ->
          {"notifications/resources/updated", notification_params(notification)}

        "resource" ->
          {"notifications/resources/updated", notification_params(notification)}

        "resourceUpdated" ->
          {"notifications/resources/updated", notification_params(notification)}

        _ ->
          {nil, %{}}
      end

    if method,
      do:
        put_subscription_meta(%{"jsonrpc" => "2.0", "method" => method, "params" => params}, id),
      else: %{}
  end

  defp put_subscription_meta(event, id) do
    params = plain_map(Map.get(event, "params"))
    meta = plain_map(Map.get(params, "_meta") || Map.get(params, :_meta))
    params = Map.delete(params, :_meta)
    meta = Map.put(meta, "io.modelcontextprotocol/subscriptionId", id)
    Map.put(event, "params", Map.put(params, "_meta", meta))
  end

  defp valid_metadata_object?(value) when is_map(value) do
    not is_struct(value) and
      Enum.all?([Map.fetch(value, "_meta"), Map.fetch(value, :_meta)], fn
        :error -> true
        {:ok, meta} -> is_map(meta) and not is_struct(meta)
      end)
  end

  defp notification_type(notification) do
    case Map.get(notification, "type") || Map.get(notification, :type) do
      type when is_binary(type) -> type
      type when is_atom(type) -> Atom.to_string(type)
      _ -> nil
    end
  end

  defp notification_params(notification) do
    notification
    |> Map.delete("type")
    |> Map.delete(:type)
    |> plain_map()
  end

  defp notification_meta(notification) when is_map(notification) do
    case Map.get(notification, "_meta") || Map.get(notification, :_meta) do
      meta when is_map(meta) -> if(is_struct(meta), do: %{}, else: %{"_meta" => meta})
      _ -> %{}
    end
  end

  defp plain_map(value) when is_map(value) do
    if is_struct(value), do: %{}, else: value
  end

  defp plain_map(_value), do: %{}

  defp acknowledgement(id, filter) do
    %{
      "jsonrpc" => "2.0",
      "method" => "notifications/subscriptions/acknowledged",
      "params" => %{
        "notifications" => filter,
        "_meta" => %{"io.modelcontextprotocol/subscriptionId" => id}
      }
    }
  end

  defp remove(state, key) do
    case state.subscriptions[key] do
      %{monitor: monitor} -> Process.demonitor(monitor, [:flush])
      _ -> :ok
    end

    update_in(state.subscriptions, &Map.delete(&1, key))
  end

  defp find_key(_state, _id, owner) when not is_pid(owner) and not is_nil(owner), do: nil

  defp find_key(_state, id, owner) when is_pid(owner), do: {owner, id}

  defp find_key(_state, _id, nil), do: nil
end
