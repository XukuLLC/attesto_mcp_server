defmodule AttestoMCP.Server.Schema.Cache do
  @moduledoc false
  use GenServer

  @max_entries 64
  @max_bytes 8 * 1024 * 1024
  @max_entry_bytes 256 * 1024
  @call_timeout 100

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def get(key, table \\ __MODULE__) do
    {:ok, :ets.lookup_element(table, key, 2)}
  rescue
    ArgumentError -> :miss
  end

  def put(key, root, server \\ __MODULE__) do
    # Include both retained key copies (ETS and the FIFO), heap words, and the
    # external payload of binaries. Counting both representations deliberately
    # overestimates retention, including off-heap strings and compiled regexes.
    key_bytes = :erlang.external_size(key)

    if key_bytes <= @max_entry_bytes do
      bytes =
        :erts_debug.flat_size({key, key, root}) * :erlang.system_info(:wordsize) +
          :erlang.external_size({key, key, root}) + 256

      if bytes <= @max_entry_bytes do
        reservation = make_ref()

        case reserve(server, reservation, bytes) do
          :ok ->
            case detach_for_cache({key, root}) do
              {:ok, {key, root}} ->
                GenServer.call(server, {:put, reservation, key, root, bytes}, @call_timeout)

              :uncacheable ->
                GenServer.cast(server, {:cancel, reservation})
            end

          :busy ->
            :ok
        end
      end
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  # Encoded size counts a slice, not the larger backing binary it retains. Only
  # admitted roots are copied, once, before entering either ETS or the owner's
  # mailbox. Preserve every byte while discarding unrelated source buffers.
  defp detach_for_cache(value) do
    detach_binaries(value)
  rescue
    _ -> :uncacheable
  catch
    _, _ -> :uncacheable
  end

  defp detach_binaries(value) when is_binary(value) do
    if :binary.referenced_byte_size(value) > byte_size(value),
      do: {:ok, :binary.copy(value)},
      else: {:ok, value}
  end

  defp detach_binaries(value) when is_map(value) do
    Enum.reduce_while(:maps.to_list(value), {:ok, %{}}, fn {key, nested}, {:ok, detached} ->
      with {:ok, key} <- detach_binaries(key),
           {:ok, nested} <- detach_binaries(nested) do
        {:cont, {:ok, Map.put(detached, key, nested)}}
      else
        :uncacheable -> {:halt, :uncacheable}
      end
    end)
  end

  defp detach_binaries([head | tail]) do
    with {:ok, head} <- detach_binaries(head),
         {:ok, tail} <- detach_binaries(tail) do
      {:ok, [head | tail]}
    end
  end

  defp detach_binaries(value) when is_tuple(value) do
    with {:ok, values} <- detach_binaries(Tuple.to_list(value)),
         do: {:ok, List.to_tuple(values)}
  end

  # Closures can hide binary references in environments that cannot be safely
  # rewritten. Current JSV roots use module validators and data; a future root
  # containing a function simply uses the uncached validation path.
  defp detach_binaries(value) when is_function(value), do: :uncacheable
  defp detach_binaries(value), do: {:ok, value}

  defp reserve(server, reservation, bytes) do
    GenServer.call(server, {:reserve, reservation, bytes}, @call_timeout)
  catch
    :exit, _ ->
      # A timed-out reservation may still be in the owner's mailbox. The small
      # cancellation follows it in sender order and cannot contain a root.
      GenServer.cast(server, {:cancel, reservation})
      :busy
  end

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :name, __MODULE__)
    :ets.new(table, [:named_table, :protected, :set, read_concurrency: true])

    {:ok,
     %{
       table: table,
       order: :queue.new(),
       entries: 0,
       bytes: 0,
       max_entries: Keyword.get(opts, :max_entries, @max_entries),
       max_bytes: Keyword.get(opts, :max_bytes, @max_bytes),
       max_entry_bytes: Keyword.get(opts, :max_entry_bytes, @max_entry_bytes),
       reservation: nil
     }}
  end

  @impl true
  def handle_call({:reserve, reservation, bytes}, {pid, _}, %{reservation: nil} = state) do
    if bytes <= state.max_entry_bytes and bytes <= state.max_bytes and state.max_entries > 0 do
      monitor = Process.monitor(pid)
      {:reply, :ok, %{state | reservation: {pid, reservation, monitor, bytes}}}
    else
      {:reply, :busy, state}
    end
  end

  def handle_call({:reserve, _reservation, _bytes}, _from, state), do: {:reply, :busy, state}

  def handle_call(
        {:put, reservation, key, root, bytes},
        {pid, _},
        %{reservation: {pid, reservation, monitor, bytes}} = state
      ) do
    Process.demonitor(monitor, [:flush])
    state = %{state | reservation: nil}

    if :ets.member(state.table, key) do
      {:reply, :ok, state}
    else
      state = make_room(state, bytes)
      :ets.insert(state.table, {key, root})

      {:reply, :ok,
       %{
         state
         | order: :queue.in({key, bytes}, state.order),
           entries: state.entries + 1,
           bytes: state.bytes + bytes
       }}
    end
  end

  def handle_call({:put, _reference, _key, _root, _bytes}, _from, state),
    do: {:reply, :ok, state}

  def handle_call(:stats, _from, state) do
    {:reply, Map.take(state, [:entries, :bytes, :max_entries, :max_bytes, :max_entry_bytes]),
     state}
  end

  @impl true
  def handle_cast({:cancel, reservation}, %{reservation: {_pid, reservation, monitor, _}} = state) do
    Process.demonitor(monitor, [:flush])
    {:noreply, %{state | reservation: nil}}
  end

  def handle_cast({:cancel, _reservation}, state), do: {:noreply, state}

  @impl true
  def handle_info(
        {:DOWN, monitor, :process, pid, _},
        %{reservation: {pid, _reservation, monitor, _}} = state
      ),
      do: {:noreply, %{state | reservation: nil}}

  def handle_info(_message, state), do: {:noreply, state}

  defp make_room(state, bytes)
       when state.entries < state.max_entries and state.bytes + bytes <= state.max_bytes,
       do: state

  defp make_room(state, bytes) do
    {{:value, {key, retained_bytes}}, order} = :queue.out(state.order)
    :ets.delete(state.table, key)

    make_room(
      %{state | order: order, entries: state.entries - 1, bytes: state.bytes - retained_bytes},
      bytes
    )
  end
end
