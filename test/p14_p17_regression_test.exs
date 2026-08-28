defmodule AttestoMCP.Server.P14P17RegressionTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server
  alias AttestoMCP.Server.Registry

  import ExUnit.CaptureIO

  @modern "2026-07-28"

  test "registration canonicalizes atom/string fields and rejects conflicting aliases" do
    {:ok, server} = Server.start_link([])

    assert :ok =
             Server.register_tool(server, "atom-schema", %{
               "description" => "Atom schema",
               inputSchema: %{type: "object", properties: %{value: %{type: "string"}}},
               handler: fn args, _ -> {:ok, args} end
             })

    assert {:error, {:invalid_definition, {:conflicting_key, _}}} =
             Server.register_tool(server, "conflict", %{
               "inputSchema" => %{"type" => "object"},
               input_schema: %{"type" => "object"}
             })

    assert {:error, {:invalid_definition, _}} =
             Server.register_tool(server, "nested-conflict", %{
               "inputSchema" => %{
                 "type" => "object",
                 "properties" => %{"x" => %{"type" => "string"}},
                 properties: %{}
               },
               handler: fn _, _ -> {:ok, %{}} end
             })

    assert {:error, {:invalid_schema, :root_type}} =
             Server.register_tool(server, "array-root", %{
               input_schema: %{"type" => "array"}
             })

    request = %{
      kind: :request,
      id: 1,
      method: "tools/list",
      params: %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @modern,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    assert {1, %{"result" => %{"tools" => [%{"inputSchema" => schema}]}}} =
             Server.dispatch(server, request, %{principal: "p"}, version: @modern)

    assert schema["type"] == "object"
    assert schema["properties"]["value"]["type"] == "string"
  end

  test "preserves validated standard metadata and rejects malformed icons" do
    {:ok, server} = Server.start_link([])

    metadata = %{
      title: "Echo title",
      icons: [%{src: "https://example.test/icon.png", sizes: ["32x32"], theme: "light"}],
      _meta: %{"vendor" => %{"enabled" => true}}
    }

    assert :ok =
             Server.register_tool(
               server,
               "metadata-tool",
               Map.merge(metadata, %{handler: fn _, _ -> {:ok, "ok"} end})
             )

    request = %{
      kind: :request,
      id: 94,
      method: "tools/list",
      params: %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @modern,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    assert {94, %{"result" => %{"tools" => [tool | _]}}} =
             Server.dispatch(server, request, %{principal: "metadata"}, version: @modern)

    assert tool["title"] == "Echo title"

    assert tool["icons"] == [
             %{"src" => "https://example.test/icon.png", "sizes" => ["32x32"], "theme" => "light"}
           ]

    assert tool["_meta"] == %{"vendor" => %{"enabled" => true}}

    assert {:error, {:invalid_definition, :icons}} =
             Server.register_tool(server, "bad-metadata", %{
               icons: [%{src: "", theme: "invalid"}],
               handler: fn _, _ -> {:ok, "bad"} end
             })
  end

  test "stdio callback failure is contained and reader errors terminate promptly" do
    {:ok, server} = Server.start_link([])
    parent = self()

    input = fn ->
      send(parent, :reader_called)
      {:error, :closed}
    end

    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert :ok = Server.Stdio.run(server, input: input, principal: "reader")
      end)

    assert_receive :reader_called
    assert stderr =~ "stdio input error"
  end

  test "registry rejects a non-map schema root and accepts bounded string-key JSON schema" do
    {:ok, registry} = Registry.start_link([])

    assert {:error, {:invalid_schema, :root_type}} =
             Registry.register(registry, :tool, "bad", %{input_schema: true})

    assert :ok =
             Registry.register(registry, :tool, "good", %{
               input_schema: %{
                 "type" => "object",
                 "properties" => %{"x" => %{"type" => "integer"}}
               },
               handler: fn _, _ -> {:ok, "ok"} end
             })
  end

  test "live stdio pipe answers a near-limit frame before the writer closes" do
    executable = System.find_executable("elixir") || raise "elixir executable not found"
    script = Path.expand("../examples/stdio.exs", __DIR__)

    install_dir =
      Path.join(System.tmp_dir!(), "attesto-mcp-live-#{System.unique_integer([:positive])}")

    File.mkdir_p!(install_dir)

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :use_stdio,
        {:env, [{~c"MIX_INSTALL_DIR", String.to_charlist(install_dir)}]},
        {:args, [script]}
      ])

    on_exit(fn ->
      if Port.info(port), do: Port.close(port)
      File.rm_rf!(install_dir)
    end)

    request = %{
      "jsonrpc" => "2.0",
      "id" => 91,
      "method" => "server/discover",
      "params" => %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @modern,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        },
        "padding" => String.duplicate("x", 60_000)
      }
    }

    assert Port.command(port, Jason.encode!(request) <> "\n")

    line = receive_port_line(port, "")
    assert {:ok, response} = Jason.decode(line)
    assert response["id"] == 91
    assert response["result"]["resultType"] == "complete"
  end

  test "live stdio pipe recovers after malformed and over-limit lines" do
    executable = System.find_executable("elixir") || raise "elixir executable not found"
    script = Path.expand("../examples/stdio.exs", __DIR__)

    install_dir =
      Path.join(System.tmp_dir!(), "attesto-mcp-recovery-#{System.unique_integer([:positive])}")

    File.mkdir_p!(install_dir)

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :use_stdio,
        {:env, [{~c"MIX_INSTALL_DIR", String.to_charlist(install_dir)}]},
        {:args, [script]}
      ])

    on_exit(fn ->
      if Port.info(port), do: Port.close(port)
      File.rm_rf!(install_dir)
    end)

    valid_request = %{
      "jsonrpc" => "2.0",
      "id" => 95,
      "method" => "server/discover",
      "params" => %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @modern,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    input = [
      "not-json\n",
      String.duplicate("x", 64_001),
      "\n",
      Jason.encode!(valid_request),
      "\n"
    ]

    assert Port.command(port, IO.iodata_to_binary(input))

    [malformed_error, oversized_error, response] =
      port
      |> receive_port_lines(3, "")
      |> Enum.map(&Jason.decode!/1)

    assert malformed_error["id"] == nil
    assert malformed_error["error"]["code"] == -32700
    assert oversized_error["id"] == nil
    assert oversized_error["error"]["code"] == -32700
    assert oversized_error["error"]["data"]["reason"] == "message_too_large"
    assert response["id"] == 95
    assert response["result"]["resultType"] == "complete"
  end

  test "2025-06-18 initialize is accepted and echoed exactly" do
    {:ok, server} = Server.start_link([])

    request = %{
      kind: :request,
      id: 92,
      method: "initialize",
      params: %{
        "protocolVersion" => "2025-06-18",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "compat-client", "version" => "1"}
      }
    }

    assert {92, %{"result" => %{"protocolVersion" => "2025-06-18"}}} =
             Server.dispatch(server, request, %{principal: "compat"}, version: "2025-06-18")
  end

  test "stdio routes a latest-era initialize through modern method handling" do
    {:ok, server} = Server.start_link([])

    {:ok, source} =
      Agent.start_link(fn ->
        [
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 93,
            "method" => "initialize",
            "params" => %{
              "_meta" => %{
                "io.modelcontextprotocol/protocolVersion" => @modern,
                "io.modelcontextprotocol/clientCapabilities" => %{}
              }
            }
          }) <> "\n",
          :eof
        ]
      end)

    input = fn ->
      Agent.get_and_update(source, fn
        [next | rest] -> {next, rest}
        [] -> {:eof, []}
      end)
    end

    output =
      capture_io(fn ->
        assert :ok = Server.Stdio.run(server, input: input, principal: "modern-stdio")
      end)

    assert {:ok, response} =
             output |> String.split("\n") |> Enum.find(&(&1 != "")) |> Jason.decode()

    assert response["id"] == 93
    assert response["error"]["code"] == -32601
  end

  defp receive_port_line(port, buffer) do
    case String.split(buffer, "\n", parts: 2) do
      [line, _rest] when line != "" ->
        line

      _ ->
        receive do
          {^port, {:data, data}} -> receive_port_line(port, buffer <> data)
          {^port, {:exit_status, status}} -> flunk("stdio exited before response: #{status}")
        after
          30_000 -> flunk("stdio live pipe did not answer")
        end
    end
  end

  defp receive_port_lines(port, count, buffer) do
    if length(:binary.matches(buffer, "\n")) >= count do
      buffer
      |> String.split("\n", trim: true)
      |> Enum.take(count)
    else
      receive do
        {^port, {:data, data}} -> receive_port_lines(port, count, buffer <> data)
        {^port, {:exit_status, status}} -> flunk("stdio exited before responses: #{status}")
      after
        30_000 -> flunk("stdio live pipe did not answer")
      end
    end
  end
end
