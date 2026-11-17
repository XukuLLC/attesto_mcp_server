defmodule AttestoMCP.Server.SamplingTest do
  use ExUnit.Case, async: true

  alias AttestoMCP.Server
  alias AttestoMCP.Server.Test, as: Client

  @method "sampling/createMessage"
  @modern "2026-07-28"
  @legacy "2025-11-25"
  @oldest "2025-06-18"
  @tools %{"sampling" => %{"tools" => %{}}}
  @sampling %{"sampling" => %{}}
  @start %{"role" => "user", "content" => %{"type" => "text", "text" => "Look up a value"}}
  @finish %{
    "role" => "assistant",
    "content" => %{"type" => "text", "text" => "Found it"},
    "model" => "sample-model",
    "stopReason" => "provider-specific-stop"
  }

  for count <- [1, 2] do
    @count count

    test "modern sampling completes a tool loop with #{count} tool-use blocks" do
      calls = Enum.map(1..@count, &tool_use/1)
      first = sampling_params()
      response = tool_use_result(calls)
      continuation = follow_up(first, response)
      {:ok, server} = Server.start_link([])

      :ok =
        Server.register_tool(server, "sample", %{
          handler: fn
            %{"follow_up" => final}, _ -> {:ok, final["content"]["text"]}
            %{"generation" => result}, _ -> input_request(follow_up(first, result), "follow_up")
            _args, _ -> input_request(first, "generation")
          end
        })

      assert %{
               "result" => %{
                 "inputRequests" => %{"generation" => %{"params" => ^first}},
                 "requestState" => first_state
               }
             } = call_modern(server, @tools)

      assert %{
               "result" => %{
                 "inputRequests" => %{"follow_up" => %{"params" => ^continuation}},
                 "requestState" => second_state
               }
             } = retry_modern(server, first_state, %{"generation" => response})

      assert %{"result" => %{"content" => [%{"type" => "text", "text" => "Found it"}]}} =
               retry_modern(server, second_state, %{"follow_up" => @finish})
    end

    test "session-bound sampling completes a tool loop with #{count} tool-use blocks" do
      {server, session, stream} = legacy_session(@legacy, @tools)
      first = sampling_params()
      response = tool_use_result(Enum.map(1..@count, &tool_use/1))
      continuation = follow_up(first, response)

      :ok =
        Server.register_tool(server, "sample", %{
          handler: fn _args, context ->
            with {:ok, result} <- context.client_request.(@method, first),
                 {:ok, final} <- context.client_request.(@method, follow_up(first, result)) do
              {:ok, final["content"]["text"]}
            end
          end
        })

      task = Task.async(fn -> call_legacy(server, session) end)

      assert_receive {:mcp_legacy_event, ^stream, _,
                      %{"method" => @method, "id" => first_id, "params" => ^first}},
                     1_000

      assert :ok = deliver(server, session, first_id, response)

      assert_receive {:mcp_legacy_event, ^stream, _,
                      %{"method" => @method, "id" => second_id, "params" => ^continuation}},
                     1_000

      assert :ok = deliver(server, session, second_id, @finish)

      assert {1, %{"result" => %{"content" => [%{"type" => "text", "text" => "Found it"}]}}} =
               Task.await(task)
    end
  end

  test "both tool-enabled revisions require the sampling tools capability for either field" do
    {legacy, session, _stream} = legacy_session(@legacy, @sampling)

    for field <- ["tools", "toolChoice"] do
      params = Map.take(sampling_params(), ["messages", "maxTokens", field])
      modern = modern_handler(params)

      assert {:error, :missing_capability} = ask(legacy, session, params)
      refute_received {:mcp_legacy_event, _, _, %{"method" => @method}}

      for capabilities <- [@sampling, %{}] do
        assert %{
                 "error" => %{"code" => -32_021, "data" => %{"requiredCapabilities" => @sampling}}
               } =
                 call_modern(modern, capabilities)
      end
    end
  end

  test "both tool-enabled revisions refuse invalid outgoing messages, tools, and tool choices" do
    {legacy, session, _stream} = legacy_session(@legacy, @tools)
    first = sampling_params()
    first_answer = tool_result("call-1")
    calls = %{"role" => "assistant", "content" => [tool_use(1), tool_use(2)]}

    for params <- [
          Map.delete(first, "maxTokens"),
          Map.put(first, "metadata", nil),
          %{first | "tools" => [%{"name" => "lookup", "inputSchema" => %{"type" => "array"}}]},
          %{
            first
            | "tools" => [put_in(hd(first["tools"]), ["annotations"], %{"readOnlyHint" => 1})]
          },
          %{first | "toolChoice" => %{"mode" => "sometimes"}},
          %{first | "toolChoice" => nil},
          %{first | "messages" => [calls]},
          %{first | "messages" => [calls, @start, user([first_answer, tool_result("call-2")])]},
          %{first | "messages" => [calls, user([first_answer])]},
          %{first | "messages" => [calls, user([first_answer, tool_result("other")])]},
          %{first | "messages" => [calls, user([first_answer, first_answer])]},
          %{
            first
            | "messages" => [
                calls,
                user([first_answer, tool_result("call-2"), @start["content"]])
              ]
          },
          %{first | "messages" => [user(first_answer)]},
          %{first | "messages" => [user(tool_use(1))]},
          %{first | "messages" => [user([[Map.fetch!(@start, "content")]])]}
        ] do
      assert {:error, :invalid_input_request} = ask(legacy, session, params)

      assert %{"error" => %{"code" => -32_602, "data" => %{"reason" => "invalid_input_requests"}}} =
               params |> modern_handler() |> call_modern(@tools)
    end

    refute_received {:mcp_legacy_event, _, _, %{"method" => @method}}
  end

  test "2025-06-18 sampling rejects tool use on requests and results and requires a single block" do
    {server, session, stream} = legacy_session(@oldest, @sampling)
    plain = %{"maxTokens" => 64, "messages" => [@start]}
    call = %{"role" => "assistant", "content" => tool_use(1)}

    assert {:error, :invalid_input_request} =
             ask(server, session, %{plain | "messages" => [call]})

    assert {:error, :invalid_input_request} =
             ask(server, session, %{plain | "messages" => [user([@start["content"]])]})

    refute_received {:mcp_legacy_event, ^stream, _, %{"method" => @method}}

    for result <- [tool_use_result([tool_use(1)]), %{@finish | "content" => [@finish["content"]]}] do
      assert_legacy_invalid_response(server, session, stream, plain, result)
    end
  end

  test "sampling forbids top-level resource content and malformed results in every revision" do
    plain = %{"maxTokens" => 64, "messages" => [@start]}
    modern = modern_handler(plain)
    %{"result" => %{"requestState" => state}} = call_modern(modern, @sampling)

    malformed_results = [
      %{
        @finish
        | "content" => %{"type" => "resource_link", "uri" => "urn:test", "name" => "test"}
      },
      %{
        @finish
        | "content" => %{
            "type" => "resource",
            "resource" => %{"uri" => "urn:test", "text" => "example"}
          }
      },
      %{@finish | "role" => "system"},
      %{@finish | "model" => nil},
      %{@finish | "stopReason" => false},
      %{@finish | "stopReason" => nil}
    ]

    for result <- malformed_results do
      assert %{"error" => %{"code" => -32_602, "data" => %{"reason" => "invalid_input_response"}}} =
               retry_modern(modern, state, %{"generation" => result}, @sampling)
    end

    for revision <- [@legacy, @oldest] do
      {server, session, stream} = legacy_session(revision, @sampling)

      for result <- malformed_results do
        assert_legacy_invalid_response(server, session, stream, plain, result)
      end
    end
  end

  test "tool result structured content follows the protocol revision" do
    {legacy, session, _stream} = legacy_session(@legacy, @tools)
    params = sampling_params()
    call = %{"role" => "assistant", "content" => tool_use(1)}
    result = Map.put(tool_result("call-1"), "structuredContent", [1, nil])
    params = %{params | "messages" => [@start, call, user(result)]}

    assert {:error, :invalid_input_request} = ask(legacy, session, params)

    assert %{"result" => %{"inputRequests" => %{"generation" => %{"params" => ^params}}}} =
             params |> modern_handler() |> call_modern(@tools)
  end

  defp sampling_params do
    %{
      "messages" => [@start],
      "maxTokens" => 64,
      "tools" => [%{"name" => "lookup", "inputSchema" => %{"type" => "object"}}],
      "toolChoice" => %{"mode" => "auto"}
    }
  end

  defp tool_use(id),
    do: %{"type" => "tool_use", "id" => "call-#{id}", "name" => "lookup", "input" => %{}}

  defp tool_result(id) do
    %{
      "type" => "tool_result",
      "toolUseId" => id,
      "content" => [
        %{"type" => "text", "text" => "value"},
        %{"type" => "resource_link", "name" => "detail", "uri" => "urn:lookup:detail"}
      ]
    }
  end

  defp tool_use_result([call]), do: %{@finish | "content" => call, "stopReason" => "toolUse"}
  defp tool_use_result(calls), do: %{@finish | "content" => calls, "stopReason" => "toolUse"}
  defp user(content), do: %{"role" => "user", "content" => content}

  defp follow_up(first, result) do
    calls = result["content"]
    answers = calls |> List.wrap() |> Enum.reverse() |> Enum.map(&tool_result(&1["id"]))
    answers = if is_map(calls), do: hd(answers), else: answers

    %{
      first
      | "messages" => first["messages"] ++ [Map.take(result, ["role", "content"]), user(answers)]
    }
  end

  defp input_request(params, key),
    do: {:input_required, %{key => %{"method" => @method, "params" => params}}}

  defp modern_handler(params) do
    {:ok, server} = Server.start_link([])

    :ok =
      Server.register_tool(server, "sample", %{
        handler: fn _, _ -> input_request(params, "generation") end
      })

    server
  end

  defp call_modern(server, capabilities),
    do:
      Client.call_tool(server, "sample", %{},
        client_capabilities: capabilities,
        protocol_version: @modern
      )

  defp retry_modern(server, state, responses, capabilities \\ @tools) do
    Client.call_tool(server, "sample", %{},
      request_state: state,
      input_responses: responses,
      client_capabilities: capabilities,
      protocol_version: @modern
    )
  end

  defp legacy_session(revision, capabilities) do
    {:ok, server} = Server.start_link([])
    {:ok, session} = Server.new_session(server, "owner", nil)
    :ok = Server.negotiate_session(server, session.id, "owner", nil, revision, capabilities)
    :ok = Server.mark_initialized(server, session.id)
    {:ok, stream} = Server.open_legacy_stream(server, session.id, "owner", nil, self())
    {server, session, stream}
  end

  defp ask(server, session, params),
    do: Server.request_client(server, session.id, "owner", nil, @method, params, 1_000)

  defp deliver(server, session, id, result),
    do:
      Server.deliver_client_response(server, session.id, "owner", nil, %{
        kind: :response,
        id: id,
        result: result
      })

  defp call_legacy(server, session) do
    Server.dispatch(
      server,
      %{
        kind: :request,
        id: 1,
        method: "tools/call",
        params: %{"name" => "sample", "arguments" => %{}}
      },
      %{principal: "owner", session_id: session.id},
      version: @legacy
    )
  end

  defp assert_legacy_invalid_response(server, session, stream, params, result) do
    task = Task.async(fn -> ask(server, session, params) end)
    assert_receive {:mcp_legacy_event, ^stream, _, %{"method" => @method, "id" => id}}, 1_000
    assert {:error, :invalid_response} = deliver(server, session, id, result)
    assert {:error, :invalid_response} = Task.await(task)
  end
end
