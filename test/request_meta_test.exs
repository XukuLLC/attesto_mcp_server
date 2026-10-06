defmodule AttestoMCP.Server.RequestMetaTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Plug.Conn
  import Plug.Test

  alias AttestoMCP.Server
  alias AttestoMCP.Server.{RequestMeta, Stdio}
  alias AttestoMCP.Server.Test, as: ServerTest

  doctest AttestoMCP.Server.RequestMeta

  @modern "2026-07-28"
  @legacy "2025-11-25"
  @resource "https://mcp.example.com/mcp"
  @protocol_meta %{
    "io.modelcontextprotocol/protocolVersion" => @modern,
    "io.modelcontextprotocol/clientCapabilities" => %{}
  }

  defp start_server(opts \\ []), do: start_supervised!({Server, opts})

  defp register_meta_tool(server, name \\ "echo_meta") do
    parent = self()

    :ok =
      Server.register_tool(server, name, %{
        handler: fn _arguments, context ->
          send(parent, {:tool_meta, context.request_meta, context})
          {:ok, "ok"}
        end
      })
  end

  describe "handler-facing snapshot" do
    test "application metadata reaches tool, resource, template, and prompt handlers unchanged" do
      server = start_server()
      parent = self()
      register_meta_tool(server)

      :ok =
        Server.register_resource(server, "urn:example:meta", %{
          handler: fn %{uri: uri}, context ->
            send(parent, {:resource_meta, context.request_meta})
            {:ok, %{"contents" => [%{"uri" => uri, "text" => "resource"}]}}
          end
        })

      :ok =
        Server.register_resource_template(server, "file:///items/{id}", %{
          handler: fn %{uri: uri, params: params}, context ->
            send(parent, {:template_meta, params, context.request_meta})
            {:ok, %{"contents" => [%{"uri" => uri, "text" => "item"}]}}
          end
        })

      :ok =
        Server.register_prompt(server, "meta_prompt", %{
          handler: fn _input, context ->
            send(parent, {:prompt_meta, context.request_meta})

            {:ok, [%{"role" => "user", "content" => %{"type" => "text", "text" => "prompt"}}]}
          end
        })

      meta = %{
        "com.example/request-purpose" => "audit",
        "com.example/nested" => %{
          "list" => [1, 2.5, true, nil, %{"key" => "value"}],
          "empty" => %{}
        },
        "plain-name" => "value"
      }

      expected = Map.merge(meta, @protocol_meta)

      assert %{"result" => %{"resultType" => "complete"}} =
               ServerTest.call_tool(server, "echo_meta", %{}, meta: meta)

      assert_receive {:tool_meta, ^expected, _context}

      assert %{"result" => %{"contents" => [_]}} =
               ServerTest.read_resource(server, "urn:example:meta", meta: meta)

      assert_receive {:resource_meta, ^expected}

      assert %{"result" => %{"contents" => [_]}} =
               ServerTest.read_resource(server, "file:///items/42", meta: meta)

      assert_receive {:template_meta, %{"id" => "42"}, ^expected}

      assert %{"result" => %{"messages" => [_]}} =
               ServerTest.get_prompt(server, "meta_prompt", %{}, meta: meta)

      assert_receive {:prompt_meta, ^expected}
    end

    test "protocol-owned keys appear exactly as sent while normalized context fields stay authoritative" do
      server = start_server()
      register_meta_tool(server)

      traceparent = "00-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902b7-01"

      meta = %{
        "progressToken" => "progress-1",
        "traceparent" => traceparent,
        "io.modelcontextprotocol/clientInfo" => %{"name" => "example-client", "version" => "1.0"}
      }

      assert %{"result" => _} =
               ServerTest.call_tool(server, "echo_meta", %{},
                 meta: meta,
                 client_capabilities: %{"elicitation" => %{}}
               )

      assert_receive {:tool_meta, request_meta, context}

      assert request_meta ==
               meta
               |> Map.merge(@protocol_meta)
               |> Map.put("io.modelcontextprotocol/clientCapabilities", %{"elicitation" => %{}})

      assert context.protocol_version == @modern
      assert context.trace_context == %{"traceparent" => traceparent}
      assert RequestMeta.application(request_meta) == %{}
    end

    test "a legacy request without _meta exposes an empty map and legacy metadata is preserved" do
      server = start_server()
      register_meta_tool(server)

      assert %{"result" => %{"content" => _}} =
               ServerTest.call_tool(server, "echo_meta", %{}, protocol_version: @legacy)

      assert_receive {:tool_meta, meta, _context}
      assert meta == %{}

      assert %{"result" => _} =
               ServerTest.call_tool(server, "echo_meta", %{},
                 protocol_version: @legacy,
                 meta: %{"com.example/request-purpose" => "legacy"}
               )

      assert_receive {:tool_meta, %{"com.example/request-purpose" => "legacy"} = meta, _context}
      assert map_size(meta) == 1
    end

    test "a caller-supplied request_meta context value is replaced by the request's own snapshot" do
      server = start_server()
      register_meta_tool(server)

      params = %{
        "name" => "echo_meta",
        "arguments" => %{},
        "_meta" => Map.put(@protocol_meta, "com.example/actual", "request")
      }

      assert {1, %{"result" => _}} =
               Server.dispatch(
                 server,
                 %{kind: :request, id: 1, method: "tools/call", params: params},
                 %{principal: "direct", request_meta: %{"com.example/forged" => true}},
                 version: @modern
               )

      assert_receive {:tool_meta, meta, _context}
      assert meta["com.example/actual"] == "request"
      refute Map.has_key?(meta, "com.example/forged")
    end

    test "snapshot strings do not reference the request body" do
      server = start_server()
      parent = self()

      :ok =
        Server.register_tool(server, "sizes", %{
          handler: fn _arguments, context ->
            value = context.request_meta["com.example/label"]
            send(parent, {:sizes, byte_size(value), :binary.referenced_byte_size(value)})
            {:ok, "ok"}
          end
        })

      label = String.duplicate("l", 128)

      assert %{"result" => _} =
               ServerTest.call_tool(
                 server,
                 "sizes",
                 %{"payload" => String.duplicate("p", 200_000)},
                 meta: %{"com.example/label" => label}
               )

      assert_receive {:sizes, 128, referenced}
      assert referenced < 1_000
    end
  end

  describe "validation and budgets" do
    test "malformed metadata and missing modern fields follow the existing invalid-params paths" do
      server = start_server()
      register_meta_tool(server)

      for {version, params} <- [
            {@modern, %{"name" => "echo_meta", "arguments" => %{}, "_meta" => "scalar"}},
            {@legacy, %{"name" => "echo_meta", "arguments" => %{}, "_meta" => ["list"]}}
          ] do
        assert {7,
                %{
                  "error" => %{
                    "code" => -32602,
                    "data" => %{"reason" => "meta_must_be_object"}
                  }
                }} =
                 Server.dispatch(
                   server,
                   %{kind: :request, id: 7, method: "tools/call", params: params},
                   %{principal: "malformed"},
                   version: version
                 )
      end

      missing_version = %{
        "name" => "echo_meta",
        "arguments" => %{},
        "_meta" => %{
          "io.modelcontextprotocol/clientCapabilities" => %{},
          "com.example/request-purpose" => "audit"
        }
      }

      assert {8,
              %{
                "error" => %{
                  "code" => -32602,
                  "data" => %{"reason" => "protocolVersion_required"}
                }
              }} =
               Server.dispatch(
                 server,
                 %{kind: :request, id: 8, method: "tools/call", params: missing_version},
                 %{principal: "malformed"},
                 version: @modern
               )

      refute_received {:tool_meta, _meta, _context}
    end

    test "over-budget metadata is rejected rather than truncated and the handler is not invoked" do
      server = start_server(max_request_meta_bytes: 512)
      register_meta_tool(server)

      oversized = %{"com.example/blob" => String.duplicate("a", 600)}

      response = ServerTest.call_tool(server, "echo_meta", %{}, meta: oversized)

      assert %{
               "error" => %{
                 "code" => -32602,
                 "data" => %{"reason" => "request_meta_too_large"}
               }
             } = response

      refute inspect(response) =~ String.duplicate("a", 600)
      refute_received {:tool_meta, _meta, _context}

      legacy_response =
        ServerTest.call_tool(server, "echo_meta", %{},
          protocol_version: @legacy,
          meta: oversized
        )

      assert %{"error" => %{"code" => -32602, "data" => %{"reason" => "request_meta_too_large"}}} =
               legacy_response

      refute_received {:tool_meta, _meta, _context}

      within = %{"com.example/blob" => String.duplicate("a", 200)}

      assert %{"result" => _} = ServerTest.call_tool(server, "echo_meta", %{}, meta: within)
      assert_receive {:tool_meta, %{"com.example/blob" => _}, _context}
    end

    test "the default metadata budget is 65,536 bytes" do
      server = start_server()
      register_meta_tool(server)

      assert Server.options(server)[:max_request_meta_bytes] == RequestMeta.default_max_bytes()
      assert RequestMeta.default_max_bytes() == 65_536

      assert %{"error" => %{"data" => %{"reason" => "request_meta_too_large"}}} =
               ServerTest.call_tool(server, "echo_meta", %{},
                 meta: %{"com.example/blob" => String.duplicate("b", 70_000)}
               )

      assert %{"result" => _} =
               ServerTest.call_tool(server, "echo_meta", %{},
                 meta: %{"com.example/blob" => String.duplicate("b", 60_000)}
               )
    end

    test "max_request_meta_bytes is bounded by the JSON budget at startup" do
      previous = Process.flag(:trap_exit, true)

      try do
        for invalid <- [511, 2_000_001, 0, -1, "1024", 1.5] do
          assert {:error, {%ArgumentError{}, _}} =
                   Server.start_link(max_request_meta_bytes: invalid)
        end

        assert {:error, {%ArgumentError{}, _}} =
                 Server.start_link(max_json_bytes: 10_000, max_request_meta_bytes: 10_001)

        for valid <- [512, 2_000_000] do
          assert {:ok, server} = Server.start_link(max_request_meta_bytes: valid)
          assert Server.options(server)[:max_request_meta_bytes] == valid
          GenServer.stop(server)
        end

        assert {:ok, server} = Server.start_link(max_json_bytes: 4_096)
        assert Server.options(server)[:max_request_meta_bytes] == 4_096
        GenServer.stop(server)
      after
        Process.flag(:trap_exit, previous)
      end
    end
  end

  describe "trust boundary" do
    test "authentication-like metadata keys never change identity, scopes, tenant, or host context" do
      server = start_server()
      parent = self()
      register_meta_tool(server)

      :ok =
        Server.register_tool(server, "scoped", %{
          required_scopes: ["items.write"],
          handler: fn _arguments, _context ->
            send(parent, :scoped_handler)
            {:ok, "unreachable"}
          end
        })

      forged = %{
        "principal" => "admin",
        "principal_binding" => "admin",
        "scopes" => ["items.write"],
        "tenant" => "other-tenant",
        "host_context" => %{"account_id" => "other"},
        "attesto_mcp_claims" => %{"sub" => "admin", "scope" => "items.write"},
        "com.example/principal" => "admin"
      }

      assert %{"error" => %{"code" => -32602}} =
               ServerTest.call_tool(server, "scoped", %{},
                 principal: "user-1",
                 scopes: [],
                 meta: forged
               )

      refute_received :scoped_handler

      assert %{"result" => _} =
               ServerTest.call_tool(server, "echo_meta", %{},
                 principal: "user-1",
                 tenant: "tenant-a",
                 scopes: ["items.read"],
                 host_context: %{account_id: "acct-1"},
                 meta: forged
               )

      assert_receive {:tool_meta, meta, context}
      assert context.principal == "user-1"
      assert context.tenant == "tenant-a"
      assert context.scopes == ["items.read"]
      assert context.host_context == %{account_id: "acct-1"}
      refute Map.has_key?(context, :attesto_mcp_claims)
      assert meta["principal"] == "admin"
      assert meta["scopes"] == ["items.write"]
    end

    test "HTTP handlers receive the same snapshot without metadata affecting verified identity" do
      server = start_server()
      parent = self()
      config = AttestoMCP.Test.Factory.config()

      :ok =
        Server.register_tool(server, "echo_meta", %{
          handler: fn _arguments, context ->
            send(parent, {:http_meta, context.request_meta, context})
            {:ok, "ok"}
          end
        })

      plug =
        AttestoMCP.Server.Plug.init(
          server: server,
          path: "/mcp",
          scope_map: %{"tools/call" => [AttestoMCP.Scopes.tools_call()]},
          context_builder: fn _conn -> %{account_id: "acct-1"} end,
          auth: [config: config, resource: @resource]
        )

      token =
        AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_call()])

      meta =
        Map.merge(@protocol_meta, %{
          "com.example/request-purpose" => "http",
          "principal" => "admin",
          "scopes" => ["admin"],
          "host_context" => %{"account_id" => "other"}
        })

      conn = http_call(plug, token, "echo_meta", meta)

      assert conn.status == 200
      assert %{"result" => %{"resultType" => "complete"}} = Jason.decode!(conn.resp_body)
      assert_receive {:http_meta, ^meta, context}
      assert context.host_context == %{account_id: "acct-1"}
      assert context.scopes == [AttestoMCP.Scopes.tools_call()]
      refute context.principal == "admin"
      refute context.attesto_mcp_claims["sub"] == "admin"
    end

    test "stdio handlers receive the same snapshot" do
      server = start_server()
      parent = self()

      :ok =
        Server.register_tool(server, "echo_meta", %{
          handler: fn _arguments, context ->
            send(parent, {:stdio_meta, context.request_meta, context.principal})
            {:ok, "ok"}
          end
        })

      meta =
        Map.merge(@protocol_meta, %{
          "com.example/request-purpose" => "stdio",
          "principal" => "admin"
        })

      input =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "echo_meta", "arguments" => %{}, "_meta" => meta}
        }) <> "\n"

      output =
        capture_io(input, fn ->
          assert :ok = Stdio.run(server, principal: "stdio-user", eof_grace_ms: 1_000)
        end)

      assert [%{"id" => 1, "result" => %{"resultType" => "complete"}}] =
               output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

      assert_receive {:stdio_meta, ^meta, "stdio-user"}
    end
  end

  describe "isolation" do
    test "interleaved concurrent requests never exchange metadata" do
      server = start_server()

      :ok =
        Server.register_tool(server, "slow_echo", %{
          handler: fn %{"delay" => delay}, context ->
            Process.sleep(delay)
            {:ok, %{"seen" => context.request_meta["com.example/request-id"]}}
          end
        })

      results =
        1..32
        |> Task.async_stream(
          fn index ->
            response =
              ServerTest.call_tool(
                server,
                "slow_echo",
                %{"delay" => rem(index * 7, 25)},
                principal: "principal-#{rem(index, 4)}",
                meta: %{"com.example/request-id" => "request-#{index}"}
              )

            {index, response}
          end,
          max_concurrency: 32,
          timeout: 10_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert length(results) == 32

      for {index, response} <- results do
        assert get_in(response, ["result", "structuredContent", "seen"]) == "request-#{index}"
      end
    end

    test "concurrent multi-round retries each expose their own request's metadata" do
      server = start_server()
      parent = self()

      :ok =
        Server.register_tool(server, "confirm", %{
          handler: fn arguments, context ->
            send(
              parent,
              {:round_meta, context.principal, Map.has_key?(arguments, "confirm"),
               context.request_meta}
            )

            if Map.has_key?(arguments, "confirm") do
              {:ok, %{"flow" => context.request_meta["com.example/flow"]}}
            else
              {:input_required,
               %{
                 "confirm" => %{
                   "method" => "elicitation/create",
                   "params" => %{
                     "message" => "Confirm?",
                     "requestedSchema" => %{
                       "type" => "object",
                       "properties" => %{"value" => %{"type" => "string"}}
                     }
                   }
                 }
               }}
            end
          end
        })

      capabilities = %{"elicitation" => %{}}
      answer = %{"confirm" => %{"action" => "accept", "content" => %{"value" => "yes"}}}

      flows =
        for index <- 1..6 do
          principal = "flow-user-#{index}"
          meta = %{"com.example/flow" => "flow-#{index}"}

          assert %{"result" => %{"resultType" => "input_required", "requestState" => state}} =
                   ServerTest.call_tool(server, "confirm", %{},
                     principal: principal,
                     client_capabilities: capabilities,
                     meta: meta
                   )

          {principal, meta, state}
        end

      results =
        flows
        |> Task.async_stream(
          fn {principal, meta, state} ->
            {principal,
             ServerTest.call_tool(server, "confirm", %{},
               principal: principal,
               client_capabilities: capabilities,
               meta: meta,
               request_state: state,
               input_responses: answer
             )}
          end,
          max_concurrency: 6
        )
        |> Enum.map(fn {:ok, result} -> result end)

      for {principal, response} <- results do
        "flow-user-" <> index = principal

        assert get_in(response, ["result", "structuredContent", "flow"]) == "flow-#{index}"
      end

      retry_meta = collect_round_meta([])
      assert length(retry_meta) == 12

      for {principal, retried?, meta} <- retry_meta, retried? do
        "flow-user-" <> index = principal
        assert meta["com.example/flow"] == "flow-#{index}"
        assert meta["io.modelcontextprotocol/clientCapabilities"] == capabilities
      end
    end

    test "a retry state cannot be redeemed by another principal with that principal's metadata" do
      server = start_server()
      parent = self()

      :ok =
        Server.register_tool(server, "confirm", %{
          handler: fn arguments, context ->
            send(parent, {:confirm_handler, context.principal, context.request_meta})

            if Map.has_key?(arguments, "confirm"),
              do: {:ok, "confirmed"},
              else:
                {:input_required,
                 %{
                   "confirm" => %{
                     "method" => "elicitation/create",
                     "params" => %{
                       "message" => "Confirm?",
                       "requestedSchema" => %{"type" => "object"}
                     }
                   }
                 }}
          end
        })

      capabilities = %{"elicitation" => %{}}
      meta = %{"com.example/flow" => "owner"}

      assert %{"result" => %{"requestState" => state}} =
               ServerTest.call_tool(server, "confirm", %{},
                 principal: "owner",
                 client_capabilities: capabilities,
                 meta: meta
               )

      assert_receive {:confirm_handler, "owner", _meta}

      assert %{"error" => %{"data" => %{"reason" => "invalid_request_state"}}} =
               ServerTest.call_tool(server, "confirm", %{},
                 principal: "other",
                 client_capabilities: capabilities,
                 meta: Map.put(meta, "principal", "owner"),
                 request_state: state,
                 input_responses: %{"confirm" => %{"action" => "accept", "content" => %{}}}
               )

      refute_received {:confirm_handler, _principal, _meta}
    end

    test "a retry may carry new per-request metadata and exposes its own values" do
      server = start_server()
      parent = self()

      :ok =
        Server.register_tool(server, "confirm", %{
          handler: fn arguments, context ->
            send(parent, {:round, Map.has_key?(arguments, "confirm"), context.request_meta})

            if Map.has_key?(arguments, "confirm"),
              do: {:ok, "confirmed"},
              else:
                {:input_required,
                 %{
                   "confirm" => %{
                     "method" => "elicitation/create",
                     "params" => %{
                       "message" => "Confirm?",
                       "requestedSchema" => %{"type" => "object"}
                     }
                   }
                 }}
          end
        })

      capabilities = %{"elicitation" => %{}}
      answer = %{"confirm" => %{"action" => "accept", "content" => %{}}}

      first_meta = %{
        "com.example/round" => "first",
        "traceparent" => "00-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902b7-01",
        "progressToken" => "p-1",
        "io.modelcontextprotocol/clientInfo" => %{"name" => "example-client", "version" => "1"}
      }

      retry_meta = %{
        "com.example/round" => "second",
        "traceparent" => "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
        "progressToken" => "p-2",
        "io.modelcontextprotocol/clientInfo" => %{"name" => "example-client", "version" => "2"}
      }

      assert %{"result" => %{"requestState" => state}} =
               ServerTest.call_tool(server, "confirm", %{},
                 client_capabilities: capabilities,
                 meta: first_meta
               )

      assert_receive {:round, false, %{"com.example/round" => "first"}}

      assert %{"result" => %{"resultType" => "complete"}} =
               ServerTest.call_tool(server, "confirm", %{},
                 client_capabilities: capabilities,
                 meta: retry_meta,
                 request_state: state,
                 input_responses: answer
               )

      assert_receive {:round, true, seen}
      assert Map.take(seen, Map.keys(retry_meta)) == retry_meta
    end

    test "a retry with different client capabilities is rejected" do
      server = start_server()

      :ok =
        Server.register_tool(server, "confirm", %{
          handler: fn arguments, _context ->
            if Map.has_key?(arguments, "confirm"),
              do: {:ok, "confirmed"},
              else:
                {:input_required,
                 %{
                   "confirm" => %{
                     "method" => "elicitation/create",
                     "params" => %{
                       "message" => "Confirm?",
                       "requestedSchema" => %{"type" => "object"}
                     }
                   }
                 }}
          end
        })

      assert %{"result" => %{"requestState" => state}} =
               ServerTest.call_tool(server, "confirm", %{},
                 client_capabilities: %{"elicitation" => %{}}
               )

      assert %{"error" => %{"data" => %{"reason" => "invalid_request_state"}}} =
               ServerTest.call_tool(server, "confirm", %{},
                 client_capabilities: %{"elicitation" => %{}, "sampling" => %{}},
                 request_state: state,
                 input_responses: %{"confirm" => %{"action" => "accept", "content" => %{}}}
               )
    end
  end

  describe "observability" do
    @events [
      [:attesto_mcp_server, :request, :start],
      [:attesto_mcp_server, :request, :stop],
      [:attesto_mcp_server, :request, :exception],
      [:attesto_mcp_server, :handler, :start],
      [:attesto_mcp_server, :handler, :stop],
      [:attesto_mcp_server, :handler, :exception],
      [:attesto_mcp_server, :cache, :choice],
      [:attesto_mcp_server, :protocol, :error],
      [:attesto_mcp_server, :mrtr, :round],
      [:attesto_mcp_server, :http_request, :stop],
      [:attesto_mcp_server, :auth, :refusal]
    ]

    test "metadata values stay out of telemetry and error responses" do
      server = start_server(max_request_meta_bytes: 1_024)
      register_meta_tool(server)
      parent = self()
      handler_id = {__MODULE__, make_ref()}

      :ok =
        :telemetry.attach_many(handler_id, @events, &__MODULE__.forward_telemetry/4, parent)

      on_exit(fn -> :telemetry.detach(handler_id) end)

      secret = "sk-test-value-0123456789"
      meta = %{"com.example/secret" => secret, "com.example/key-#{secret}" => true}

      success = ServerTest.call_tool(server, "echo_meta", %{}, meta: meta)
      assert %{"result" => _} = success
      refute inspect(success) =~ secret

      unknown = ServerTest.call_tool(server, "missing_tool", %{}, meta: meta)
      assert %{"error" => %{"code" => -32602}} = unknown
      refute inspect(unknown) =~ secret

      too_large =
        ServerTest.call_tool(server, "echo_meta", %{},
          meta: Map.put(meta, "com.example/blob", String.duplicate("x", 2_000))
        )

      assert %{"error" => %{"data" => %{"reason" => "request_meta_too_large"}}} = too_large
      refute inspect(too_large) =~ secret

      listed = ServerTest.list_tools(server, meta: meta)
      assert %{"result" => %{"tools" => [_]}} = listed
      refute inspect(listed) =~ secret

      events = collect_telemetry([])

      assert Enum.any?(events, fn {event, _m, _md} ->
               event == [:attesto_mcp_server, :handler, :stop]
             end)

      assert Enum.any?(events, fn {event, _m, _md} ->
               event == [:attesto_mcp_server, :cache, :choice]
             end)

      for {event, measurements, metadata} <- events do
        refute inspect(metadata) =~ secret, "#{inspect(event)} metadata exposed request metadata"
        refute inspect(measurements) =~ secret
      end
    end
  end

  describe "key helpers" do
    test "reserved keys follow the MCP prefix rule" do
      for key <- [
            "progressToken",
            "traceparent",
            "tracestate",
            "baggage",
            "io.modelcontextprotocol/protocolVersion",
            "dev.mcp/anything",
            "org.modelcontextprotocol.api/value",
            "com.mcp.tools/value"
          ] do
        assert RequestMeta.reserved_key?(key), key
      end

      for key <- [
            "com.example.mcp/value",
            "com.example/request-purpose",
            "plain",
            "mcp/value",
            :atom_key,
            7
          ] do
        refute RequestMeta.reserved_key?(key), inspect(key)
      end
    end

    test "valid keys follow the MCP key grammar" do
      for key <- [
            "com.example/request-purpose",
            "com.example/",
            "simple",
            "a",
            "a.b-c_d9",
            "x/name",
            "io.modelcontextprotocol/protocolVersion"
          ] do
        assert RequestMeta.valid_key?(key), key
      end

      for key <- [
            "",
            "_leading",
            "trailing_",
            "-leading",
            "1com/value",
            "com..example/value",
            "com.example-/value",
            "com.example/has space",
            "com.example/a/b",
            String.duplicate("a", 257),
            :atom,
            nil
          ] do
        refute RequestMeta.valid_key?(key), inspect(key)
      end
    end

    test "application/1 keeps only non-reserved keys" do
      meta = %{
        "com.example/request-purpose" => "audit",
        "plain" => 1,
        "io.modelcontextprotocol/clientCapabilities" => %{},
        "progressToken" => 1,
        "baggage" => "a=b"
      }

      assert RequestMeta.application(meta) == %{
               "com.example/request-purpose" => "audit",
               "plain" => 1
             }
    end
  end

  def forward_telemetry(event, measurements, metadata, parent),
    do: send(parent, {:telemetry, event, measurements, metadata})

  defp collect_round_meta(acc) do
    receive do
      {:round_meta, principal, retried?, meta} ->
        collect_round_meta([{principal, retried?, meta} | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  defp collect_telemetry(acc) do
    receive do
      {:telemetry, event, measurements, metadata} ->
        collect_telemetry([{event, measurements, metadata} | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  defp http_call(plug, token, tool, meta) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => tool, "arguments" => %{}, "_meta" => meta}
    }

    conn(:post, "/mcp", Jason.encode!(request))
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("mcp-protocol-version", @modern)
    |> put_req_header("mcp-method", "tools/call")
    |> put_req_header("mcp-name", tool)
    |> AttestoMCP.Server.Plug.call(plug)
  end
end
