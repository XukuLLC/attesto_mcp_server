defmodule AttestoMCP.Server.HardeningElicitationTest do
  use ExUnit.Case, async: true

  alias AttestoMCP.Server
  alias AttestoMCP.Server.{Elicitation, InteractionOwner, Options, Retry, UrlElicitation}

  @modern "2026-07-28"
  @form %{
    "message" => "Enter a count",
    "requestedSchema" => %{
      "type" => "object",
      "properties" => %{"count" => %{"type" => "integer", "minimum" => 1}},
      "required" => ["count"],
      "additionalProperties" => false
    }
  }

  test "accepted forms share schema validation on both legacy revisions and modern retries" do
    server = start_supervised!({Server, []})

    for version <- ["2025-06-18", "2025-11-25"] do
      {session, stream} = legacy_session(server, version)

      for response <- [
            %{"action" => "accept", "content" => %{"count" => "1"}},
            %{"action" => "accept", "content" => %{}},
            %{"action" => "accept", "content" => %{"count" => 0}},
            %{"action" => "accept", "content" => %{"count" => 1, "extra" => true}},
            %{"action" => "accept", "content" => %{"count" => 1}},
            %{"action" => "decline"},
            %{"action" => "cancel"}
          ] do
        valid = Elicitation.valid_response?(@form, response, [])

        task =
          Task.async(fn ->
            Server.request_client(server, session.id, "owner", nil, "elicitation/create", @form)
          end)

        assert_receive {:mcp_legacy_event, ^stream, _, %{"id" => id}}, 1_000

        result =
          Server.deliver_client_response(server, session.id, "owner", nil, %{
            kind: :response,
            id: id,
            result: response
          })

        if valid do
          assert result == :ok
          assert Task.await(task) == {:ok, response}
        else
          assert result == {:error, :invalid_response}
          assert Task.await(task) == {:error, :invalid_response}
        end

        Server.ack_legacy_stream(server, stream)

        modern =
          Retry.validate_responses(
            %{"q" => %{"form" => %{"method" => "elicitation/create", "params" => @form}}},
            %{"inputResponses" => %{"form" => response}},
            []
          )

        assert modern == :ok == valid
      end

      Server.delete_session(server, session.id)
    end
  end

  test "form requests accept the 2025-11-25 enum forms, including multi-select, and nothing nested" do
    form = fn property ->
      %{
        "message" => "Pick",
        "requestedSchema" => %{"type" => "object", "properties" => %{"choice" => property}}
      }
    end

    accepted = [
      %{"type" => "string", "enum" => ["a", "b"]},
      %{
        "type" => "string",
        "oneOf" => [%{"const" => "a", "title" => "A"}, %{"const" => "b", "title" => "B"}]
      },
      %{"type" => "string", "enum" => ["a", "b"], "enumNames" => ["A", "B"]},
      %{
        "type" => "array",
        "items" => %{"type" => "string", "enum" => ["a", "b"]},
        "minItems" => 1,
        "maxItems" => 2
      },
      %{
        "type" => "array",
        "items" => %{
          "anyOf" => [%{"const" => "a", "title" => "A"}, %{"const" => "b", "title" => "B"}]
        }
      }
    ]

    for property <- accepted do
      assert Elicitation.valid_request?(form.(property), []),
             "expected #{inspect(property)} to be accepted"
    end

    refused = [
      %{"type" => "array", "items" => %{"type" => "object", "properties" => %{}}},
      %{"type" => "array", "items" => %{"type" => "string"}},
      %{"type" => "array", "items" => %{"anyOf" => [%{"type" => "object"}]}},
      %{"type" => "array", "items" => %{"anyOf" => [%{"const" => "a", "properties" => %{}}]}},
      %{"type" => "array"},
      %{"type" => "object", "properties" => %{}}
    ]

    for property <- refused do
      refute Elicitation.valid_request?(form.(property), []),
             "expected #{inspect(property)} to be refused"
    end

    multi = form.(Enum.at(accepted, 3))

    assert Elicitation.valid_response?(
             multi,
             %{"action" => "accept", "content" => %{"choice" => ["a"]}},
             []
           )

    refute Elicitation.valid_response?(
             multi,
             %{"action" => "accept", "content" => %{"choice" => ["c"]}},
             []
           )
  end

  test "both outbound paths reject unsafe URLs and allow only explicit loopback HTTP" do
    server = start_supervised!({Server, []})
    {session, _stream} = legacy_session(server, "2025-11-25")

    bad_urls = [
      "javascript:alert(1)",
      "file:///tmp/approval",
      "data:text/html,bad",
      "http://example.test/approve",
      "https://user:pass@example.test/",
      "https://example.test/\e[2J",
      "https://example.test/\u009D",
      "https://example.test/\n",
      "https://example.test/%ZZ",
      "https://example.test/#secret",
      "https:///missing"
    ]

    for url <- bad_urls do
      params = %{"mode" => "url", "message" => "Approve", "url" => url}

      assert {:error, :invalid_input_requests} =
               Retry.normalize_requests(
                 %{"method" => "elicitation/create", "params" => params},
                 []
               )

      assert {:error, :invalid_input_request} =
               Server.request_client(
                 server,
                 session.id,
                 "owner",
                 nil,
                 "elicitation/create",
                 params,
                 100
               )
    end

    for url <- [
          "http://localhost:8080/approve",
          "http://127.0.0.1/approve",
          "http://[::1]/approve"
        ] do
      refute Elicitation.valid_url?(url, [])
      assert Elicitation.valid_url?(url, elicitation_allow_loopback_http: true)
    end

    for url <- [
          "http://127.0.0.2/",
          "http://localhost.example.test/",
          "http://0.0.0.0/",
          "http://example.test/",
          "http://user@localhost/"
        ] do
      refute Elicitation.valid_url?(url, elicitation_allow_loopback_http: true)
    end

    assert Elicitation.valid_url?("https://example.test/approve?id=opaque", [])
    assert_raise ArgumentError, fn -> Options.normalize(elicitation_allow_loopback_http: :yes) end
  end

  test "valid URL requests reach clients on both paths, including the development opt-in" do
    server = start_supervised!({Server, elicitation_allow_loopback_http: true})
    {session, stream} = legacy_session(server, "2025-11-25")

    for url <- ["https://example.test/approve", "http://127.0.0.1:8080/approve"] do
      params = %{"mode" => "url", "message" => "Approve", "url" => url}

      assert {:ok, _} =
               Retry.normalize_requests(%{"method" => "elicitation/create", "params" => params},
                 elicitation_allow_loopback_http: true
               )

      task =
        Task.async(fn ->
          Server.request_client(server, session.id, "owner", nil, "elicitation/create", params)
        end)

      assert_receive {:mcp_legacy_event, ^stream, _, %{"id" => id, "params" => ^params}}, 1_000

      assert :ok =
               Server.deliver_client_response(server, session.id, "owner", nil, %{
                 kind: :response,
                 id: id,
                 result: %{"action" => "cancel"}
               })

      assert {:ok, %{"action" => "cancel"}} = Task.await(task)
      Server.ack_legacy_stream(server, stream)
    end
  end

  test "legacy server requests canonicalize atom keys and reject display controls before sending" do
    server = start_supervised!({Server, display_text_policy: :reject})
    {:ok, session} = Server.new_session(server, "owner")

    :ok =
      Server.negotiate_session(server, session.id, "owner", nil, "2025-11-25", %{
        "sampling" => %{},
        "elicitation" => %{}
      })

    :ok = Server.mark_initialized(server, session.id)
    {:ok, stream} = Server.open_legacy_stream(server, session.id, "owner", nil, self())

    assert {:error, :invalid_input_request} =
             Server.request_client(
               server,
               session.id,
               "owner",
               nil,
               "sampling/createMessage",
               %{messages: [%{role: "user", content: %{type: "text", text: "bad\e"}}]},
               100
             )

    assert {:error, :invalid_input_request} =
             Server.request_client(
               server,
               session.id,
               "owner",
               nil,
               "elicitation/create",
               %{message: "bad\e", requestedSchema: %{type: "object"}},
               100
             )

    refute_received {:mcp_legacy_event, ^stream, _, _}
  end

  test "URL approvals independently bind issuer subject client tenant and custom principal" do
    server = start_supervised!({Server, []})
    context = context()
    owner = InteractionOwner.from_context(context)
    assert owner.principal_binding == {:account, "same-principal"}

    {:ok, %{id: id}} =
      UrlElicitation.stage_url_elicitation(server, context, "approve", %{"id" => "item"})

    for foreign <- foreign_contexts(context) do
      foreign_owner = InteractionOwner.from_context(foreign)

      assert {:error, :foreign} =
               UrlElicitation.resolve_url_elicitation(server, id, foreign_owner)

      assert {:error, :foreign} =
               UrlElicitation.consume_url_elicitation(server, id, foreign_owner)
    end

    assert {:error, :foreign} =
             UrlElicitation.consume_url_elicitation(server, id, context.principal_binding)

    assert {:ok, %{fields: %{"id" => "item"}}} =
             UrlElicitation.resolve_url_elicitation(server, id, owner)

    assert {:ok, _} = UrlElicitation.consume_url_elicitation(server, id, owner)
    assert {:error, :consumed} = UrlElicitation.consume_url_elicitation(server, id, owner)
  end

  test "modern retry state refuses other clients and tenants before invoking the handler" do
    server = start_supervised!({Server, []})
    parent = self()

    assert :ok =
             Server.register_tool(server, "approve",
               handler: fn args, _ ->
                 send(parent, {:handler, args})

                 if args["form"],
                   do: {:ok, "done"},
                   else:
                     {:input_required,
                      %{"form" => %{"method" => "elicitation/create", "params" => @form}}}
               end
             )

    params = %{
      "name" => "approve",
      "arguments" => %{},
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => @modern,
        "io.modelcontextprotocol/clientCapabilities" => %{"elicitation" => %{}}
      }
    }

    assert {1, %{"result" => %{"requestState" => state}}} = dispatch(server, params, context())
    assert_receive {:handler, %{}}

    retry =
      Map.merge(params, %{
        "requestState" => state,
        "inputResponses" => %{"form" => %{"action" => "accept", "content" => %{"count" => 1}}}
      })

    for foreign <- foreign_contexts(context()) do
      assert {2, %{"error" => %{"data" => %{"reason" => "invalid_request_state"}}}} =
               dispatch(server, retry, foreign)

      refute_received {:handler, _}
    end

    assert {2, %{"result" => %{"resultType" => "complete"}}} = dispatch(server, retry, context())
    assert_receive {:handler, %{"form" => _}}
  end

  defp legacy_session(server, version) do
    {:ok, session} = Server.new_session(server, "owner")

    :ok =
      Server.negotiate_session(server, session.id, "owner", nil, version, %{"elicitation" => %{}})

    :ok = Server.mark_initialized(server, session.id)
    {:ok, stream} = Server.open_legacy_stream(server, session.id, "owner", nil, self())
    {session, stream}
  end

  defp context do
    %{
      principal_binding: {:account, "same-principal"},
      tenant: "tenant-a",
      attesto_mcp_claims: %{"iss" => "issuer-a", "sub" => "subject-a", "client_id" => "client-a"}
    }
  end

  defp foreign_contexts(context) do
    [
      Map.put(context, :principal_binding, "other"),
      Map.put(context, :tenant, "other")
      | for(
          key <- ["iss", "sub", "client_id"],
          do: put_in(context, [:attesto_mcp_claims, key], "other")
        )
    ]
  end

  defp dispatch(server, params, context),
    do:
      Server.dispatch(
        server,
        %{
          kind: :request,
          id: if(params["requestState"], do: 2, else: 1),
          method: "tools/call",
          params: params
        },
        context,
        version: @modern
      )
end
