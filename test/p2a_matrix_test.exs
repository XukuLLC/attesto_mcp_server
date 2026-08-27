defmodule AttestoMCP.Server.P2AMatrixTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server
  alias AttestoMCP.Server.Schema

  @modern "2026-07-28"
  @legacy "2025-11-25"

  defp modern(extra) do
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

  defp call(server, id, params, era \\ @modern) do
    params = if era == @modern, do: modern(params), else: params

    Server.dispatch(
      server,
      %{kind: :request, id: id, method: "tools/call", params: params},
      %{principal: "matrix", tenant: "tenant"},
      version: era
    )
  end

  @tag :t25
  test "tool input, business errors, output schemas, all content variants, and filtering" do
    {:ok, server} = Server.start_link([])

    assert :ok =
             Server.register_tool(server, "variants", %{
               input_schema: %{
                 "type" => "object",
                 "required" => ["mode"],
                 "properties" => %{"mode" => %{"type" => "string"}}
               },
               output_schema: %{
                 "type" => "object",
                 "required" => ["ok"],
                 "properties" => %{"ok" => %{"type" => "boolean"}}
               },
               handler: fn
                 %{"mode" => "mixed"}, _ ->
                   {:ok,
                    %{
                      "structuredContent" => %{"ok" => true},
                      "content" => [
                        %{"type" => "text", "text" => "text"},
                        %{"type" => "image", "data" => "aGVsbG8=", "mimeType" => "image/png"},
                        %{"type" => "audio", "data" => "aGVsbG8=", "mimeType" => "audio/wav"},
                        %{"type" => "resource_link", "uri" => "urn:link", "name" => "link"},
                        %{
                          "type" => "resource",
                          "resource" => %{"uri" => "urn:embedded", "text" => "embedded"}
                        }
                      ],
                      "isError" => false
                    }}

                 %{"mode" => "business"}, _ ->
                   {:error, :upstream_secret}

                 %{"mode" => "bad"}, _ ->
                   {:ok, %{"content" => [%{"type" => "text"}]}}

                 %{"mode" => "mismatch"}, _ ->
                   {:ok, %{"structuredContent" => %{"ok" => "no"}, "content" => []}}
               end
             })

    assert :ok =
             Server.register_tool(server, "filtered", %{
               required_scopes: ["matrix:private"],
               handler: fn _, _ -> {:ok, "secret"} end
             })

    assert {1, %{"result" => %{"resultType" => "complete", "isError" => false}}} =
             call(server, 1, %{"name" => "variants", "arguments" => %{"mode" => "mixed"}})

    assert {2, %{"result" => %{"isError" => true}}} =
             call(server, 2, %{"name" => "variants", "arguments" => %{"mode" => "business"}})

    assert {3, %{"result" => %{"isError" => true}}} =
             call(server, 3, %{"name" => "variants", "arguments" => %{"mode" => "bad"}})

    assert {4, %{"result" => %{"isError" => true}}} =
             call(server, 4, %{"name" => "variants", "arguments" => %{"mode" => "mismatch"}})

    assert {5, %{"error" => %{"code" => -32602}}} =
             call(server, 5, %{"name" => "variants", "arguments" => %{}}, @modern)

    assert {6, %{"error" => %{"code" => -32602}}} =
             call(server, 6, %{"name" => "filtered", "arguments" => %{}}, @modern)

    assert {7, %{"error" => %{"code" => -32602}}} =
             call(server, 7, %{"name" => "filtered", "arguments" => %{}}, @legacy)

    assert {8, %{"result" => %{"isError" => false}}} =
             call(
               server,
               8,
               %{"name" => "variants", "arguments" => %{"mode" => "mixed"}},
               @legacy
             )

    list_request = %{kind: :request, id: 9, method: "tools/list", params: modern(%{})}

    assert {9, %{"result" => %{"tools" => tools}}} =
             Server.dispatch(server, list_request, %{principal: "matrix", scopes: []},
               version: @modern
             )

    refute Enum.any?(tools, &(&1["name"] == "filtered"))

    assert {9, %{"result" => %{"tools" => scoped_tools}}} =
             Server.dispatch(
               server,
               list_request,
               %{principal: "matrix", scopes: ["matrix:private"]},
               version: @modern
             )

    assert Enum.any?(scoped_tools, &(&1["name"] == "filtered"))
  end

  @tag :t26
  test "static/template resources validate text/blob content and dated errors" do
    {:ok, server} = Server.start_link([])
    blob = Base.encode64(<<251, 255>>)
    assert blob == "+/8="

    assert :ok =
             Server.register_resource(server, "urn:static", %{
               annotations: %{"audience" => ["user"]},
               handler: fn _, _ ->
                 {:ok,
                  %{
                    "contents" => [
                      %{"uri" => "urn:static", "mimeType" => "text/plain", "text" => "hello"},
                      %{
                        "uri" => "urn:static",
                        "mimeType" => "application/octet-stream",
                        "blob" => blob
                      }
                    ]
                  }}
               end
             })

    assert :ok =
             Server.register_resource(server, "urn:empty", %{
               handler: fn _, _ -> {:ok, %{"contents" => []}} end
             })

    assert :ok =
             Server.register_resource_template(server, "urn:template/{id}", %{
               handler: fn %{params: %{"id" => id}, uri: uri}, _ ->
                 {:ok, %{"contents" => [%{"uri" => uri, "text" => id}]}}
               end
             })

    assert {:error, {:duplicate, :template, "urn:template/{id}"}} =
             Server.register_resource_template(server, "urn:template/{id}", %{})

    list = fn id, method, era ->
      params = if era == @modern, do: modern(%{}), else: %{}

      Server.dispatch(
        server,
        %{kind: :request, id: id, method: method, params: params},
        %{principal: "matrix"},
        version: era
      )
    end

    assert {8, %{"result" => %{"resources" => resources, "resultType" => "complete"}}} =
             list.(8, "resources/list", @modern)

    assert Enum.any?(resources, &(&1["uri"] == "urn:static" and &1["mimeType"] == nil))

    assert Enum.any?(
             resources,
             &(&1["uri"] == "urn:static" and &1["annotations"] == %{"audience" => ["user"]})
           )

    assert {9, %{"result" => %{"resourceTemplates" => [%{"uriTemplate" => "urn:template/{id}"}]}}} =
             list.(9, "resources/templates/list", @modern)

    assert {10, %{"result" => %{"resources" => _}}} = list.(10, "resources/list", @legacy)

    read = fn id, uri, era ->
      params = if era == @modern, do: modern(%{"uri" => uri}), else: %{"uri" => uri}

      Server.dispatch(
        server,
        %{kind: :request, id: id, method: "resources/read", params: params},
        %{principal: "matrix"},
        version: era
      )
    end

    assert {1, %{"result" => %{"contents" => contents}}} = read.(1, "urn:static", @modern)
    assert length(contents) == 2
    assert Enum.any?(contents, &Map.has_key?(&1, "blob"))
    assert {2, %{"result" => %{"contents" => []}}} = read.(2, "urn:empty", @modern)

    assert {3, %{"result" => %{"contents" => [%{"text" => "blue"}]}}} =
             read.(3, "urn:template/blue", @legacy)

    assert {4, %{"error" => %{"code" => -32602}}} = read.(4, "urn:missing", @modern)
    assert {5, %{"error" => %{"code" => -32002}}} = read.(5, "urn:missing", @legacy)
    assert {6, %{"error" => %{"code" => -32602}}} = read.(6, "urn:template/../secret", @modern)

    assert {:error, {:invalid_definition, :uri}} =
             Server.register_resource(server, "http://localhost/private", %{})

    assert :ok =
             Server.register_resource(server, "urn:invalid", %{
               handler: fn _, _ ->
                 {:ok, %{"contents" => [%{"uri" => "urn:invalid", "blob" => "%%%"}]}}
               end
             })

    assert :ok =
             Server.register_resource(server, "urn:mixed", %{
               handler: fn _, _ ->
                 {:ok, %{"contents" => [%{"uri" => "urn:mixed", "text" => "x", "blob" => blob}]}}
               end
             })

    assert :ok =
             Server.register_resource(server, "urn:missing-uri", %{
               handler: fn _, _ -> {:ok, %{"contents" => [%{"text" => "x"}]}} end
             })

    assert {7, %{"error" => %{"code" => -32603}}} = read.(7, "urn:invalid", @modern)
    assert {11, %{"error" => %{"code" => -32603}}} = read.(11, "urn:mixed", @modern)
    assert {12, %{"error" => %{"code" => -32603}}} = read.(12, "urn:missing-uri", @modern)

    assert :ok =
             Server.register_resource(server, "urn:content-block", %{
               handler: fn _, _ ->
                 {:ok, [%{"type" => "text", "text" => "not-resource-content"}]}
               end
             })

    assert {13, %{"error" => %{"code" => -32603}}} = read.(13, "urn:content-block", @modern)
  end

  @tag :t27
  test "prompts and completion refs enforce arguments, content, context, and caps" do
    {:ok, server} = Server.start_link([])
    parent = self()

    assert :ok =
             Server.register_prompt(server, "all-content", %{
               arguments: [
                 %{"name" => "required", "required" => true},
                 %{"name" => "optional", "required" => false}
               ],
               handler: fn
                 %{arguments: %{"required" => "yes"}}, _ ->
                   {:ok,
                    %{
                      "messages" => [
                        %{"role" => "user", "content" => %{"type" => "text", "text" => "text"}},
                        %{
                          "role" => "assistant",
                          "content" => %{
                            "type" => "image",
                            "data" => "aA==",
                            "mimeType" => "image/png"
                          }
                        },
                        %{
                          "role" => "user",
                          "content" => %{
                            "type" => "audio",
                            "data" => "aA==",
                            "mimeType" => "audio/wav"
                          }
                        },
                        %{
                          "role" => "assistant",
                          "content" => %{
                            "type" => "resource_link",
                            "uri" => "urn:prompt",
                            "name" => "prompt"
                          }
                        },
                        %{
                          "role" => "user",
                          "content" => %{
                            "type" => "resource",
                            "resource" => %{"uri" => "urn:embed", "text" => "x"}
                          }
                        }
                      ]
                    }}

                 _, _ ->
                   {:ok,
                    %{
                      "messages" => [
                        %{"role" => "user", "content" => %{"type" => "text", "text" => "x"}}
                      ]
                    }}
               end
             })

    assert :ok =
             Server.register_resource_template(server, "urn:completion/{id}", %{
               handler: fn _, _ -> {:ok, %{}} end
             })

    assert :ok =
             Server.register_completion(server, "prompt-complete", %{
               ref: %{"type" => "ref/prompt", "name" => "all-content"},
               handler: fn %{context: context, value: value}, _ ->
                 send(parent, {:completion_context, context})
                 {:ok, Enum.map(1..105, &"#{value}#{&1}")}
               end
             })

    assert :ok =
             Server.register_completion(server, "resource-complete", %{
               ref: %{"type" => "ref/resource", "uri" => "urn:completion/{id}"},
               handler: fn %{value: value}, _ -> {:ok, [value <> "-resource"]} end
             })

    assert {:error, {:duplicate, :completion_ref, _}} =
             Server.register_completion(server, "prompt-complete-duplicate", %{
               ref: %{"type" => "ref/prompt", "name" => "all-content"},
               handler: fn _, _ -> {:ok, []} end
             })

    assert {:error, {:duplicate, :completion, "prompt-complete"}} =
             Server.register_completion(server, "prompt-complete", %{
               ref: %{"type" => "ref/resource", "uri" => "urn:completion/{id}"},
               handler: fn _, _ -> {:ok, []} end
             })

    prompt = fn id, args ->
      Server.dispatch(
        server,
        %{
          kind: :request,
          id: id,
          method: "prompts/get",
          params: modern(%{"name" => "all-content", "arguments" => args})
        },
        %{principal: "matrix"},
        version: @modern
      )
    end

    assert {1, %{"result" => %{"messages" => messages}}} = prompt.(1, %{"required" => "yes"})
    assert length(messages) == 5
    assert {2, %{"error" => %{"code" => -32602}}} = prompt.(2, %{})

    assert {3, %{"error" => %{"code" => -32602}}} =
             prompt.(3, %{"required" => "yes", "unknown" => true})

    completion = fn id, ref, value, context ->
      Server.dispatch(
        server,
        %{
          kind: :request,
          id: id,
          method: "completion/complete",
          params:
            modern(%{
              "ref" => ref,
              "argument" => %{"name" => "x", "value" => value},
              "context" => context
            })
        },
        %{principal: "matrix"},
        version: @modern
      )
    end

    assert {4,
            %{
              "result" => %{
                "completion" => %{"values" => values, "total" => 105, "hasMore" => true}
              }
            }} =
             completion.(4, %{"type" => "ref/prompt", "name" => "all-content"}, "v", %{
               "scope" => "test"
             })

    assert length(values) == 100
    assert_receive {:completion_context, %{"scope" => "test"}}

    assert {5, %{"result" => %{"completion" => %{"values" => ["x-resource"]}}}} =
             completion.(5, %{"type" => "ref/resource", "uri" => "urn:completion/{id}"}, "x", %{})

    assert {9, legacy_completion} =
             Server.dispatch(
               server,
               %{
                 kind: :request,
                 id: 9,
                 method: "completion/complete",
                 params: %{
                   "ref" => %{"type" => "ref/prompt", "name" => "all-content"},
                   "argument" => %{"name" => "x", "value" => "v"}
                 }
               },
               %{principal: "matrix"},
               version: @legacy
             )

    refute Map.has_key?(legacy_completion["result"], "resultType")

    assert {6, %{"error" => %{"code" => -32602}}} =
             completion.(6, %{"type" => "ref/prompt", "name" => "missing"}, "x", %{})

    assert {7, %{"error" => %{"code" => -32602}}} =
             completion.(7, %{"type" => "ref/prompt", "name" => "all-content"}, 1, %{})

    assert :ok =
             Server.register_prompt(server, "malformed", %{
               handler: fn _, _ ->
                 {:ok, %{"messages" => [%{"role" => "system", "content" => %{"type" => "text"}}]}}
               end
             })

    assert {8, %{"error" => %{"code" => -32603}}} =
             Server.dispatch(
               server,
               %{
                 kind: :request,
                 id: 8,
                 method: "prompts/get",
                 params: modern(%{"name" => "malformed"})
               },
               %{principal: "matrix"},
               version: @modern
             )

    assert {10, %{"result" => %{"messages" => _} = legacy_prompt}} =
             Server.dispatch(
               server,
               %{
                 kind: :request,
                 id: 10,
                 method: "prompts/get",
                 params: %{"name" => "all-content", "arguments" => %{"required" => "yes"}}
               },
               %{principal: "matrix"},
               version: @legacy
             )

    refute Map.has_key?(legacy_prompt, "resultType")
  end

  @tag :t28
  test "bounded schema matrix covers applicators, constraints and fail-closed vocabularies" do
    assert :ok =
             Schema.validate(%{"kind" => "a", "x1" => 2}, %{
               "type" => "object",
               "properties" => %{"kind" => %{"type" => "string"}},
               "patternProperties" => %{"^x" => %{"type" => "integer"}},
               "propertyNames" => %{"pattern" => "^[a-z0-9]+$"},
               "additionalProperties" => false
             })

    assert {:error, _} =
             Schema.validate(%{"kind" => "a", "X" => 2}, %{
               "propertyNames" => %{"pattern" => "^[a-z]+$"}
             })

    assert :ok =
             Schema.validate(%{"kind" => "a", "dependent" => true}, %{
               "dependentRequired" => %{"kind" => ["dependent"]}
             })

    assert {:error, _} =
             Schema.validate(%{"kind" => "a"}, %{
               "dependentRequired" => %{"kind" => ["dependent"]}
             })

    assert :ok =
             Schema.validate(%{"kind" => "a", "extra" => 1}, %{
               "dependentSchemas" => %{
                 "kind" => %{"properties" => %{"extra" => %{"type" => "integer"}}}
               }
             })

    assert :ok =
             Schema.validate(%{"nested" => %{"ok" => true}}, %{
               "properties" => %{"nested" => %{"properties" => %{"ok" => true}}}
             })

    assert {:error, _} =
             Schema.validate(%{"nested" => %{"ok" => false}}, %{
               "properties" => %{"nested" => %{"properties" => %{"ok" => false}}}
             })

    assert :ok = Schema.validate(%{"a" => 1}, %{"allOf" => [true, %{"minProperties" => 1}]})
    assert :ok = Schema.validate("x", %{"oneOf" => [%{"type" => "string"}, false]})
    assert {:error, _} = Schema.validate("x", %{"anyOf" => [false, %{"type" => "integer"}]})
    assert :ok = Schema.validate(%{}, true)
    assert {:error, :schema_false} = Schema.validate(%{}, false)
    assert {:error, _} = Schema.validate(%{}, %{"minProperties" => 1, "maxProperties" => 2})

    assert :ok =
             Schema.validate([1, 2], %{
               "contains" => %{"type" => "integer"},
               "minContains" => 2,
               "maxContains" => 2
             })

    assert {:error, _} =
             Schema.validate([1, 2, 3], %{
               "contains" => %{"type" => "integer"},
               "maxContains" => 2
             })

    assert :ok =
             Schema.validate(["x", 1], %{
               "prefixItems" => [%{"type" => "string"}, %{"type" => "integer"}]
             })

    assert {:error, _} = Schema.validate([1, 1], %{"uniqueItems" => true})
    assert :ok = Schema.validate(6, %{"minimum" => 2, "maximum" => 10, "multipleOf" => 2})
    assert {:error, _} = Schema.validate(5, %{"multipleOf" => 2})
    assert {:error, _} = Schema.validate(2, %{"exclusiveMinimum" => 2})
    assert {:error, _} = Schema.validate(2, %{"exclusiveMaximum" => 2})
    assert {:error, _} = Schema.validate("é", %{"minLength" => 2})
    assert :ok = Schema.validate("éé", %{"minLength" => 2, "maxLength" => 2})

    conditional = %{
      "if" => %{"properties" => %{"kind" => %{"const" => "a"}}},
      "then" => %{"required" => ["a"]},
      "else" => %{"required" => ["b"]}
    }

    assert :ok = Schema.validate(%{"kind" => "a", "a" => true}, conditional)
    assert {:error, _} = Schema.validate(%{"kind" => "b"}, conditional)

    cyclic = %{
      "$defs" => %{
        "node" => %{"type" => "object", "properties" => %{"next" => %{"$ref" => "#/$defs/node"}}}
      },
      "$ref" => "#/$defs/node"
    }

    assert :ok = Schema.validate(%{"next" => %{}}, cyclic)
    assert :ok = Schema.validate([true, false], %{"items" => %{"anyOf" => [true, false]}})

    anchored = %{
      "$defs" => %{
        "tag" => %{"$anchor" => "tag", "type" => "string"},
        "value" => %{"type" => "string", "$dynamicAnchor" => "value"}
      },
      "properties" => %{"name" => %{"$ref" => "#tag"}},
      "contentEncoding" => "base64",
      "contentMediaType" => "text/plain",
      "unevaluatedItems" => false
    }

    assert :ok = Schema.validate_schema(anchored)
    assert :ok = Schema.validate(%{"name" => "ok"}, anchored)
    assert {:error, _} = Schema.validate(%{"name" => 1}, anchored)
    assert :ok = Schema.validate_schema(%{"$schema" => "http://json-schema.org/draft-07/schema#"})

    draft7 = %{
      "$schema" => "http://json-schema.org/draft-07/schema#",
      "type" => "array",
      "items" => [%{"type" => "string"}, %{"type" => "integer"}],
      "additionalItems" => false
    }

    assert :ok = Schema.validate(["head", 2], draft7)
    assert {:error, _} = Schema.validate(["head", 2, 3], draft7)

    assert {:error, {:invalid_keyword, "exclusiveMinimum"}} =
             Schema.validate_schema(%{"exclusiveMinimum" => true})

    assert {:error, {:invalid_keyword, "uniqueItems"}} =
             Schema.validate_schema(%{"uniqueItems" => "yes"})

    assert :ok = Schema.validate(%{"" => 1}, %{"required" => [""]})

    assert :ok =
             Schema.validate(%{"credit" => true, "billing" => "yes"}, %{
               "$schema" => "http://json-schema.org/draft-07/schema#",
               "dependencies" => %{"credit" => ["billing"]}
             })

    assert {:error, _} =
             Schema.validate(%{"credit" => true}, %{
               "$schema" => "http://json-schema.org/draft-07/schema#",
               "dependencies" => %{"credit" => ["billing"]}
             })

    dynamic = %{
      "$dynamicAnchor" => "node",
      "type" => "string"
    }

    assert :ok =
             Schema.validate("value", %{"$defs" => %{"node" => dynamic}, "$dynamicRef" => "#node"})

    assert {:error, _} =
             Schema.validate(1, %{"$defs" => %{"node" => dynamic}, "$dynamicRef" => "#node"})

    assert {:error, _} =
             Schema.validate(["head", 2], %{
               "prefixItems" => [%{"type" => "string"}],
               "unevaluatedItems" => false
             })

    assert {:error, :unsupported_format} = Schema.validate_schema(%{"format" => "not-a-format"})

    assert :ok =
             Schema.validate_schema(%{"$schema" => "http://json-schema.org/draft-07/schema#"})

    assert {:error, :remote_ref_disabled} =
             Schema.validate_schema(%{
               "properties" => %{"x" => %{"$ref" => "https://example.invalid"}}
             })

    deep = Enum.reduce(1..34, %{}, fn _, acc -> %{"properties" => %{"x" => acc}} end)
    assert {:error, :schema_too_deep} = Schema.validate_schema(deep)

    assert {:error, :schema_too_complex} =
             Schema.validate_schema(%{"enum" => Enum.to_list(1..501)})

    assert {:error, :invalid_pattern} =
             Schema.validate_schema(%{"pattern" => String.duplicate("x", 257)})
  end
end
