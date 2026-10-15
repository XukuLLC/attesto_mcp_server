defmodule AttestoMCP.Server.UrlElicitationStore.ETS do
  @moduledoc """
  Private in-memory URL elicitation store used by default.

  Each server instance owns an ETS store process by default unless configured
  with an external store adapter. The in-memory store is bounded by entry and
  approximate external-term byte limits. It rejects duplicate record keys and
  never evicts an unexpired approval to admit another one. Periodic cleanup is
  limited to 1,000 records per call; admission cleanup scans at most the
  configured entry bound and reclaims as many expired records as the new record
  needs.
  """

  use GenServer

  @behaviour AttestoMCP.Server.UrlElicitationStore

  @max_cleanup 1_000
  @default_max_entries 10_000
  @default_max_bytes 64 * 1024 * 1024

  @doc false
  @spec default_max_entries() :: pos_integer()
  def default_max_entries, do: @default_max_entries

  @doc false
  @spec default_max_bytes() :: pos_integer()
  def default_max_bytes, do: @default_max_bytes

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def put(store, record), do: GenServer.call(store, {:put, record})

  @impl true
  def fetch(store, namespace, id), do: GenServer.call(store, {:fetch, namespace, id})

  @impl true
  def consume(store, namespace, id, subject_hash, now_ms)
      when is_integer(now_ms) and now_ms >= 0 do
    GenServer.call(store, {:consume, namespace, id, subject_hash, now_ms})
  end

  def consume(_store, _namespace, _id, _subject_hash, _now_ms), do: {:error, :invalid_timestamp}

  @impl true
  def cleanup_expired(store, now_ms) when is_integer(now_ms) and now_ms >= 0 do
    GenServer.call(store, {:cleanup_expired, now_ms})
  end

  def cleanup_expired(_store, _now_ms), do: {:error, :invalid_timestamp}

  @impl true
  def init(opts) do
    max_entries = Keyword.get(opts, :max_entries, @default_max_entries)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    unless is_integer(max_entries) and max_entries > 0 do
      raise ArgumentError, ":max_entries must be a positive integer"
    end

    unless is_integer(max_bytes) and max_bytes > 0 do
      raise ArgumentError, ":max_bytes must be a positive integer"
    end

    {:ok,
     %{
       records: %{},
       count: 0,
       bytes: 0,
       max_entries: max_entries,
       max_bytes: max_bytes
     }}
  end

  @impl true
  def handle_call({:put, record}, _from, state) do
    if valid_record?(record) do
      key = {record["namespace"], record["id"]}

      if Map.has_key?(state.records, key) do
        {:reply, {:error, :already_exists}, state}
      else
        record_bytes = record_size(record)
        state = maybe_cleanup_for_capacity(state, record_bytes)

        if capacity_available?(state, record_bytes) do
          records = Map.put(state.records, key, record)

          {:reply, :ok,
           %{state | records: records, count: state.count + 1, bytes: state.bytes + record_bytes}}
        else
          {:reply, {:error, :capacity}, state}
        end
      end
    else
      {:reply, {:error, :invalid_record}, state}
    end
  end

  def handle_call({:fetch, namespace, id}, _from, state) do
    if valid_key_part?(namespace) and valid_key_part?(id) do
      case Map.get(state.records, {namespace, id}) do
        nil -> {:reply, :not_found, state}
        record -> {:reply, {:ok, record}, state}
      end
    else
      {:reply, :not_found, state}
    end
  end

  def handle_call({:consume, namespace, id, subject_hash, now_ms}, _from, state) do
    if valid_key_part?(namespace) and valid_key_part?(id) do
      case Map.get(state.records, {namespace, id}) do
        nil ->
          {:reply, :not_found, state}

        record ->
          cond do
            record["subject_hash"] != subject_hash ->
              {:reply, {:error, :foreign}, state}

            not is_nil(record["consumed_at_ms"]) ->
              {:reply, {:error, :consumed}, state}

            is_integer(record["expires_at_ms"]) and now_ms >= record["expires_at_ms"] ->
              {:reply, {:error, :expired}, state}

            true ->
              consumed = Map.put(record, "consumed_at_ms", now_ms)
              new_records = Map.put(state.records, {namespace, id}, consumed)
              new_bytes = state.bytes - record_size(record) + record_size(consumed)
              {:reply, {:ok, consumed}, %{state | records: new_records, bytes: new_bytes}}
          end
      end
    else
      {:reply, :not_found, state}
    end
  end

  def handle_call({:cleanup_expired, now_ms}, _from, state) do
    {expired_ids, state} = cleanup_expired_records(state, now_ms)
    {:reply, {:ok, expired_ids}, state}
  end

  defp maybe_cleanup_for_capacity(state, record_bytes) do
    if capacity_available?(state, record_bytes) do
      state
    else
      reclaim_expired_for_capacity(state, record_bytes, System.system_time(:millisecond))
    end
  end

  defp reclaim_expired_for_capacity(state, record_bytes, now_ms) do
    Enum.reduce_while(state.records, state, fn {key, record}, acc ->
      cond do
        capacity_available?(acc, record_bytes) ->
          {:halt, acc}

        expired?(record, now_ms) ->
          {:cont, delete_record(acc, key, record)}

        true ->
          {:cont, acc}
      end
    end)
  end

  defp capacity_available?(state, record_bytes) do
    state.count < state.max_entries and state.bytes + record_bytes <= state.max_bytes
  end

  defp cleanup_expired_records(state, now_ms) do
    {expired_entries, _count} =
      Enum.reduce_while(state.records, {[], 0}, fn {_key, record} = entry, {entries, count} ->
        cond do
          count >= @max_cleanup ->
            {:halt, {entries, count}}

          expired?(record, now_ms) ->
            {:cont, {[entry | entries], count + 1}}

          true ->
            {:cont, {entries, count}}
        end
      end)

    {expired_ids, records, removed_bytes} =
      Enum.reduce(expired_entries, {[], state.records, 0}, fn {{_namespace, id} = key, record},
                                                              {ids, records, bytes} ->
        {[id | ids], Map.delete(records, key), bytes + record_size(record)}
      end)

    new_state = %{
      state
      | records: records,
        count: state.count - length(expired_entries),
        bytes: max(state.bytes - removed_bytes, 0)
    }

    {Enum.reverse(expired_ids), new_state}
  end

  defp delete_record(state, key, record) do
    %{
      state
      | records: Map.delete(state.records, key),
        count: state.count - 1,
        bytes: max(state.bytes - record_size(record), 0)
    }
  end

  defp expired?(record, now_ms),
    do: is_integer(record["expires_at_ms"]) and record["expires_at_ms"] <= now_ms

  defp record_size(record), do: :erlang.external_size(record)

  defp valid_record?(record) when is_map(record) do
    valid_key_part?(record["id"]) and
      valid_key_part?(record["namespace"]) and
      is_binary(record["subject_hash"]) and
      is_binary(record["action"]) and
      is_map(record["fields"]) and
      is_integer(record["created_at_ms"]) and record["created_at_ms"] >= 0 and
      is_integer(record["expires_at_ms"]) and record["expires_at_ms"] >= 0 and
      (is_nil(record["consumed_at_ms"]) or
         (is_integer(record["consumed_at_ms"]) and record["consumed_at_ms"] >= 0))
  end

  defp valid_record?(_record), do: false

  defp valid_key_part?(value) do
    is_binary(value) and byte_size(value) in 1..256 and String.valid?(value) and
      :binary.match(value, <<0>>) == :nomatch
  end
end
