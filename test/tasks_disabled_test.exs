defmodule AttestoMCP.Server.TasksDisabledTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server

  @modern "2026-07-28"
  @legacy "2025-11-25"

  test "modern and legacy task profiles remain unadvertised and unreachable" do
    {:ok, server} =
      Server.start_link(
        modern_tasks: true,
        legacy_tasks: true,
        capabilities: %{
          "extensions" => %{"io.modelcontextprotocol/tasks" => %{"advertised" => true}}
        }
      )

    modern_params = %{
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => @modern,
        "io.modelcontextprotocol/clientCapabilities" => %{}
      }
    }

    assert {1, %{"result" => discovery}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 1, method: "server/discover", params: modern_params},
               %{principal: "tasks"},
               version: @modern
             )

    refute get_in(discovery, ["capabilities", "extensions", "io.modelcontextprotocol/tasks"])

    assert {2, %{"error" => %{"code" => -32601}}} =
             Server.dispatch(
               server,
               %{
                 kind: :request,
                 id: 2,
                 method: "tasks/get",
                 params: Map.put(modern_params, "taskId", "guess")
               },
               %{principal: "tasks"},
               version: @modern
             )

    assert {3, %{"error" => %{"code" => -32601}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 3, method: "tasks/list", params: modern_params},
               %{principal: "tasks"},
               version: @modern
             )

    legacy_params = %{
      "protocolVersion" => @legacy,
      "capabilities" => %{"extensions" => %{"io.modelcontextprotocol/tasks" => %{}}},
      "clientInfo" => %{"name" => "tasks-test", "version" => "1.0"}
    }

    assert {4, %{"result" => %{"capabilities" => legacy_capabilities}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 4, method: "initialize", params: legacy_params},
               %{principal: "tasks"},
               version: @legacy
             )

    refute get_in(legacy_capabilities, ["extensions", "io.modelcontextprotocol/tasks"])

    assert {5, %{"error" => %{"code" => -32601}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 5, method: "tasks/get", params: %{"taskId" => "guess"}},
               %{principal: "tasks"},
               version: @legacy
             )

    assert {6, %{"error" => %{"code" => -32601}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 6, method: "tasks/result", params: %{"taskId" => "guess"}},
               %{principal: "tasks"},
               version: @legacy
             )

    assert :ok =
             Server.register_tool(server, "legacy_echo", %{
               input_schema: %{"type" => "object"},
               handler: fn arguments, _ -> {:ok, arguments} end
             })

    assert {7, %{"result" => legacy_result}} =
             Server.dispatch(
               server,
               %{
                 kind: :request,
                 id: 7,
                 method: "tools/call",
                 params: %{
                   "name" => "legacy_echo",
                   "arguments" => %{"value" => "normal"},
                   "task" => %{"ttl" => 1000}
                 }
               },
               %{principal: "tasks"},
               version: @legacy
             )

    refute Map.has_key?(legacy_result, "task")
  end

  test "a modern task opt-in has no effect while the profile is disabled" do
    {:ok, server} = Server.start_link(modern_tasks: true)

    assert :ok =
             Server.register_tool(server, "echo", %{
               input_schema: %{"type" => "object"},
               handler: fn arguments, _ -> {:ok, arguments} end
             })

    params = %{
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => @modern,
        "io.modelcontextprotocol/clientCapabilities" => %{}
      },
      "name" => "echo",
      "arguments" => %{"value" => "normal"},
      "task" => %{"ttl" => 1000}
    }

    assert {7, %{"result" => %{"resultType" => "complete"}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 7, method: "tools/call", params: params},
               %{principal: "tasks"},
               version: @modern
             )
  end

  test "the public task store boundary fails closed" do
    {:ok, tasks} = AttestoMCP.Server.Tasks.start_link([])

    assert {:error, :tasks_disabled} =
             AttestoMCP.Server.Tasks.create(tasks, @modern, "owner", %{})

    assert {:error, :tasks_disabled} = AttestoMCP.Server.Tasks.get(tasks, "task", "owner")
    assert {:error, :tasks_disabled} = AttestoMCP.Server.Tasks.update(tasks, "task", "owner", %{})
    assert {:error, :tasks_disabled} = AttestoMCP.Server.Tasks.cancel(tasks, "task", "owner")
  end
end
