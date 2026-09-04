defmodule AttestoMCP.Server.UrlElicitationStore.ETS do
  @moduledoc """
  Private in-memory URL elicitation store used by default.

  Each server instance owns an ETS store process by default unless configured
  with an external store adapter.
  """

  use GenServer

  @behaviour AttestoMCP.Server.UrlElicitationStore

  @max_cleanup 1_000

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
  def init(_opts), do: {:ok, %{records: %{}}}

  @impl true
  def handle_call({:put, record}, _from, state) do
    if valid_record?(record) do
      key = {record["namespace"], record["id"]}
      {:reply, :ok, put_in(state, [:records, key], record)}
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
              {:reply, {:ok, consumed}, %{state | records: new_records}}
          end
      end
    else
      {:reply, :not_found, state}
    end
  end

  def handle_call({:cleanup_expired, now_ms}, _from, state) do
    expired_entries =
      state.records
      |> Enum.filter(fn {_key, record} ->
        is_integer(record["expires_at_ms"]) and record["expires_at_ms"] <= now_ms
      end)
      |> Enum.take(@max_cleanup)

    expired_ids = Enum.map(expired_entries, fn {{_ns, id}, _record} -> id end)

    new_records =
      Enum.reduce(expired_entries, state.records, fn {key, _record}, acc ->
        Map.delete(acc, key)
      end)

    {:reply, {:ok, expired_ids}, %{state | records: new_records}}
  end

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
