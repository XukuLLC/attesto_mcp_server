defmodule AttestoMCP.Server.HardeningStdioTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server
  alias AttestoMCP.Server.Stdio

  for kind <- [:valid, :oversized] do
    @kind kind
    test "a flood of #{@kind} frames stops reading while output is blocked" do
      server = start_supervised!({Server, rate_limits: false, max_queue: 8})
      count = start_supervised!({Agent, fn -> 0 end})
      parent = self()

      input = fn ->
        index = Agent.get_and_update(count, &{&1, &1 + 1})
        if index == 0, do: send(parent, {:reader, self()})

        cond do
          index == 2_000 ->
            :eof

          @kind == :oversized ->
            {:oversized, :message_too_large}

          true ->
            Jason.encode!(%{
              jsonrpc: "2.0",
              id: index,
              method: "ping",
              params: %{
                "_meta" => %{
                  "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
                  "io.modelcontextprotocol/clientCapabilities" => %{}
                }
              }
            }) <> "\n"
        end
      end

      io = spawn(fn -> blocked_io(parent) end)

      {dispatcher, monitor} =
        spawn_monitor(fn ->
          Process.group_leader(self(), io)
          send(parent, {:done, Stdio.run(server, input: input, eof_grace_ms: 1_000)})
        end)

      on_exit(fn ->
        Process.exit(dispatcher, :kill)
        Process.exit(io, :kill)
      end)

      assert_receive {:reader, reader}, 1_000
      assert_receive {:blocked, ^dispatcher}, 1_000
      # Give the one outstanding credit time to reach the reader. It cannot
      # read the remaining flood while the writer has not acknowledged output.
      Process.sleep(50)
      read = Agent.get(count, & &1)
      assert read <= 10
      if @kind == :oversized, do: assert(read == 1)
      {:messages, messages} = Process.info(dispatcher, :messages)

      assert Enum.count(
               messages,
               &(is_tuple(&1) and elem(&1, 0) in [:stdio_line, :stdio_oversized])
             ) <= 1

      Process.sleep(50)
      assert Agent.get(count, & &1) == read
      assert Process.alive?(reader)

      send(io, :release)
      assert_receive {:done, :ok}, 10_000
      assert_receive {:DOWN, ^monitor, :process, ^dispatcher, :normal}, 1_000
      send(io, {:count, self()})
      assert_receive {:writes, 2_000}, 1_000
      refute Process.alive?(reader)
    end
  end

  test "a reader waiting for credit terminates when the dispatcher dies" do
    server = start_supervised!({Server, []})
    parent = self()
    io = spawn(fn -> blocked_io(parent) end)

    dispatcher =
      spawn(fn ->
        Process.group_leader(self(), io)

        Stdio.run(server,
          input: fn ->
            send(parent, {:reader, self()})
            {:oversized, :message_too_large}
          end
        )
      end)

    on_exit(fn ->
      Process.exit(dispatcher, :kill)
      Process.exit(io, :kill)
    end)

    assert_receive {:reader, reader}, 1_000
    assert_receive {:blocked, ^dispatcher}, 1_000
    monitor = Process.monitor(reader)
    Process.exit(dispatcher, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^reader, :normal}, 1_000
  end

  defp blocked_io(parent) do
    receive do
      {:io_request, from, reply_as, _request} ->
        send(parent, {:blocked, from})

        receive do
          :release -> send(from, {:io_reply, reply_as, :ok})
        end

        io_loop(1)
    end
  end

  defp io_loop(count) do
    receive do
      {:io_request, from, reply_as, _request} ->
        send(from, {:io_reply, reply_as, :ok})
        io_loop(count + 1)

      {:count, from} ->
        send(from, {:writes, count})
        io_loop(count)
    end
  end
end
