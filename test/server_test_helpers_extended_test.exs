defmodule AttestoMCP.Server.TestHelpersExtendedTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server
  alias AttestoMCP.Server.Test, as: ServerTest

  @modern "2026-07-28"
  @legacy "2025-11-25"

  defp start_server(opts \\ []), do: start_supervised!({Server, opts})

  defp form_request(message) do
    %{
      "method" => "elicitation/create",
      "params" => %{
        "message" => message,
        "requestedSchema" => %{
          "type" => "object",
          "properties" => %{"value" => %{"type" => "string"}},
          "required" => ["value"]
        }
      }
    }
  end

  describe "resources" do
    test "read_resource resolves templates through the production matcher" do
      server = start_server()
      parent = self()

      :ok =
        Server.register_resource_template(server, "file:///items/{id}", %{
          handler: fn %{uri: uri, params: params}, _context ->
            send(parent, {:template_handler, uri, params})
            {:ok, %{"contents" => [%{"uri" => uri, "text" => "item " <> params["id"]}]}}
          end
        })

      assert %{
               "jsonrpc" => "2.0",
               "result" => %{
                 "resultType" => "complete",
                 "contents" => [%{"uri" => "file:///items/42", "text" => "item 42"}],
                 "ttlMs" => ttl,
                 "cacheScope" => "private"
               }
             } = ServerTest.read_resource(server, "file:///items/42")

      assert is_integer(ttl)
      assert_receive {:template_handler, "file:///items/42", %{"id" => "42"}}

      assert %{"error" => %{"code" => -32602}} =
               ServerTest.read_resource(server, "file:///other/42")
    end

    test "a denied resource returns the same neutral error as an unknown resource" do
      server = start_server()
      parent = self()

      :ok =
        Server.register_resource(server, "urn:example:restricted", %{
          required_scopes: ["docs.read"],
          handler: fn %{uri: uri}, _context ->
            send(parent, :restricted_handler)
            {:ok, %{"contents" => [%{"uri" => uri, "text" => "restricted"}]}}
          end
        })

      denied = ServerTest.read_resource(server, "urn:example:restricted", request_id: "r-1")
      unknown = ServerTest.read_resource(server, "urn:example:unknown", request_id: "r-1")

      assert %{"error" => %{"code" => -32602, "data" => %{"uri" => "urn:example:restricted"}}} =
               denied

      assert %{"error" => %{"code" => -32602, "data" => %{"uri" => "urn:example:unknown"}}} =
               unknown

      assert Map.keys(denied["error"]["data"]) == Map.keys(unknown["error"]["data"])
      refute_received :restricted_handler

      assert %{"result" => %{"contents" => [%{"text" => "restricted"}]}} =
               ServerTest.read_resource(server, "urn:example:restricted", scopes: ["docs.read"])

      assert_receive :restricted_handler
    end

    test "resource handler failures use the production error" do
      server = start_server()

      :ok =
        Server.register_resource(server, "urn:example:failing", %{
          handler: fn _input, _context -> {:error, :unavailable} end
        })

      assert %{
               "error" => %{
                 "code" => -32603,
                 "data" => %{"reason" => "resource_handler_failure"}
               }
             } = ServerTest.read_resource(server, "urn:example:failing")
    end
  end

  describe "prompts and completions" do
    setup do
      server = start_server()
      parent = self()

      :ok =
        Server.register_prompt(server, "summarize", %{
          arguments: [
            %{"name" => "topic", "required" => true},
            %{"name" => "tone", "required" => false}
          ],
          handler: fn %{arguments: arguments}, _context ->
            send(parent, {:prompt_handler, arguments})

            {:ok,
             [
               %{
                 "role" => "user",
                 "content" => %{"type" => "text", "text" => "Summarize " <> arguments["topic"]}
               }
             ]}
          end
        })

      :ok =
        Server.register_completion(server, "topic_completion", %{
          ref: %{"type" => "ref/prompt", "name" => "summarize"},
          handler: fn %{value: value, context: completion_context}, _context ->
            send(parent, {:completion_handler, value, completion_context})
            {:ok, [value <> "-one", value <> "-two"]}
          end
        })

      %{server: server}
    end

    test "get_prompt returns messages and rejects missing required arguments", %{server: server} do
      assert %{
               "result" => %{
                 "resultType" => "complete",
                 "messages" => [%{"content" => %{"text" => "Summarize release"}}]
               }
             } = ServerTest.get_prompt(server, "summarize", %{"topic" => "release"})

      assert_receive {:prompt_handler, %{"topic" => "release"}}

      assert %{
               "error" => %{
                 "code" => -32602,
                 "data" => %{"reason" => "invalid_prompt_arguments"}
               }
             } = ServerTest.get_prompt(server, "summarize", %{"tone" => "brief"})

      refute_received {:prompt_handler, _arguments}

      assert %{"error" => %{"code" => -32602}} =
               ServerTest.get_prompt(server, "unknown_prompt", %{})
    end

    test "complete routes references and completion context through the production path", %{
      server: server
    } do
      assert %{
               "result" => %{
                 "resultType" => "complete",
                 "completion" => %{
                   "values" => ["rel-one", "rel-two"],
                   "total" => 2,
                   "hasMore" => false
                 }
               }
             } =
               ServerTest.complete(
                 server,
                 %{"type" => "ref/prompt", "name" => "summarize"},
                 %{"name" => "topic", "value" => "rel"},
                 completion_context: %{"arguments" => %{"tone" => "brief"}}
               )

      assert_receive {:completion_handler, "rel", %{"arguments" => %{"tone" => "brief"}}}

      assert %{
               "error" => %{
                 "code" => -32602,
                 "data" => %{"reason" => "unknown_completion_ref"}
               }
             } =
               ServerTest.complete(
                 server,
                 %{"type" => "ref/prompt", "name" => "unregistered"},
                 %{"name" => "topic", "value" => "rel"}
               )

      assert %{
               "error" => %{
                 "code" => -32602,
                 "data" => %{"reason" => "completion_ref_required"}
               }
             } =
               ServerTest.complete(
                 server,
                 %{"type" => "ref/unsupported", "name" => "summarize"},
                 %{"name" => "topic", "value" => "rel"}
               )

      refute_received {:completion_handler, _value, _context}
    end
  end

  describe "discovery and catalogs" do
    test "discover returns the modern discovery result" do
      server = start_server(instructions: "Use the example tools.")

      assert %{
               "jsonrpc" => "2.0",
               "result" => %{
                 "resultType" => "complete",
                 "supportedVersions" => versions,
                 "capabilities" => %{"tools" => _, "resources" => _, "prompts" => _},
                 "instructions" => "Use the example tools.",
                 "ttlMs" => ttl,
                 "cacheScope" => "private",
                 "_meta" => %{"io.modelcontextprotocol/serverInfo" => %{"name" => _}}
               }
             } = ServerTest.discover(server)

      assert @modern in versions
      assert is_integer(ttl)
    end

    test "list helpers paginate every catalog with signed cursors" do
      server = start_server(page_size: 1)

      for name <- ["alpha", "beta", "gamma"] do
        :ok = Server.register_tool(server, name, %{handler: fn _, _ -> {:ok, name} end})
      end

      for uri <- ["urn:example:one", "urn:example:two"] do
        :ok =
          Server.register_resource(server, uri, %{
            handler: fn _, _ -> {:ok, %{"contents" => [%{"uri" => uri, "text" => uri}]}} end
          })
      end

      for template <- ["file:///a/{id}", "file:///b/{id}"] do
        :ok =
          Server.register_resource_template(server, template, %{
            handler: fn %{uri: uri}, _ ->
              {:ok, %{"contents" => [%{"uri" => uri, "text" => ""}]}}
            end
          })
      end

      for name <- ["first_prompt", "second_prompt"] do
        :ok =
          Server.register_prompt(server, name, %{
            handler: fn _, _ ->
              {:ok, [%{"role" => "user", "content" => %{"type" => "text", "text" => name}}]}
            end
          })
      end

      assert collect_pages(&ServerTest.list_tools(server, &1), "tools", "name") ==
               ["alpha", "beta", "gamma"]

      assert collect_pages(&ServerTest.list_resources(server, &1), "resources", "uri") ==
               ["urn:example:one", "urn:example:two"]

      assert collect_pages(
               &ServerTest.list_resource_templates(server, &1),
               "resourceTemplates",
               "uriTemplate"
             ) == ["file:///a/{id}", "file:///b/{id}"]

      assert collect_pages(&ServerTest.list_prompts(server, &1), "prompts", "name") ==
               ["first_prompt", "second_prompt"]

      %{"result" => %{"nextCursor" => cursor}} =
        ServerTest.list_tools(server, principal: "owner")

      assert %{"result" => %{"tools" => [%{"name" => "beta"}]}} =
               ServerTest.list_tools(server, principal: "owner", cursor: cursor)

      assert %{"error" => %{"code" => -32602, "data" => %{"reason" => "invalid_cursor"}}} =
               ServerTest.list_tools(server, principal: "someone-else", cursor: cursor)

      assert %{"error" => %{"code" => -32602, "data" => %{"reason" => "invalid_cursor"}}} =
               ServerTest.list_tools(server, cursor: "not-a-cursor")
    end

    test "list helpers honour definition scopes and legacy revisions" do
      server = start_server()

      :ok = Server.register_tool(server, "public_tool", %{handler: fn _, _ -> {:ok, "p"} end})

      :ok =
        Server.register_tool(server, "scoped_tool", %{
          required_scopes: ["items.write"],
          handler: fn _, _ -> {:ok, "s"} end
        })

      assert %{"result" => %{"tools" => [%{"name" => "public_tool"}]}} =
               ServerTest.list_tools(server)

      assert %{"result" => %{"tools" => tools}} =
               ServerTest.list_tools(server, scopes: ["items.write"])

      assert Enum.map(tools, & &1["name"]) == ["public_tool", "scoped_tool"]

      assert %{"result" => legacy} = ServerTest.list_tools(server, protocol_version: @legacy)
      assert [%{"name" => "public_tool"}] = legacy["tools"]
      refute Map.has_key?(legacy, "resultType")
      refute Map.has_key?(legacy, "ttlMs")
      refute Map.has_key?(legacy, "cacheScope")
    end

    test "request/4 sends other methods through the same builder" do
      server = start_server()
      :ok = Server.register_tool(server, "alpha", %{handler: fn _, _ -> {:ok, "a"} end})

      assert %{"result" => %{"tools" => [%{"name" => "alpha"}]}} =
               ServerTest.request(server, "tools/list")

      assert %{"result" => %{"resultType" => "complete", "content" => [%{"text" => "a"}]}} =
               ServerTest.request(server, "tools/call", %{"name" => "alpha", "arguments" => %{}})

      assert %{"error" => %{"code" => -32601}} = ServerTest.request(server, "example/unknown")
    end
  end

  describe "tools and multi-round retries" do
    test "a valid partial retry re-requests only the missing input and then completes" do
      server = start_server()
      parent = self()

      :ok =
        Server.register_tool(server, "two_inputs", %{
          handler: fn arguments, context ->
            send(parent, {:two_inputs, arguments, context.request_meta["com.example/flow"]})

            if Map.has_key?(arguments, "first") and Map.has_key?(arguments, "second"),
              do: {:ok, %{"first" => arguments["first"], "second" => arguments["second"]}},
              else:
                {:input_required,
                 %{"first" => form_request("first?"), "second" => form_request("second?")}}
          end
        })

      opts = [
        client_capabilities: %{"elicitation" => %{}},
        meta: %{"com.example/flow" => "partial"}
      ]

      first = %{"action" => "accept", "content" => %{"value" => "one"}}
      second = %{"action" => "accept", "content" => %{"value" => "two"}}

      assert %{
               "result" => %{
                 "resultType" => "input_required",
                 "inputRequests" => requests,
                 "requestState" => state
               }
             } = ServerTest.call_tool(server, "two_inputs", %{}, opts)

      assert Map.keys(requests) |> Enum.sort() == ["first", "second"]
      assert_receive {:two_inputs, %{}, "partial"}

      assert %{
               "result" => %{
                 "resultType" => "input_required",
                 "inputRequests" => missing,
                 "requestState" => next_state
               }
             } =
               ServerTest.call_tool(
                 server,
                 "two_inputs",
                 %{},
                 opts ++ [request_state: state, input_responses: %{"first" => first}]
               )

      assert Map.keys(missing) == ["second"]
      refute_received {:two_inputs, _arguments, _flow}

      assert %{
               "result" => %{
                 "resultType" => "complete",
                 "structuredContent" => %{"first" => ^first, "second" => ^second}
               }
             } =
               ServerTest.call_tool(
                 server,
                 "two_inputs",
                 %{},
                 opts ++ [request_state: next_state, input_responses: %{"second" => second}]
               )

      assert_receive {:two_inputs, %{"first" => ^first, "second" => ^second}, "partial"}

      assert %{"error" => %{"data" => %{"reason" => "invalid_request_state"}}} =
               ServerTest.call_tool(
                 server,
                 "two_inputs",
                 %{},
                 opts ++ [request_state: next_state, input_responses: %{"second" => second}]
               )
    end

    test "request/4 carries retry fields for any MRTR-capable method" do
      server = start_server()

      :ok =
        Server.register_prompt(server, "confirm_prompt", %{
          handler: fn %{arguments: arguments}, _context ->
            if Map.has_key?(arguments, "confirm"),
              do:
                {:ok,
                 [%{"role" => "user", "content" => %{"type" => "text", "text" => "confirmed"}}]},
              else: {:input_required, %{"confirm" => form_request("confirm?")}}
          end
        })

      opts = [client_capabilities: %{"elicitation" => %{}}]
      params = %{"name" => "confirm_prompt", "arguments" => %{}}

      assert %{"result" => %{"resultType" => "input_required", "requestState" => state}} =
               ServerTest.request(server, "prompts/get", params, opts)

      assert %{"result" => %{"resultType" => "complete", "messages" => [_]}} =
               ServerTest.request(
                 server,
                 "prompts/get",
                 params,
                 opts ++
                   [
                     request_state: state,
                     input_responses: %{
                       "confirm" => %{"action" => "accept", "content" => %{"value" => "y"}}
                     }
                   ]
               )
    end

    test "tool helpers keep schema, scope, handler, and output checks on the production path" do
      server = start_server()
      parent = self()

      :ok =
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
          handler: fn arguments, _context ->
            send(parent, {:typed_handler, arguments})
            {:ok, %{"id" => 7}}
          end
        })

      :ok =
        Server.register_tool(server, "failing", %{
          handler: fn _arguments, _context -> {:error, :unavailable} end
        })

      :ok =
        Server.register_tool(server, "raising", %{
          handler: fn _arguments, _context -> raise "handler crashed" end
        })

      :ok =
        Server.register_tool(server, "non_json", %{
          handler: fn _arguments, _context -> {:ok, %{"pid" => self()}} end
        })

      assert %{"error" => %{"code" => -32602, "data" => %{"reason" => "tool_arguments_invalid"}}} =
               ServerTest.call_tool(server, "typed", %{"id" => 5})

      refute_received {:typed_handler, _arguments}

      assert %{
               "result" => %{
                 "isError" => true,
                 "content" => [%{"text" => "tool output failed outputSchema"}]
               }
             } = ServerTest.call_tool(server, "typed", %{"id" => "item-1"})

      assert_receive {:typed_handler, %{"id" => "item-1"}}

      assert %{
               "result" => %{
                 "isError" => true,
                 "content" => [%{"text" => "tool execution failed"}]
               }
             } =
               ServerTest.call_tool(server, "failing", %{})

      assert %{"error" => %{"code" => -32603}} = ServerTest.call_tool(server, "raising", %{})

      assert %{
               "result" => %{
                 "isError" => true,
                 "content" => [%{"text" => "tool output was invalid"}]
               }
             } =
               ServerTest.call_tool(server, "non_json", %{})
    end

    test "timeouts are bounded and return the server's timeout error" do
      server = start_server()

      :ok =
        Server.register_tool(server, "sleepy", %{
          handler: fn _arguments, _context ->
            Process.sleep(1_000)
            {:ok, "late"}
          end
        })

      assert %{"error" => %{"code" => -32603, "data" => %{"reason" => "timeout"}}} =
               ServerTest.call_tool(server, "sleepy", %{}, timeout: 50)
    end

    test "call_tool keeps its 2.3 defaults" do
      server = start_server()
      parent = self()

      :ok =
        Server.register_tool(server, "context", %{
          handler: fn _arguments, context ->
            send(parent, {:context, context})
            {:ok, "ok"}
          end
        })

      assert %{"jsonrpc" => "2.0", "id" => id, "result" => %{"resultType" => "complete"}} =
               ServerTest.call_tool(server, "context", %{})

      assert is_integer(id)
      assert_receive {:context, context}
      assert context.principal == "test-principal"
      assert context.scopes == []
      refute Map.has_key?(context, :tenant)
      refute Map.has_key?(context, :host_context)
      assert context.protocol_version == @modern

      assert %{"id" => "fixed"} =
               ServerTest.call_tool(server, "context", %{}, request_id: "fixed")
    end

    test "helper metadata reaches handlers alongside the generated protocol keys" do
      server = start_server()
      parent = self()

      :ok =
        Server.register_prompt(server, "meta_prompt", %{
          handler: fn _input, context ->
            send(parent, {:prompt_meta, context.request_meta})
            {:ok, [%{"role" => "user", "content" => %{"type" => "text", "text" => "ok"}}]}
          end
        })

      assert %{"result" => _} =
               ServerTest.get_prompt(server, "meta_prompt", %{},
                 meta: %{"com.example/request-purpose" => "helper"},
                 client_capabilities: %{"sampling" => %{}}
               )

      assert_receive {:prompt_meta, meta}

      assert meta == %{
               "com.example/request-purpose" => "helper",
               "io.modelcontextprotocol/protocolVersion" => @modern,
               "io.modelcontextprotocol/clientCapabilities" => %{"sampling" => %{}}
             }
    end
  end

  describe "setup errors" do
    setup do
      server = start_server()
      :ok = Server.register_tool(server, "alpha", %{handler: fn _, _ -> {:ok, "a"} end})
      %{server: server}
    end

    test "malformed options raise ArgumentError", %{server: server} do
      invalid_calls = [
        fn -> ServerTest.call_tool(server, "alpha", %{}, unknown: true) end,
        fn -> ServerTest.call_tool(server, "alpha", %{}, principal: "a", principal: "b") end,
        fn -> ServerTest.call_tool(server, "alpha", %{}, cursor: "c") end,
        fn -> ServerTest.call_tool(server, "alpha", %{}, scopes: "items.read") end,
        fn -> ServerTest.call_tool(server, "alpha", %{}, timeout: 0) end,
        fn -> ServerTest.list_tools(server, request_state: "state") end,
        fn -> ServerTest.list_tools(server, completion_context: %{}) end,
        fn -> ServerTest.list_tools(server, cursor: 5) end,
        fn -> ServerTest.read_resource(server, "") end,
        fn -> ServerTest.get_prompt(server, "", %{}) end,
        fn -> ServerTest.complete(server, opaque("ref"), %{}) end,
        fn ->
          ServerTest.complete(server, %{"type" => "ref/prompt", "name" => "p"}, %{},
            completion_context: "context"
          )
        end
      ]

      for call <- invalid_calls do
        assert_raise ArgumentError, call
      end
    end

    test "metadata cannot override generated protocol fields", %{server: server} do
      for meta <- [
            %{"io.modelcontextprotocol/protocolVersion" => @legacy},
            %{"io.modelcontextprotocol/clientCapabilities" => %{"sampling" => %{}}},
            %{atom_key: true},
            ["not", "a", "map"]
          ] do
        assert_raise ArgumentError, fn ->
          ServerTest.call_tool(server, "alpha", %{}, meta: meta)
        end
      end

      assert_raise ArgumentError, ~r/protocol_version/, fn ->
        ServerTest.list_tools(server,
          meta: %{"io.modelcontextprotocol/protocolVersion" => @modern}
        )
      end
    end

    test "retry fields require the modern revision and valid types", %{server: server} do
      assert_raise ArgumentError, fn ->
        ServerTest.call_tool(server, "alpha", %{},
          protocol_version: @legacy,
          request_state: "state"
        )
      end

      assert_raise ArgumentError, fn ->
        ServerTest.call_tool(server, "alpha", %{}, request_state: 42)
      end

      assert_raise ArgumentError, fn ->
        ServerTest.call_tool(server, "alpha", %{}, input_responses: [1])
      end
    end

    test "request/4 keeps protocol fields out of params", %{server: server} do
      for key <- ["_meta", "requestState", "inputResponses"] do
        assert_raise ArgumentError, fn ->
          ServerTest.request(server, "tools/list", %{key => %{}})
        end
      end

      assert_raise ArgumentError, fn -> ServerTest.request(server, "", %{}) end
      assert_raise ArgumentError, fn -> ServerTest.request(server, "tools/list", opaque([1])) end
    end

    test "discover is modern-only and values must be JSON", %{server: server} do
      assert_raise ArgumentError, fn ->
        ServerTest.discover(server, protocol_version: @legacy)
      end

      assert_raise ArgumentError, fn ->
        ServerTest.call_tool(server, "alpha", %{"pid" => self()})
      end

      assert_raise ArgumentError, fn ->
        ServerTest.call_tool(server, "alpha", %{}, meta: %{"com.example/pid" => self()})
      end
    end

    test "protocol errors are returned, not raised", %{server: server} do
      assert %{"error" => %{"code" => -32602}} =
               ServerTest.call_tool(server, "missing", %{})

      assert %{"error" => %{"code" => _}} =
               ServerTest.call_tool(server, "alpha", %{}, protocol_version: "1999-01-01")
    end
  end

  # Keeps deliberately invalid setup values opaque to the type checker so the
  # suite still compiles with warnings as errors.
  defp opaque(value), do: Process.get({__MODULE__, :opaque}, value)

  defp collect_pages(list_fun, key, field, cursor \\ nil, acc \\ []) do
    opts = if cursor, do: [cursor: cursor], else: []
    response = list_fun.(opts)
    result = Map.fetch!(response, "result")
    names = Enum.map(Map.fetch!(result, key), & &1[field])
    assert length(names) == 1
    assert result["resultType"] == "complete"
    acc = acc ++ names

    case result["nextCursor"] do
      nil -> acc
      next -> collect_pages(list_fun, key, field, next, acc)
    end
  end
end
