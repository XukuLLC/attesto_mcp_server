defmodule AttestoMCP.Server.P10P13RegressionTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server

  @modern "2026-07-28"
  @legacy "2025-11-25"

  defp modern(extra) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => @modern,
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    Map.put(
      Map.put(extra, "_meta", Map.merge(meta, Map.get(extra, "_meta", %{}))),
      "_meta",
      Map.merge(meta, Map.get(extra, "_meta", %{}))
    )
  end

  defp dispatch(server, id, method, params, version, context \\ %{principal: "p"}) do
    Server.dispatch(
      server,
      %{kind: :request, id: id, method: method, params: params},
      context,
      version: version
    )
  end

  test "completion registration and requests require dated references and typed arguments" do
    {:ok, server} = Server.start_link([])

    assert {:error, {:invalid_definition, :completion_ref}} =
             Server.register_completion(server, "missing", %{handler: fn _, _ -> {:ok, []} end})

    assert {:error, {:invalid_definition, :completion_ref}} =
             Server.register_completion(server, "binary", %{
               ref: "prompt",
               handler: fn _, _ -> {:ok, []} end
             })

    assert :ok =
             Server.register_completion(server, "topic", %{
               ref: %{type: "ref/prompt", name: "prompt"},
               handler: fn %{value: value}, _ -> {:ok, [value <> "-one", value <> "-two"]} end
             })

    assert :ok =
             Server.register_completion(server, "duplicates", %{
               ref: %{type: "ref/prompt", name: "duplicate-prompt"},
               handler: fn _, _ -> {:ok, %{"values" => ["same", "same"], "total" => 2}} end
             })

    assert {1, %{"result" => %{"resultType" => "complete", "completion" => completion}}} =
             dispatch(
               server,
               1,
               "completion/complete",
               modern(%{
                 "ref" => %{"type" => "ref/prompt", "name" => "prompt"},
                 "argument" => %{"name" => "topic", "value" => "a"},
                 "context" => %{"arguments" => %{"topic" => "a"}}
               }),
               @modern
             )

    assert completion["values"] == ["a-one", "a-two"]
    assert completion["total"] == 2
    refute Map.has_key?(completion, "resultType")

    assert {5,
            %{
              "result" => %{
                "completion" => %{"values" => ["same"], "total" => 2, "hasMore" => true}
              }
            }} =
             dispatch(
               server,
               5,
               "completion/complete",
               modern(%{
                 "ref" => %{"type" => "ref/prompt", "name" => "duplicate-prompt"},
                 "argument" => %{"name" => "topic", "value" => "a"}
               }),
               @modern
             )

    assert {2, %{"error" => %{"code" => -32602}}} =
             dispatch(
               server,
               2,
               "completion/complete",
               modern(%{
                 "ref" => %{"type" => "ref/prompt", "name" => "prompt"},
                 "argument" => %{"value" => "a"}
               }),
               @modern
             )

    assert {3, %{"error" => %{"code" => -32602}}} =
             dispatch(
               server,
               3,
               "completion/complete",
               modern(%{
                 "ref" => %{"type" => "ref/prompt", "name" => "prompt"},
                 "argument" => %{"name" => "topic", "value" => "a"},
                 "context" => %{"arguments" => %{"topic" => 1}}
               }),
               @modern
             )

    assert {4, %{"result" => legacy}} =
             dispatch(
               server,
               4,
               "completion/complete",
               %{
                 "ref" => %{"type" => "ref/prompt", "name" => "prompt"},
                 "argument" => %{"name" => "topic", "value" => "a"}
               },
               @legacy
             )

    refute Map.has_key?(legacy, "resultType")
  end

  test "modern metadata is required and every successful result receives serverInfo" do
    {:ok, server} = Server.start_link([])

    assert {1, %{"error" => %{"code" => -32602}}} =
             dispatch(server, 1, "tools/list", %{}, @modern)

    assert :ok =
             Server.register_tool(server, "one", %{
               handler: fn _, _ -> {:ok, "ok"} end
             })

    assert :ok =
             Server.register_tool(server, "custom", %{
               handler: fn _, _ ->
                 {:ok,
                  %{
                    "content" => [%{"type" => "text", "text" => "ok"}],
                    "isError" => false,
                    "_meta" => %{
                      "io.modelcontextprotocol/serverInfo" => %{
                        "name" => "custom",
                        "version" => "v"
                      }
                    }
                  }}
               end
             })

    assert :ok =
             Server.register_resource(server, "urn:one", %{
               handler: fn _, _ -> {:ok, [%{"uri" => "urn:one", "text" => "ok"}]} end
             })

    assert :ok =
             Server.register_prompt(server, "one-prompt", %{
               arguments: [%{name: "topic", required: true}],
               handler: fn _, _ ->
                 {:ok, [%{"role" => "user", "content" => %{"type" => "text", "text" => "ok"}}]}
               end
             })

    assert :ok =
             Server.register_completion(server, "one-completion", %{
               ref: %{type: "ref/prompt", name: "one-prompt"},
               handler: fn _, _ -> {:ok, ["ok"]} end
             })

    requests = [
      {2, "tools/list", modern(%{})},
      {3, "resources/list", modern(%{})},
      {4, "resources/read", modern(%{"uri" => "urn:one"})},
      {5, "prompts/list", modern(%{})},
      {6, "prompts/get", modern(%{"name" => "one-prompt", "arguments" => %{"topic" => "x"}})},
      {7, "completion/complete",
       modern(%{
         "ref" => %{"type" => "ref/prompt", "name" => "one-prompt"},
         "argument" => %{"name" => "topic", "value" => "x"}
       })}
    ]

    for {id, method, params} <- requests do
      assert {^id, %{"result" => %{"_meta" => %{"io.modelcontextprotocol/serverInfo" => info}}}} =
               dispatch(server, id, method, params, @modern)

      assert is_binary(info["name"])
      assert is_binary(info["version"])
    end

    assert {8, %{"result" => %{"_meta" => %{"io.modelcontextprotocol/serverInfo" => authored}}}} =
             dispatch(
               server,
               8,
               "tools/call",
               modern(%{"name" => "custom", "arguments" => %{}}),
               @modern
             )

    assert authored == %{"name" => "custom", "version" => "v"}
  end

  test "legacy initialize validates required fields and omits nil instructions" do
    {:ok, server} = Server.start_link([])

    for params <- [
          %{},
          %{"protocolVersion" => @legacy},
          %{"protocolVersion" => @legacy, "capabilities" => []}
        ] do
      assert {1, %{"error" => %{"code" => -32602}}} =
               dispatch(server, 1, "initialize", params, @legacy, %{principal: "legacy"})
    end

    valid = %{
      "protocolVersion" => @legacy,
      "capabilities" => %{},
      "clientInfo" => %{"name" => "client", "version" => "1"}
    }

    assert {2, %{"result" => result}} =
             dispatch(server, 2, "initialize", valid, @legacy, %{principal: "legacy"})

    assert result["protocolVersion"] == @legacy
    refute Map.has_key?(result, "instructions")
    refute Map.has_key?(result, "resultType")

    modern_initialize = %{
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => @modern,
        "io.modelcontextprotocol/clientCapabilities" => %{}
      }
    }

    assert {3, %{"error" => %{"code" => -32601}}} =
             dispatch(server, 3, "initialize", modern_initialize, @modern)
  end

  test "MRTR accepts only schema-valid requests and typed responses" do
    {:ok, server} = Server.start_link([])

    assert :ok =
             Server.register_tool(server, "url-input", %{
               handler: fn args, _ ->
                 if Map.has_key?(args, "url") do
                   {:ok, "accepted"}
                 else
                   {:input_required,
                    %{
                      "url" => %{
                        "method" => "elicitation/create",
                        "params" => %{
                          "mode" => "url",
                          "message" => "open",
                          "url" => "https://example.test/form"
                        }
                      }
                    }}
                 end
               end
             })

    capable =
      modern(%{
        "name" => "url-input",
        "arguments" => %{},
        "_meta" => %{"io.modelcontextprotocol/clientCapabilities" => %{"elicitation" => %{}}}
      })

    assert {1,
            %{
              "result" => %{
                "resultType" => "input_required",
                "inputRequests" => requests,
                "requestState" => state
              }
            }} =
             dispatch(server, 1, "tools/call", capable, @modern)

    assert requests["url"]["params"]["mode"] == "url"

    assert {2, %{"result" => %{"resultType" => "complete"}}} =
             dispatch(
               server,
               2,
               "tools/call",
               Map.merge(capable, %{
                 "requestState" => state,
                 "inputResponses" => %{"url" => %{"action" => "decline"}}
               }),
               @modern
             )

    assert :ok =
             Server.register_tool(server, "bad-input", %{
               handler: fn _, _ ->
                 {:input_required,
                  %{
                    "bad" => %{
                      "method" => "sampling/createMessage",
                      "params" => %{
                        "messages" => [
                          %{"role" => "system", "content" => %{"type" => "text", "text" => "x"}}
                        ]
                      }
                    }
                  }}
               end
             })

    assert {3, %{"error" => %{"code" => -32602}}} =
             dispatch(server, 3, "tools/call", Map.put(capable, "name", "bad-input"), @modern)
  end

  test "subscription wire messages carry honored filters and only graceful results expose correlation" do
    {:ok, server} = Server.start_link([])
    parent = self()

    params = modern(%{"notifications" => %{"toolsListChanged" => true}})

    assert {11, %{"result" => %{"resultType" => "complete", "_meta" => meta} = result}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 11, method: "subscriptions/listen", params: params},
               %{principal: "sub"},
               version: @modern,
               on_event: fn event -> send(parent, {:subscription_event, event}) end
             )

    assert meta["io.modelcontextprotocol/subscriptionId"] == 11
    assert is_map(meta["io.modelcontextprotocol/serverInfo"])
    refute Map.has_key?(result, "subscriptionId")

    assert_receive {:subscription_event, acknowledgment}
    assert acknowledgment["method"] == "notifications/subscriptions/acknowledged"
    assert get_in(acknowledgment, ["params", "notifications", "toolsListChanged"]) == true

    assert get_in(acknowledgment, ["params", "_meta", "io.modelcontextprotocol/subscriptionId"]) ==
             11

    :ok = Server.publish(server, %{"type" => "toolsListChanged"})
    assert_receive {:mcp_subscription, _, 11, event}
    assert event["method"] == "notifications/tools/list_changed"
    assert get_in(event, ["params", "_meta", "io.modelcontextprotocol/subscriptionId"]) == 11

    Server.ack_subscription(server, 11)
    :ok = Server.close_subscription(server, 11)
    assert_receive {:mcp_subscription_close, 11}

    assert {12, %{"error" => %{"code" => -32602}}} =
             dispatch(
               server,
               12,
               "subscriptions/listen",
               modern(%{"notifications" => %{"resourceSubscriptions" => "not-a-list"}}),
               @modern,
               %{principal: "sub"}
             )
  end
end
