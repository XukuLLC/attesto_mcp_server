defmodule AttestoMCP.Server.P1AMRTRTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server

  @version "2026-07-28"

  defp modern(extra) do
    Map.merge(
      %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @version,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      },
      extra
    )
  end

  defp start_server do
    {:ok, server} = Server.start_link(max_concurrency: 8)
    server
  end

  test "tools MRTR uses server keys, validates capabilities, retry IDs, and ignores extras" do
    server = start_server()

    :ok =
      Server.register_tool(server, "multi", %{
        input_schema: %{"type" => "object"},
        handler: fn args, _ ->
          if Map.has_key?(args, "client_choice") and Map.has_key?(args, "client_context"),
            do: {:ok, args},
            else:
              {:input_required,
               %{
                 "client_choice" => %{
                   "method" => "elicitation/create",
                   "params" => %{
                     "message" => "choose",
                     "requestedSchema" => %{"type" => "object"}
                   }
                 },
                 "client_context" => %{
                   "method" => "sampling/createMessage",
                   "params" => %{"messages" => []}
                 }
               }}
        end
      })

    base = modern(%{"name" => "multi", "arguments" => %{}})

    assert {1, %{"error" => %{"code" => -32021, "data" => %{"requiredCapabilities" => required}}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 1, method: "tools/call", params: base},
               %{principal: "mrtr"},
               version: @version
             )

    assert Map.has_key?(required, "elicitation")

    capable =
      put_in(
        base,
        ["_meta", "io.modelcontextprotocol/clientCapabilities"],
        %{"elicitation" => %{}, "sampling" => %{}}
      )

    assert {2,
            %{
              "result" => %{
                "resultType" => "input_required",
                "inputRequests" => requests,
                "requestState" => state
              }
            }} =
             Server.dispatch(
               server,
               %{kind: :request, id: 2, method: "tools/call", params: capable},
               %{principal: "mrtr"},
               version: @version
             )

    assert Map.keys(requests) |> Enum.sort() == ["client_choice", "client_context"]
    assert requests["client_choice"]["method"] == "elicitation/create"
    assert requests["client_context"]["method"] == "sampling/createMessage"
    refute Map.has_key?(requests["client_choice"], "key")

    retry =
      Map.merge(capable, %{
        "requestState" => state,
        "inputResponses" => %{"client_choice" => "ok"}
      })

    assert {2, %{"error" => %{"code" => -32602}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 2, method: "tools/call", params: retry},
               %{principal: "mrtr"},
               version: @version
             )

    assert {4, %{"error" => %{"code" => -32602}}} =
             Server.dispatch(
               server,
               %{
                 kind: :request,
                 id: 4,
                 method: "tools/call",
                 params:
                   Map.merge(retry, %{
                     "inputResponses" => %{
                       "client_choice" => %{"action" => "accept", "content" => %{}},
                       "unexpected" => true
                     }
                   })
               },
               %{principal: "mrtr"},
               version: @version
             )

    assert {5,
            %{"error" => %{"code" => -32602, "data" => %{"reason" => "invalid_input_response"}}}} =
             Server.dispatch(
               server,
               %{
                 kind: :request,
                 id: 5,
                 method: "tools/call",
                 params:
                   Map.merge(retry, %{
                     "inputResponses" => %{
                       "client_choice" => %{"action" => "accept", "content" => %{}},
                       "client_context" => "not-a-sampling-result"
                     }
                   })
               },
               %{principal: "mrtr"},
               version: @version
             )

    valid_retry =
      Map.put(
        retry,
        "inputResponses",
        %{
          "client_choice" => %{"action" => "accept", "content" => %{"choice" => "ok"}},
          "client_context" => %{
            "role" => "assistant",
            "content" => %{"type" => "text", "text" => "context"},
            "model" => "model-a",
            "stopReason" => "endTurn"
          },
          "unrecognized" => "ignored"
        }
      )

    assert {3, %{"result" => %{"resultType" => "complete"}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 3, method: "tools/call", params: valid_retry},
               %{principal: "mrtr"},
               version: @version
             )
  end

  test "list-form MRTR requests receive deterministic generated keys" do
    server = start_server()

    :ok =
      Server.register_tool(server, "list-inputs", %{
        input_schema: %{"type" => "object"},
        handler: fn _, _ ->
          {:input_required,
           [
             %{
               "method" => "elicitation/create",
               "params" => %{
                 "message" => "choose",
                 "requestedSchema" => %{"type" => "object"}
               }
             },
             %{"method" => "roots/list", "params" => %{}}
           ]}
        end
      })

    params =
      modern(%{
        "name" => "list-inputs",
        "arguments" => %{},
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @version,
          "io.modelcontextprotocol/clientCapabilities" => %{
            "elicitation" => %{},
            "roots" => %{}
          }
        }
      })

    assert {77, %{"result" => %{"inputRequests" => requests}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 77, method: "tools/call", params: params},
               %{principal: "list"},
               version: @version
             )

    assert Map.keys(requests) |> Enum.sort() == ["input_1", "input_2"]
    assert requests["input_1"]["method"] == "elicitation/create"
    assert requests["input_2"]["method"] == "roots/list"
  end

  test "resources and prompts bind operation identity and request type capability" do
    server = start_server()

    :ok =
      Server.register_resource(server, "urn:mrtr", %{
        handler: fn params, _ ->
          if Map.has_key?(params, "roots"),
            do: {:ok, [%{"uri" => "urn:mrtr", "text" => "done"}]},
            else: {:input_required, %{"roots" => %{"method" => "roots/list", "params" => %{}}}}
        end
      })

    :ok =
      Server.register_prompt(server, "mrtr-prompt", %{
        handler: fn %{arguments: arguments}, _ ->
          if Map.has_key?(arguments, "sample"),
            do: {:ok, [%{"role" => "user", "content" => %{"type" => "text", "text" => "done"}}]},
            else:
              {:input_required,
               %{
                 "sample" => %{
                   "method" => "sampling/createMessage",
                   "params" => %{
                     "messages" => [
                       %{"role" => "user", "content" => %{"type" => "text", "text" => "sample"}}
                     ]
                   }
                 }
               }}
        end
      })

    resource =
      modern(%{
        "uri" => "urn:mrtr",
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @version,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      })

    assert {10, %{"error" => %{"code" => -32021}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 10, method: "resources/read", params: resource},
               %{principal: "mrtr"},
               version: @version
             )

    resource_capable =
      put_in(resource, ["_meta", "io.modelcontextprotocol/clientCapabilities", "roots"], %{})

    assert {11,
            %{
              "result" => %{
                "requestState" => resource_state,
                "inputRequests" => resource_requests
              }
            }} =
             Server.dispatch(
               server,
               %{kind: :request, id: 11, method: "resources/read", params: resource_capable},
               %{principal: "mrtr"},
               version: @version
             )

    [resource_key] = Map.keys(resource_requests)

    assert {12, %{"result" => %{"contents" => _}}} =
             Server.dispatch(
               server,
               %{
                 kind: :request,
                 id: 12,
                 method: "resources/read",
                 params:
                   Map.merge(resource_capable, %{
                     "requestState" => resource_state,
                     "inputResponses" => %{
                       resource_key => %{"roots" => [%{"uri" => "file:///tmp"}]}
                     }
                   })
               },
               %{principal: "mrtr"},
               version: @version
             )

    prompt =
      modern(%{
        "name" => "mrtr-prompt",
        "arguments" => %{},
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @version,
          "io.modelcontextprotocol/clientCapabilities" => %{"sampling" => %{}}
        }
      })

    assert {13,
            %{"result" => %{"requestState" => prompt_state, "inputRequests" => prompt_requests}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 13, method: "prompts/get", params: prompt},
               %{principal: "mrtr"},
               version: @version
             )

    [prompt_key] = Map.keys(prompt_requests)

    assert {14, %{"result" => %{"messages" => _}}} =
             Server.dispatch(
               server,
               %{
                 kind: :request,
                 id: 14,
                 method: "prompts/get",
                 params:
                   Map.merge(prompt, %{
                     "requestState" => prompt_state,
                     "inputResponses" => %{
                       prompt_key => %{
                         "role" => "assistant",
                         "content" => %{"type" => "text", "text" => "answer"},
                         "model" => "model-b",
                         "stopReason" => "endTurn"
                       }
                     }
                   })
               },
               %{principal: "mrtr"},
               version: @version
             )
  end

  test "tools MRTR supports multiple typed rounds with fresh state and IDs" do
    server = start_server()

    :ok =
      Server.register_tool(server, "rounds", %{
        input_schema: %{"type" => "object"},
        handler: fn args, _context ->
          cond do
            is_map(args["second"]) and Map.has_key?(args["second"], "roots") ->
              {:ok, args}

            Map.has_key?(args, "first") ->
              {:input_required, %{"second" => %{"method" => "roots/list", "params" => %{}}}}

            true ->
              {:input_required,
               %{
                 "first" => %{
                   "method" => "elicitation/create",
                   "params" => %{
                     "message" => "first round",
                     "requestedSchema" => %{"type" => "object"}
                   }
                 }
               }}
          end
        end
      })

    params =
      modern(%{
        "name" => "rounds",
        "arguments" => %{},
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @version,
          "io.modelcontextprotocol/clientCapabilities" => %{
            "elicitation" => %{},
            "roots" => %{}
          }
        }
      })

    assert {60, %{"result" => %{"requestState" => state_one, "inputRequests" => requests_one}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 60, method: "tools/call", params: params},
               %{principal: "rounds"},
               version: @version
             )

    [first_key] = Map.keys(requests_one)
    assert requests_one[first_key]["method"] == "elicitation/create"

    first_response = %{"action" => "accept", "content" => %{"value" => "yes"}}

    retry_one =
      Map.merge(params, %{
        "requestState" => state_one,
        "inputResponses" => %{first_key => first_response}
      })

    assert {61,
            %{
              "result" => %{
                "resultType" => "input_required",
                "requestState" => state_two,
                "inputRequests" => requests_two
              }
            }} =
             Server.dispatch(
               server,
               %{kind: :request, id: 61, method: "tools/call", params: retry_one},
               %{principal: "rounds"},
               version: @version
             )

    [second_key] = Map.keys(requests_two)
    assert requests_two[second_key]["method"] == "roots/list"

    assert {62, %{"error" => %{"code" => -32602}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 62, method: "tools/call", params: retry_one},
               %{principal: "rounds"},
               version: @version
             )

    assert {63,
            %{"error" => %{"code" => -32602, "data" => %{"reason" => "invalid_input_response"}}}} =
             Server.dispatch(
               server,
               %{
                 kind: :request,
                 id: 63,
                 method: "tools/call",
                 params:
                   Map.merge(params, %{
                     "requestState" => state_two,
                     "inputResponses" => %{second_key => first_response}
                   })
               },
               %{principal: "rounds"},
               version: @version
             )

    assert {64, %{"result" => %{"resultType" => "complete"}}} =
             Server.dispatch(
               server,
               %{
                 kind: :request,
                 id: 64,
                 method: "tools/call",
                 params:
                   Map.merge(params, %{
                     "requestState" => state_two,
                     "inputResponses" => %{
                       second_key => %{"roots" => [%{"uri" => "file:///workspace/round-two"}]}
                     }
                   })
               },
               %{principal: "rounds"},
               version: @version
             )
  end

  test "request state rejects operation replay and tampering" do
    state =
      AttestoMCP.Server.RequestState.issue(
        "alice",
        "tenant",
        @version,
        "tools/call",
        %{"name" => "one"},
        request_id: 1,
        operation_identity: %{"tool" => "one"},
        input_keys: ["input_1"]
      )

    assert {:error, :invalid_request_state} =
             AttestoMCP.Server.RequestState.verify_payload(
               state,
               "alice",
               "tenant",
               @version,
               "tools/call",
               %{"name" => "one"},
               request_id: 2,
               operation_identity: %{"tool" => "two"},
               responses: %{"input_1" => true}
             )

    assert {:error, :invalid_request_state} =
             AttestoMCP.Server.RequestState.verify_payload(
               state,
               "alice",
               "tenant",
               @version,
               "tools/call",
               %{"name" => "changed"},
               request_id: 2,
               operation_identity: %{"tool" => "one"},
               responses: %{"input_1" => true}
             )
  end

  test "protocol retry state binds principal, tenant, method, operation, tampering, replay, and expiry" do
    server = start_server()

    :ok =
      Server.register_tool(server, "bound", %{
        input_schema: %{"type" => "object"},
        handler: fn args, _ ->
          if Map.has_key?(args, "input"),
            do: {:ok, "accepted"},
            else:
              {:input_required,
               %{
                 "input" => %{
                   "method" => "elicitation/create",
                   "params" => %{
                     "message" => "answer",
                     "requestedSchema" => %{"type" => "object"}
                   }
                 }
               }}
        end
      })

    :ok =
      Server.register_tool(server, "other", %{
        input_schema: %{"type" => "object"},
        handler: fn _, _ -> {:ok, "other"} end
      })

    params =
      modern(%{
        "name" => "bound",
        "arguments" => %{},
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @version,
          "io.modelcontextprotocol/clientCapabilities" => %{"elicitation" => %{}}
        }
      })

    assert {30, %{"result" => %{"requestState" => state, "inputRequests" => requests}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 30, method: "tools/call", params: params},
               %{principal: "alice", tenant: "tenant-a"},
               version: @version
             )

    [key] = Map.keys(requests)
    typed_response = %{"action" => "accept", "content" => %{}}

    retry_params =
      Map.merge(params, %{"requestState" => state, "inputResponses" => %{key => typed_response}})

    for {id, context} <- [
          {31, %{principal: "bob", tenant: "tenant-a"}},
          {32, %{principal: "alice", tenant: "tenant-b"}}
        ] do
      assert {^id, %{"error" => %{"code" => -32602}}} =
               Server.dispatch(
                 server,
                 %{kind: :request, id: id, method: "tools/call", params: retry_params},
                 context,
                 version: @version
               )
    end

    assert {33, %{"error" => %{"code" => -32602}}} =
             Server.dispatch(
               server,
               %{
                 kind: :request,
                 id: 33,
                 method: "tools/call",
                 params: Map.put(retry_params, "name", "other")
               },
               %{principal: "alice", tenant: "tenant-a"},
               version: @version
             )

    assert {34, %{"error" => %{"code" => -32602}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 34, method: "prompts/get", params: retry_params},
               %{principal: "alice", tenant: "tenant-a"},
               version: @version
             )

    state_size = byte_size(state)
    <<first::binary-size(^state_size - 1), last>> = state
    tampered = first <> <<Bitwise.bxor(last, 1)>>

    assert {35, %{"error" => %{"code" => -32602}}} =
             Server.dispatch(
               server,
               %{
                 kind: :request,
                 id: 35,
                 method: "tools/call",
                 params: Map.put(retry_params, "requestState", tampered)
               },
               %{principal: "alice", tenant: "tenant-a"},
               version: @version
             )

    assert {36, %{"result" => %{"resultType" => "complete"}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 36, method: "tools/call", params: retry_params},
               %{principal: "alice", tenant: "tenant-a"},
               version: @version
             )

    assert {37, %{"error" => %{"code" => -32602}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 37, method: "tools/call", params: retry_params},
               %{principal: "alice", tenant: "tenant-a"},
               version: @version
             )

    expiring = start_server_with_ttl(1)

    :ok =
      Server.register_tool(expiring, "expire", %{
        input_schema: %{"type" => "object"},
        handler: fn args, _ ->
          if Map.has_key?(args, "x"),
            do: {:ok, "done"},
            else:
              {:input_required,
               %{
                 "x" => %{
                   "method" => "elicitation/create",
                   "params" => %{
                     "message" => "expire",
                     "requestedSchema" => %{"type" => "object"}
                   }
                 }
               }}
        end
      })

    expiring_params =
      modern(%{
        "name" => "expire",
        "arguments" => %{},
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @version,
          "io.modelcontextprotocol/clientCapabilities" => %{"elicitation" => %{}}
        }
      })

    assert {40,
            %{
              "result" => %{
                "requestState" => expiring_state,
                "inputRequests" => expiring_requests
              }
            }} =
             Server.dispatch(
               expiring,
               %{kind: :request, id: 40, method: "tools/call", params: expiring_params},
               %{principal: "alice"},
               version: @version
             )

    [expiring_key] = Map.keys(expiring_requests)
    Process.sleep(5)

    assert {41, %{"error" => %{"code" => -32602}}} =
             Server.dispatch(
               expiring,
               %{
                 kind: :request,
                 id: 41,
                 method: "tools/call",
                 params:
                   Map.merge(expiring_params, %{
                     "requestState" => expiring_state,
                     "inputResponses" => %{expiring_key => typed_response}
                   })
               },
               %{principal: "alice"},
               version: @version
             )
  end

  defp start_server_with_ttl(ttl) do
    {:ok, server} = Server.start_link(max_concurrency: 8, request_state_ttl: ttl)
    server
  end
end
