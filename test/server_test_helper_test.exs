defmodule AttestoMCP.Server.TestHelperTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server
  alias AttestoMCP.Server.{Content, Result}
  alias AttestoMCP.Server.Test, as: ServerTest

  setup do
    %{server: start_supervised!({Server, []})}
  end

  test "call_tool exercises scopes, authorize, input validation, handler, and wire output", %{
    server: server
  } do
    parent = self()
    principal = %{id: "user-7"}

    assert :ok =
             Server.register_tool(server, "get_item", %{
               input_schema: %{
                 "type" => "object",
                 "properties" => %{"id" => %{"type" => "string"}},
                 "required" => ["id"],
                 "additionalProperties" => false
               },
               output_schema: %{
                 "type" => "object",
                 "properties" => %{"id" => %{"type" => "string"}},
                 "required" => ["id"],
                 "additionalProperties" => false
               },
               required_scopes: ["items.read"],
               authorize: fn context ->
                 send(parent, {:authorized, context})

                 context.principal == principal and
                   context.host_context == %{account_id: "acct-1"}
               end,
               handler: fn arguments, context ->
                 send(parent, {:handled, arguments, context})

                 {:ok,
                  Result.tool(Content.text("item #{arguments["id"]}"),
                    structured_content: %{"id" => arguments["id"]}
                  )}
               end
             })

    response =
      ServerTest.call_tool(server, "get_item", %{id: "item-7"},
        request_id: "call-1",
        principal: principal,
        scopes: ["items.read"],
        host_context: %{account_id: "acct-1"}
      )

    assert %{
             "jsonrpc" => "2.0",
             "id" => "call-1",
             "result" => %{
               "resultType" => "complete",
               "structuredContent" => %{"id" => "item-7"},
               "content" => [%{"type" => "text", "text" => "item item-7"}]
             }
           } = response

    assert_receive {:authorized,
                    %{
                      principal: ^principal,
                      scopes: ["items.read"],
                      host_context: %{account_id: "acct-1"}
                    }}

    assert_receive {:handled, %{"id" => "item-7"}, %{principal: ^principal}}
    refute_receive {:authorized, _context}
    refute_receive {:handled, _arguments, _context}
  end

  test "scope and authorize denials are neutral and do not invoke the handler", %{server: server} do
    parent = self()

    assert :ok =
             Server.register_tool(server, "restricted", %{
               required_scopes: ["items.read"],
               authorize: fn context ->
                 send(parent, {:authorize_attempt, context.principal})
                 context.principal == "allowed"
               end,
               handler: fn _arguments, _context ->
                 send(parent, :restricted_handler)
                 {:ok, "unreachable"}
               end
             })

    assert %{"error" => %{"code" => -32602}} =
             ServerTest.call_tool(server, "restricted", %{}, principal: "allowed", scopes: [])

    refute_receive {:authorize_attempt, _principal}
    refute_receive :restricted_handler

    assert %{"error" => %{"code" => -32602}} =
             ServerTest.call_tool(server, "restricted", %{},
               principal: "denied",
               scopes: ["items.read"]
             )

    assert_receive {:authorize_attempt, "denied"}
    refute_receive :restricted_handler
  end

  test "input and output schemas use the production failure results", %{server: server} do
    parent = self()

    assert :ok =
             Server.register_tool(server, "typed", %{
               input_schema: %{
                 "type" => "object",
                 "properties" => %{"id" => %{"type" => "string"}},
                 "required" => ["id"]
               },
               output_schema: %{
                 "type" => "object",
                 "properties" => %{"id" => %{"type" => "string"}},
                 "required" => ["id"]
               },
               handler: fn _arguments, _context ->
                 send(parent, :typed_handler)

                 {:ok,
                  Result.tool(Content.text("bad output"),
                    structured_content: %{"id" => 7}
                  )}
               end
             })

    assert %{
             "error" => %{
               "code" => -32602,
               "data" => %{"reason" => "tool_arguments_invalid"}
             }
           } = ServerTest.call_tool(server, "typed", %{})

    refute_receive :typed_handler

    assert %{
             "result" => %{
               "resultType" => "complete",
               "isError" => true,
               "content" => [
                 %{"type" => "text", "text" => "tool output failed outputSchema"}
               ]
             }
           } = ServerTest.call_tool(server, "typed", %{"id" => "item-7"})

    assert_receive :typed_handler
  end

  test "rejects malformed helper setup", %{server: server} do
    assert_raise ArgumentError, fn ->
      ServerTest.call_tool(server, "tool", %{}, scopes: [], scopes: [])
    end

    assert_raise ArgumentError, fn ->
      ServerTest.call_tool(server, "tool", %{}, unknown: true)
    end

    assert_raise ArgumentError, fn ->
      ServerTest.call_tool(server, "tool", %{}, scopes: [:not_a_scope])
    end

    assert_raise ArgumentError, fn ->
      ServerTest.call_tool(server, "tool", %{"value" => self()})
    end
  end
end
