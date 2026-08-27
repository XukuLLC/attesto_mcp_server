defmodule AttestoMCP.Server.P2ASchemaResourceTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server
  alias AttestoMCP.Server.Schema

  @modern "2026-07-28"
  @legacy "2025-11-25"

  defp modern(extra \\ %{}) do
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

  test "schema validation handles Unicode lengths, nested booleans and local refs" do
    schema = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$defs" => %{"tag" => %{"type" => "string", "minLength" => 2}},
      "type" => "object",
      "properties" => %{
        "name" => %{"$ref" => "#/$defs/tag"},
        "items" => %{"type" => "array", "items" => true}
      },
      "required" => ["name"]
    }

    assert :ok = Schema.validate(%{"name" => "éé", "items" => [1, false]}, schema)
    assert {:error, _} = Schema.validate(%{"name" => "é"}, schema)
    assert :ok = Schema.validate_schema(%{"items" => %{"items" => false}})
    assert {:error, :schema_false} = Schema.validate([1], %{"items" => false})

    composed = %{
      "allOf" => [%{"properties" => %{"id" => %{"type" => "integer"}}}],
      "unevaluatedProperties" => false
    }

    assert :ok = Schema.validate(%{"id" => 1}, composed)
    assert {:error, _} = Schema.validate(%{"id" => 1, "extra" => true}, composed)
  end

  test "schema registration rejects remote refs and unsafe regexes" do
    assert {:error, :remote_ref_disabled} =
             Schema.validate_schema(%{"$ref" => "https://example.invalid/schema"})

    assert :ok =
             Schema.validate_schema(%{"$schema" => "http://json-schema.org/draft-07/schema#"})

    assert {:error, :invalid_pattern} =
             Schema.validate_schema(%{"pattern" => String.duplicate("a", 257)})

    {:ok, registry} = Server.Registry.start_link([])

    assert {:error, {:invalid_schema, :remote_ref_disabled}} =
             Server.Registry.register(registry, :tool, "remote", %{
               input_schema: %{"$ref" => "https://example.invalid/schema"}
             })

    assert {:error, {:invalid_definition, :uri}} =
             Server.Registry.register(registry, :resource, "http://localhost/private", %{})
  end

  test "resource URI templates dispatch captured variables and reject traversal" do
    {:ok, server} = Server.start_link([])

    assert :ok =
             Server.register_resource_template(server, "urn:item/{id}", %{
               handler: fn %{params: %{"id" => id}, uri: uri}, _ ->
                 {:ok, %{"contents" => [%{"uri" => uri, "text" => id}]}}
               end
             })

    request = %{
      kind: :request,
      id: 1,
      method: "resources/read",
      params: %{"uri" => "urn:item/alpha"}
    }

    assert {1, %{"result" => %{"contents" => [%{"text" => "alpha"}]}}} =
             Server.dispatch(server, request, %{principal: "p"}, version: @legacy)

    unsafe = %{request | id: 2, params: %{"uri" => "urn:item/../secret"}}

    assert {2, %{"error" => %{"code" => -32602}}} =
             Server.dispatch(server, unsafe, %{principal: "p"}, version: @legacy)
  end

  test "prompt required arguments and completion invoke only the selected handler" do
    {:ok, server} = Server.start_link([])
    parent = self()

    assert :ok =
             Server.register_prompt(server, "welcome", %{
               arguments: [%{"name" => "name", "required" => true}],
               handler: fn %{arguments: args}, _ ->
                 {:ok,
                  [%{"role" => "user", "content" => %{"type" => "text", "text" => args["name"]}}]}
               end
             })

    assert :ok =
             Server.register_completion(server, "welcome-name", %{
               ref: %{"type" => "ref/prompt", "name" => "welcome"},
               handler: fn %{value: value}, _ ->
                 send(parent, :selected_completion)
                 {:ok, [value <> "-one", value <> "-two"]}
               end
             })

    assert :ok =
             Server.register_completion(server, "other", %{
               ref: %{"type" => "ref/prompt", "name" => "other"},
               handler: fn _, _ ->
                 send(parent, :wrong_completion)
                 {:ok, ["wrong"]}
               end
             })

    missing = %{
      kind: :request,
      id: 1,
      method: "prompts/get",
      params: modern(%{"name" => "welcome", "arguments" => %{}})
    }

    assert {1, %{"error" => %{"code" => -32602}}} =
             Server.dispatch(server, missing, %{principal: "p"}, version: @modern)

    prompt = put_in(missing.params["arguments"], %{"name" => "Ada"})

    assert {1, %{"result" => %{"messages" => [%{"role" => "user"}]}}} =
             Server.dispatch(server, prompt, %{principal: "p"}, version: @modern)

    completion = %{
      kind: :request,
      id: 2,
      method: "completion/complete",
      params:
        modern(%{
          "ref" => %{"type" => "ref/prompt", "name" => "welcome"},
          "argument" => %{"name" => "name", "value" => "a"}
        })
    }

    assert {2, %{"result" => %{"completion" => %{"values" => ["a-one", "a-two"]}}}} =
             Server.dispatch(server, completion, %{principal: "p"}, version: @modern)

    assert_received :selected_completion
    refute_received :wrong_completion
  end

  @tag :t39
  test "pagination cursor binds tenant, scope, revision and page size" do
    {:ok, server} = Server.start_link(page_size: 100, cursor_secret: "p2a-secret")

    for index <- 1..101 do
      assert :ok =
               Server.register_tool(server, "tool_#{index}", %{
                 handler: fn _, _ -> {:ok, "ok"} end
               })
    end

    request = %{kind: :request, id: 1, method: "tools/list", params: modern()}

    assert {1, first = %{"result" => %{"nextCursor" => cursor}}} =
             Server.dispatch(server, request, %{principal: "alice", tenant: "one", scopes: []},
               version: @modern
             )

    assert first["result"]["cacheScope"] == "private"

    prefix = binary_part(cursor, 0, byte_size(cursor) - 1)
    last = :binary.last(cursor)
    tampered = prefix <> <<Bitwise.bxor(last, 1)>>

    assert {1, %{"error" => %{"code" => -32602}}} =
             Server.dispatch(
               server,
               put_in(request.params["cursor"], tampered),
               %{principal: "alice", tenant: "one", scopes: []},
               version: @modern
             )

    next = put_in(request.params["cursor"], cursor)

    assert {1, %{"error" => %{"code" => -32602}}} =
             Server.dispatch(server, next, %{principal: "alice", tenant: "two", scopes: []},
               version: @modern
             )

    assert {1, %{"error" => %{"code" => -32602}}} =
             Server.dispatch(
               server,
               next,
               %{principal: "alice", tenant: "one", scopes: ["other"]},
               version: @modern
             )

    assert {1, %{"result" => %{"tools" => tools}}} =
             Server.dispatch(server, next, %{principal: "alice", tenant: "one", scopes: []},
               version: @modern
             )

    assert length(tools) == 1

    assert :ok =
             Server.register_tool(server, "new_revision", %{handler: fn _, _ -> {:ok, "ok"} end})

    assert {1, %{"error" => %{"code" => -32602}}} =
             Server.dispatch(server, next, %{principal: "alice", tenant: "one", scopes: []},
               version: @modern
             )
  end
end
