defmodule AttestoMCP.Server.ScopePolicyAcceptanceTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AttestoMCP.Server

  @resource "https://mcp.example.com/mcp"
  @modern "2026-07-28"
  @legacy "2025-11-25"
  @legacy_2025_06_18 "2025-06-18"
  @documents "documents.read"
  @reports "reports.read"
  @policy %{
    "tools/list" => :visible_definitions,
    "tools/call" => :selected_definition,
    "resources/list" => :visible_definitions,
    "resources/templates/list" => :visible_definitions,
    "resources/read" => :selected_definition
  }

  setup do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    parent = self()

    assert :ok =
             Server.register_tool(server, "documents", %{
               required_scopes: [@documents],
               handler: fn _arguments, _context ->
                 send(parent, {:scope_policy_handler, :documents})
                 {:ok, "documents"}
               end
             })

    assert :ok =
             Server.register_tool(server, "reports", %{
               required_scopes: [@reports],
               handler: fn _arguments, _context ->
                 send(parent, {:scope_policy_handler, :reports})
                 {:ok, "reports"}
               end
             })

    assert :ok =
             Server.register_resource(server, "urn:documents", %{
               required_scopes: [@documents],
               handler: fn _arguments, _context ->
                 send(parent, {:scope_policy_handler, :resource_documents})
                 {:ok, %{"contents" => [%{"uri" => "urn:documents", "text" => "documents"}]}}
               end
             })

    assert :ok =
             Server.register_resource_template(server, "urn:documents/{id}", %{
               required_scopes: [@documents],
               handler: fn %{params: %{"id" => id}}, _context ->
                 send(parent, {:scope_policy_handler, :template_documents})
                 {:ok, %{"contents" => [%{"uri" => "urn:documents/" <> id, "text" => id}]}}
               end
             })

    assert :ok =
             Server.register_resource(server, "urn:reports", %{
               required_scopes: [@reports],
               handler: fn _arguments, _context ->
                 send(parent, {:scope_policy_handler, :resource_reports})
                 {:ok, %{"contents" => [%{"uri" => "urn:reports", "text" => "reports"}]}}
               end
             })

    # The denied exact static must not fall through to this visible template.
    assert :ok =
             Server.register_resource(server, "urn:shared/item", %{
               required_scopes: [@reports],
               handler: fn _arguments, _context ->
                 send(parent, {:scope_policy_handler, :overlap_static})
                 {:ok, %{"contents" => [%{"uri" => "urn:shared/item", "text" => "static"}]}}
               end
             })

    assert :ok =
             Server.register_resource_template(server, "urn:shared/{id}", %{
               required_scopes: [@documents],
               handler: fn _arguments, _context ->
                 send(parent, {:scope_policy_handler, :overlap_template})
                 {:ok, %{"contents" => [%{"uri" => "urn:shared/item", "text" => "template"}]}}
               end
             })

    on_exit(fn ->
      if Process.alive?(server) do
        try do
          GenServer.stop(server)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    %{server: server, config: config}
  end

  test "modern catalogs and selected calls/read use definition scopes", %{
    server: server,
    config: config
  } do
    plug = plug(server, config)
    documents = token(config, [@documents])
    reports = token(config, [@reports])

    listed = http_call(plug, documents, @modern, "tools/list", %{})
    assert listed.status == 200
    assert names(listed, "tools") == ["documents"]

    inverse = http_call(plug, reports, @modern, "tools/list", %{})
    assert inverse.status == 200
    assert names(inverse, "tools") == ["reports"]

    resources = http_call(plug, documents, @modern, "resources/list", %{})
    assert resources.status == 200
    assert uris(resources, "resources") == ["urn:documents"]

    inverse_resources = http_call(plug, reports, @modern, "resources/list", %{})
    assert inverse_resources.status == 200
    assert uris(inverse_resources, "resources") == ["urn:reports", "urn:shared/item"]

    templates = http_call(plug, documents, @modern, "resources/templates/list", %{})
    assert templates.status == 200
    assert uris(templates, "resourceTemplates") == ["urn:documents/{id}", "urn:shared/{id}"]

    inverse_templates = http_call(plug, reports, @modern, "resources/templates/list", %{})
    assert inverse_templates.status == 200
    assert uris(inverse_templates, "resourceTemplates") == []

    assert http_call(plug, documents, @modern, "tools/call", %{
             "name" => "documents",
             "arguments" => %{}
           }).status == 200

    denied_call =
      http_call(plug, documents, @modern, "tools/call", %{
        "name" => "reports",
        "arguments" => %{}
      })

    assert denied_call.status == 200
    assert Jason.decode!(denied_call.resp_body)["error"]["code"] == -32602
    refute_receive {:scope_policy_handler, :reports}

    denied_notification =
      http_call(
        plug,
        documents,
        @modern,
        "tools/call",
        %{
          "name" => "reports",
          "arguments" => %{}
        },
        id: nil
      )

    assert denied_notification.status == 202
    refute_receive {:scope_policy_handler, :reports}

    static = http_call(plug, documents, @modern, "resources/read", %{"uri" => "urn:documents"})
    assert static.status == 200
    assert Jason.decode!(static.resp_body)["result"]["contents"] != []
    assert_receive {:scope_policy_handler, :resource_documents}

    template =
      http_call(plug, documents, @modern, "resources/read", %{
        "uri" => "urn:documents/alpha"
      })

    assert template.status == 200
    assert Jason.decode!(template.resp_body)["result"]["contents"] != []
    assert_receive {:scope_policy_handler, :template_documents}

    hidden_resource =
      http_call(plug, documents, @modern, "resources/read", %{"uri" => "urn:reports"})

    assert hidden_resource.status == 200
    assert Jason.decode!(hidden_resource.resp_body)["error"]["code"] == -32602
    refute_receive {:scope_policy_handler, :resource_reports}

    overlap =
      http_call(plug, documents, @modern, "resources/read", %{"uri" => "urn:shared/item"})

    assert overlap.status == 200
    assert Jason.decode!(overlap.resp_body)["error"]["code"] == -32602
    refute_receive {:scope_policy_handler, :overlap_static}
    refute_receive {:scope_policy_handler, :overlap_template}

    overlap_notification =
      http_call(plug, documents, @modern, "resources/read", %{"uri" => "urn:shared/item"},
        id: nil
      )

    assert overlap_notification.status == 202
    refute_receive {:scope_policy_handler, :overlap_static}
    refute_receive {:scope_policy_handler, :overlap_template}
  end

  test "selected policy does not fall through a denied first matching template", %{
    server: server,
    config: config
  } do
    parent = self()

    assert :ok =
             Server.register_resource_template(server, "urn:ordered/{first}", %{
               required_scopes: [@reports],
               handler: fn _arguments, _context ->
                 send(parent, {:scope_policy_handler, :ordered_first})
                 {:ok, %{"contents" => [%{"uri" => "urn:ordered/item", "text" => "first"}]}}
               end
             })

    assert :ok =
             Server.register_resource_template(server, "urn:ordered/{second}", %{
               required_scopes: [@documents],
               handler: fn _arguments, _context ->
                 send(parent, {:scope_policy_handler, :ordered_second})
                 {:ok, %{"contents" => [%{"uri" => "urn:ordered/item", "text" => "second"}]}}
               end
             })

    response =
      plug(server, config)
      |> http_call(token(config, [@documents]), @modern, "resources/read", %{
        "uri" => "urn:ordered/item"
      })

    assert response.status == 200
    assert Jason.decode!(response.resp_body)["error"]["code"] == -32602
    refute_receive {:scope_policy_handler, :ordered_first}
    refute_receive {:scope_policy_handler, :ordered_second}
  end

  test "legacy sessions apply the same catalog and selected-definition decisions", %{
    server: server,
    config: config
  } do
    plug = plug(server, config)
    documents = token(config, [@documents])

    for version <- [@legacy, @legacy_2025_06_18] do
      initialized =
        http_call(plug, documents, version, "initialize", %{
          "protocolVersion" => version,
          "capabilities" => %{},
          "clientInfo" => %{"name" => "scope-policy", "version" => "1"}
        })

      assert initialized.status == 200
      session = initialized |> get_resp_header("mcp-session-id") |> List.first()
      assert is_binary(session)

      assert http_call(plug, documents, version, "notifications/initialized", %{},
               session_id: session,
               id: nil
             ).status == 202

      listed = http_call(plug, documents, version, "tools/list", %{}, session_id: session)
      assert listed.status == 200
      assert names(listed, "tools") == ["documents"]

      resources = http_call(plug, documents, version, "resources/list", %{}, session_id: session)
      assert resources.status == 200
      assert uris(resources, "resources") == ["urn:documents"]

      inverse_session =
        http_call(plug, token(config, [@reports]), version, "initialize", %{
          "protocolVersion" => version,
          "capabilities" => %{},
          "clientInfo" => %{"name" => "scope-policy-inverse", "version" => "1"}
        })
        |> get_resp_header("mcp-session-id")
        |> List.first()

      assert is_binary(inverse_session)

      assert http_call(plug, token(config, [@reports]), version, "notifications/initialized", %{},
               session_id: inverse_session,
               id: nil
             ).status == 202

      inverse_resources =
        http_call(plug, token(config, [@reports]), version, "resources/list", %{},
          session_id: inverse_session
        )

      assert inverse_resources.status == 200
      assert uris(inverse_resources, "resources") == ["urn:reports", "urn:shared/item"]

      inverse_templates =
        http_call(plug, token(config, [@reports]), version, "resources/templates/list", %{},
          session_id: inverse_session
        )

      assert inverse_templates.status == 200
      assert uris(inverse_templates, "resourceTemplates") == []

      templates =
        http_call(plug, documents, version, "resources/templates/list", %{}, session_id: session)

      assert templates.status == 200
      assert Jason.decode!(templates.resp_body)["result"]["resourceTemplates"] != []

      static =
        http_call(plug, documents, version, "resources/read", %{"uri" => "urn:documents"},
          session_id: session
        )

      assert static.status == 200
      assert Jason.decode!(static.resp_body)["result"]["contents"] != []

      template =
        http_call(
          plug,
          documents,
          version,
          "resources/read",
          %{"uri" => "urn:documents/legacy"},
          session_id: session
        )

      assert template.status == 200
      assert Jason.decode!(template.resp_body)["result"]["contents"] != []

      called =
        http_call(
          plug,
          documents,
          version,
          "tools/call",
          %{
            "name" => "reports",
            "arguments" => %{}
          },
          session_id: session
        )

      assert called.status == 200
      assert Jason.decode!(called.resp_body)["error"]["code"] == -32602
      refute_receive {:scope_policy_handler, :reports}

      notification =
        http_call(
          plug,
          documents,
          version,
          "tools/call",
          %{"name" => "reports", "arguments" => %{}},
          session_id: session,
          id: nil
        )

      assert notification.status == 202
      refute_receive {:scope_policy_handler, :reports}
    end
  end

  test "selected authorization runs before MRTR retry-state consumption" do
    {:ok, server} = Server.start_link([])
    parent = self()

    assert :ok =
             Server.register_tool(server, "retry", %{
               required_scopes: [@documents],
               handler: fn arguments, _context ->
                 send(parent, {:retry_handler, arguments})

                 if Map.has_key?(arguments, "answer"),
                   do: {:ok, "accepted"},
                   else:
                     {:input_required,
                      %{
                        "answer" => %{
                          "method" => "elicitation/create",
                          "params" => %{
                            "message" => "answer",
                            "requestedSchema" => %{"type" => "object"}
                          }
                        }
                      }}
               end
             })

    params = %{
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => @modern,
        "io.modelcontextprotocol/clientCapabilities" => %{"elicitation" => %{}}
      },
      "name" => "retry",
      "arguments" => %{}
    }

    allowed = fn required -> if required == [@documents], do: :ok, else: :denied end

    assert {1, %{"result" => %{"requestState" => request_state}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 1, method: "tools/call", params: params},
               %{principal: "mrtr", scopes: [@documents]},
               version: @modern,
               definition_authorizer: allowed
             )

    assert_receive {:retry_handler, %{}}, 1_000

    denied =
      Server.dispatch(
        server,
        %{
          kind: :request,
          id: 2,
          method: "tools/call",
          params:
            Map.merge(params, %{
              "requestState" => request_state,
              "inputResponses" => %{"answer" => %{"action" => "accept", "content" => %{}}}
            })
        },
        %{principal: "mrtr", scopes: [@documents]},
        version: @modern,
        definition_authorizer: fn _ -> :denied end
      )

    assert {2, %{"error" => %{"code" => -32602}}} = denied
    refute_receive {:retry_handler, _}

    assert {3, %{"result" => %{"resultType" => "complete"}}} =
             Server.dispatch(
               server,
               %{
                 kind: :request,
                 id: 3,
                 method: "tools/call",
                 params:
                   Map.merge(params, %{
                     "requestState" => request_state,
                     "inputResponses" => %{"answer" => %{"action" => "accept", "content" => %{}}}
                   })
               },
               %{principal: "mrtr", scopes: [@documents]},
               version: @modern,
               definition_authorizer: allowed
             )

    assert_receive {:retry_handler, %{"answer" => _}}, 1_000
  end

  test "selected resource authorization runs before MRTR retry-state consumption" do
    {:ok, server} = Server.start_link([])
    parent = self()

    assert :ok =
             Server.register_resource(server, "retry-resource", %{
               uri: "urn:retry-resource",
               required_scopes: [@documents],
               handler: fn arguments, _context ->
                 send(parent, {:retry_resource_handler, arguments})

                 if Map.has_key?(arguments, "answer"),
                   do: {:ok, %{"contents" => [%{"uri" => "urn:retry-resource", "text" => "ok"}]}},
                   else:
                     {:input_required,
                      %{
                        "answer" => %{
                          "method" => "elicitation/create",
                          "params" => %{
                            "message" => "answer",
                            "requestedSchema" => %{"type" => "object"}
                          }
                        }
                      }}
               end
             })

    params = %{
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => @modern,
        "io.modelcontextprotocol/clientCapabilities" => %{"elicitation" => %{}}
      },
      "uri" => "urn:retry-resource"
    }

    allowed = fn required -> if required == [@documents], do: :ok, else: :denied end

    assert {1, %{"result" => %{"requestState" => request_state}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 1, method: "resources/read", params: params},
               %{principal: "resource-mrtr", scopes: [@documents]},
               version: @modern,
               definition_authorizer: allowed
             )

    assert_receive {:retry_resource_handler, %{uri: "urn:retry-resource", params: %{}}}, 1_000

    denied =
      Server.dispatch(
        server,
        %{
          kind: :request,
          id: 2,
          method: "resources/read",
          params:
            Map.merge(params, %{
              "requestState" => request_state,
              "inputResponses" => %{"answer" => %{"action" => "accept", "content" => %{}}}
            })
        },
        %{principal: "resource-mrtr", scopes: [@documents]},
        version: @modern,
        definition_authorizer: fn _ -> :denied end
      )

    assert {2, %{"error" => %{"code" => -32602}}} = denied
    refute_receive {:retry_resource_handler, _}

    assert {3, %{"result" => %{"resultType" => "complete"}}} =
             Server.dispatch(
               server,
               %{
                 kind: :request,
                 id: 3,
                 method: "resources/read",
                 params:
                   Map.merge(params, %{
                     "requestState" => request_state,
                     "inputResponses" => %{"answer" => %{"action" => "accept", "content" => %{}}}
                   })
               },
               %{principal: "resource-mrtr", scopes: [@documents]},
               version: @modern,
               definition_authorizer: allowed
             )

    assert_receive {:retry_resource_handler, %{"answer" => _}}, 1_000
  end

  test "default dispatch evaluates each definition callback once" do
    {:ok, server} = Server.start_link([])
    parent = self()

    assert :ok =
             Server.register_tool(server, "default-tool", %{
               authorize: fn _context ->
                 send(parent, :default_tool_authorized)
                 true
               end,
               handler: fn _arguments, _context -> {:ok, "ok"} end
             })

    assert :ok =
             Server.register_resource(server, "urn:default", %{
               authorize: fn _context ->
                 send(parent, :default_resource_authorized)
                 true
               end,
               handler: fn _arguments, _context ->
                 {:ok, %{"contents" => [%{"uri" => "urn:default", "text" => "ok"}]}}
               end
             })

    params = %{
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => @modern,
        "io.modelcontextprotocol/clientCapabilities" => %{}
      }
    }

    assert {1, %{"result" => %{"resultType" => "complete"}}} =
             Server.dispatch(
               server,
               %{
                 kind: :request,
                 id: 1,
                 method: "tools/call",
                 params:
                   Map.merge(params, %{
                     "name" => "default-tool",
                     "arguments" => %{}
                   })
               },
               %{principal: "default"},
               version: @modern
             )

    assert_receive :default_tool_authorized, 1_000
    refute_receive :default_tool_authorized

    assert {2, %{"result" => %{"resultType" => "complete"}}} =
             Server.dispatch(
               server,
               %{
                 kind: :request,
                 id: 2,
                 method: "resources/read",
                 params:
                   Map.merge(params, %{
                     "uri" => "urn:default"
                   })
               },
               %{principal: "default"},
               version: @modern
             )

    assert_receive :default_resource_authorized, 1_000
    refute_receive :default_resource_authorized
  end

  test "default tool lookup retains visible duplicate fallback" do
    {:ok, server} = Server.start_link([])
    parent = self()

    assert :ok =
             Server.register_tool(server, "hidden-duplicate", %{
               name: "duplicate",
               required_scopes: [@reports],
               handler: fn _arguments, _context ->
                 send(parent, :hidden_duplicate)
                 {:ok, "hidden"}
               end
             })

    assert :ok =
             Server.register_tool(server, "visible-duplicate", %{
               name: "duplicate",
               handler: fn _arguments, _context ->
                 send(parent, :visible_duplicate)
                 {:ok, "visible"}
               end
             })

    params = %{
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => @modern,
        "io.modelcontextprotocol/clientCapabilities" => %{}
      },
      "name" => "duplicate",
      "arguments" => %{}
    }

    assert {1, %{"result" => %{"resultType" => "complete"}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 1, method: "tools/call", params: params},
               %{principal: "duplicate"},
               version: @modern
             )

    assert_receive :visible_duplicate, 1_000
    refute_receive :hidden_duplicate
  end

  test "unscoped definitions are authenticated-only only under explicit policy", %{
    server: server,
    config: config
  } do
    parent = self()

    assert :ok =
             Server.register_tool(server, "authenticated-only", %{
               handler: fn _arguments, _context ->
                 send(parent, :authenticated_only_handler)
                 {:ok, "ok"}
               end
             })

    documents = token(config, [@documents])

    default_plug =
      Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource]
      )

    denied =
      http_call(default_plug, documents, @modern, "tools/call", %{
        "name" => "authenticated-only",
        "arguments" => %{}
      })

    assert denied.status == 403
    refute_receive :authenticated_only_handler

    allowed =
      http_call(plug(server, config), documents, @modern, "tools/call", %{
        "name" => "authenticated-only",
        "arguments" => %{}
      })

    assert allowed.status == 200
    assert_receive :authenticated_only_handler
  end

  test "definition authorize callbacks false or raise remain neutral and skip handlers", %{
    server: server,
    config: config
  } do
    parent = self()

    assert :ok =
             Server.register_tool(server, "authorize-false", %{
               required_scopes: [@documents],
               authorize: fn _context -> false end,
               handler: fn _arguments, _context ->
                 send(parent, :authorize_false_handler)
                 {:ok, "unexpected"}
               end
             })

    assert :ok =
             Server.register_tool(server, "authorize-raise", %{
               required_scopes: [@documents],
               authorize: fn _context -> raise "authorization callback failure" end,
               handler: fn _arguments, _context ->
                 send(parent, :authorize_raise_handler)
                 {:ok, "unexpected"}
               end
             })

    assert :ok =
             Server.register_resource(server, "authorize-false-resource", %{
               uri: "urn:authorize-false",
               required_scopes: [@documents],
               authorize: fn _context -> false end,
               handler: fn _arguments, _context ->
                 send(parent, :authorize_false_resource_handler)
                 {:ok, %{"contents" => []}}
               end
             })

    assert :ok =
             Server.register_resource(server, "authorize-raise-resource", %{
               uri: "urn:authorize-raise",
               required_scopes: [@documents],
               authorize: fn _context -> raise "authorization callback failure" end,
               handler: fn _arguments, _context ->
                 send(parent, :authorize_raise_resource_handler)
                 {:ok, %{"contents" => []}}
               end
             })

    plug = plug(server, config)
    documents = token(config, [@documents])

    listed = http_call(plug, documents, @modern, "tools/list", %{})
    assert listed.status == 200
    refute "authorize-false" in names(listed, "tools")
    refute "authorize-raise" in names(listed, "tools")

    for name <- ["authorize-false", "authorize-raise"] do
      response =
        http_call(plug, documents, @modern, "tools/call", %{
          "name" => name,
          "arguments" => %{}
        })

      assert response.status == 200
      assert Jason.decode!(response.resp_body)["error"]["code"] == -32602
    end

    for uri <- ["urn:authorize-false", "urn:authorize-raise"] do
      response = http_call(plug, documents, @modern, "resources/read", %{"uri" => uri})
      assert response.status == 200
      assert Jason.decode!(response.resp_body)["error"]["code"] == -32602
    end

    refute_receive :authorize_false_handler
    refute_receive :authorize_raise_handler
    refute_receive :authorize_false_resource_handler
    refute_receive :authorize_raise_resource_handler
  end

  test "hidden and missing selected definitions have identical neutral responses", %{
    server: server,
    config: config
  } do
    plug = plug(server, config)
    documents = token(config, [@documents])

    hidden_tool =
      http_call(
        plug,
        documents,
        @modern,
        "tools/call",
        %{
          "name" => "reports",
          "arguments" => %{}
        },
        id: 700
      )

    missing_tool =
      http_call(
        plug,
        documents,
        @modern,
        "tools/call",
        %{
          "name" => "does-not-exist",
          "arguments" => %{}
        },
        id: 700
      )

    assert hidden_tool.status == missing_tool.status
    assert get_resp_header(hidden_tool, "www-authenticate") == []

    assert get_resp_header(hidden_tool, "www-authenticate") ==
             get_resp_header(missing_tool, "www-authenticate")

    hidden_tool_error = Jason.decode!(hidden_tool.resp_body)["error"]
    missing_tool_error = Jason.decode!(missing_tool.resp_body)["error"]
    assert hidden_tool_error["code"] == missing_tool_error["code"]
    assert hidden_tool_error["data"]["reason"] == "unknown_tool"
    assert missing_tool_error["data"]["reason"] == "unknown_tool"

    assert Map.drop(hidden_tool_error["data"], ["name"]) ==
             Map.drop(missing_tool_error["data"], ["name"])

    hidden_resource =
      http_call(plug, documents, @modern, "resources/read", %{"uri" => "urn:reports"}, id: 701)

    missing_resource =
      http_call(plug, documents, @modern, "resources/read", %{"uri" => "urn:missing"}, id: 701)

    assert hidden_resource.status == missing_resource.status
    assert get_resp_header(hidden_resource, "www-authenticate") == []

    assert get_resp_header(hidden_resource, "www-authenticate") ==
             get_resp_header(missing_resource, "www-authenticate")

    hidden_resource_error = Jason.decode!(hidden_resource.resp_body)["error"]
    missing_resource_error = Jason.decode!(missing_resource.resp_body)["error"]
    assert hidden_resource_error["code"] == missing_resource_error["code"]
    assert hidden_resource_error["data"] == %{"uri" => "urn:reports"}
    assert missing_resource_error["data"] == %{"uri" => "urn:missing"}
  end

  test "named-server policy overlap fails closed before authentication and explicit map replaces it",
       %{
         config: config
       } do
    name = String.to_atom("scope_policy_server_#{System.unique_integer([:positive])}")

    plug =
      Server.Plug.init(
        server: name,
        path: "/mcp",
        auth: [config: config, resource: @resource],
        scope_policy: %{"tools/call" => :selected_definition}
      )

    {:ok, first_server} = Server.start_link(name: name, scope_map: %{"tools/call" => []})
    GenServer.stop(first_server)
    {:ok, server} = Server.start_link(name: name, scope_map: %{"tools/call" => []})

    malformed =
      conn(:post, "/mcp", "not-json")
      |> put_req_header("authorization", "not-a-token")
      |> put_req_header("content-type", "application/json")

    failed = Server.Plug.call(malformed, plug)
    assert failed.status == 500
    assert %Plug.Conn.Unfetched{} = failed.body_params

    replacement_plug =
      Server.Plug.init(
        server: name,
        path: "/mcp",
        auth: [config: config, resource: @resource],
        scope_map: %{},
        scope_policy: %{"tools/call" => :selected_definition}
      )

    response =
      http_call(
        replacement_plug,
        token(config, [@documents]),
        @modern,
        "tools/call",
        %{"name" => "missing", "arguments" => %{}}
      )

    assert response.status == 200
    assert Jason.decode!(response.resp_body)["error"]["code"] == -32602

    GenServer.stop(server)
  end

  test "definition policy preserves DPoP and mTLS binding checks once", %{
    server: server,
    config: config
  } do
    {:ok, replay_count} = Agent.start_link(fn -> 0 end)

    replay_check = fn _key, _ttl ->
      Agent.update(replay_count, &(&1 + 1))
      :ok
    end

    jwk = JOSE.JWK.generate_key({:ec, :secp256r1})
    {_unused, jkt} = AttestoMCP.Test.Factory.dpop_proof("placeholder", jwk: jwk)

    dpop_token =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [@documents],
        dpop_jkt: jkt
      )

    {proof, ^jkt} = AttestoMCP.Test.Factory.dpop_proof(dpop_token, jwk: jwk, htu: @resource)

    dpop_plug =
      Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [
          config: config,
          resource: @resource,
          replay_check: replay_check,
          htu: fn _conn -> @resource end
        ],
        scope_policy: %{"tools/call" => :selected_definition}
      )

    dpop_response =
      http_call(dpop_plug, {:dpop, dpop_token, proof}, @modern, "tools/call", %{
        "name" => "documents",
        "arguments" => %{}
      })

    assert dpop_response.status == 200
    assert Agent.get(replay_count, & &1) == 1

    cert = AttestoMCP.Test.Factory.self_signed_cert_der()
    {:ok, thumbprint} = Attesto.MTLS.compute_thumbprint(cert)
    {:ok, cert_count} = Agent.start_link(fn -> 0 end)

    mtls_plug =
      Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [
          config: config,
          resource: @resource,
          cert_der: fn _conn ->
            Agent.update(cert_count, &(&1 + 1))
            cert
          end
        ],
        scope_policy: %{"tools/call" => :selected_definition}
      )

    mtls_token =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [@documents],
        mtls_cert_thumbprint: thumbprint
      )

    mtls_response =
      http_call(mtls_plug, mtls_token, @modern, "tools/call", %{
        "name" => "documents",
        "arguments" => %{}
      })

    assert mtls_response.status == 200
    assert Agent.get(cert_count, & &1) == 1
  end

  test "unresolved principals fail before reading the body", %{
    server: server,
    config: config
  } do
    access_token = token(config, [@documents])

    unresolved_plug =
      Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [
          config: config,
          resource: @resource,
          principal: fn _claims, _sender -> {:error, :unresolved_principal} end
        ],
        scope_policy: %{"tools/call" => :selected_definition}
      )

    unresolved = Server.Plug.call(unread_request(access_token), unresolved_plug)
    assert unresolved.status == 401
    assert %Plug.Conn.Unfetched{} = unresolved.body_params
  end

  test "scope policy values and scope-map overlap are rejected at Plug init", %{
    server: server,
    config: config
  } do
    base = [server: server, path: "/mcp", auth: [config: config, resource: @resource]]

    assert_raise ArgumentError, ~r/:scope_policy must map supported/, fn ->
      Server.Plug.init(base ++ [scope_policy: %{"prompts/get" => :selected_definition}])
    end

    assert_raise ArgumentError, ~r/:scope_policy must map supported/, fn ->
      Server.Plug.init(base ++ [scope_policy: %{"tools/list" => :authenticated_only}])
    end

    assert %{opts: nil_scope_opts} = Server.Plug.init(base ++ [scope_map: nil])
    assert Keyword.has_key?(nil_scope_opts, :scope_map)
    assert nil_scope_opts[:scope_map] == nil

    assert_raise ArgumentError, ~r/cannot overlap/, fn ->
      Server.Plug.init(
        base ++
          [
            scope_map: %{"tools/call" => []},
            scope_policy: %{"tools/call" => :selected_definition}
          ]
      )
    end

    {:ok, configured_server} = Server.start_link(scope_map: %{"tools/call" => []})

    on_exit(fn ->
      if Process.alive?(configured_server), do: GenServer.stop(configured_server)
    end)

    assert_raise ArgumentError, ~r/cannot overlap/, fn ->
      Server.Plug.init(
        server: configured_server,
        path: "/mcp",
        auth: [config: config, resource: @resource],
        scope_policy: %{"tools/call" => :selected_definition}
      )
    end

    assert is_map(
             Server.Plug.init(
               server: configured_server,
               path: "/mcp",
               auth: [config: config, resource: @resource],
               scope_map: %{},
               scope_policy: %{"tools/call" => :selected_definition}
             )
           )
  end

  test "modern resource subscription delivery requires generic and definition scopes" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    parent = self()

    assert :ok =
             Server.register_resource(server, "subscription-resource", %{
               uri: "urn:subscription",
               required_scopes: [@documents],
               handler: fn _arguments, _context -> {:ok, %{"contents" => []}} end
             })

    plug =
      Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource]
      )

    generic_token = token(config, [AttestoMCP.Scopes.resources_read()])
    union_token = token(config, [AttestoMCP.Scopes.resources_read(), @documents])

    generic_pid = start_modern_stream(parent, plug, generic_token, 200, ["urn:subscription"])
    assert :ok = await_subscriptions(server, 1)

    assert :ok =
             Server.publish(server, %{"type" => "resourceUpdated", "uri" => "urn:subscription"})

    assert :ok = Server.close_subscription(server, 200, generic_pid)
    assert_receive {:modern_stream_done, 200, generic_conn}, 2_000
    refute "notifications/resources/updated" in stream_methods(generic_conn)

    union_pid = start_modern_stream(parent, plug, union_token, 201, ["urn:subscription"])
    assert :ok = await_subscriptions(server, 1)

    assert :ok =
             Server.publish(server, %{"type" => "resourceUpdated", "uri" => "urn:subscription"})

    assert :ok = Server.close_subscription(server, 201, union_pid)
    assert_receive {:modern_stream_done, 201, union_conn}, 2_000
    assert "notifications/resources/updated" in stream_methods(union_conn)

    assert Process.alive?(server)
    GenServer.stop(server)
  end

  test "exact unscoped static resource wins over a scoped template for modern delivery" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    parent = self()

    assert :ok =
             Server.register_resource_template(server, "urn:precedence/{id}", %{
               required_scopes: [@documents],
               handler: fn _arguments, _context -> {:ok, %{"contents" => []}} end
             })

    assert :ok =
             Server.register_resource(server, "precedence-static", %{
               uri: "urn:precedence/item",
               required_scopes: [],
               handler: fn _arguments, _context -> {:ok, %{"contents" => []}} end
             })

    assert :ok =
             Server.register_resource_template(server, "urn:ordered/{z}", %{
               required_scopes: [@reports],
               handler: fn _arguments, _context -> {:ok, %{"contents" => []}} end
             })

    assert :ok =
             Server.register_resource_template(server, "urn:ordered/{a}", %{
               required_scopes: [@documents],
               handler: fn _arguments, _context -> {:ok, %{"contents" => []}} end
             })

    plug =
      Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource]
      )

    pid =
      start_modern_stream(
        parent,
        plug,
        token(config, [AttestoMCP.Scopes.resources_read()]),
        202,
        ["urn:precedence/item"]
      )

    assert :ok = await_subscriptions(server, 1)

    assert :ok =
             Server.publish(server, %{"type" => "resourceUpdated", "uri" => "urn:precedence/item"})

    assert :ok = Server.close_subscription(server, 202, pid)
    assert_receive {:modern_stream_done, 202, conn}, 2_000
    assert "notifications/resources/updated" in stream_methods(conn)

    ordered_pid =
      start_modern_stream(
        parent,
        plug,
        token(config, [AttestoMCP.Scopes.resources_read(), @documents]),
        205,
        ["urn:ordered/item"]
      )

    assert :ok = await_subscriptions(server, 1)

    assert :ok =
             Server.publish(server, %{"type" => "resourceUpdated", "uri" => "urn:ordered/item"})

    assert :ok = Server.close_subscription(server, 205, ordered_pid)
    assert_receive {:modern_stream_done, 205, ordered_conn}, 2_000
    assert "notifications/resources/updated" in stream_methods(ordered_conn)

    GenServer.stop(server)
  end

  test "legacy resource subscription delivery retains the generic-plus-definition union" do
    {:ok, server} = Server.start_link([])
    config = AttestoMCP.Test.Factory.config()
    parent = self()

    assert :ok =
             Server.register_resource(server, "legacy-subscription-resource", %{
               uri: "urn:legacy-subscription",
               required_scopes: [@documents],
               handler: fn _arguments, _context -> {:ok, %{"contents" => []}} end
             })

    plug =
      Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource]
      )

    generic_token = token(config, [AttestoMCP.Scopes.resources_read()])
    union_token = token(config, [AttestoMCP.Scopes.resources_read(), @documents])

    generic_session = initialize_legacy_session(plug, generic_token, @legacy)
    assert :ok = legacy_subscribe(plug, generic_token, generic_session, "urn:legacy-subscription")
    _generic_pid = start_legacy_stream(parent, plug, generic_token, generic_session, 203)
    assert :ok = await_legacy_streams(server, 1)

    assert :ok =
             Server.publish(server, %{
               "type" => "resourceUpdated",
               "uri" => "urn:legacy-subscription"
             })

    assert :ok = Server.delete_session(server, generic_session)
    assert_receive {:legacy_stream_done, 203, generic_conn}, 2_000
    refute generic_conn.resp_body =~ "notifications/resources/updated"

    union_session = initialize_legacy_session(plug, union_token, @legacy)
    assert :ok = legacy_subscribe(plug, union_token, union_session, "urn:legacy-subscription")
    _union_pid = start_legacy_stream(parent, plug, union_token, union_session, 204)
    assert :ok = await_legacy_streams(server, 1)

    assert :ok =
             Server.publish(server, %{
               "type" => "resourceUpdated",
               "uri" => "urn:legacy-subscription"
             })

    assert :ok = Server.delete_session(server, union_session)
    assert_receive {:legacy_stream_done, 204, union_conn}, 2_000
    assert union_conn.resp_body =~ "notifications/resources/updated"

    GenServer.stop(server)
  end

  defp plug(server, config),
    do:
      Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource],
        scope_policy: @policy
      )

  defp token(config, scopes),
    do: AttestoMCP.Test.Factory.access_token(config, scopes: scopes)

  defp names(conn, key),
    do:
      conn
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()
      |> get_in(["result", key])
      |> Enum.map(& &1["name"])

  defp uris(conn, key),
    do:
      conn
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()
      |> get_in(["result", key])
      |> Enum.map(&(&1["uri"] || &1["uriTemplate"]))

  defp http_call(plug, token, version, method, params, opts \\ []) do
    id = Keyword.get(opts, :id, :erlang.unique_integer([:positive]))

    params =
      if version == @modern do
        Map.put_new(
          params,
          "_meta",
          %{
            "io.modelcontextprotocol/protocolVersion" => @modern,
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }
        )
      else
        params
      end

    payload =
      %{"jsonrpc" => "2.0", "method" => method, "params" => params}
      |> then(fn payload -> if is_nil(id), do: payload, else: Map.put(payload, "id", id) end)

    conn =
      conn(:post, "/mcp", Jason.encode!(payload))
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("mcp-protocol-version", version)

    conn =
      case token do
        {:dpop, access_token, proof} ->
          conn
          |> put_req_header("authorization", "DPoP " <> access_token)
          |> put_req_header("dpop", proof)

        access_token when is_binary(access_token) ->
          put_req_header(conn, "authorization", "Bearer " <> access_token)
      end

    conn =
      if version == @modern,
        do: put_req_header(conn, "mcp-method", method),
        else: conn

    conn =
      if version == @modern and method in ["tools/call", "resources/read"],
        do: put_req_header(conn, "mcp-name", params["name"] || params["uri"]),
        else: conn

    conn =
      case Keyword.get(opts, :session_id) do
        nil -> conn
        session -> put_req_header(conn, "mcp-session-id", session)
      end

    Server.Plug.call(conn, plug)
  end

  defp unread_request(token) do
    conn(:post, "/mcp", "not-json")
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
  end

  defp start_modern_stream(parent, plug, token, id, uris) do
    spawn(fn ->
      request = %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => "subscriptions/listen",
        "params" => %{
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => @modern,
            "io.modelcontextprotocol/clientCapabilities" => %{}
          },
          "notifications" => %{"resourceSubscriptions" => uris}
        }
      }

      conn =
        conn(:post, "/mcp", Jason.encode!(request))
        |> put_req_header("authorization", "Bearer " <> token)
        |> put_req_header("accept", "application/json, text/event-stream")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("mcp-protocol-version", @modern)
        |> put_req_header("mcp-method", "subscriptions/listen")

      send(parent, {:modern_stream_done, id, Server.Plug.call(conn, plug)})
    end)
  end

  defp stream_methods(conn),
    do: conn |> stream_messages() |> Enum.map(& &1["method"])

  defp stream_messages(conn) do
    conn.resp_body
    |> String.split("\n\n", trim: true)
    |> Enum.map(fn event ->
      event |> String.split("data: ", parts: 2) |> List.last() |> Jason.decode!()
    end)
  end

  defp await_subscriptions(_server, 0), do: {:error, :timeout}

  defp await_subscriptions(server, expected, attempts \\ 100) do
    if Server.stats(server).subscriptions == expected do
      :ok
    else
      if attempts <= 0 do
        {:error, :timeout}
      else
        Process.sleep(10)
        await_subscriptions(server, expected, attempts - 1)
      end
    end
  end

  defp initialize_legacy_session(plug, token, version) do
    initialized =
      http_call(plug, token, version, "initialize", %{
        "protocolVersion" => version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "scope-policy", "version" => "1"}
      })

    assert initialized.status == 200
    session = initialized |> get_resp_header("mcp-session-id") |> List.first()

    assert http_call(plug, token, version, "notifications/initialized", %{},
             session_id: session,
             id: nil
           ).status == 202

    session
  end

  defp legacy_subscribe(plug, token, session, uri) do
    response =
      http_call(plug, token, @legacy, "resources/subscribe", %{"uri" => uri}, session_id: session)

    if response.status == 200, do: :ok, else: {:error, response.status}
  end

  defp start_legacy_stream(parent, plug, token, session, id) do
    spawn(fn ->
      conn =
        conn(:get, "/mcp")
        |> put_req_header("authorization", "Bearer " <> token)
        |> put_req_header("accept", "text/event-stream")
        |> put_req_header("mcp-session-id", session)
        |> put_req_header("mcp-protocol-version", @legacy)

      send(parent, {:legacy_stream_done, id, Server.Plug.call(conn, plug)})
    end)
  end

  defp await_legacy_streams(_server, 0), do: {:error, :timeout}

  defp await_legacy_streams(server, expected, attempts \\ 100) do
    if Server.stats(server).legacy_streams == expected do
      :ok
    else
      if attempts <= 0 do
        {:error, :timeout}
      else
        Process.sleep(10)
        await_legacy_streams(server, expected, attempts - 1)
      end
    end
  end
end
