defmodule AttestoMCP.Server.LegacyCoreTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server

  @legacy "2025-11-25"
  @legacy_2025_06_18 "2025-06-18"

  test "legacy ping, logging, and initialization negotiate supported frozen versions" do
    {:ok, server} = Server.start_link([])

    assert {1, %{"result" => %{}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 1, method: "ping", params: %{}},
               %{principal: "legacy"},
               version: @legacy
             )

    assert {2, %{"result" => %{}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 2, method: "logging/setLevel", params: %{"level" => "info"}},
               %{principal: "legacy"},
               version: @legacy
             )

    assert {3, %{"error" => %{"code" => -32602}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 3, method: "logging/setLevel", params: %{"level" => "nope"}},
               %{principal: "legacy"},
               version: @legacy
             )

    assert {4, %{"result" => %{"protocolVersion" => @legacy, "capabilities" => capabilities}}} =
             Server.dispatch(
               server,
               %{
                 kind: :request,
                 id: 4,
                 method: "initialize",
                 params: %{
                   "protocolVersion" => @legacy,
                   "capabilities" => %{},
                   "clientInfo" => %{"name" => "legacy-test", "version" => "1.0"}
                 }
               },
               %{principal: "legacy"},
               version: @legacy
             )

    assert capabilities["resources"]["subscribe"] == true
    assert capabilities["logging"] == %{}

    assert {41, %{"result" => %{"protocolVersion" => @legacy_2025_06_18}}} =
             Server.dispatch(
               server,
               %{
                 kind: :request,
                 id: 41,
                 method: "initialize",
                 params: %{
                   "protocolVersion" => @legacy_2025_06_18,
                   "capabilities" => %{},
                   "clientInfo" => %{"name" => "compat-test", "version" => "1.0"}
                 }
               },
               %{principal: "legacy"},
               version: @legacy_2025_06_18
             )

    assert {5, %{"error" => %{"code" => -32022, "data" => data}}} =
             Server.dispatch(
               server,
               %{
                 kind: :request,
                 id: 5,
                 method: "initialize",
                 params: %{
                   "protocolVersion" => "2026-07-28",
                   "capabilities" => %{},
                   "clientInfo" => %{"name" => "legacy-test", "version" => "1.0"}
                 }
               },
               %{principal: "legacy"},
               version: @legacy
             )

    assert data["requested"] == "2026-07-28"
    assert data["supported"] == [@legacy, @legacy_2025_06_18]
  end

  test "legacy resource subscriptions filter one-route SSE delivery and close on delete" do
    {:ok, server} = Server.start_link([])
    {:ok, session} = Server.new_session(server, "legacy", "tenant")

    assert :ok = Server.negotiate_session(server, session.id, "legacy", "tenant", @legacy, %{})
    assert :ok = Server.mark_initialized(server, session.id)
    assert {:error, :not_found} = Server.get_session(server, session.id, "other", "tenant")
    assert {:error, :not_found} = Server.get_session(server, session.id, "legacy", "other")

    assert {:ok, stream} =
             Server.open_legacy_stream(server, session.id, "legacy", "tenant", self())

    assert {10, %{"result" => %{}}} =
             Server.dispatch(
               server,
               %{
                 kind: :request,
                 id: 10,
                 method: "resources/subscribe",
                 params: %{"uri" => "urn:one"}
               },
               %{
                 principal: "legacy",
                 tenant: "tenant",
                 session_id: session.id,
                 client_capabilities: %{"sampling" => %{}}
               },
               version: @legacy
             )

    Server.publish(server, %{"type" => "resource", "uri" => "urn:other"})
    refute_receive {:mcp_legacy_event, ^stream, _, _}, 100

    Server.publish(server, %{"type" => "resourceSubscriptions", "uri" => "urn:other"})
    refute_receive {:mcp_legacy_event, ^stream, _, _}, 100

    assert {:error, :invalid_notification} =
             Server.publish(server, %{
               "type" => "resource",
               "uri" => "urn:one",
               "_meta" => 5,
               "unexpected" => true
             })

    refute_receive {:mcp_legacy_event, ^stream, _, _}, 100

    Server.publish(server, %{"type" => "resourceSubscriptions", "uri" => "urn:one"})
    assert_receive {:mcp_legacy_event, ^stream, alias_event_id, alias_event}, 1_000
    assert alias_event_id == 1
    assert alias_event["method"] == "notifications/resources/updated"

    Server.publish(server, %{"type" => "resource", "uri" => "urn:one"})
    assert_receive {:mcp_legacy_event, ^stream, event_id, event}, 1_000
    assert event_id == 2
    assert event["method"] == "notifications/resources/updated"

    Server.delete_session(server, session.id)
    assert_receive {:mcp_legacy_close, ^stream, :session_deleted}, 1_000
  end

  test "legacy resource subscriptions bound URI bytes and per-session entries" do
    {:ok, server} = Server.start_link([])
    {:ok, session} = Server.new_session(server, "bounded", nil)

    assert :ok = Server.negotiate_session(server, session.id, "bounded", nil, @legacy, %{})
    assert :ok = Server.mark_initialized(server, session.id)

    assert {:error, :invalid_uri} =
             Server.subscribe_resource(
               server,
               session.id,
               "bounded",
               nil,
               "urn:" <> String.duplicate("x", 4_093)
             )

    for uri <- ["", <<255>>, "urn:bad\0", "urn:bad\r", "urn:bad\n"] do
      assert {:error, :invalid_uri} =
               Server.subscribe_resource(server, session.id, "bounded", nil, uri)
    end

    boundary_uri = "urn:" <> String.duplicate("x", 4_092)
    assert byte_size(boundary_uri) == 4_096
    assert :ok = Server.subscribe_resource(server, session.id, "bounded", nil, boundary_uri)
    assert :ok = Server.unsubscribe_resource(server, session.id, "bounded", nil, boundary_uri)

    backing =
      String.duplicate("p", 100_000) <>
        "urn:" <> String.duplicate("r", 4_092) <> String.duplicate("s", 100_000)

    retained_uri = binary_part(backing, 100_000, 4_096)
    assert :binary.referenced_byte_size(retained_uri) > byte_size(retained_uri)
    assert :ok = Server.subscribe_resource(server, session.id, "bounded", nil, retained_uri)
    assert {:ok, retained} = Server.get_session(server, session.id, "bounded", nil)
    stored_uri = retained.resource_subscriptions |> Map.keys() |> List.first()
    assert stored_uri == retained_uri
    assert :binary.referenced_byte_size(stored_uri) == byte_size(stored_uri)
    assert :ok = Server.unsubscribe_resource(server, session.id, "bounded", nil, retained_uri)

    for index <- 1..128 do
      assert :ok =
               Server.subscribe_resource(
                 server,
                 session.id,
                 "bounded",
                 nil,
                 "urn:bounded:#{index}"
               )
    end

    assert :ok =
             Server.subscribe_resource(server, session.id, "bounded", nil, "urn:bounded:1")

    assert {:error, :limit_reached} =
             Server.subscribe_resource(server, session.id, "bounded", nil, "urn:bounded:129")

    assert {20, %{"error" => %{"code" => -32602, "data" => limit_data}}} =
             Server.dispatch(
               server,
               %{
                 kind: :request,
                 id: 20,
                 method: "resources/subscribe",
                 params: %{"uri" => "urn:bounded:129"}
               },
               %{principal: "bounded", session_id: session.id},
               version: @legacy
             )

    assert limit_data["reason"] == "resource_subscription_limit"
    assert {:ok, current} = Server.get_session(server, session.id, "bounded", nil)
    assert map_size(current.resource_subscriptions) == 128

    assert :ok =
             Server.unsubscribe_resource(server, session.id, "bounded", nil, "urn:bounded:1")

    assert :ok =
             Server.subscribe_resource(server, session.id, "bounded", nil, "urn:bounded:129")
  end

  test "2025-06-18 omits newer catalog icons and rejects newer client-request modes" do
    {:ok, server} = Server.start_link([])

    assert :ok =
             Server.register_tool(server, "versioned", %{
               icons: [%{src: "https://example.test/icon.png"}],
               handler: fn _, _ -> {:ok, "ok"} end
             })

    icon = %{"src" => "https://example.test/icon.png"}

    assert :ok =
             Server.register_tool(server, "versioned_content", %{
               handler: fn _, _ ->
                 {:ok,
                  %{
                    "content" => [
                      %{
                        "type" => "resource_link",
                        "uri" => "https://example.test/resource",
                        "name" => "resource",
                        "icons" => [icon]
                      },
                      %{
                        "type" => "resource",
                        "resource" => %{
                          "uri" => "https://example.test/embedded",
                          "text" => "embedded",
                          "icons" => [icon]
                        }
                      }
                    ]
                  }}
               end
             })

    assert :ok =
             Server.register_resource(server, "https://example.test/resource", %{
               icons: [%{src: "https://example.test/icon.png"}],
               handler: fn _, _ ->
                 {:ok,
                  %{
                    "contents" => [
                      %{
                        "uri" => "https://example.test/resource",
                        "text" => "resource",
                        "icons" => [icon]
                      }
                    ]
                  }}
               end
             })

    assert :ok =
             Server.register_resource_template(server, "https://example.test/{id}", %{
               icons: [%{src: "https://example.test/icon.png"}]
             })

    assert :ok =
             Server.register_prompt(server, "versioned_prompt", %{
               icons: [%{src: "https://example.test/icon.png"}],
               handler: fn _, _ ->
                 {:ok,
                  %{
                    "messages" => [
                      %{
                        "role" => "user",
                        "content" => %{
                          "type" => "resource_link",
                          "uri" => "https://example.test/resource",
                          "name" => "resource",
                          "icons" => [icon]
                        }
                      }
                    ]
                  }}
               end
             })

    list = %{kind: :request, id: 50, method: "tools/list", params: %{}}

    assert {50, %{"result" => %{"tools" => older_tools}}} =
             Server.dispatch(server, list, %{principal: "older"}, version: @legacy_2025_06_18)

    older = Enum.find(older_tools, &(&1["name"] == "versioned"))
    refute Map.has_key?(older, "icons")

    assert {50, %{"result" => %{"tools" => newer_tools}}} =
             Server.dispatch(server, list, %{principal: "newer"}, version: @legacy)

    newer = Enum.find(newer_tools, &(&1["name"] == "versioned"))
    assert is_list(newer["icons"])

    catalogs = [
      {"resources/list", "resources", "uri", "https://example.test/resource"},
      {"resources/templates/list", "resourceTemplates", "uriTemplate",
       "https://example.test/{id}"},
      {"prompts/list", "prompts", "name", "versioned_prompt"}
    ]

    Enum.with_index(catalogs, 60)
    |> Enum.each(fn {{method, result_key, identity_key, identity}, id} ->
      request = %{kind: :request, id: id, method: method, params: %{}}

      assert {^id, %{"result" => %{^result_key => older_items}}} =
               Server.dispatch(server, request, %{principal: "older"},
                 version: @legacy_2025_06_18
               )

      older_item = Enum.find(older_items, &(Map.get(&1, identity_key) == identity))
      refute Map.has_key?(older_item, "icons")

      assert {^id, %{"result" => %{^result_key => newer_items}}} =
               Server.dispatch(server, request, %{principal: "newer"}, version: @legacy)

      newer_item = Enum.find(newer_items, &(Map.get(&1, identity_key) == identity))
      assert newer_item["icons"] == [icon]
    end)

    call = %{
      kind: :request,
      id: 51,
      method: "tools/call",
      params: %{"name" => "versioned_content", "arguments" => %{}}
    }

    assert {51, %{"result" => %{"content" => [older_link, older_embedded]}}} =
             Server.dispatch(server, call, %{principal: "older"}, version: @legacy_2025_06_18)

    refute Map.has_key?(older_link, "icons")
    refute Map.has_key?(older_embedded["resource"], "icons")

    assert {51, %{"result" => %{"content" => [newer_link, newer_embedded]}}} =
             Server.dispatch(server, call, %{principal: "newer"}, version: @legacy)

    assert newer_link["icons"] == [icon]
    assert newer_embedded["resource"]["icons"] == [icon]

    read = %{
      kind: :request,
      id: 52,
      method: "resources/read",
      params: %{"uri" => "https://example.test/resource"}
    }

    assert {52, %{"result" => %{"contents" => [older_resource]}}} =
             Server.dispatch(server, read, %{principal: "older"}, version: @legacy_2025_06_18)

    refute Map.has_key?(older_resource, "icons")

    assert {52, %{"result" => %{"contents" => [newer_resource]}}} =
             Server.dispatch(server, read, %{principal: "newer"}, version: @legacy)

    assert newer_resource["icons"] == [icon]

    get_prompt = %{
      kind: :request,
      id: 53,
      method: "prompts/get",
      params: %{"name" => "versioned_prompt", "arguments" => %{}}
    }

    assert {53, %{"result" => %{"messages" => [%{"content" => older_prompt_content}]}}} =
             Server.dispatch(server, get_prompt, %{principal: "older"},
               version: @legacy_2025_06_18
             )

    refute Map.has_key?(older_prompt_content, "icons")

    assert {53, %{"result" => %{"messages" => [%{"content" => newer_prompt_content}]}}} =
             Server.dispatch(server, get_prompt, %{principal: "newer"}, version: @legacy)

    assert newer_prompt_content["icons"] == [icon]

    {:ok, session} = Server.new_session(server, "older", "tenant")

    assert :ok =
             Server.negotiate_session(
               server,
               session.id,
               "older",
               "tenant",
               @legacy_2025_06_18,
               %{"sampling" => %{}, "elicitation" => %{}}
             )

    assert :ok = Server.mark_initialized(server, session.id)

    assert {:ok, _stream} =
             Server.open_legacy_stream(server, session.id, "older", "tenant", self())

    assert {:error, :unsupported} =
             Server.request_client(
               server,
               session.id,
               "older",
               "tenant",
               "elicitation/create",
               %{
                 "mode" => "url",
                 "url" => "https://example.test/continue",
                 "message" => "Continue"
               },
               100
             )

    assert {:error, :unsupported} =
             Server.request_client(
               server,
               session.id,
               "older",
               "tenant",
               "sampling/createMessage",
               %{"messages" => [], "toolChoice" => %{"mode" => "none"}},
               100
             )

    assert {:error, :unsupported} =
             Server.request_client(
               server,
               session.id,
               "older",
               "tenant",
               "elicitation/create",
               %{
                 "mode" => "form",
                 "message" => "Continue",
                 "requestedSchema" => %{"type" => "object"}
               },
               100
             )

    assert {:error, :unsupported} =
             Server.request_client(
               server,
               session.id,
               "older",
               "tenant",
               "sampling/createMessage",
               %{"messages" => [], "tools" => []},
               100
             )

    refute_receive {:mcp_legacy_event, _, _, _}, 50
  end

  test "session version setter rejects unknown revisions and negotiated changes" do
    {:ok, server} = Server.start_link([])
    {:ok, session} = Server.new_session(server, "legacy", nil)

    assert {:error, :invalid_version} = Server.set_session_version(server, session.id, "unknown")
    assert :ok = Server.set_session_version(server, session.id, @legacy_2025_06_18)
    assert {:error, :invalid_version} = Server.set_session_version(server, session.id, @legacy)
  end

  test "session negotiation is single-use and cannot replace revision or capabilities" do
    {:ok, server} = Server.start_link([])
    {:ok, session} = Server.new_session(server, "legacy", nil)
    capabilities = %{"elicitation" => %{}}

    assert :ok =
             Server.negotiate_session(
               server,
               session.id,
               "legacy",
               nil,
               @legacy_2025_06_18,
               capabilities
             )

    assert {:error, :already_negotiated} =
             Server.negotiate_session(server, session.id, "legacy", nil, @legacy, %{})

    assert {:ok, retained} = Server.get_session(server, session.id, "legacy", nil)
    assert retained.version == @legacy_2025_06_18
    assert retained.client_capabilities == capabilities

    request = %{kind: :request, id: 54, method: "tools/list", params: %{}}

    assert {54, %{"error" => %{"code" => -32600, "data" => binding_error}}} =
             Server.dispatch(
               server,
               request,
               %{
                 principal: "legacy",
                 session_id: session.id,
                 protocol_version: @legacy_2025_06_18
               },
               version: @legacy
             )

    assert binding_error["reason"] == "negotiated_version_mismatch"
  end

  test "legacy server-originated requests require initialized negotiated capability and route responses" do
    {:ok, server} = Server.start_link([])
    {:ok, session} = Server.new_session(server, "legacy", "tenant")

    assert :ok =
             Server.negotiate_session(
               server,
               session.id,
               "legacy",
               "tenant",
               @legacy,
               %{"sampling" => %{}}
             )

    assert {:error, :not_found} =
             Server.open_legacy_stream(server, session.id, "legacy", "tenant", self())

    assert :ok = Server.mark_initialized(server, session.id)

    assert {:ok, stream} =
             Server.open_legacy_stream(server, session.id, "legacy", "tenant", self())

    parent = self()

    assert :ok =
             Server.register_tool(server, "asks_client", %{
               input_schema: %{"type" => "object"},
               handler: fn _arguments, context ->
                 result = context.client_request.("sampling/createMessage", %{"messages" => []})
                 send(parent, {:client_result, result})
                 {:ok, "done"}
               end
             })

    dispatch =
      spawn(fn ->
        send(
          parent,
          {:dispatch,
           Server.dispatch(
             server,
             %{
               kind: :request,
               id: 20,
               method: "tools/call",
               params: %{"name" => "asks_client", "arguments" => %{}}
             },
             %{principal: "legacy", tenant: "tenant", session_id: session.id},
             version: @legacy
           )}
        )
      end)

    {_event_id, request} = receive_legacy_server_request(stream)
    assert request["method"] == "sampling/createMessage"
    request_id = request["id"]

    assert :ok =
             Server.deliver_client_response(
               server,
               session.id,
               "legacy",
               "tenant",
               %{
                 kind: :response,
                 id: request_id,
                 result: %{
                   "role" => "assistant",
                   "content" => %{"type" => "text", "text" => "ok"},
                   "model" => "legacy-model",
                   "stopReason" => "endTurn"
                 },
                 error: nil
               }
             )

    assert_receive {:client_result,
                    {:ok,
                     %{
                       "role" => "assistant",
                       "content" => %{"type" => "text", "text" => "ok"},
                       "model" => "legacy-model",
                       "stopReason" => "endTurn"
                     }}},
                   1_000

    assert_receive {:dispatch, {20, %{"result" => %{"content" => _}}}}, 1_000
    refute Process.alive?(dispatch)

    assert {:error, :not_found} =
             Server.deliver_client_response(
               server,
               session.id,
               "legacy",
               "tenant",
               %{kind: :response, id: request_id, result: %{}, error: nil}
             )
  end

  test "100 randomized legacy session and stream ownership iterations stay bounded" do
    {:ok, server} = Server.start_link([])
    random = :rand.seed_s(:exsplus, {17, 29, 41})

    {_random, count} =
      Enum.reduce(1..100, {random, 0}, fn index, {rand, count} ->
        {:ok, session} = Server.new_session(server, "owner-#{index}", "tenant-#{rem(index, 3)}")

        assert :ok =
                 Server.negotiate_session(
                   server,
                   session.id,
                   session.principal,
                   session.tenant,
                   @legacy,
                   %{}
                 )

        assert :ok = Server.mark_initialized(server, session.id)

        assert {:ok, stream} =
                 Server.open_legacy_stream(
                   server,
                   session.id,
                   session.principal,
                   session.tenant,
                   self()
                 )

        {choice, rand} = :rand.uniform_s(3, rand)

        case choice do
          1 ->
            Server.publish(server, %{"type" => "toolsListChanged"})
            assert :ok = Server.delete_session(server, session.id)
            assert_receive {:mcp_legacy_close, ^stream, :session_deleted}, 1_000

          2 ->
            assert :ok = Server.close_legacy_stream(server, stream)
            assert :ok = Server.delete_session(server, session.id)

          3 ->
            assert :ok = Server.delete_session(server, session.id)
            assert_receive {:mcp_legacy_close, ^stream, :session_deleted}, 1_000
        end

        assert {:error, :not_found} =
                 Server.get_session(server, session.id, session.principal, session.tenant)

        {rand, count + 1}
      end)

    assert count == 100
  end

  test "legacy server requests return typed sampling, elicitation, and roots results" do
    {:ok, server} = Server.start_link(client_request_timeout: 25)
    {:ok, session} = Server.new_session(server, "legacy", "tenant")

    assert :ok =
             Server.negotiate_session(
               server,
               session.id,
               "legacy",
               "tenant",
               @legacy,
               %{"sampling" => %{}, "elicitation" => %{}, "roots" => %{}}
             )

    assert :ok = Server.mark_initialized(server, session.id)

    assert {:ok, stream} =
             Server.open_legacy_stream(server, session.id, "legacy", "tenant", self())

    parent = self()

    methods = [
      {"sample", "sampling/createMessage",
       %{
         "messages" => [],
         "tools" => [%{"name" => "lookup", "inputSchema" => %{"type" => "object"}}],
         "toolChoice" => %{"mode" => "auto"}
       }},
      {"elicit", "elicitation/create",
       %{
         "mode" => "form",
         "message" => "confirm",
         "requestedSchema" => %{"type" => "object"}
       }},
      {"roots", "roots/list", %{}}
    ]

    Enum.each(methods, fn {name, method, params} ->
      assert :ok =
               Server.register_tool(server, name, %{
                 input_schema: %{"type" => "object"},
                 handler: fn _arguments, context ->
                   result = context.client_request.(method, params)
                   send(parent, {:handler_result, name, result})
                   {:ok, "complete"}
                 end
               })
    end)

    dispatches =
      Enum.map(methods, fn {name, _method, _params} ->
        spawn(fn ->
          send(
            parent,
            {:dispatch_result, name,
             Server.dispatch(
               server,
               %{
                 kind: :request,
                 id: name,
                 method: "tools/call",
                 params: %{"name" => name, "arguments" => %{}}
               },
               %{principal: "legacy", tenant: "tenant", session_id: session.id},
               version: @legacy
             )}
          )
        end)
      end)

    requests =
      Enum.map(1..3, fn _ ->
        {_event_id, request} = receive_legacy_server_request(stream)
        {request["id"], request["method"], request["params"]}
      end)

    assert {_id, "sampling/createMessage", %{"tools" => [_], "toolChoice" => %{"mode" => "auto"}}} =
             Enum.find(requests, fn {_id, method, _params} ->
               method == "sampling/createMessage"
             end)

    assert {_id, "elicitation/create", %{"mode" => "form", "requestedSchema" => %{}}} =
             Enum.find(requests, fn {_id, method, _params} -> method == "elicitation/create" end)

    Enum.each(requests, fn
      {id, "sampling/createMessage", _params} ->
        assert :ok =
                 Server.deliver_client_response(server, session.id, "legacy", "tenant", %{
                   kind: :response,
                   id: id,
                   result: %{
                     "role" => "assistant",
                     "content" => %{"type" => "text", "text" => "ok"},
                     "model" => "model",
                     "stopReason" => "endTurn"
                   },
                   error: nil
                 })

      _ ->
        :ok
    end)

    Enum.each(requests, fn
      {id, "elicitation/create", _params} ->
        assert :ok =
                 Server.deliver_client_response(server, session.id, "legacy", "tenant", %{
                   kind: :response,
                   id: id,
                   result: %{"action" => "accept", "content" => %{"answer" => "yes"}},
                   error: nil
                 })

      {id, "roots/list", _params} ->
        assert :ok =
                 Server.deliver_client_response(server, session.id, "legacy", "tenant", %{
                   kind: :response,
                   id: id,
                   result: %{"roots" => [%{"uri" => "file:///workspace", "name" => "workspace"}]},
                   error: nil
                 })

      _ ->
        :ok
    end)

    assert_receive {:handler_result, "sample", {:ok, %{"role" => "assistant"}}}, 1_000
    assert_receive {:handler_result, "elicit", {:ok, %{"action" => "accept"}}}, 1_000
    assert_receive {:handler_result, "roots", {:ok, %{"roots" => [_]}}}, 1_000

    Enum.each(dispatches, fn _pid ->
      assert_receive {:dispatch_result, _name, {_id, %{"result" => %{"content" => _}}}}, 1_000
    end)
  end

  test "legacy server request errors, invalid results, and expiry are correlated" do
    {:ok, server} = Server.start_link(client_request_timeout: 20)
    {:ok, session} = Server.new_session(server, "legacy", "tenant")

    assert :ok =
             Server.negotiate_session(
               server,
               session.id,
               "legacy",
               "tenant",
               @legacy,
               %{"sampling" => %{}}
             )

    assert :ok = Server.mark_initialized(server, session.id)

    assert {:ok, stream} =
             Server.open_legacy_stream(server, session.id, "legacy", "tenant", self())

    parent = self()

    for {name, mode} <- [{"error", :error}, {"invalid", :invalid}, {"timeout", :timeout}] do
      assert :ok =
               Server.register_tool(server, name, %{
                 input_schema: %{"type" => "object"},
                 handler: fn _arguments, context ->
                   result = context.client_request.("sampling/createMessage", %{"messages" => []})
                   send(parent, {:handler_result, name, result})
                   {:ok, Atom.to_string(mode)}
                 end
               })
    end

    spawn(fn ->
      Server.dispatch(
        server,
        %{
          kind: :request,
          id: "error",
          method: "tools/call",
          params: %{"name" => "error", "arguments" => %{}}
        },
        %{principal: "legacy", tenant: "tenant", session_id: session.id},
        version: @legacy
      )
    end)

    {_event_id, error_request} = receive_legacy_server_request(stream)

    assert {:error, {:client_error, %{"code" => -1, "message" => "declined"}}} =
             Server.deliver_client_response(server, session.id, "legacy", "tenant", %{
               kind: :response,
               id: error_request["id"],
               result: nil,
               error: %{"code" => -1, "message" => "declined"}
             })

    assert_receive {:handler_result, "error", {:error, {:client_error, %{"code" => -1}}}}, 1_000

    spawn(fn ->
      Server.dispatch(
        server,
        %{
          kind: :request,
          id: "invalid",
          method: "tools/call",
          params: %{"name" => "invalid", "arguments" => %{}}
        },
        %{principal: "legacy", tenant: "tenant", session_id: session.id},
        version: @legacy
      )
    end)

    {_event_id, invalid_request} = receive_legacy_server_request(stream)

    assert {:error, :invalid_response} =
             Server.deliver_client_response(server, session.id, "legacy", "tenant", %{
               kind: :response,
               id: invalid_request["id"],
               result: %{"role" => "assistant"},
               error: nil
             })

    assert_receive {:handler_result, "invalid", {:error, :invalid_response}}, 1_000

    spawn(fn ->
      Server.dispatch(
        server,
        %{
          kind: :request,
          id: "timeout",
          method: "tools/call",
          params: %{"name" => "timeout", "arguments" => %{}}
        },
        %{principal: "legacy", tenant: "tenant", session_id: session.id},
        version: @legacy
      )
    end)

    {_event_id, timeout_request} = receive_legacy_server_request(stream)
    assert_receive {:handler_result, "timeout", {:error, :timeout}}, 1_000

    assert {:error, :not_found} =
             Server.deliver_client_response(server, session.id, "legacy", "tenant", %{
               kind: :response,
               id: timeout_request["id"],
               result: %{
                 "role" => "assistant",
                 "content" => %{"type" => "text", "text" => "late"},
                 "model" => "model",
                 "stopReason" => "endTurn"
               },
               error: nil
             })
  end

  defp receive_legacy_server_request(stream) do
    receive do
      {:mcp_legacy_event, ^stream, event_id, %{"method" => method} = request}
      when method in ["sampling/createMessage", "elicitation/create", "roots/list"] ->
        {event_id, request}

      {:mcp_legacy_event, ^stream, _event_id, _notification} ->
        receive_legacy_server_request(stream)
    after
      1_000 ->
        flunk("timed out waiting for a legacy server request")
    end
  end
end
