defmodule AttestoMCP.Server.RetryBindingMetadataTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server
  alias AttestoMCP.Server.Test, as: ServerTest

  @modern "2026-07-28"
  @capabilities %{"elicitation" => %{}}
  @answer %{"confirm" => %{"action" => "accept", "content" => %{}}}
  @application_meta %{
    "com.example/item" => "A",
    "com.example/options" => %{"mode" => "safe"},
    "plain" => "unchanged",
    "io.modelcontextprotocol/exampleExtension" => %{"enabled" => false},
    "io.modelcontextprotocol/logLevel" => "info"
  }

  setup do
    server = start_supervised!({Server, []})

    for kind <- [:tool, :resource, :prompt] do
      register_interactive(server, kind, self())
    end

    %{server: server}
  end

  test "each primitive accepts fresh trace, progress, and client display metadata", %{
    server: server
  } do
    first_meta = Map.merge(@application_meta, volatile_meta("first"))
    retry_meta = Map.merge(@application_meta, volatile_meta("second"))

    for kind <- [:tool, :resource, :prompt] do
      assert %{"result" => %{"requestState" => state}} = invoke(server, kind, first_meta)
      assert_receive {:round, ^kind, false, first_snapshot, first_trace}
      assert Map.take(first_snapshot, Map.keys(first_meta)) == first_meta
      assert first_trace == Map.take(first_meta, ["traceparent", "tracestate", "baggage"])

      assert %{"result" => %{"resultType" => "complete"}} =
               invoke(server, kind, retry_meta, request_state: state, input_responses: @answer)

      assert_receive {:round, ^kind, true, retry_snapshot, retry_trace}
      assert Map.take(retry_snapshot, Map.keys(retry_meta)) == retry_meta
      assert retry_trace == Map.take(retry_meta, ["traceparent", "tracestate", "baggage"])
      refute retry_trace == first_trace
    end
  end

  test "application and unknown metadata changes cannot redeem any primitive's state", %{
    server: server
  } do
    for kind <- [:tool, :resource, :prompt], changed_meta <- changed_bound_metadata() do
      assert %{"result" => %{"requestState" => state}} = invoke(server, kind, @application_meta)
      assert_receive {:round, ^kind, false, _snapshot, _trace}

      assert %{"error" => %{"data" => %{"reason" => "invalid_request_state"}}} =
               invoke(server, kind, changed_meta, request_state: state, input_responses: @answer)

      refute_received {:round, ^kind, true, _snapshot, _trace}

      assert %{"result" => %{"resultType" => "complete"}} =
               invoke(server, kind, @application_meta,
                 request_state: state,
                 input_responses: @answer
               )

      assert_receive {:round, ^kind, true, _snapshot, _trace}

      assert %{"error" => %{"data" => %{"reason" => "invalid_request_state"}}} =
               invoke(server, kind, @application_meta,
                 request_state: state,
                 input_responses: @answer
               )
    end
  end

  test "an answer to the item A confirmation cannot complete item B", %{server: server} do
    assert %{
             "result" => %{
               "requestState" => state,
               "inputRequests" => %{"confirm" => %{"params" => %{"message" => "Confirm item A"}}}
             }
           } = invoke(server, :tool, @application_meta)

    assert_receive {:round, :tool, false, _snapshot, _trace}

    assert %{"error" => %{"data" => %{"reason" => "invalid_request_state"}}} =
             invoke(server, :tool, Map.put(@application_meta, "com.example/item", "B"),
               request_state: state,
               input_responses: @answer
             )

    refute_received {:round, :tool, true, _snapshot, _trace}

    assert %{"result" => %{"structuredContent" => %{"confirmed_item" => "A"}}} =
             invoke(server, :tool, @application_meta,
               request_state: state,
               input_responses: @answer
             )
  end

  test "adding or removing volatile metadata keeps the operation bound", %{server: server} do
    first_meta = Map.merge(@application_meta, volatile_meta("first"))

    assert %{"result" => %{"requestState" => state}} = invoke(server, :tool, first_meta)
    assert_receive {:round, :tool, false, _snapshot, _trace}

    assert %{"result" => %{"resultType" => "complete"}} =
             invoke(server, :tool, @application_meta,
               request_state: state,
               input_responses: @answer
             )

    assert_receive {:round, :tool, true, snapshot, %{}}
    refute Map.has_key?(snapshot, "traceparent")
    refute Map.has_key?(snapshot, "progressToken")

    assert %{"result" => %{"requestState" => next_state}} =
             invoke(server, :tool, @application_meta)

    assert_receive {:round, :tool, false, _snapshot, _trace}

    assert %{"result" => %{"resultType" => "complete"}} =
             invoke(server, :tool, first_meta,
               request_state: next_state,
               input_responses: @answer
             )

    assert_receive {:round, :tool, true, snapshot, _trace}
    assert snapshot["progressToken"] == "first-progress"
  end

  test "trusted client binding and tenant changes leave the original state usable", %{
    server: server
  } do
    context = %{
      principal: "user",
      principal_binding: {"user", "client-a"},
      tenant: "tenant-a",
      scopes: []
    }

    params = protocol_params()
    assert %{"result" => %{"requestState" => state}} = dispatch(server, 1, params, context)
    assert_receive {:round, :tool, false, _snapshot, _trace}
    retry_params = retry_params(params, state)

    assert %{"error" => %{"data" => %{"reason" => "invalid_request_state"}}} =
             dispatch(server, 2, retry_params, %{
               context
               | principal_binding: {"user", "client-b"}
             })

    assert %{"error" => %{"data" => %{"reason" => "invalid_request_state"}}} =
             dispatch(server, 3, retry_params, %{context | tenant: "tenant-b"})

    refute_received {:round, :tool, true, _snapshot, _trace}

    assert %{"result" => %{"resultType" => "complete"}} =
             dispatch(server, 4, retry_params, context)

    assert %{"error" => %{"data" => %{"reason" => "invalid_request_state"}}} =
             dispatch(server, 5, retry_params, context)
  end

  test "a scope-denied direct retry does not consume the valid state" do
    server = start_supervised!({Server, []}, id: :scoped_retry)
    register_interactive(server, :tool, self(), %{required_scopes: ["items.read"]})
    context = %{principal: "user", tenant: "tenant-a", scopes: ["items.read"]}
    params = protocol_params()

    assert %{"result" => %{"requestState" => state}} = dispatch(server, 1, params, context)
    assert_receive {:round, :tool, false, _snapshot, _trace}
    retry_params = retry_params(params, state)

    assert %{"error" => %{"data" => %{"reason" => "unknown_tool"}}} =
             dispatch(server, 2, retry_params, %{context | scopes: []})

    refute_received {:round, :tool, true, _snapshot, _trace}

    assert %{"result" => %{"resultType" => "complete"}} =
             dispatch(server, 3, retry_params, context)
  end

  test "a completed tool retry cannot retain handler-authored cache hints", %{server: server} do
    :ok =
      Server.register_tool(server, "authored_hints", %{
        handler: fn arguments, _context ->
          if Map.has_key?(arguments, "confirm"),
            do:
              {:ok,
               %{
                 "content" => [%{"type" => "text", "text" => "confirmed"}],
                 "ttlMs" => 60_000,
                 "cacheScope" => "public"
               }},
            else: {:input_required, %{"confirm" => form_request("Confirm?")}}
        end
      })

    opts = [client_capabilities: @capabilities]

    assert %{"result" => %{"requestState" => state}} =
             ServerTest.call_tool(server, "authored_hints", %{}, opts)

    assert %{"result" => %{"resultType" => "complete"} = result} =
             ServerTest.call_tool(
               server,
               "authored_hints",
               %{},
               opts ++ [request_state: state, input_responses: @answer]
             )

    refute Map.has_key?(result, "ttlMs")
    refute Map.has_key?(result, "cacheScope")
  end

  defp changed_bound_metadata do
    [
      Map.put(@application_meta, "com.example/item", "B"),
      Map.put(@application_meta, "com.example/options", %{"mode" => "other"}),
      Map.delete(@application_meta, "plain"),
      Map.put(@application_meta, "com.example/new-option", true),
      Map.put(@application_meta, "io.modelcontextprotocol/exampleExtension", %{"enabled" => true}),
      Map.put(@application_meta, "io.modelcontextprotocol/logLevel", "debug")
    ]
  end

  defp volatile_meta(round) do
    parent = if round == "first", do: "00f067aa0ba902b7", else: "b7ad6b7169203331"

    %{
      "traceparent" => "00-0af7651916cd43dd8448eb211c80319c-#{parent}-01",
      "tracestate" => "example=#{round}",
      "baggage" => "round=#{round}",
      "progressToken" => "#{round}-progress",
      "io.modelcontextprotocol/clientInfo" => %{"name" => "example-client", "version" => round}
    }
  end

  defp register_interactive(server, kind, owner, fields \\ %{}) do
    handler = fn input, context -> interactive_result(kind, input, context, owner) end
    definition = Map.put(fields, :handler, handler)

    case kind do
      :tool -> :ok = Server.register_tool(server, "confirm", definition)
      :resource -> :ok = Server.register_resource(server, "urn:example:confirm", definition)
      :prompt -> :ok = Server.register_prompt(server, "confirm", definition)
    end
  end

  defp interactive_result(kind, input, context, owner) do
    arguments = if kind == :prompt, do: input.arguments, else: input
    answered? = Map.has_key?(arguments, "confirm")
    send(owner, {:round, kind, answered?, context.request_meta, context.trace_context})
    item = context.request_meta["com.example/item"]

    if answered?,
      do: {:ok, completed_result(kind, item)},
      else: {:input_required, %{"confirm" => form_request("Confirm item #{item}")}}
  end

  defp completed_result(:tool, item), do: %{"confirmed_item" => item}

  defp completed_result(:resource, item),
    do: %{"contents" => [%{"uri" => "urn:example:confirm", "text" => "confirmed #{item}"}]}

  defp completed_result(:prompt, item),
    do: [%{"role" => "user", "content" => %{"type" => "text", "text" => "confirmed #{item}"}}]

  defp form_request(message) do
    %{
      "method" => "elicitation/create",
      "params" => %{"message" => message, "requestedSchema" => %{"type" => "object"}}
    }
  end

  defp invoke(server, kind, meta, retry_opts \\ []) do
    opts = [client_capabilities: @capabilities, meta: meta] ++ retry_opts

    case kind do
      :tool -> ServerTest.call_tool(server, "confirm", %{}, opts)
      :resource -> ServerTest.read_resource(server, "urn:example:confirm", opts)
      :prompt -> ServerTest.get_prompt(server, "confirm", %{}, opts)
    end
  end

  defp protocol_params do
    %{
      "name" => "confirm",
      "arguments" => %{},
      "_meta" =>
        Map.merge(@application_meta, %{
          "io.modelcontextprotocol/protocolVersion" => @modern,
          "io.modelcontextprotocol/clientCapabilities" => @capabilities
        })
    }
  end

  defp retry_params(params, state),
    do: params |> Map.put("requestState", state) |> Map.put("inputResponses", @answer)

  defp dispatch(server, id, params, context) do
    {^id, response} =
      Server.dispatch(
        server,
        %{kind: :request, id: id, method: "tools/call", params: params},
        context,
        version: @modern
      )

    response
  end
end
