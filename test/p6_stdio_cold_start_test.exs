defmodule AttestoMCP.Server.P6StdioColdStartTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server.JSONRPC
  alias AttestoMCP.Test.OwnedPort

  @modern "2026-07-28"
  @cold_start_timeout_ms 300_000
  @port_stop_timeout_ms 30_000

  @tag timeout: 350_000
  test "cold Mix.install keeps stdout protocol-only with an isolated install directory" do
    root = File.cwd!()

    install_dir =
      Path.join(System.tmp_dir!(), "attesto-mcp-p6-#{System.unique_integer([:positive])}")

    output_path = Path.join(install_dir, "stdout")
    error_path = Path.join(install_dir, "stderr")
    input_path = Path.join(install_dir, "stdin")
    File.mkdir_p!(install_dir)

    metadata = %{
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => @modern,
        "io.modelcontextprotocol/clientCapabilities" => %{}
      }
    }

    input =
      [
        %{"jsonrpc" => "2.0", "id" => 1, "method" => "server/discover", "params" => metadata},
        %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list", "params" => metadata},
        %{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "tools/call",
          "params" =>
            Map.merge(metadata, %{
              "name" => "echo",
              "arguments" => %{"hello" => "world"}
            })
        }
      ]
      |> Enum.map_join("\n", &Jason.encode!/1)
      |> Kernel.<>("\n")

    File.write!(input_path, input)
    executable = System.find_executable("elixir") || raise "elixir executable not found"

    command =
      ~s(exec "$ATTESTO_P6_ELIXIR" "$ATTESTO_P6_SCRIPT" <"$ATTESTO_P6_STDIN" >"$ATTESTO_P6_STDOUT" 2>"$ATTESTO_P6_STDERR")

    port =
      Port.open({:spawn_executable, ~c"/bin/sh"}, [
        :binary,
        :exit_status,
        :hide,
        {:cd, String.to_charlist(root)},
        {:args, [~c"-c", String.to_charlist(command)]},
        {:env,
         [
           {~c"MIX_INSTALL_DIR", String.to_charlist(install_dir)},
           {~c"ATTESTO_P6_ELIXIR", String.to_charlist(executable)},
           {~c"ATTESTO_P6_SCRIPT", String.to_charlist(Path.join(root, "examples/stdio.exs"))},
           {~c"ATTESTO_P6_STDIN", String.to_charlist(input_path)},
           {~c"ATTESTO_P6_STDOUT", String.to_charlist(output_path)},
           {~c"ATTESTO_P6_STDERR", String.to_charlist(error_path)}
         ]}
      ])

    monitor = :erlang.monitor(:port, port)
    process = OwnedPort.capture(port)
    cleanup = OwnedPort.cleanup(port, monitor, process, install_dir, @port_stop_timeout_ms)

    on_exit(cleanup)

    try do
      status =
        case await_port_exit(port, monitor, deadline(@cold_start_timeout_ms)) do
          {:ok, status} -> status
          :timeout -> flunk("cold stdio process timed out:\n#{read_if_present(error_path)}")
        end

      assert status == 0, read_if_present(error_path)

      lines = output_path |> File.read!() |> String.split("\n", trim: true)
      assert length(lines) == 3, inspect(lines)

      messages = Enum.map(lines, &Jason.decode!/1)
      assert Enum.map(messages, & &1["id"]) |> Enum.sort() == [1, 2, 3]
      assert Enum.all?(messages, &(&1["jsonrpc"] == "2.0"))
      assert Enum.all?(lines, &match?({:ok, %{kind: :response}}, JSONRPC.decode(&1)))

      assert Enum.all?(messages, &(get_in(&1, ["result", "resultType"]) == "complete"))
      assert Enum.find(messages, &(&1["id"] == 1))["result"]["supportedVersions"]
      assert Enum.find(messages, &(&1["id"] == 2))["result"]["tools"]

      assert Enum.find(messages, &(&1["id"] == 3))["result"]["structuredContent"] == %{
               "hello" => "world"
             }
    after
      cleanup.()
    end
  end

  defp await_port_exit(port, monitor, deadline, status \\ nil, down? \\ false)

  defp await_port_exit(_port, _monitor, _deadline, status, true) when is_integer(status),
    do: {:ok, status}

  defp await_port_exit(port, monitor, deadline, status, down?) do
    receive do
      {^port, {:exit_status, next_status}} ->
        await_port_exit(port, monitor, deadline, next_status, down?)

      {:DOWN, ^monitor, :port, ^port, _reason} ->
        await_port_exit(port, monitor, deadline, status, true)

      {^port, {:data, _data}} ->
        await_port_exit(port, monitor, deadline, status, down?)
    after
      remaining(deadline) -> :timeout
    end
  end

  defp read_if_present(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      {:error, _reason} -> ""
    end
  end

  defp deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
