defmodule AttestoMCP.Server.AlternativeScopeSetsTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server

  @modern "2026-07-28"
  @legacy "2025-11-25"
  @primary ["records.read"]
  @alternatives [["records.admin"], ["workspace.read", "records.execute"]]

  setup do
    %{server: start_supervised!({Server, []})}
  end

  test "registration canonicalizes bounded alternative scope sets", %{server: server} do
    assert :ok =
             Server.register_tool(server, "canonical", %{
               "requiredScopes" => @primary,
               "alternativeScopeSets" => @alternatives,
               "handler" => fn _arguments, _context -> {:ok, "ok"} end
             })

    definition = Server.snapshot(server).tool["canonical"]
    assert definition.required_scopes == @primary
    assert definition.alternative_scope_sets == @alternatives

    assert {:error, {:invalid_definition, :alternative_scope_sets}} =
             Server.register_tool(server, "empty-primary", %{
               required_scopes: [],
               alternative_scope_sets: [["records.admin"]]
             })

    invalid_alternatives = [
      [[]],
      [["records.admin", "records.admin"]],
      [Enum.reverse(@primary)],
      [["records.admin"], ["records.admin"]],
      [["records.admin" | :improper]],
      [["records.admin"] | :improper],
      Enum.map(1..8, &["records.alternative.#{&1}"]),
      [[String.duplicate("a", 257)]]
    ]

    Enum.with_index(invalid_alternatives, fn alternatives, index ->
      assert {:error, {:invalid_definition, :alternative_scope_sets}} =
               Server.register_tool(server, "invalid-alternative-#{index}", %{
                 required_scopes: @primary,
                 alternative_scope_sets: alternatives
               })
    end)

    over_membership_limit =
      Enum.map(1..7, fn set ->
        Enum.map(1..19, &"records.alternative.#{set}.#{&1}")
      end)

    assert {:error, {:invalid_definition, :alternative_scope_sets}} =
             Server.register_tool(server, "too-many-scope-memberships", %{
               required_scopes: @primary,
               alternative_scope_sets: over_membership_limit
             })
  end

  test "all primitive lookups accept any complete clause in both protocol eras", %{
    server: server
  } do
    register_all_primitives(server)

    for era <- [@modern, @legacy],
        scopes <- [@primary, ["records.admin"], ["workspace.read", "records.execute"]] do
      assert {_, %{"result" => %{"tools" => [%{"name" => "alternative-tool"}]}}} =
               dispatch(server, era, "tools/list", %{}, scopes)

      assert {_, %{"result" => %{"resources" => [%{"uri" => "urn:alternative:static"}]}}} =
               dispatch(server, era, "resources/list", %{}, scopes)

      assert {_,
              %{
                "result" => %{
                  "resourceTemplates" => [
                    %{
                      "uriTemplate" => "urn:alternative:template/{id}"
                    }
                  ]
                }
              }} = dispatch(server, era, "resources/templates/list", %{}, scopes)

      assert {_, %{"result" => %{"prompts" => [%{"name" => "alternative-prompt"}]}}} =
               dispatch(server, era, "prompts/list", %{}, scopes)

      assert {_, %{"result" => %{"isError" => false}}} =
               dispatch(
                 server,
                 era,
                 "tools/call",
                 %{"name" => "alternative-tool", "arguments" => %{}},
                 scopes
               )

      assert {_, %{"result" => %{"contents" => [_]}}} =
               dispatch(
                 server,
                 era,
                 "resources/read",
                 %{"uri" => "urn:alternative:template/item"},
                 scopes
               )

      assert {_, %{"result" => %{"messages" => [_]}}} =
               dispatch(
                 server,
                 era,
                 "prompts/get",
                 %{"name" => "alternative-prompt", "arguments" => %{}},
                 scopes
               )

      assert {_, %{"result" => %{"completion" => %{"values" => ["value"]}}}} =
               dispatch(
                 server,
                 era,
                 "completion/complete",
                 %{
                   "ref" => %{"type" => "ref/prompt", "name" => "alternative-prompt"},
                   "argument" => %{"name" => "topic", "value" => "v"}
                 },
                 scopes
               )
    end

    for era <- [@modern, @legacy] do
      partial = ["workspace.read"]

      assert {_, %{"result" => %{"tools" => []}}} =
               dispatch(server, era, "tools/list", %{}, partial)

      assert {_, %{"result" => %{"resources" => []}}} =
               dispatch(server, era, "resources/list", %{}, partial)

      assert {_, %{"result" => %{"resourceTemplates" => []}}} =
               dispatch(server, era, "resources/templates/list", %{}, partial)

      assert {_, %{"result" => %{"prompts" => []}}} =
               dispatch(server, era, "prompts/list", %{}, partial)

      for {method, params} <- [
            {"tools/call", %{"name" => "alternative-tool", "arguments" => %{}}},
            {"resources/read", %{"uri" => "urn:alternative:static"}},
            {"prompts/get", %{"name" => "alternative-prompt", "arguments" => %{}}},
            {"completion/complete",
             %{
               "ref" => %{"type" => "ref/prompt", "name" => "alternative-prompt"},
               "argument" => %{"name" => "topic", "value" => "v"}
             }}
          ] do
        expected_code =
          if era == @legacy and method == "resources/read", do: -32_002, else: -32_602

        assert {_, %{"error" => %{"code" => ^expected_code}}} =
                 dispatch(server, era, method, params, partial)
      end
    end
  end

  test "definition authorize runs once and only after a scope clause succeeds", %{server: server} do
    parent = self()

    assert :ok =
             Server.register_tool(server, "ordered", %{
               required_scopes: @primary,
               alternative_scope_sets: @alternatives,
               authorize: fn context ->
                 send(parent, {:authorized, context.scopes})
                 true
               end,
               handler: fn _arguments, _context -> {:ok, "ok"} end
             })

    assert {_, %{"error" => %{"code" => -32602}}} =
             dispatch(
               server,
               @modern,
               "tools/call",
               %{"name" => "ordered", "arguments" => %{}},
               ["workspace.read"]
             )

    refute_receive {:authorized, _}

    assert {_, %{"result" => %{"isError" => false}}} =
             dispatch(
               server,
               @modern,
               "tools/call",
               %{"name" => "ordered", "arguments" => %{}},
               ["records.admin", "workspace.read", "records.execute"]
             )

    assert_receive {:authorized, ["records.admin", "workspace.read", "records.execute"]}
    refute_receive {:authorized, _}
  end

  test "prepared definition authorizers still receive one flat clause at a time", %{
    server: server
  } do
    parent = self()

    assert :ok =
             Server.register_tool(server, "prepared-alternative", %{
               required_scopes: @primary,
               alternative_scope_sets: @alternatives,
               handler: fn _arguments, _context ->
                 send(parent, :prepared_alternative_handler)
                 {:ok, "ok"}
               end
             })

    authorizer = fn required ->
      send(parent, {:prepared_clause, required})
      if required == ["records.admin"], do: :ok, else: :denied
    end

    params = %{
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => @modern,
        "io.modelcontextprotocol/clientCapabilities" => %{}
      },
      "name" => "prepared-alternative",
      "arguments" => %{}
    }

    assert {1, %{"result" => %{"isError" => false}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 1, method: "tools/call", params: params},
               %{principal: "prepared", scopes: ["records.admin"]},
               version: @modern,
               definition_authorizer: authorizer
             )

    assert_receive {:prepared_clause, @primary}
    assert_receive {:prepared_clause, ["records.admin"]}
    refute_receive {:prepared_clause, ["workspace.read", "records.execute"]}
    assert_receive :prepared_alternative_handler
  end

  defp register_all_primitives(server) do
    common = [required_scopes: @primary, alternative_scope_sets: @alternatives]

    assert :ok =
             Server.register_tool(
               server,
               "alternative-tool",
               Keyword.put(common, :handler, fn _arguments, _context -> {:ok, "ok"} end)
             )

    assert :ok =
             Server.register_resource(
               server,
               "urn:alternative:static",
               Keyword.put(common, :handler, fn _input, _context ->
                 {:ok,
                  %{
                    "contents" => [
                      %{"uri" => "urn:alternative:static", "text" => "static"}
                    ]
                  }}
               end)
             )

    assert :ok =
             Server.register_resource_template(
               server,
               "urn:alternative:template/{id}",
               Keyword.put(common, :handler, fn %{uri: uri}, _context ->
                 {:ok, %{"contents" => [%{"uri" => uri, "text" => "template"}]}}
               end)
             )

    assert :ok =
             Server.register_prompt(
               server,
               "alternative-prompt",
               Keyword.put(common, :handler, fn _input, _context ->
                 {:ok,
                  [
                    %{
                      "role" => "user",
                      "content" => %{"type" => "text", "text" => "prompt"}
                    }
                  ]}
               end)
             )

    assert :ok =
             Server.register_completion(
               server,
               "alternative-completion",
               common
               |> Keyword.put(:ref, %{"type" => "ref/prompt", "name" => "alternative-prompt"})
               |> Keyword.put(:handler, fn _input, _context -> {:ok, ["value"]} end)
             )
  end

  defp dispatch(server, era, method, params, scopes) do
    id = System.unique_integer([:positive])

    params =
      if era == @modern do
        Map.put(params, "_meta", %{
          "io.modelcontextprotocol/protocolVersion" => @modern,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        })
      else
        params
      end

    Server.dispatch(
      server,
      %{kind: :request, id: id, method: method, params: params},
      %{principal: "alternative-scope-test", scopes: scopes},
      version: era
    )
  end
end
