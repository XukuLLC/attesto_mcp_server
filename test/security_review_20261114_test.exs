defmodule AttestoMCP.Server.SecurityReview20261114Test do
  use ExUnit.Case, async: true

  alias AttestoMCP.Server
  alias AttestoMCP.Server.{Elicitation, Error, Output, Registry, Text}
  alias AttestoMCP.Server.Test, as: Client

  @legacy "2025-11-25"
  @esc "\e[2J\e]8;;https://evil.example\a"

  test "server-initiated requests skip revoked legacy GET streams" do
    {:ok, server} = Server.start_link(client_request_timeout: 500)
    {:ok, session} = Server.new_session(server, "usr", "tenant")

    assert :ok =
             Server.negotiate_session(server, session.id, "usr", "tenant", @legacy, %{
               "elicitation" => %{}
             })

    assert :ok = Server.mark_initialized(server, session.id)

    parent = self()
    {:ok, active_flag} = Agent.start_link(fn -> true end)
    {:ok, revoked_flag} = Agent.start_link(fn -> false end)

    relay = fn tag ->
      spawn(fn ->
        receive_loop(parent, tag)
      end)
    end

    valid_sink = relay.(:valid)
    revoked_sink = relay.(:revoked)

    assert {:ok, valid_ref} =
             Server.open_legacy_stream(
               server,
               session.id,
               "usr",
               "tenant",
               valid_sink,
               fn _ -> Agent.get(active_flag, & &1) end
             )

    assert {:ok, revoked_ref} =
             Server.open_legacy_stream(
               server,
               session.id,
               "usr",
               "tenant",
               revoked_sink,
               fn _ -> Agent.get(revoked_flag, & &1) end
             )

    params = %{
      "mode" => "form",
      "message" => "Confirm transfer?",
      "requestedSchema" => %{
        "type" => "object",
        "properties" => %{"ok" => %{"type" => "boolean"}}
      }
    }

    task =
      Task.async(fn ->
        Server.request_client(
          server,
          session.id,
          "usr",
          "tenant",
          "elicitation/create",
          params,
          500
        )
      end)

    assert_receive {:valid, {:mcp_legacy_event, ^valid_ref, _event_id, req}}, 1_000
    refute_receive {:revoked, {:mcp_legacy_event, ^revoked_ref, _, _}}, 50
    Server.ack_legacy_stream(server, valid_ref)

    assert :ok =
             Server.deliver_client_response(server, session.id, "usr", "tenant", %{
               kind: :response,
               id: req["id"],
               result: %{"action" => "accept", "content" => %{"ok" => true}},
               error: nil
             })

    assert {:ok, %{"action" => "accept", "content" => %{"ok" => true}}} = Task.await(task, 1_000)

    # When every stream's authorizer returns false, no stream receives the request.
    Agent.update(active_flag, fn _ -> false end)

    assert {:error, :not_ready} =
             Server.request_client(
               server,
               session.id,
               "usr",
               "tenant",
               "elicitation/create",
               params,
               100
             )

    refute_receive {:valid, {:mcp_legacy_event, ^valid_ref, _, _}}, 50
    refute_receive {:revoked, {:mcp_legacy_event, ^revoked_ref, _, _}}, 50
    send(valid_sink, :stop)
    send(revoked_sink, :stop)
  end

  test "display_text_policy: :reject inspects completion values, enumNames, systemPrompt, mimeType, uri, error data and notifications" do
    {:ok, server} =
      Server.start_link(
        display_text_policy: :reject,
        rate_limits: false,
        capabilities: %{"logging" => %{}}
      )

    assert :ok =
             Server.register_prompt(server, "p",
               arguments: [%{name: "a"}],
               handler: fn _ -> [] end
             )

    assert :ok =
             Server.register_completion(server, "p",
               ref: %{"type" => "ref/prompt", "name" => "p"},
               handler: fn _, _ -> {:ok, %{values: [@esc], hasMore: false}} end
             )

    assert %{"error" => %{"code" => -32603}} =
             Client.complete(server, %{"type" => "ref/prompt", "name" => "p"}, %{
               "name" => "a",
               "value" => ""
             })

    assert :ok =
             Server.register_tool(server, "mime",
               handler: fn _ ->
                 %{
                   content: [
                     %{
                       type: "resource",
                       resource: %{uri: "urn:x", mimeType: "text/plain" <> @esc, text: "ok"}
                     }
                   ]
                 }
               end
             )

    assert %{"error" => %{"code" => -32603}} = Client.call_tool(server, "mime", %{})

    assert :ok =
             Server.register_tool(server, "errdata",
               handler: fn _ -> {:error, Error.invalid_params(%{"reason" => @esc})} end
             )

    assert %{"error" => %{"code" => -32603}} = Client.call_tool(server, "errdata", %{})

    enum_names_msg = %{
      "method" => "elicitation/create",
      "params" => %{
        "message" => "pick",
        "requestedSchema" => %{
          "type" => "object",
          "properties" => %{
            "c" => %{"type" => "string", "enum" => ["a"], "enumNames" => [@esc]}
          }
        }
      }
    }

    assert {:error, :terminal_control_character} =
             Text.wire(enum_names_msg, display_text_policy: :reject)

    assert :ok =
             Server.register_tool(server, "enumnames",
               handler: fn _ -> {:input_required, %{"q" => enum_names_msg}} end
             )

    assert %{"error" => _} =
             Client.call_tool(server, "enumnames", %{},
               client_capabilities: %{"elicitation" => %{}}
             )

    sampling_msg = %{
      "method" => "sampling/createMessage",
      "params" => %{
        "messages" => [
          %{"role" => "user", "content" => %{"type" => "text", "text" => "hi"}}
        ],
        "systemPrompt" => @esc,
        "maxTokens" => 10
      }
    }

    assert {:error, :terminal_control_character} =
             Text.wire(sampling_msg, display_text_policy: :reject)

    assert :ok =
             Server.register_tool(server, "sample",
               handler: fn _ -> {:input_required, %{"s" => sampling_msg}} end
             )

    assert %{"error" => _} =
             Client.call_tool(server, "sample", %{}, client_capabilities: %{"sampling" => %{}})

    log = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/message",
      "params" => %{"level" => "info", "logger" => @esc, "data" => @esc}
    }

    assert {:error, :terminal_control_character} = Text.wire(log, display_text_policy: :reject)

    media = %{
      "content" => [%{"type" => "image", "mimeType" => "image/png", "data" => @esc}]
    }

    assert :ok = Text.wire(media, display_text_policy: :reject)

    parent = self()

    assert :ok =
             Server.register_tool(server, "notify_bad",
               handler: fn _, context ->
                 res =
                   context.notify.(%{
                     "jsonrpc" => "2.0",
                     "method" => "notifications/message",
                     "params" => %{"level" => "info", "data" => %{"msg" => @esc}}
                   })

                 send(parent, {:notify_res, res})
                 {:ok, "done"}
               end
             )

    assert {99, %{"result" => _}} =
             Server.dispatch(
               server,
               %{
                 kind: :request,
                 id: 99,
                 method: "tools/call",
                 params: %{
                   "_meta" => %{
                     "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
                     "io.modelcontextprotocol/clientCapabilities" => %{}
                   },
                   "name" => "notify_bad",
                   "arguments" => %{}
                 }
               },
               %{principal: "p"},
               version: "2026-07-28",
               on_event: fn event -> send(parent, {:stream_event, event}) end
             )

    assert_receive {:notify_res, {:error, :terminal_control_character}}, 1_000
  end

  test "rejects undeclared elicitation keys and non-flat schema combinators" do
    opts = [max_json_bytes: 100_000]
    schema = %{"type" => "object", "properties" => %{"ok" => %{"type" => "boolean"}}}
    params = %{"message" => "Approve?", "requestedSchema" => schema}

    assert Elicitation.valid_response?(
             params,
             %{"action" => "accept", "content" => %{"ok" => true}},
             opts
           )

    refute Elicitation.valid_response?(
             params,
             %{"action" => "accept", "content" => %{"ok" => true, "role" => %{"admin" => true}}},
             opts
           )

    bad_schemas = [
      %{
        "type" => "object",
        "properties" => %{},
        "patternProperties" => %{".*" => %{"type" => "object"}}
      },
      %{
        "type" => "object",
        "properties" => %{"c" => %{"type" => "string"}},
        "additionalProperties" => %{"type" => "object"}
      },
      %{"type" => "object", "properties" => %{"c" => %{"type" => "string", "$ref" => "#"}}},
      %{
        "type" => "object",
        "properties" => %{"c" => %{"type" => "string", "oneOf" => [%{"type" => "object"}]}}
      },
      %{
        "type" => "object",
        "properties" => %{
          "c" => %{
            "type" => "array",
            "items" => %{"type" => "string", "enum" => ["a"], "$ref" => "#/properties/c"}
          }
        }
      },
      %{
        "type" => "object",
        "properties" => %{
          "c" => %{
            "type" => "array",
            "items" => %{"anyOf" => [%{"const" => "a"}], "type" => "object"}
          }
        }
      }
    ]

    for bad_schema <- bad_schemas do
      refute Elicitation.valid_request?(
               %{"message" => "m", "requestedSchema" => bad_schema},
               opts
             )
    end
  end

  test "double-space and blank Authorization headers match Attesto.Plug.Authenticate.parse_authorization/1" do
    assert {:ok, :bearer, "tok"} = Attesto.Plug.Authenticate.parse_authorization("Bearer  tok")
    assert :malformed = Attesto.Plug.Authenticate.parse_authorization("Bearer   ")
    assert {:ok, :bearer, "tok"} = Attesto.Plug.Authenticate.parse_authorization("Bearer tok")
  end

  test "Output.safe_uri?/1 and Registry reject mixed-case loopback hosts and terminal controls" do
    refute Output.safe_uri?("http://LOCALHOST/x")
    refute Output.safe_uri?("urn:x\e[2J")

    {:ok, registry} = Registry.start_link([])

    assert {:error, {:invalid_definition, :uri}} =
             Registry.register(registry, :resource, "http://LOCALHOST/x", %{})

    assert {:error, {:invalid_definition, :uri}} =
             Registry.register(registry, :resource, "urn:x\e[2J", %{})
  end

  defp receive_loop(parent, tag) do
    receive do
      :stop ->
        :ok

      msg ->
        send(parent, {tag, msg})
        receive_loop(parent, tag)
    end
  end
end
