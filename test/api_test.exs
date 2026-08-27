defmodule AttestoMCP.Server.APITest do
  use ExUnit.Case, async: false

  doctest AttestoMCP.Server.API

  alias AttestoMCP.Server.API

  @tag :t03
  test "stable facade registers, dispatches and exposes a snapshot" do
    {:ok, server} = API.start_link([])

    assert :ok =
             API.register_tool(server, "api_echo", %{
               input_schema: %{"type" => "object"},
               handler: fn arguments, _context -> {:ok, arguments} end
             })

    assert %{tool: tools} = API.snapshot(server)
    assert Enum.any?(tools, fn {_id, definition} -> definition.name == "api_echo" end)

    request = %{
      kind: :request,
      id: 1,
      method: "tools/call",
      params: %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        },
        "name" => "api_echo",
        "arguments" => %{"value" => 1}
      }
    }

    assert {1, %{"result" => %{"resultType" => "complete"}}} =
             API.dispatch(server, request, %{principal: "api"}, version: "2026-07-28")
  end

  test "stable facade exposes all non-task registration and lifecycle calls" do
    {:ok, server} = API.start_link([])

    assert :ok = API.register_resource(server, "urn:api", %{handler: fn _, _ -> {:ok, []} end})

    assert :ok =
             API.register_resource_template(server, "urn:api/{id}", %{
               handler: fn _, _ -> {:ok, []} end
             })

    assert :ok = API.register_prompt(server, "api_prompt", %{handler: fn _, _ -> {:ok, []} end})

    assert :ok =
             API.register_completion(server, "api_completion", %{
               ref: %{"type" => "ref/prompt", "name" => "api_prompt"},
               handler: fn _, _ -> {:ok, []} end
             })

    assert :ok = API.register(server, :tool, "api_custom", %{handler: fn _, _ -> {:ok, "ok"} end})

    {:ok, session} = API.new_session(server, "principal", "tenant")
    assert {:ok, _} = API.get_session(server, session.id, "principal", "tenant")
    assert :ok = API.delete_session(server, session.id)
    assert {:error, :not_found} = API.get_session(server, session.id, "principal", "tenant")

    assert :ok = API.publish(server, %{"type" => "toolsListChanged"})
    assert :ok = API.close_subscription(server, "missing")
    assert :ok = API.cancel_subscription(server, "missing")
    assert :ok = API.cancel_request(server, "principal", "missing")
  end
end
