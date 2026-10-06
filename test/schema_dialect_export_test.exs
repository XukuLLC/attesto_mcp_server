defmodule AttestoMCP.Server.SchemaDialectExportTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server
  alias AttestoMCP.Server.Test, as: ServerTest

  @dialect_2020_12 "https://json-schema.org/draft/2020-12/schema"
  @draft_07 "http://json-schema.org/draft-07/schema#"

  defp start_server(opts) do
    start_supervised!({Server, opts}, id: make_ref())
  end

  defp tools(server, opts \\ []) do
    server
    |> ServerTest.list_tools(opts)
    |> get_in(["result", "tools"])
    |> Map.new(&{&1["name"], &1})
  end

  defp register(server, name, definition) do
    assert :ok =
             Server.register_tool(
               server,
               name,
               Map.put_new(definition, :handler, fn args, _ctx -> {:ok, args} end)
             )
  end

  test "export is off by default and leaves host-authored schemas unchanged" do
    server = start_server([])
    schema = %{"type" => "object", "properties" => %{"id" => %{"type" => "string"}}}
    register(server, "plain", %{input_schema: schema, output_schema: %{"type" => "object"}})

    assert %{"inputSchema" => ^schema, "outputSchema" => %{"type" => "object"}} =
             tools(server)["plain"]
  end

  test "absent root dialects are exported as JSON Schema 2020-12 and explicit ones are kept" do
    server = start_server(export_schema_dialect: true)

    register(server, "absent", %{
      input_schema: %{"type" => "object", "properties" => %{"id" => %{"type" => "string"}}},
      output_schema: %{"type" => "object"}
    })

    draft_07 = %{
      "$schema" => @draft_07,
      "type" => "object",
      "properties" => %{"id" => %{"type" => "string"}},
      "definitions" => %{"id" => %{"type" => "string"}}
    }

    register(server, "draft-07", %{input_schema: draft_07, output_schema: draft_07})

    explicit_2020 = %{"$schema" => @dialect_2020_12, "type" => "object"}
    register(server, "explicit", %{input_schema: explicit_2020})

    catalog = tools(server)

    assert catalog["absent"]["inputSchema"] == %{
             "$schema" => @dialect_2020_12,
             "type" => "object",
             "properties" => %{"id" => %{"type" => "string"}}
           }

    assert catalog["absent"]["outputSchema"] == %{
             "$schema" => @dialect_2020_12,
             "type" => "object"
           }

    assert catalog["draft-07"]["inputSchema"] == draft_07
    assert catalog["draft-07"]["outputSchema"] == draft_07
    assert catalog["explicit"]["inputSchema"] == explicit_2020
    refute Map.has_key?(catalog["explicit"], "outputSchema")
  end

  test "only schema roots change; nested resources, references, and data stay exact" do
    server = start_server(export_schema_dialect: true)

    input = %{
      "$id" => "https://example.com/schemas/order",
      "type" => "object",
      "properties" => %{
        "item" => %{"$ref" => "#/$defs/item"},
        "nested" => %{
          "$id" => "https://example.com/schemas/nested",
          "type" => "object",
          "properties" => %{"code" => %{"type" => "string"}}
        },
        "mode" => %{"const" => %{"type" => "object", "properties" => %{}}},
        "options" => %{
          "type" => "object",
          "default" => %{"type" => "object"},
          "examples" => [%{"type" => "object", "properties" => %{}}]
        }
      },
      "$defs" => %{"item" => %{"type" => "object", "properties" => %{}}}
    }

    register(server, "nested", %{input_schema: input, output_schema: false})

    exported = tools(server)["nested"]

    assert exported["inputSchema"] == Map.put(input, "$schema", @dialect_2020_12)
    assert exported["outputSchema"] == false
  end

  test "export does not change registered definitions or validation outcomes" do
    server = start_server(export_schema_dialect: true)

    input = %{
      "type" => "object",
      "properties" => %{"email" => %{"type" => "string", "format" => "email"}},
      "required" => ["email"],
      "additionalProperties" => false
    }

    register(server, "contact", %{input_schema: input})
    before = Server.snapshot(server)

    assert tools(server)["contact"]["inputSchema"]["$schema"] == @dialect_2020_12
    assert Server.snapshot(server) == before
    assert before.tool["contact"].input_schema == input

    assert %{"result" => %{"structuredContent" => %{"email" => "a@example.com"}}} =
             ServerTest.call_tool(server, "contact", %{"email" => "a@example.com"})

    for invalid <- [%{}, %{"email" => "not-an-email"}, %{"email" => "a@example.com", "x" => 1}] do
      assert %{"error" => %{"data" => %{"reason" => "tool_arguments_invalid"}}} =
               ServerTest.call_tool(server, "contact", invalid)
    end
  end

  test "unsupported dialects are still rejected through registration" do
    server = start_server(export_schema_dialect: true)

    assert {:error, {:invalid_schema, _reason}} =
             Server.register_tool(server, "draft-04", %{
               input_schema: %{
                 "$schema" => "http://json-schema.org/draft-04/schema#",
                 "type" => "object"
               },
               handler: fn _args, _ctx -> {:ok, "unreachable"} end
             })
  end

  test "export follows the revisions that define a root dialect member" do
    server = start_server(export_schema_dialect: true)
    register(server, "versions", %{input_schema: %{"type" => "object"}})

    assert tools(server, protocol_version: "2025-11-25")["versions"]["inputSchema"] == %{
             "$schema" => @dialect_2020_12,
             "type" => "object"
           }

    assert tools(server, protocol_version: "2025-06-18")["versions"]["inputSchema"] == %{
             "type" => "object"
           }
  end

  test "the enlarged catalog is checked against the output budget" do
    description = String.duplicate("d", 1_200)
    definition = %{description: description, handler: fn _args, _ctx -> {:ok, "ok"} end}

    measure = start_server(max_json_bytes: 8_192)
    assert :ok = Server.register_tool(measure, "sized", definition)

    size =
      measure |> ServerTest.list_tools() |> Map.fetch!("result") |> Jason.encode!() |> byte_size()

    fits = start_server(max_json_bytes: size)
    assert :ok = Server.register_tool(fits, "sized", definition)
    assert %{"result" => %{"tools" => [_tool]}} = ServerTest.list_tools(fits)

    enlarged = start_server(max_json_bytes: size, export_schema_dialect: true)
    assert :ok = Server.register_tool(enlarged, "sized", definition)

    assert %{"error" => %{"code" => -32603}} = ServerTest.list_tools(enlarged)
  end

  test "pagination fingerprints include the exported representation" do
    server = start_server(export_schema_dialect: true, page_size: 1)
    register(server, "a-tool", %{})
    register(server, "b-tool", %{})

    first = ServerTest.list_tools(server)
    cursor = first["result"]["nextCursor"]
    assert is_binary(cursor)

    assert %{"result" => %{"tools" => [%{"name" => "b-tool", "inputSchema" => schema}]}} =
             ServerTest.list_tools(server, cursor: cursor)

    assert schema["$schema"] == @dialect_2020_12
  end

  test "a cursor issued for one exported representation is rejected for another" do
    secret = :crypto.strong_rand_bytes(32)
    plain = start_server(page_size: 1, cursor_secret: secret)
    peer = start_server(page_size: 1, cursor_secret: secret)
    exported = start_server(page_size: 1, cursor_secret: secret, export_schema_dialect: true)

    for server <- [plain, peer, exported] do
      register(server, "a-tool", %{})
      register(server, "b-tool", %{})
    end

    plain_cursor = ServerTest.list_tools(plain)["result"]["nextCursor"]
    exported_cursor = ServerTest.list_tools(exported)["result"]["nextCursor"]

    assert %{"result" => %{"tools" => [%{"name" => "b-tool"}]}} =
             ServerTest.list_tools(peer, cursor: plain_cursor)

    assert %{"error" => %{"data" => %{"reason" => "invalid_cursor"}}} =
             ServerTest.list_tools(exported, cursor: plain_cursor)

    assert %{"error" => %{"data" => %{"reason" => "invalid_cursor"}}} =
             ServerTest.list_tools(plain, cursor: exported_cursor)
  end

  test "the option must be boolean" do
    Process.flag(:trap_exit, true)

    assert {:error, {%ArgumentError{message: message}, _stack}} =
             Server.start_link(export_schema_dialect: "yes")

    assert message =~ "export_schema_dialect"
  end
end
