defmodule AttestoMCP.Test.OwnedPort do
  @moduledoc false

  @type owned_process :: %{os_pid: pos_integer(), identity: String.t() | nil}

  @spec capture(port()) :: owned_process()
  def capture(port) when is_port(port) do
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    %{os_pid: os_pid, identity: process_identity(os_pid)}
  end

  @spec cleanup(port(), reference(), owned_process(), Path.t(), non_neg_integer()) ::
          (-> :ok)
  def cleanup(port, monitor, process, directory, timeout_ms)
      when is_port(port) and is_reference(monitor) and is_integer(timeout_ms) and timeout_ms >= 0 do
    once = :atomics.new(1, [])

    fn ->
      if :atomics.exchange(once, 1, 1) == 0 do
        stop_and_remove(port, monitor, process, directory, deadline(timeout_ms))
      else
        :ok
      end
    end
  end

  @spec deadline(non_neg_integer()) :: integer()
  def deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  @spec remaining(integer()) :: non_neg_integer()
  def remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp stop_and_remove(port, monitor, process, directory, deadline) do
    try do
      if owned_port_alive?(port, process) do
        terminate(port, process, deadline)

        if owned_port_alive?(port, process) do
          close_port(port)
          await_port_down(port, monitor, deadline)
        end
      end

      File.rm_rf!(directory)
      :ok
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp terminate(port, %{os_pid: os_pid, identity: identity} = process, deadline) do
    if owned_port_alive?(port, process) and process_identity(os_pid) == identity and
         not is_nil(identity) do
      signal_processes(port, process, [{os_pid, identity}], "STOP")

      targets =
        os_pid
        |> freeze_process_tree(port, process, MapSet.new([os_pid]), 0, deadline)
        |> Enum.map(&{&1, process_identity(&1)})
        |> Enum.reject(fn {_pid, process_identity} -> is_nil(process_identity) end)
        |> Enum.sort_by(fn {pid, _identity} -> pid == os_pid end)

      signal_processes(port, process, targets, "KILL")
      await_process_exit(targets, deadline)
    end

    :ok
  end

  defp freeze_process_tree(os_pid, port, process, stopped, stable_rounds, deadline) do
    current = MapSet.new(process_tree(os_pid))
    unstopped = MapSet.difference(current, stopped)

    unstopped_targets =
      unstopped
      |> Enum.map(&{&1, process_identity(&1)})
      |> Enum.reject(fn {_pid, identity} -> is_nil(identity) end)

    signal_processes(port, process, unstopped_targets, "STOP")
    stopped = MapSet.union(stopped, current)

    cond do
      not owned_port_alive?(port, process) ->
        []

      MapSet.size(unstopped) > 0 ->
        freeze_process_tree(os_pid, port, process, stopped, 0, deadline)

      stable_rounds < 2 and remaining(deadline) > 0 ->
        Process.sleep(min(10, remaining(deadline)))
        freeze_process_tree(os_pid, port, process, stopped, stable_rounds + 1, deadline)

      stable_rounds >= 2 ->
        MapSet.to_list(stopped)

      true ->
        raise ExUnit.AssertionError, message: "owned process tree did not stop before cleanup"
    end
  end

  defp process_tree(root_pid) do
    pairs = process_pairs()
    collect_process_tree([root_pid], MapSet.new([root_pid]), pairs)
  end

  defp collect_process_tree([], collected, _pairs), do: MapSet.to_list(collected)

  defp collect_process_tree(parents, collected, pairs) do
    parent_set = MapSet.new(parents)

    children =
      for {pid, parent_pid} <- pairs,
          MapSet.member?(parent_set, parent_pid),
          not MapSet.member?(collected, pid),
          do: pid

    collect_process_tree(children, Enum.reduce(children, collected, &MapSet.put(&2, &1)), pairs)
  end

  defp process_pairs do
    case System.cmd("/bin/ps", ["-axo", "pid=,ppid="], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case String.split(String.trim(line), ~r/\s+/, parts: 2) do
            [pid, parent_pid] ->
              try do
                [{String.to_integer(pid), String.to_integer(parent_pid)}]
              rescue
                ArgumentError -> []
              end

            _other ->
              []
          end
        end)

      {_output, _status} ->
        []
    end
  end

  defp process_identity(pid) do
    case System.cmd("/bin/ps", ["-p", Integer.to_string(pid), "-o", "lstart="],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case String.trim(output) do
          "" -> nil
          identity -> identity
        end

      {_output, _status} ->
        nil
    end
  end

  defp signal_processes(port, process, targets, signal) do
    Enum.reduce_while(targets, :ok, fn {pid, identity}, :ok ->
      cond do
        not owned_port_alive?(port, process) ->
          {:halt, :port_down}

        process_identity(pid) == identity ->
          _ =
            System.cmd("/bin/kill", ["-#{signal}", Integer.to_string(pid)],
              stderr_to_stdout: true
            )

          {:cont, :ok}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp owned_port_alive?(port, %{os_pid: os_pid}) do
    Port.info(port, :os_pid) == {:os_pid, os_pid}
  rescue
    ArgumentError -> false
  end

  defp await_process_exit(targets, deadline) do
    alive =
      Enum.filter(targets, fn {pid, identity} ->
        process_identity(pid) == identity
      end)

    cond do
      alive == [] ->
        :ok

      remaining(deadline) > 0 ->
        Process.sleep(min(10, remaining(deadline)))
        await_process_exit(alive, deadline)

      true ->
        raise ExUnit.AssertionError,
          message: "owned process tree did not terminate before cleanup"
    end
  end

  defp await_port_down(port, monitor, deadline) do
    receive do
      {:DOWN, ^monitor, :port, ^port, _reason} -> :ok
      {^port, {:data, _data}} -> await_port_down(port, monitor, deadline)
      {^port, {:exit_status, _status}} -> await_port_down(port, monitor, deadline)
    after
      remaining(deadline) ->
        if Port.info(port) do
          raise ExUnit.AssertionError, message: "owned port did not terminate before cleanup"
        else
          :ok
        end
    end
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
