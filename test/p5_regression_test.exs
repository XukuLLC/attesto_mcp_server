defmodule AttestoMCP.Server.P5RegressionTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server
  alias AttestoMCP.Server.{JSONRPC, Schema, Subscriptions}

  @modern "2026-07-28"
  @legacy "2025-11-25"

  defp request(id, method, params \\ %{}) do
    %{kind: :request, id: id, method: method, params: params}
  end

  defp modern_params(extra \\ %{}) do
    Map.merge(
      %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @modern,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      },
      extra
    )
  end

  test "a hard-killed tool task cannot kill its dispatch caller and permits recover" do
    {:ok, server} = Server.start_link(max_concurrency: 1)

    :ok =
      Server.register_tool(server, "kill", %{handler: fn _, _ -> Process.exit(self(), :kill) end})

    :ok = Server.register_tool(server, "ok", %{handler: fn _, _ -> {:ok, "alive"} end})

    result =
      Server.dispatch(
        server,
        request(1, "tools/call", modern_params(%{"name" => "kill", "arguments" => %{}})),
        %{principal: "p"},
        version: @modern
      )

    assert {1, %{"error" => %{"code" => -32603}}} = result
    assert Process.alive?(self())

    assert eventually(fn -> Server.stats(server).active == 0 end)

    assert {2, %{"result" => %{"resultType" => "complete"}}} =
             Server.dispatch(
               server,
               request(2, "tools/call", modern_params(%{"name" => "ok", "arguments" => %{}})),
               %{principal: "p"},
               version: @modern
             )
  end

  test "hard-killed prompt handlers are correlated safely" do
    {:ok, server} = Server.start_link(max_concurrency: 1)

    :ok =
      Server.register_prompt(server, "kill", %{
        handler: fn _, _ -> Process.exit(self(), :kill) end
      })

    assert {7, %{"error" => %{"code" => -32603}}} =
             Server.dispatch(
               server,
               request(7, "prompts/get", modern_params(%{"name" => "kill", "arguments" => %{}})),
               %{principal: "p"},
               version: @modern
             )
  end

  test "legacy results and catalogs never contain modern discriminators" do
    {:ok, server} = Server.start_link([])

    :ok = Server.register_tool(server, "scalar", %{handler: fn _, _ -> {:ok, [1, true, nil]} end})
    :ok = Server.register_resource(server, "urn:p5", %{handler: fn _, _ -> {:ok, []} end})
    :ok = Server.register_prompt(server, "p5", %{handler: fn _, _ -> {:ok, []} end})

    assert {1, %{"result" => tools}} =
             Server.dispatch(server, request(1, "tools/list"), %{principal: "p"},
               version: @legacy
             )

    refute Map.has_key?(tools, "resultType")

    assert {2, %{"result" => result}} =
             Server.dispatch(
               server,
               request(2, "tools/call", %{"name" => "scalar", "arguments" => %{}}),
               %{principal: "p"},
               version: @legacy
             )

    refute Map.has_key?(result, "resultType")
    assert is_map(result["structuredContent"])

    assert {3, %{"result" => %{"resultType" => "complete"}}} =
             Server.dispatch(
               server,
               request(3, "resources/list", modern_params()),
               %{principal: "p"},
               version: @modern
             )
  end

  test "wire annotations and recursive registration values are bounded" do
    {:ok, server} = Server.start_link([])

    assert :ok =
             Server.register_tool(server, "annotated", %{
               annotations: %{
                 "audience" => ["user"],
                 "priority" => 0.5,
                 "nested" => %{"ok" => true}
               }
             })

    assert {:error, {:invalid_definition, :annotations}} =
             Server.register_tool(server, "pid", %{annotations: %{"bad" => self()}})

    assert :ok = Server.register_resource_template(server, "urn:item/{id*}", %{})
  end

  test "content annotations are accepted on every content variant" do
    {:ok, server} = Server.start_link([])

    content = [
      %{"type" => "text", "text" => "hello", "annotations" => %{"audience" => ["user"]}},
      %{
        "type" => "image",
        "data" => "aGk=",
        "mimeType" => "image/png",
        "annotations" => %{"priority" => 0.2}
      },
      %{
        "type" => "audio",
        "data" => "aGk=",
        "mimeType" => "audio/wav",
        "annotations" => %{"lastModified" => "2026-08-25"}
      },
      %{
        "type" => "resource_link",
        "uri" => "urn:item",
        "name" => "item",
        "annotations" => %{"x" => %{"ok" => true}}
      },
      %{
        "type" => "resource",
        "resource" => %{
          "uri" => "urn:item",
          "text" => "body",
          "annotations" => %{"audience" => ["assistant"]}
        }
      }
    ]

    :ok =
      Server.register_tool(server, "content", %{
        handler: fn _, _ -> {:ok, %{"content" => content}} end
      })

    assert {1, %{"result" => %{"resultType" => "complete", "content" => ^content}}} =
             Server.dispatch(
               server,
               request(
                 1,
                 "tools/call",
                 modern_params(%{"name" => "content", "arguments" => %{}})
               ),
               %{principal: "p"},
               version: @modern
             )
  end

  test "schema const null and IP formats distinguish exact values" do
    assert Schema.validate(nil, %{"const" => nil}) == :ok
    assert {:error, :const_mismatch} = Schema.validate("not-null", %{"const" => nil})
    assert Schema.validate("127.0.0.1", %{"format" => "ipv4"}) == :ok
    assert {:error, :format} = Schema.validate("::1", %{"format" => "ipv4"})
    assert Schema.validate("::1", %{"format" => "ipv6"}) == :ok
    assert {:error, :format} = Schema.validate("127.0.0.1", %{"format" => "ipv6"})
    assert Schema.validate(-3, %{"minimum" => -4, "maximum" => -1}) == :ok
  end

  test "invalid outbound terms become a safe correlated protocol error" do
    wire = JSONRPC.encode(%{"jsonrpc" => "2.0", "id" => 42, "result" => self()})
    assert %{"id" => 42, "error" => %{"code" => -32603}} = Jason.decode!(wire)
  end

  test "subscription overflow sends one bounded notification per saturated interval" do
    {:ok, subscriptions} = Subscriptions.start_link(max_queue: 1)
    sink = spawn(fn -> Process.sleep(2_000) end)
    on_exit(fn -> if Process.alive?(sink), do: Process.exit(sink, :kill) end)

    assert {:ok, "wire-id"} =
             Subscriptions.open(
               subscriptions,
               "p",
               "t",
               "wire-id",
               %{"toolsListChanged" => true},
               sink,
               make_ref(),
               nil
             )

    Enum.each(1..100, fn _ ->
      Subscriptions.publish_sync(subscriptions, %{"type" => "toolsListChanged"})
    end)

    assert Process.info(sink, :message_queue_len) |> elem(1) <= 3
    assert Subscriptions.stats(subscriptions).queued == 1
  end

  test "request state TTL is bounded to its replay-retention policy" do
    assert {:error, {%ArgumentError{}, _}} = GenServer.start(Server, request_state_ttl: 120_001)
  end

  test "handler context includes the negotiated protocol version" do
    {:ok, server} = Server.start_link([])
    parent = self()

    :ok =
      Server.register_tool(server, "version", %{
        handler: fn _, context ->
          send(parent, {:version, context.protocol_version})
          {:ok, "ok"}
        end
      })

    assert {1, _} =
             Server.dispatch(
               server,
               request(1, "tools/call", %{"name" => "version", "arguments" => %{}}),
               %{principal: "p"},
               version: @legacy
             )

    assert_receive {:version, @legacy}
  end

  defp eventually(fun, attempts \\ 20)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(5)
          eventually(fun, attempts - 1)
        )
  end
end
