defmodule AttestoMCP.Server.SessionStore.ETS do
  @moduledoc "Private in-memory session store used by default."
  use GenServer

  @behaviour AttestoMCP.Server.SessionStore
  alias AttestoMCP.Server.Session
  @max_list 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def save(store, key, record), do: GenServer.call(store, {:save, key, record})

  @impl true
  def load(store, key), do: GenServer.call(store, {:load, key})

  @impl true
  def delete(store, key), do: GenServer.call(store, {:delete, key})

  @impl true
  def list_active(store), do: GenServer.call(store, :list_active)

  @impl true
  def update_ttl(store, key, now), do: GenServer.call(store, {:update_ttl, key, now})

  @impl true
  def update(store, key, fun), do: GenServer.call(store, {:update, key, fun})

  @impl true
  def cleanup_expired(store), do: GenServer.call(store, :cleanup_expired)

  @impl true
  def init(_opts),
    do: {:ok, %{records: %{}, cleanup_queue: :queue.new(), queued: MapSet.new()}}

  @impl true
  def handle_call({:save, key, record}, _from, state) do
    state = enqueue_new_key(state, key)
    {:reply, :ok, put_in(state, [:records, key], record)}
  end

  def handle_call({:load, key}, _from, state) do
    reply =
      case state.records,
        do: (
          %{^key => record} ->
            case Session.record_version_status(record) do
              :invalid -> :not_found
              _ -> {:ok, record}
            end

          _ ->
            :not_found
        )

    state =
      if reply == :not_found and Map.has_key?(state.records, key) and
           Session.record_version_status(state.records[key]) == :invalid do
        delete_record(state, key)
      else
        state
      end

    {:reply, reply, state}
  end

  def handle_call({:delete, key}, _from, state) do
    state = %{
      state
      | records: Map.delete(state.records, key),
        cleanup_queue: :queue.delete(key, state.cleanup_queue),
        queued: MapSet.delete(state.queued, key)
    }

    {:reply, :ok, state}
  end

  def handle_call(:list_active, _from, state) do
    now = System.system_time(:millisecond)
    {_expired, state} = cleanup_records(state, now, @max_list, [])

    records =
      state.records
      |> Enum.take(@max_list)
      |> Enum.reject(fn {_key, record} -> expired?(record, now) end)

    {:reply, {:ok, records}, state}
  end

  def handle_call({:update_ttl, key, now}, _from, state) do
    update_record(state, key, fn record ->
      case Session.record_version_status(record) do
        :future ->
          # A node that cannot decode this record must neither rewrite nor
          # delete it during a touch. Return the opaque record so callers can
          # distinguish preservation from an absent row.
          :preserve

        :invalid ->
          # Invalid version markers are corrupt, not opaque future records.
          # Remove them as one atomic store operation.
          :delete

        :current ->
          # The expiry decision must include time spent waiting in the GenServer
          # mailbox. Otherwise a delayed refresh could revive an already-expired
          # session. A refresh can arrive out of order across callers, so never
          # move last_seen backwards.
          effective_now = max(now, System.system_time(:millisecond))

          if expired?(record, effective_now),
            do: :delete,
            else: {:ok, Map.put(record, "last_seen_ms", max(record["last_seen_ms"], now))}
      end
    end)
  end

  def handle_call({:update, key, fun}, _from, state) do
    update_record(state, key, fn record ->
      case Session.record_version_status(record) do
        :future -> :preserve
        :invalid -> :delete
        :current -> fun.(record)
      end
    end)
  end

  def handle_call(:cleanup_expired, _from, state) do
    now = System.system_time(:millisecond)
    {expired, state} = cleanup_records(state, now, @max_list, [])
    {:reply, {:ok, Enum.reverse(expired)}, state}
  end

  defp enqueue_new_key(state, key) do
    if MapSet.member?(state.queued, key) do
      state
    else
      %{
        state
        | cleanup_queue: :queue.in(key, state.cleanup_queue),
          queued: MapSet.put(state.queued, key)
      }
    end
  end

  defp delete_record(state, key) do
    %{
      state
      | records: Map.delete(state.records, key),
        cleanup_queue: :queue.delete(key, state.cleanup_queue),
        queued: MapSet.delete(state.queued, key)
    }
  end

  defp cleanup_records(state, _now, 0, expired), do: {expired, state}

  defp cleanup_records(state, now, remaining, expired) do
    case :queue.out(state.cleanup_queue) do
      {:empty, _queue} ->
        {expired, state}

      {{:value, key}, queue} ->
        state = %{state | cleanup_queue: queue}

        case state.records do
          %{^key => record} ->
            if expired?(record, now) do
              state = %{
                state
                | records: Map.delete(state.records, key),
                  queued: MapSet.delete(state.queued, key)
              }

              cleanup_records(state, now, remaining - 1, [key | expired])
            else
              state = %{state | cleanup_queue: :queue.in(key, state.cleanup_queue)}
              cleanup_records(state, now, remaining - 1, expired)
            end

          _ ->
            state = %{state | queued: MapSet.delete(state.queued, key)}
            cleanup_records(state, now, remaining - 1, expired)
        end
    end
  end

  defp update_record(state, key, fun) do
    case state.records do
      %{^key => record} ->
        try do
          case fun.(record) do
            {:ok, updated} when is_map(updated) ->
              {:reply, {:ok, updated}, put_in(state, [:records, key], updated)}

            :delete ->
              state = %{
                state
                | records: Map.delete(state.records, key),
                  cleanup_queue: :queue.delete(key, state.cleanup_queue),
                  queued: MapSet.delete(state.queued, key)
              }

              {:reply, :not_found, state}

            :preserve ->
              {:reply, {:ok, record}, state}

            {:error, reason} ->
              {:reply, {:error, reason}, state}

            _other ->
              {:reply, {:error, :invalid_update}, state}
          end
        catch
          _kind, _reason -> {:reply, {:error, :update_failed}, state}
        end

      _ ->
        {:reply, :not_found, state}
    end
  end

  defp expired?(record, now) do
    case Session.record_version_status(record) do
      :future ->
        false

      :invalid ->
        true

      :current ->
        created = record["created_at_ms"]
        seen = record["last_seen_ms"]
        absolute = record["absolute_timeout_ms"]
        idle = record["idle_timeout_ms"]

        not (is_integer(created) and is_integer(seen) and is_integer(absolute) and
               is_integer(idle)) or now - created > absolute or now - seen > idle
    end
  end
end
