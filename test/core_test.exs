defmodule AttestoMCP.Server.CoreTest do
  use ExUnit.Case, async: false
  alias AttestoMCP.Server

  setup do
    {:ok, server} = Server.start_link(max_concurrency: 8)

    :ok =
      Server.register_tool(server, "echo", %{
        description: "Echo",
        input_schema: %{"type" => "object"},
        handler: fn params, _ -> {:ok, params} end
      })

    :ok =
      Server.register_resource(server, "urn:example:item", %{
        name: "item",
        handler: fn _, _ -> {:ok, [%{"uri" => "urn:example:item", "text" => "hello"}]} end
      })

    :ok =
      Server.register_prompt(server, "greet", %{
        handler: fn _, _ ->
          {:ok, [%{"role" => "user", "content" => %{"type" => "text", "text" => "hi"}}]}
        end
      })

    %{server: server}
  end

  test "modern discovery, list, call, and resource read correlate IDs", %{server: server} do
    params = %{
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities" => %{}
      }
    }

    assert {1, %{"jsonrpc" => "2.0", "id" => 1, "result" => discovery}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 1, method: "server/discover", params: params},
               %{principal: "p", scopes: []},
               version: "2026-07-28"
             )

    assert discovery["resultType"] == "complete"
    assert "2026-07-28" in discovery["supportedVersions"]
    assert "2025-06-18" in discovery["supportedVersions"]

    assert get_in(discovery, ["_meta", "io.modelcontextprotocol/serverInfo", "version"]) ==
             Mix.Project.config()[:version]

    assert {2, %{"result" => %{"tools" => [%{"name" => "echo"}]}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 2, method: "tools/list", params: params},
               %{principal: "p"},
               version: "2026-07-28"
             )

    call = %{
      kind: :request,
      id: 3,
      method: "tools/call",
      params: Map.merge(params, %{"name" => "echo", "arguments" => %{"value" => 1}})
    }

    assert {3, %{"result" => %{"isError" => false, "resultType" => "complete"}}} =
             Server.dispatch(server, call, %{principal: "p"}, version: "2026-07-28")

    read = %{
      kind: :request,
      id: 4,
      method: "resources/read",
      params: Map.merge(params, %{"uri" => "urn:example:item"})
    }

    assert {4,
            %{"result" => %{"contents" => [%{"uri" => "urn:example:item", "text" => "hello"}]}}} =
             Server.dispatch(server, read, %{principal: "p"}, version: "2026-07-28")
  end

  test "modern metadata rejects legacy revisions instead of crossing lifecycle paths", %{
    server: server
  } do
    request = %{
      kind: :request,
      id: 11,
      method: "tools/list",
      params: %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2025-06-18",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    assert {11, %{"error" => %{"code" => -32022}}} =
             Server.dispatch(server, request, %{principal: "p"})

    assert {11, %{"error" => %{"code" => -32022}}} =
             Server.dispatch(server, request, %{principal: "p"}, version: "2026-07-28")
  end

  test "configured protocol versions gate legacy initialization", %{server: _server} do
    {:ok, server} = Server.start_link(protocol_versions: ["2026-07-28"])
    {:ok, session} = Server.new_session(server, "configured", nil)

    assert {:error, :invalid_negotiation} =
             Server.negotiate_session(
               server,
               session.id,
               "configured",
               nil,
               "2025-06-18",
               %{}
             )

    assert {:error, :invalid_version} =
             Server.set_session_version(server, session.id, "2025-06-18")

    request = %{
      kind: :request,
      id: 12,
      method: "initialize",
      params: %{
        "protocolVersion" => "2025-06-18",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "configured-client", "version" => "1.0"}
      }
    }

    assert {12, %{"error" => %{"code" => -32022, "data" => data}}} =
             Server.dispatch(server, request, %{principal: "p"}, version: "2025-06-18")

    assert data["supported"] == ["2026-07-28"]

    {:ok, legacy_only} = Server.start_link(protocol_versions: ["2025-06-18"])

    assert {12, %{"result" => %{"protocolVersion" => "2025-06-18"}}} =
             Server.dispatch(legacy_only, request, %{principal: "p"}, version: "2025-06-18")

    newer_request = put_in(request, [:params, "protocolVersion"], "2025-11-25")

    assert {12, %{"error" => %{"code" => -32022, "data" => newer_data}}} =
             Server.dispatch(legacy_only, newer_request, %{principal: "p"}, version: "2025-11-25")

    assert newer_data["supported"] == ["2025-06-18"]
  end

  test "unknown modern methods preserve ID and use method-not-found", %{server: server} do
    request = %{
      kind: :request,
      id: "unknown",
      method: "not/a-method",
      params: %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    assert {"unknown", %{"error" => %{"code" => -32601, "data" => %{"method" => "not/a-method"}}}} =
             Server.dispatch(server, request, %{}, version: "2026-07-28")
  end

  test "legacy initialize and notifications remain a separate path", %{server: server} do
    request = %{
      kind: :request,
      id: 10,
      method: "initialize",
      params: %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "core-test", "version" => "1.0"}
      }
    }

    assert {10, %{"result" => %{"protocolVersion" => "2025-11-25"}}} =
             Server.dispatch(server, request, %{principal: "legacy"}, version: "2025-11-25")

    assert :notification =
             Server.dispatch(
               server,
               %{kind: :notification, method: "notifications/initialized", params: %{}},
               %{principal: "legacy"},
               version: "2025-11-25"
             )
  end

  test "progress callback is caller-token bound and monotonic", %{server: server} do
    :ok =
      Server.register_tool(server, "progress", %{
        handler: fn _params, context ->
          assert :ok = context.progress.("caller", 1, 2)
          assert {:error, :inactive_or_nonmonotonic_token} = context.progress.("caller", 0, 2)
          assert {:error, :inactive_or_nonmonotonic_token} = context.progress.("other", 2, 2)
          {:ok, "done"}
        end
      })

    parent = self()

    request = %{
      kind: :request,
      id: 5,
      method: "tools/call",
      params: %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{},
          "progressToken" => "caller"
        },
        "name" => "progress",
        "arguments" => %{}
      }
    }

    assert {5, %{"result" => %{"resultType" => "complete"}}} =
             Server.dispatch(server, request, %{principal: "p"},
               version: "2026-07-28",
               on_event: fn event -> send(parent, {:progress, event}) end
             )

    assert_receive {:progress,
                    %{"method" => "notifications/progress", "params" => %{"progress" => 1}}}
  end

  test "pagination issues a safe opaque cursor with nil secret/ttl defaults", %{server: server} do
    for index <- 1..101 do
      assert :ok =
               Server.register_tool(server, "page_#{index}", %{
                 handler: fn _, _ -> {:ok, "ok"} end
               })
    end

    params = %{
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities" => %{}
      }
    }

    assert {6, %{"result" => %{"nextCursor" => cursor}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 6, method: "tools/list", params: params},
               %{principal: "page"},
               version: "2026-07-28"
             )

    assert is_binary(cursor)

    assert {7, %{"result" => %{"tools" => [_ | _]}}} =
             Server.dispatch(
               server,
               %{
                 kind: :request,
                 id: 7,
                 method: "tools/list",
                 params: Map.put(params, "cursor", cursor)
               },
               %{principal: "page"},
               version: "2026-07-28"
             )
  end

  test "MRTR requires elicitation capability and accepts one signed retry", %{server: server} do
    assert :ok =
             Server.register_tool(server, "ask", %{
               handler: fn args, _ ->
                 if Map.has_key?(args, "answer"),
                   do: {:ok, args},
                   else:
                     {:input_required,
                      %{
                        "answer" => %{
                          "method" => "elicitation/create",
                          "params" => %{
                            "message" => "Please provide an answer",
                            "requestedSchema" => %{"type" => "object"}
                          }
                        }
                      }}
               end
             })

    base = %{
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities" => %{}
      },
      "name" => "ask",
      "arguments" => %{}
    }

    assert {40, %{"error" => %{"code" => -32021}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 40, method: "tools/call", params: base},
               %{principal: "mrtr"},
               version: "2026-07-28"
             )

    capable =
      put_in(base, ["_meta", "io.modelcontextprotocol/clientCapabilities", "elicitation"], %{})

    assert {41,
            %{
              "result" => %{
                "resultType" => "input_required",
                "requestState" => state,
                "inputRequests" => input_requests
              }
            }} =
             Server.dispatch(
               server,
               %{kind: :request, id: 41, method: "tools/call", params: capable},
               %{principal: "mrtr"},
               version: "2026-07-28"
             )

    [input_key] = Map.keys(input_requests)

    retry =
      Map.merge(
        capable,
        %{
          "requestState" => state,
          "inputResponses" => %{
            input_key => %{"action" => "accept", "content" => %{"answer" => "yes"}}
          }
        }
      )

    assert {42, %{"result" => %{"resultType" => "complete"}}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 42, method: "tools/call", params: retry},
               %{principal: "mrtr"},
               version: "2026-07-28"
             )
  end

  test "event consumer failure releases the concurrency permit" do
    {:ok, limited} = Server.start_link(max_concurrency: 1, per_principal_concurrency: 1)

    :ok =
      Server.register_tool(limited, "progress_once", %{
        handler: fn _, context ->
          context.progress.("p", 1, 1)
          {:ok, "ok"}
        end
      })

    params = %{
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities" => %{},
        "progressToken" => "p"
      },
      "name" => "progress_once",
      "arguments" => %{}
    }

    assert {1, %{"error" => %{"code" => -32603}}} =
             Server.dispatch(
               limited,
               %{kind: :request, id: 1, method: "tools/call", params: params},
               %{principal: "p"},
               version: "2026-07-28",
               on_event: fn _ -> raise "consumer" end
             )

    assert {2, %{"result" => _}} =
             Server.dispatch(
               limited,
               %{
                 kind: :request,
                 id: 2,
                 method: "tools/call",
                 params: Map.put(params, "_meta", Map.delete(params["_meta"], "progressToken"))
               },
               %{principal: "p"},
               version: "2026-07-28"
             )
  end

  @tag :t23
  test "event delivery failure cancels only its owning request and drains state" do
    {:ok, limited} = Server.start_link(max_concurrency: 1, per_principal_concurrency: 1)

    :ok =
      Server.register_tool(limited, "progress_once", %{
        handler: fn _, context ->
          assert :ok = context.progress.("p", 1, 1)
          {:ok, "ok"}
        end
      })

    params = %{
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities" => %{},
        "progressToken" => "p"
      },
      "name" => "progress_once",
      "arguments" => %{}
    }

    assert {1, %{"error" => %{"code" => -32603}}} =
             Server.dispatch(
               limited,
               %{kind: :request, id: 1, method: "tools/call", params: params},
               %{principal: "p"},
               version: "2026-07-28",
               on_event: fn _ -> {:error, :sink_closed} end
             )

    assert %{active: 0, active_requests: 0} = Server.stats(limited)

    assert {2, %{"error" => %{"code" => -32603}}} =
             Server.dispatch(
               limited,
               %{kind: :request, id: 2, method: "tools/call", params: params},
               %{principal: "p"},
               version: "2026-07-28"
             )
  end

  test "request timeout cancels the linked handler task" do
    {:ok, limited} = Server.start_link(max_concurrency: 1, per_principal_concurrency: 1)

    assert :ok =
             Server.register_tool(limited, "sleep", %{
               handler: fn _, _ ->
                 Process.sleep(100)
                 {:ok, "late"}
               end
             })

    request = %{
      kind: :request,
      id: 20,
      method: "tools/call",
      params: %{"name" => "sleep", "arguments" => %{}}
    }

    assert {20, %{"error" => %{"code" => -32603}}} =
             Server.dispatch(limited, request, %{principal: "timeout"},
               timeout: 5,
               version: "2025-11-25"
             )

    assert {21, %{"result" => _}} =
             Server.dispatch(limited, %{request | id: 21}, %{principal: "timeout"},
               version: "2025-11-25"
             )
  end

  test "cancellation notification targets the matching request" do
    {:ok, cancel_server} = Server.start_link(max_concurrency: 2, per_principal_concurrency: 2)
    parent = self()

    assert :ok =
             Server.register_tool(cancel_server, "wait", %{
               handler: fn _, _ ->
                 send(parent, :wait_started)
                 Process.sleep(1_000)
                 {:ok, "late"}
               end
             })

    request = %{
      kind: :request,
      id: 30,
      method: "tools/call",
      params: %{"name" => "wait", "arguments" => %{}}
    }

    caller =
      Task.async(fn ->
        Server.dispatch(cancel_server, request, %{principal: "cancel"},
          version: "2025-11-25",
          timeout: 2_000
        )
      end)

    assert_receive :wait_started

    assert :notification =
             Server.dispatch(
               cancel_server,
               %{
                 kind: :notification,
                 method: "notifications/cancelled",
                 params: %{"requestId" => 30}
               },
               %{principal: "cancel"},
               version: "2025-11-25"
             )

    assert {30, %{"error" => %{"code" => -32800}}} = Task.await(caller, 2_000)
    assert %{active: %{global: 0, requests: %{}}} = :sys.get_state(cancel_server)
  end

  test "duplicate active IDs are rejected without killing the original" do
    {:ok, duplicate_server} = Server.start_link(max_concurrency: 2, per_principal_concurrency: 2)
    parent = self()

    assert :ok =
             Server.register_tool(duplicate_server, "wait", %{
               handler: fn _, _ ->
                 send(parent, :duplicate_started)
                 Process.sleep(500)
                 {:ok, "done"}
               end
             })

    request = %{
      kind: :request,
      id: 77,
      method: "tools/call",
      params: %{"name" => "wait", "arguments" => %{}}
    }

    original =
      Task.async(fn ->
        Server.dispatch(duplicate_server, request, %{principal: "dup"}, version: "2025-11-25")
      end)

    assert_receive :duplicate_started

    assert {77, %{"error" => %{"code" => -32600, "data" => %{"reason" => "duplicate_id"}}}} =
             Server.dispatch(duplicate_server, request, %{principal: "dup"},
               version: "2025-11-25"
             )

    assert {77, %{"result" => _}} = Task.await(original, 2_000)
    assert %{active: %{global: 0, requests: %{}}} = :sys.get_state(duplicate_server)
  end

  test "repeated cancellation leaves permits and request ownership reusable" do
    {:ok, repeated} = Server.start_link(max_concurrency: 2, per_principal_concurrency: 2)
    parent = self()

    assert :ok =
             Server.register_tool(repeated, "wait", %{
               handler: fn %{"marker" => marker}, _ ->
                 send(parent, {:repeat_started, marker})
                 Process.sleep(250)
                 {:ok, marker}
               end
             })

    for id <- 1..3 do
      request = %{
        kind: :request,
        id: id,
        method: "tools/call",
        params: %{"name" => "wait", "arguments" => %{"marker" => id}}
      }

      target =
        Task.async(fn ->
          Server.dispatch(repeated, request, %{principal: "repeat"}, version: "2025-11-25")
        end)

      assert_receive {:repeat_started, ^id}

      assert :notification =
               Server.dispatch(
                 repeated,
                 %{
                   kind: :notification,
                   method: "notifications/cancelled",
                   params: %{"requestId" => id}
                 },
                 %{principal: "repeat"},
                 version: "2025-11-25"
               )

      assert {^id, %{"error" => %{"code" => -32800}}} = Task.await(target, 2_000)
      assert %{active: %{global: 0, requests: %{}}} = :sys.get_state(repeated)

      fresh_id = 100 + id

      assert {^fresh_id, %{"result" => _}} =
               Server.dispatch(
                 repeated,
                 %{
                   request
                   | id: fresh_id,
                     params: put_in(request.params, ["arguments", "marker"], "fresh")
                 },
                 %{principal: "repeat"},
                 version: "2025-11-25"
               )
    end
  end

  test "legacy session deletion is principal and tenant bound", %{server: server} do
    assert {:ok, session} = Server.new_session(server, "alice", "tenant-a")
    assert {:ok, _} = Server.get_session(server, session.id, "alice", "tenant-a")
    assert {:error, :not_found} = Server.get_session(server, session.id, "alice", "tenant-b")
    assert :ok = Server.delete_session(server, session.id)
    assert {:error, :not_found} = Server.get_session(server, session.id, "alice", "tenant-a")
  end
end
