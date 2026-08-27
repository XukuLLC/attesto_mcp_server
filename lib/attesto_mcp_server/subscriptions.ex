defmodule AttestoMCP.Server.Subscriptions do
  @moduledoc "Bounded, principal/tenant-bound modern subscription registry."
  use GenServer

  alias AttestoMCP.Server.Telemetry

  @max_queue 128

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
  def ack(pid, id), do: GenServer.cast(pid, {:ack, id})

  @doc "Returns bounded public counters for active subscriptions and queued events."
  @spec stats(pid()) :: %{count: non_neg_integer(), queued: non_neg_integer()}
  def stats(pid), do: GenServer.call(pid, :stats)

  @doc "Gracefully closes one subscription."
  @spec close(pid(), term()) :: :ok
  def close(pid, id), do: GenServer.call(pid, {:close, id, nil})

  @spec close(pid(), term(), pid() | nil) :: :ok
  def close(pid, id, owner), do: GenServer.call(pid, {:close, id, owner})

  @doc "Cancels one subscription without affecting its peers."
  @spec cancel(pid(), term()) :: :ok
  def cancel(pid, id), do: GenServer.call(pid, {:cancel, id, nil})

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
      Telemetry.execute([:subscription, :open], %{count: 1}, %{transport: :core})
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

  def handle_call({:close, id, owner}, _from, state) do
    Telemetry.execute([:subscription, :close], %{count: 1}, %{transport: :core})

    key = find_key(state, id, owner)

    case state.subscriptions[key] do
      %{sink: sink} when is_pid(sink) -> send(sink, {:mcp_subscription_close, id})
      _ -> :ok
    end

    {:reply, :ok, remove(state, key)}
  end

  def handle_call({:cancel, id, owner}, _from, state) do
    key = find_key(state, id, owner)

    case state.subscriptions[key] do
      %{sink: sink} when is_pid(sink) -> send(sink, {:mcp_subscription_cancel, id})
      _ -> :ok
    end

    {:reply, :ok, remove(state, key)}
  end

  @impl true
  def handle_cast({:ack, id}, state), do: handle_cast({:ack, id, nil}, state)

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

  defp choose_id(nil, _sink, state) do
    id = "sub_" <> Integer.to_string(state.seq + 1)
    {:ok, id, %{state | seq: state.seq + 1}}
  end

  defp choose_id(id, sink, state) when (is_binary(id) or is_integer(id)) and is_pid(sink) do
    if Map.has_key?(state.subscriptions, {sink, id}),
      do: {:error, :duplicate},
      else: {:ok, id, state}
  end

  defp choose_id(_, _sink, _state), do: {:error, :invalid_id}

  defp normalize_filter(filter) when is_map(filter) do
    keys = [
      "toolsListChanged",
      "promptsListChanged",
      "resourcesListChanged",
      "resourceSubscriptions"
    ]

    if Enum.any?(Map.keys(filter), fn key -> to_string(key) not in keys end) do
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

    if is_list(value) and Enum.all?(value, &is_binary/1), do: {:ok, value}, else: :error
  end

  defp deliver(state, id, subscription, notification, opts) do
    event = event_for(notification, id)
    current_authorizer = Keyword.get(opts, :authorize)
    authorizers = Enum.reject([subscription.authorize, current_authorizer], &is_nil/1)

    allowed =
      matches?(subscription.filter, event) and
        Enum.all?(
          authorizers,
          &authorized?(&1, %{
            principal: subscription.principal,
            tenant: subscription.tenant,
            event: event,
            required_scopes: List.wrap(opts[:required_scopes])
          })
        )

    cond do
      not allowed ->
        if matches?(subscription.filter, event),
          do:
            Telemetry.execute([:subscription, :suppressed], %{count: 1}, %{
              reason: :authorization,
              transport: :core
            })

        state

      subscription.queue_size >= (state.opts[:max_queue] || @max_queue) ->
        if not subscription.overflowed do
          send(subscription.sink, {:mcp_subscription_backpressure, id})
        end

        Telemetry.execute([:subscription, :backpressure], %{count: 1}, %{transport: :core})
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

  defp resource_uri(params) when is_map(params),
    do: params["uri"] || get_in(params, ["resource", "uri"])

  defp resource_uri(_), do: nil

  defp event_for(%{"method" => method, "params" => params}, id) when is_binary(method) do
    put_subscription_meta(%{"jsonrpc" => "2.0", "method" => method, "params" => params}, id)
  end

  defp event_for(%{method: method, params: params}, id) when is_binary(method),
    do: event_for(%{"method" => method, "params" => params}, id)

  defp event_for(notification, id) when is_map(notification) do
    type = notification["type"] || notification[:type]

    {method, params} =
      case to_string(type) do
        "toolsListChanged" ->
          {"notifications/tools/list_changed", notification_meta(notification)}

        "promptsListChanged" ->
          {"notifications/prompts/list_changed", notification_meta(notification)}

        "resourcesListChanged" ->
          {"notifications/resources/list_changed", notification_meta(notification)}

        "resourceSubscriptions" ->
          {"notifications/resources/updated", Map.delete(notification, "type")}

        "resource" ->
          {"notifications/resources/updated", Map.delete(notification, "type")}

        "resourceUpdated" ->
          {"notifications/resources/updated", Map.delete(notification, "type")}

        _ ->
          {nil, %{}}
      end

    if method,
      do:
        put_subscription_meta(%{"jsonrpc" => "2.0", "method" => method, "params" => params}, id),
      else: notification
  end

  defp event_for(_, _), do: %{}

  defp put_subscription_meta(event, id) do
    params = Map.get(event, "params", %{})
    meta = Map.put(Map.get(params, "_meta", %{}), "io.modelcontextprotocol/subscriptionId", id)
    Map.put(event, "params", Map.put(params, "_meta", meta))
  end

  defp notification_meta(notification) when is_map(notification) do
    case notification["_meta"] || notification[:_meta] do
      meta when is_map(meta) -> %{"_meta" => meta}
      _ -> %{}
    end
  end

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

  defp find_key(state, id, nil) do
    Enum.find_value(state.subscriptions, fn {key, subscription} ->
      if is_map(subscription) and subscription.id == id, do: key
    end)
  end
end
