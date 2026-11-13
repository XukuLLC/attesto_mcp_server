defmodule AttestoMCP.Server.HardeningTextTest do
  use ExUnit.Case, async: true

  alias AttestoMCP.Server
  alias AttestoMCP.Server.{Options, Registry, Result, Text}
  alias AttestoMCP.Server.Test, as: Client

  @definitions [
    tool: "tool",
    resource: "urn:resource",
    template: "urn:resource:{id}",
    prompt: "prompt"
  ]

  test "all static descriptions and titles share optional, UTF-8 and byte-limit rules" do
    for {type, identity} <- @definitions,
        {field, max} <- [description: 4_096, title: 1_024] do
      {:ok, registry} = Registry.start_link()

      for accepted <- [nil, "", " ", String.duplicate("a", max)] do
        assert {:ok, _, _} =
                 Registry.replace_all(registry, [{type, identity, %{field => accepted}}])
      end

      for rejected <- [
            false,
            1,
            <<255>>,
            String.duplicate("a", max + 1),
            String.duplicate("é", div(max, 2) + 1)
          ] do
        assert {:error, {:invalid_definition, ^field}} =
                 Registry.replace_all(registry, [{type, identity, %{field => rejected}}])
      end

      GenServer.stop(registry)
    end
  end

  test "resource aliases retain separate wire URIs and invalid URIs return errors" do
    registry = start_supervised!({Registry, []})
    assert :ok = Registry.register(registry, :resource, "host-alias", uri: "urn:resource")

    for uri <- [
          "javascript:bad",
          "http://localhost/",
          "urn:bad\n",
          "urn:bad\\path",
          "https://user@example.test/"
        ] do
      assert {:error, {:invalid_definition, :uri}} =
               Registry.register(registry, :resource, "bad", uri: uri)
    end

    assert {:error, {:invalid_definition, _}} =
             Registry.register(registry, :resource, <<255>>, uri: "urn:valid")

    assert Process.alive?(registry)
  end

  test "server identity and instructions use the shared text validator at startup" do
    for {field, max} <- [server_name: 1_024, server_version: 1_024, instructions: 65_536] do
      assert Options.normalize([{field, String.duplicate("a", max)}])[field]

      for bad <- [<<255>>, false, String.duplicate("a", max + 1)] do
        assert_raise ArgumentError, fn -> Options.normalize([{field, bad}]) end
      end
    end

    assert Options.normalize(instructions: "")[:instructions] == ""
    assert_raise ArgumentError, fn -> Options.normalize(server_name: "") end
    assert_raise ArgumentError, fn -> Options.normalize(display_text_policy: :strip) end
    assert_raise ArgumentError, fn -> Options.normalize(max_definition_bytes: 0) end
    assert_raise ArgumentError, fn -> Options.normalize(max_catalog_bytes: 64_000_001) end
  end

  test "reject covers every C0/C1 control and DEL except legitimate tab and LF" do
    for cp <- Enum.to_list(0..31) ++ Enum.to_list(127..159), cp not in [9, 10] do
      text = "before" <> <<cp::utf8>> <> "after"
      refute Text.valid?(text, 100, display_text_policy: :reject)
      assert Text.valid?(text, 100, display_text_policy: :off)
    end

    assert Text.valid?("line\n\tindent", 100, display_text_policy: :reject)
    refute Text.valid?("title\n", 100, display_text_policy: :reject, multiline: false)

    for {type, identity} <- @definitions, field <- [:description, :title] do
      {:ok, registry} = Registry.start_link(display_text_policy: :reject)

      assert {:error, {:invalid_definition, ^field}} =
               Registry.register(registry, type, identity, %{
                 field => "\e]8;;https://example.test\a"
               })

      GenServer.stop(registry)
    end

    for field <- [:server_name, :server_version, :instructions] do
      assert_raise ArgumentError, fn ->
        Options.normalize([{field, "bad\e[2J"}, {:display_text_policy, :reject}])
      end
    end
  end

  test "prompt arguments and nested schema annotations are checked without editing schema data" do
    registry = start_supervised!({Registry, display_text_policy: :reject})

    assert {:error, {:invalid_definition, :arguments}} =
             Registry.register(registry, :prompt, "p", arguments: [%{name: <<255>>}])

    assert {:error, {:invalid_definition, :description}} =
             Registry.register(registry, :prompt, "p",
               arguments: [%{name: "x", description: "\e"}]
             )

    assert :ok =
             Registry.register(registry, :prompt, "p", arguments: [%{name: "x", description: ""}])

    schema = %{
      "type" => "object",
      "properties" => %{"text" => %{"type" => "string", "title" => "\e"}}
    }

    assert {:error, {:invalid_definition, :title}} =
             Registry.register(registry, :tool, "t", input_schema: schema)

    schema = put_in(schema, ["properties", "text"], %{"type" => "string", "default" => "\e"})
    assert :ok = Registry.register(registry, :tool, "t", input_schema: schema)

    assert {:error, {:invalid_definition, :title}} =
             Registry.register(registry, :tool, "a", annotations: %{title: "\e"})
  end

  test "complete definitions, captured handler data and atomic catalogs have independent byte bounds" do
    registry =
      start_supervised!({Registry, max_definition_bytes: 1_500, max_catalog_bytes: 2_000})

    assert :ok =
             Registry.register(registry, :tool, "one", description: String.duplicate("a", 800))

    assert {:error, :definition_too_large} =
             Registry.register(registry, :tool, "huge", extra: String.duplicate("x", 1_501))

    assert {:error, :definition_too_large} =
             Registry.register(registry, :tool, "sum",
               description: String.duplicate("a", 800),
               title: String.duplicate("b", 800)
             )

    captured = String.duplicate("x", 1_501)

    assert {:error, :definition_too_large} =
             Registry.register(registry, :tool, "closure", handler: fn _ -> captured end)

    # Replace/batch rejection must preserve the complete old catalog and revision.
    before = Registry.snapshot(registry)
    revision = Registry.revision(registry)

    additions = [
      {:tool, "two", %{description: String.duplicate("b", 800)}},
      {:prompt, "three", %{description: String.duplicate("c", 800)}}
    ]

    assert {:error, :catalog_too_large} = Registry.register_all(registry, additions)
    assert Registry.snapshot(registry) == before
    assert Registry.revision(registry) == revision
    assert {:error, :catalog_too_large} = Registry.replace_all(registry, additions)
    assert Registry.snapshot(registry) == before
  end

  test "strict output rejects text in both protocol eras but leaves binary and structured data intact" do
    server = start_supervised!({Server, display_text_policy: :reject})
    assert :ok = Server.register_tool(server, "bad", handler: fn _ -> "\e[2Jhidden" end)

    assert :ok =
             Server.register_resource(server, "urn:bad",
               handler: fn _ -> %{uri: "urn:bad", text: "\u009B2J"} end
             )

    assert :ok =
             Server.register_prompt(server, "bad",
               handler: fn _ ->
                 [%{role: "user", content: %{type: "text", text: "\u009D8;;url"}}]
               end
             )

    assert :ok =
             Server.register_tool(server, "error",
               handler: fn _ -> {:error, Result.error("\e[2J")} end
             )

    assert :ok =
             Server.register_prompt(server, "error",
               handler: fn _ -> {:error, Result.error("\e[2J")} end
             )

    media = Base.encode64(<<0, 27, 128, 155, 157, 255>>)

    assert :ok =
             Server.register_tool(server, "media",
               handler: fn _ ->
                 %{
                   content: [%{type: "image", mimeType: "image/png", data: media}],
                   structuredContent: %{text: "\e"}
                 }
               end
             )

    for version <- ["2026-07-28", "2025-11-25", "2025-06-18"] do
      opts = [protocol_version: version]

      for response <- [
            Client.call_tool(server, "bad", %{}, opts),
            Client.read_resource(server, "urn:bad", opts),
            Client.get_prompt(server, "bad", %{}, opts),
            Client.call_tool(server, "error", %{}, opts),
            Client.get_prompt(server, "error", %{}, opts)
          ] do
        assert %{"error" => %{"code" => -32603}} = response
      end

      assert %{
               "result" => %{
                 "content" => [%{"data" => ^media}],
                 "structuredContent" => %{"text" => "\e"}
               }
             } = Client.call_tool(server, "media", %{}, opts)
    end
  end

  test "default off preserves display bytes and strict dynamic providers fail closed" do
    server = start_supervised!({Server, instructions: "\e"})
    assert :ok = Server.register_tool(server, "raw", description: "\e", handler: fn _ -> "\e" end)
    assert get_in(Client.discover(server), ["result", "instructions"]) == "\e"
    assert [%{"description" => "\e"}] = get_in(Client.list_tools(server), ["result", "tools"])

    assert [%{"text" => "\e"}] =
             get_in(Client.call_tool(server, "raw", %{}), ["result", "content"])

    strict =
      start_supervised!(
        {Server,
         display_text_policy: :reject,
         instructions_provider: fn _ -> {:ok, "\e"} end,
         tool_presentation: fn _, _ -> {:ok, %{title: "\e"}} end},
        id: :strict
      )

    assert :ok = Server.register_tool(strict, "raw", %{})
    assert %{"error" => _} = Client.discover(strict)
    assert %{"error" => _} = Client.list_tools(strict)
  end
end
