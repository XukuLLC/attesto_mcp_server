defmodule AttestoMCP.Server.P6StdioColdStartTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server.JSONRPC

  @modern "2026-07-28"

  test "cold Mix.install keeps stdout protocol-only with an isolated install directory" do
    root = File.cwd!()

    install_dir =
      Path.join(System.tmp_dir!(), "attesto-mcp-p6-#{System.unique_integer([:positive])}")

    output_path = Path.join(install_dir, "stdout")
    error_path = Path.join(install_dir, "stderr")
    File.mkdir_p!(install_dir)

    on_exit(fn -> File.rm_rf(install_dir) end)

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

    executable = System.find_executable("elixir") || raise "elixir executable not found"

    command =
      ~s(printf '%s' "$ATTESTO_P6_INPUT" | exec "$ATTESTO_P6_ELIXIR" "$ATTESTO_P6_SCRIPT" >"$ATTESTO_P6_STDOUT" 2>"$ATTESTO_P6_STDERR")

    {_, status} =
      System.cmd("/bin/sh", ["-c", command],
        cd: root,
        env: [
          {"MIX_INSTALL_DIR", install_dir},
          {"ATTESTO_P6_INPUT", input},
          {"ATTESTO_P6_ELIXIR", executable},
          {"ATTESTO_P6_SCRIPT", Path.join(root, "examples/stdio.exs")},
          {"ATTESTO_P6_STDOUT", output_path},
          {"ATTESTO_P6_STDERR", error_path}
        ]
      )

    assert status == 0, File.read!(error_path)

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
  end
end
