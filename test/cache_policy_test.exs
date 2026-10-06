defmodule AttestoMCP.Server.CachePolicyTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server
  alias AttestoMCP.Server.Test, as: ServerTest

  @modern "2026-07-28"
  @legacy "2025-11-25"
  @max_safe 9_007_199_254_740_991

  defp start_server(opts \\ []),
    do: start_supervised!(Supervisor.child_spec({Server, opts}, id: make_ref()))

  defp hints(%{"result" => result}), do: Map.take(result, ["ttlMs", "cacheScope"])

  defp text_resource(uri, extra \\ %{}) do
    fn _input, _context ->
      {:ok, Map.merge(%{"contents" => [%{"uri" => uri, "text" => "body"}]}, extra)}
    end
  end

  defp prompt_handler do
    fn _input, _context ->
      {:ok, [%{"role" => "user", "content" => %{"type" => "text", "text" => "hi"}}]}
    end
  end

  defp dispatch(server, method, params, context) do
    params =
      Map.put(params, "_meta", %{
        "io.modelcontextprotocol/protocolVersion" => @modern,
        "io.modelcontextprotocol/clientCapabilities" => %{}
      })

    id = System.unique_integer([:positive])

    {^id, response} =
      Server.dispatch(
        server,
        %{kind: :request, id: id, method: method, params: params},
        context,
        version: @modern
      )

    response
  end

  defp register_catalog(server) do
    assert :ok = Server.register_tool(server, "lookup", %{handler: fn _, _ -> {:ok, "ok"} end})
    assert :ok = Server.register_resource(server, "urn:doc", %{handler: text_resource("urn:doc")})

    assert :ok =
             Server.register_resource_template(server, "urn:item/{id}", %{
               handler: fn %{params: %{"id" => id}}, _ ->
                 {:ok, %{"contents" => [%{"uri" => "urn:item/" <> id, "text" => id}]}}
               end
             })

    assert :ok = Server.register_prompt(server, "greet", %{handler: prompt_handler()})
  end

  describe "without a granular policy" do
    test "keeps the private 30 second default on every cacheable result and prompts/get" do
      server = start_server()
      register_catalog(server)

      responses = [
        ServerTest.discover(server),
        ServerTest.list_tools(server),
        ServerTest.list_prompts(server),
        ServerTest.list_resources(server),
        ServerTest.list_resource_templates(server),
        ServerTest.read_resource(server, "urn:doc"),
        ServerTest.read_resource(server, "urn:item/7"),
        ServerTest.get_prompt(server, "greet", %{})
      ]

      for response <- responses do
        assert hints(response) == %{"ttlMs" => 30_000, "cacheScope" => "private"}
      end
    end

    test ":cache_ttl_ms still sets the global TTL" do
      server = start_server(cache_ttl_ms: 1_234)
      register_catalog(server)

      assert hints(ServerTest.discover(server)) == %{"ttlMs" => 1_234, "cacheScope" => "private"}

      assert hints(ServerTest.read_resource(server, "urn:doc")) ==
               %{"ttlMs" => 1_234, "cacheScope" => "private"}
    end

    test "runtime fields override handler resource hints as in 2.3" do
      server = start_server()

      assert :ok =
               Server.register_resource(server, "urn:hinted", %{
                 handler: text_resource("urn:hinted", %{"ttlMs" => 5, "cacheScope" => "public"})
               })

      assert hints(ServerTest.read_resource(server, "urn:hinted")) ==
               %{"ttlMs" => 30_000, "cacheScope" => "private"}
    end

    test "tools/call carries no cache hints" do
      server = start_server()
      register_catalog(server)
      response = ServerTest.call_tool(server, "lookup", %{})
      assert hints(response) == %{}
    end
  end

  describe "granular method and definition policies" do
    test "discovery and tool catalogs can have different TTLs" do
      server =
        start_server(
          cache_policy: [
            methods: %{
              "server/discover" => [ttl_ms: 300_000],
              "tools/list" => [ttl_ms: 60_000]
            }
          ]
        )

      register_catalog(server)

      assert hints(ServerTest.discover(server)) ==
               %{"ttlMs" => 300_000, "cacheScope" => "private"}

      assert hints(ServerTest.list_tools(server)) ==
               %{"ttlMs" => 60_000, "cacheScope" => "private"}

      # Methods without a policy keep the global fallback.
      assert hints(ServerTest.list_prompts(server)) ==
               %{"ttlMs" => 30_000, "cacheScope" => "private"}
    end

    test "two resources and a template use their own definition policies" do
      server = start_server(cache_policy: [methods: %{"resources/read" => [ttl_ms: 5_000]}])

      assert :ok =
               Server.register_resource(server, "urn:a", %{
                 cache: [ttl_ms: 1_000],
                 handler: text_resource("urn:a")
               })

      assert :ok =
               Server.register_resource(server, "urn:b", %{
                 cache: %{ttl_ms: 2_000},
                 handler: text_resource("urn:b")
               })

      assert :ok = Server.register_resource(server, "urn:c", %{handler: text_resource("urn:c")})

      assert :ok =
               Server.register_resource_template(server, "urn:item/{id}", %{
                 cache: [ttl_ms: 7_000],
                 handler: fn %{params: %{"id" => id}}, _ ->
                   {:ok, %{"contents" => [%{"uri" => "urn:item/" <> id, "text" => id}]}}
                 end
               })

      assert hints(ServerTest.read_resource(server, "urn:a"))["ttlMs"] == 1_000
      assert hints(ServerTest.read_resource(server, "urn:b"))["ttlMs"] == 2_000
      assert hints(ServerTest.read_resource(server, "urn:c"))["ttlMs"] == 5_000
      assert hints(ServerTest.read_resource(server, "urn:item/42"))["ttlMs"] == 7_000
    end

    test "max_ttl_ms caps every resolved TTL" do
      server =
        start_server(
          cache_policy: [methods: %{"tools/list" => [ttl_ms: 60_000]}, max_ttl_ms: 2_500]
        )

      assert hints(ServerTest.list_tools(server))["ttlMs"] == 2_500
      assert hints(ServerTest.discover(server))["ttlMs"] == 2_500
    end
  end

  describe "handler hints under a granular policy" do
    setup do
      server =
        start_server(
          allow_public_cache: true,
          cache_policy: [methods: %{"resources/read" => [ttl_ms: 10_000]}]
        )

      %{server: server}
    end

    test "a shorter handler TTL survives resource assembly", %{server: server} do
      assert :ok =
               Server.register_resource(server, "urn:short", %{
                 handler: text_resource("urn:short", %{"ttlMs" => 200})
               })

      assert hints(ServerTest.read_resource(server, "urn:short")) ==
               %{"ttlMs" => 200, "cacheScope" => "private"}
    end

    test "a handler cannot extend a zero-TTL policy", %{server: server} do
      assert :ok =
               Server.register_resource(server, "urn:zero", %{
                 cache: [ttl_ms: 0],
                 handler: text_resource("urn:zero", %{"ttlMs" => 60_000})
               })

      assert hints(ServerTest.read_resource(server, "urn:zero"))["ttlMs"] == 0
    end

    test "a handler cannot promote private output to public", %{server: server} do
      assert :ok =
               Server.register_resource(server, "urn:promote", %{
                 handler: text_resource("urn:promote", %{"cacheScope" => "public"})
               })

      assert hints(ServerTest.read_resource(server, "urn:promote"))["cacheScope"] == "private"
    end

    test "a handler can restrict a public policy to private", %{server: server} do
      assert :ok =
               Server.register_resource(server, "urn:public", %{
                 cache: [scope: :public],
                 handler: text_resource("urn:public")
               })

      assert :ok =
               Server.register_resource(server, "urn:restrict", %{
                 cache: [scope: :public],
                 handler: text_resource("urn:restrict", %{"cacheScope" => "private"})
               })

      assert hints(ServerTest.read_resource(server, "urn:public"))["cacheScope"] == "public"
      assert hints(ServerTest.read_resource(server, "urn:restrict"))["cacheScope"] == "private"
    end

    test "invalid handler hints are ignored", %{server: server} do
      assert :ok =
               Server.register_resource(server, "urn:negative", %{
                 handler: text_resource("urn:negative", %{"ttlMs" => -5})
               })

      assert :ok =
               Server.register_resource(server, "urn:string", %{
                 handler:
                   text_resource("urn:string", %{"ttlMs" => "soon", "cacheScope" => "everyone"})
               })

      assert hints(ServerTest.read_resource(server, "urn:negative")) ==
               %{"ttlMs" => 10_000, "cacheScope" => "private"}

      assert hints(ServerTest.read_resource(server, "urn:string")) ==
               %{"ttlMs" => 10_000, "cacheScope" => "private"}
    end
  end

  describe "public eligibility" do
    test "an unrestricted catalog with the 2.3 public options remains public" do
      server = start_server(cache_scope: :public, allow_public_cache: true)
      register_catalog(server)

      response = dispatch(server, "tools/list", %{}, %{principal: "p", public_catalog: true})
      assert hints(response)["cacheScope"] == "public"
    end

    for {label, definition} <- [
          {"required scopes", %{required_scopes: ["items.read"]}},
          {"alternative scope sets",
           %{required_scopes: ["items.read"], alternative_scope_sets: [["items.admin"]]}},
          {"an authorize callback", %{authorize: {__MODULE__, :allow}}}
        ] do
      test "a catalog with #{label} stays private under the 2.3 public options" do
        server = start_server(cache_scope: :public, allow_public_cache: true)
        assert :ok = Server.register_tool(server, "open", %{handler: fn _, _ -> {:ok, "ok"} end})

        assert :ok =
                 Server.register_tool(
                   server,
                   "guarded",
                   Map.put(unquote(Macro.escape(definition)), :handler, fn _, _ ->
                     {:ok, "ok"}
                   end)
                 )

        # The caller can see every tool, but the catalog still depends on the
        # caller, so it is never public.
        response =
          dispatch(server, "tools/list", %{}, %{
            principal: "p",
            scopes: ["items.read", "items.admin"],
            public_catalog: true
          })

        assert length(response["result"]["tools"]) == 2
        assert hints(response)["cacheScope"] == "private"
      end
    end

    test "a granular public method policy requires allow_public_cache" do
      policy = [methods: %{"tools/list" => [ttl_ms: 60_000, scope: :public]}]

      without = start_server(cache_policy: policy)
      register_catalog(without)
      assert hints(ServerTest.list_tools(without))["cacheScope"] == "private"

      with_opt_in = start_server(cache_policy: policy, allow_public_cache: true)
      register_catalog(with_opt_in)

      assert hints(ServerTest.list_tools(with_opt_in)) ==
               %{"ttlMs" => 60_000, "cacheScope" => "public"}
    end

    test "a restricted resource reads as private even with a public definition policy" do
      server = start_server(allow_public_cache: true, cache_policy: [methods: %{}])

      assert :ok =
               Server.register_resource(server, "urn:scoped", %{
                 cache: [scope: :public],
                 required_scopes: ["docs.read"],
                 handler: text_resource("urn:scoped")
               })

      assert :ok =
               Server.register_resource(server, "urn:authorized", %{
                 cache: [scope: :public],
                 authorize: {__MODULE__, :allow},
                 handler: text_resource("urn:authorized")
               })

      assert :ok =
               Server.register_resource(server, "urn:open", %{
                 cache: [scope: :public],
                 handler: text_resource("urn:open")
               })

      assert hints(ServerTest.read_resource(server, "urn:scoped", scopes: ["docs.read"]))[
               "cacheScope"
             ] == "private"

      assert hints(ServerTest.read_resource(server, "urn:authorized"))["cacheScope"] == "private"
      assert hints(ServerTest.read_resource(server, "urn:open"))["cacheScope"] == "public"
    end

    test "a filtered catalog stays private under a granular public policy" do
      server =
        start_server(
          allow_public_cache: true,
          cache_policy: [methods: %{"resources/list" => [scope: :public]}]
        )

      assert :ok =
               Server.register_resource(server, "urn:open", %{handler: text_resource("urn:open")})

      assert :ok =
               Server.register_resource(server, "urn:closed", %{
                 required_scopes: ["docs.read"],
                 handler: text_resource("urn:closed")
               })

      response = ServerTest.list_resources(server)
      assert Enum.map(response["result"]["resources"], & &1["uri"]) == ["urn:open"]
      assert hints(response)["cacheScope"] == "private"
    end
  end

  describe "pagination" do
    test "every page stays private even when the resolver selects public" do
      parent = self()

      server =
        start_server(
          page_size: 1,
          allow_public_cache: true,
          cache_policy: [
            resolver: fn request, _context ->
              send(parent, {:resolved, request.method})
              {:ok, %{scope: :public}}
            end
          ]
        )

      for name <- ["a", "b", "c"],
          do:
            assert(
              :ok = Server.register_tool(server, name, %{handler: fn _, _ -> {:ok, name} end})
            )

      first = ServerTest.list_tools(server)
      second = ServerTest.list_tools(server, cursor: first["result"]["nextCursor"])
      third = ServerTest.list_tools(server, cursor: second["result"]["nextCursor"])

      for page <- [first, second, third] do
        assert hints(page)["cacheScope"] == "private"
      end

      assert Enum.map([first, second, third], &hd(&1["result"]["tools"])["name"]) == [
               "a",
               "b",
               "c"
             ]

      refute Map.has_key?(third["result"], "nextCursor")
      assert_received {:resolved, "tools/list"}
    end

    for {from, to} <- [{:public, :private}, {:private, :public}] do
      test "a paginated continuation stays private when the resolver changes from #{from} to #{to}" do
        {:ok, scope} = Agent.start_link(fn -> unquote(from) end)

        server =
          start_server(
            page_size: 1,
            allow_public_cache: true,
            cache_policy: [
              resolver: fn _request, _context -> {:ok, %{scope: Agent.get(scope, & &1)}} end
            ]
          )

        for name <- ["a", "b"],
            do:
              assert(
                :ok = Server.register_tool(server, name, %{handler: fn _, _ -> {:ok, name} end})
              )

        first = ServerTest.list_tools(server)
        assert hints(first)["cacheScope"] == "private"
        cursor = first["result"]["nextCursor"]
        assert is_binary(cursor)

        Agent.update(scope, fn _ -> unquote(to) end)

        continuation = ServerTest.list_tools(server, cursor: cursor)
        assert continuation["result"]["tools"] |> hd() |> Map.get("name") == "b"
        assert hints(continuation)["cacheScope"] == "private"
      end
    end

    test "a page with a continuation cursor is never fresher than the cursor" do
      server =
        start_server(
          page_size: 1,
          cursor_ttl: 1_000,
          cache_policy: [methods: %{"tools/list" => [ttl_ms: 60_000]}]
        )

      for name <- ["a", "b"],
          do:
            assert(
              :ok = Server.register_tool(server, name, %{handler: fn _, _ -> {:ok, name} end})
            )

      first = ServerTest.list_tools(server)
      assert is_binary(first["result"]["nextCursor"])
      assert hints(first)["ttlMs"] <= 1_000

      last = ServerTest.list_tools(server, cursor: first["result"]["nextCursor"])
      refute Map.has_key?(last["result"], "nextCursor")
      assert hints(last)["ttlMs"] == 60_000
      assert hints(first)["cacheScope"] == hints(last)["cacheScope"]
    end
  end

  describe "multi-round requests" do
    setup do
      server =
        start_server(
          allow_public_cache: true,
          cache_policy: [
            methods: %{"resources/read" => [ttl_ms: 60_000, scope: :public]}
          ]
        )

      assert :ok =
               Server.register_resource(server, "urn:ask", %{
                 cache: [ttl_ms: 60_000, scope: :public],
                 handler: fn input, _context ->
                   if Map.has_key?(input, "answer"),
                     do: {:ok, %{"contents" => [%{"uri" => "urn:ask", "text" => "done"}]}},
                     else: {:input_required, %{"answer" => form_input_request()}}
                 end
               })

      assert :ok =
               Server.register_prompt(server, "ask", %{
                 handler: fn %{arguments: arguments}, _context ->
                   if Map.has_key?(arguments, "answer"),
                     do:
                       {:ok,
                        [%{"role" => "user", "content" => %{"type" => "text", "text" => "done"}}]},
                     else: {:input_required, %{"answer" => form_input_request()}}
                 end
               })

      %{server: server}
    end

    test "interim results carry no hints and completed retries are zero-TTL private", %{
      server: server
    } do
      capabilities = %{"elicitation" => %{}}
      answer = %{"answer" => %{"action" => "accept", "content" => %{"value" => "yes"}}}

      interim = ServerTest.read_resource(server, "urn:ask", client_capabilities: capabilities)
      assert interim["result"]["resultType"] == "input_required"
      assert hints(interim) == %{}

      retried =
        ServerTest.read_resource(server, "urn:ask",
          client_capabilities: capabilities,
          request_state: interim["result"]["requestState"],
          input_responses: answer
        )

      assert retried["result"]["resultType"] == "complete"
      assert hints(retried) == %{"ttlMs" => 0, "cacheScope" => "private"}

      prompt_interim =
        ServerTest.get_prompt(server, "ask", %{}, client_capabilities: capabilities)

      assert prompt_interim["result"]["resultType"] == "input_required"
      assert hints(prompt_interim) == %{}

      prompt_retried =
        ServerTest.get_prompt(server, "ask", %{},
          client_capabilities: capabilities,
          request_state: prompt_interim["result"]["requestState"],
          input_responses: answer
        )

      assert prompt_retried["result"]["resultType"] == "complete"
      assert hints(prompt_retried) == %{"ttlMs" => 0, "cacheScope" => "private"}
    end
  end

  describe "invalid configuration" do
    for {label, opts} <- [
          {"tools/call method", [cache_policy: [methods: %{"tools/call" => [ttl_ms: 1]}]]},
          {"prompts/get method", [cache_policy: [methods: %{"prompts/get" => [ttl_ms: 1]}]]},
          {"negative ttl", [cache_policy: [methods: %{"tools/list" => [ttl_ms: -1]}]]},
          {"float ttl", [cache_policy: [methods: %{"tools/list" => [ttl_ms: 1.5]}]]},
          {"unsafe ttl", [cache_policy: [methods: %{"tools/list" => [ttl_ms: @max_safe + 1]}]]},
          {"bad scope", [cache_policy: [methods: %{"tools/list" => [scope: :shared]}]]},
          {"unknown policy key", [cache_policy: [methods: %{"tools/list" => [ttl: 1]}]]},
          {"empty policy", [cache_policy: [methods: %{"tools/list" => []}]]},
          {"unknown cache_policy key", [cache_policy: [default: [ttl_ms: 1]]]},
          {"atom method key", [cache_policy: [methods: [tools_list: [ttl_ms: 1]]]]},
          {"non-callback resolver", [cache_policy: [resolver: :not_a_callback]]},
          {"wrong-arity resolver", [cache_policy: [resolver: {__MODULE__, :allow}]]},
          {"unsafe max_ttl_ms", [cache_policy: [max_ttl_ms: @max_safe + 1]]},
          {"non-list cache_policy", [cache_policy: :yes]},
          {"unsafe cache_ttl_ms", [cache_ttl_ms: @max_safe + 1]}
        ] do
      test "rejects #{label} at startup" do
        assert {:error, {%ArgumentError{}, _stacktrace}} =
                 GenServer.start(Server, unquote(Macro.escape(opts)))
      end
    end

    test "accepts the largest JSON-safe TTL" do
      server = start_server(cache_ttl_ms: @max_safe)
      assert hints(ServerTest.discover(server))["ttlMs"] == @max_safe
    end

    test "definition cache policies are limited to resources and templates" do
      server = start_server()

      assert {:error, {:invalid_definition, :cache}} =
               Server.register_tool(server, "cached", %{
                 cache: [ttl_ms: 1],
                 handler: fn _, _ -> {:ok, "ok"} end
               })

      assert {:error, {:invalid_definition, :cache}} =
               Server.register_prompt(server, "cached", %{
                 cache: [ttl_ms: 1],
                 handler: prompt_handler()
               })

      for bad <- [[ttl_ms: -1], [scope: :everyone], [ttl_ms: "1"], [], :public, [other: 1]] do
        assert {:error, {:invalid_definition, :cache}} =
                 Server.register_resource(server, "urn:bad", %{
                   cache: bad,
                   handler: text_resource("urn:bad")
                 })
      end

      assert Server.snapshot(server)[:resource] == %{}
    end
  end

  describe "resolver" do
    test "receives the method, definition, candidate policy, and trusted context" do
      parent = self()

      server =
        start_server(
          cache_policy: [
            methods: %{"resources/read" => [ttl_ms: 4_000]},
            resolver: fn request, context ->
              send(parent, {:resolver, request, context})
              :default
            end
          ]
        )

      assert :ok =
               Server.register_resource(server, "urn:resolved", %{
                 cache: [scope: :private],
                 handler: text_resource("urn:resolved")
               })

      assert :ok =
               Server.register_resource_template(server, "urn:tpl/{id}", %{
                 handler: fn %{params: %{"id" => id}}, _ ->
                   {:ok, %{"contents" => [%{"uri" => "urn:tpl/" <> id, "text" => id}]}}
                 end
               })

      response =
        ServerTest.read_resource(server, "urn:resolved",
          principal: "resolver-user",
          meta: %{"com.example/request-purpose" => "audit"}
        )

      assert hints(response) == %{"ttlMs" => 4_000, "cacheScope" => "private"}

      assert_received {:resolver, request, context}

      assert request == %{
               method: "resources/read",
               definition: %{type: :resource, identity: "urn:resolved"},
               policy: %{ttl_ms: 4_000, scope: :private}
             }

      assert context.principal == "resolver-user"
      assert context.request_meta["com.example/request-purpose"] == "audit"

      ServerTest.read_resource(server, "urn:tpl/9")
      assert_received {:resolver, %{definition: %{type: :template, identity: "urn:tpl/{id}"}}, _}

      ServerTest.list_tools(server)
      assert_received {:resolver, %{method: "tools/list", definition: nil}, _}
    end

    test "{:ok, policy} overrides only the fields it sets and :default keeps the static result" do
      server =
        start_server(
          allow_public_cache: true,
          cache_policy: [
            methods: %{"tools/list" => [ttl_ms: 9_000], "server/discover" => [ttl_ms: 8_000]},
            resolver: fn
              %{method: "tools/list"}, _context -> {:ok, [scope: :public]}
              %{method: "server/discover"}, _context -> {:ok, %{ttl_ms: 1_500}}
              _request, _context -> :default
            end
          ]
        )

      assert hints(ServerTest.list_tools(server)) ==
               %{"ttlMs" => 9_000, "cacheScope" => "public"}

      assert hints(ServerTest.discover(server)) ==
               %{"ttlMs" => 1_500, "cacheScope" => "private"}

      assert hints(ServerTest.list_prompts(server)) ==
               %{"ttlMs" => 30_000, "cacheScope" => "private"}
    end

    for {label, callback} <- [
          {"raises", quote(do: fn _, _ -> raise "resolver failure" end)},
          {"throws", quote(do: fn _, _ -> throw(:resolver_failure) end)},
          {"exits", quote(do: fn _, _ -> exit(:resolver_failure) end)},
          {"returns an invalid value", quote(do: fn _, _ -> :public end)},
          {"returns an invalid policy", quote(do: fn _, _ -> {:ok, %{ttl_ms: -1}} end)},
          {"returns an unknown policy key", quote(do: fn _, _ -> {:ok, %{scope: :shared}} end)}
        ] do
      test "falls back to a zero-TTL private hint when the resolver #{label}" do
        parent = self()

        server =
          start_server(
            allow_public_cache: true,
            exception_reporter: fn report -> send(parent, {:reported, report}) end,
            cache_policy: [
              methods: %{"tools/list" => [ttl_ms: 60_000, scope: :public]},
              resolver: unquote(callback)
            ]
          )

        assert :ok = Server.register_tool(server, "a", %{handler: fn _, _ -> {:ok, "a"} end})

        response = ServerTest.list_tools(server)
        assert response["result"]["tools"] |> Enum.map(& &1["name"]) == ["a"]
        assert hints(response) == %{"ttlMs" => 0, "cacheScope" => "private"}

        assert_receive {:reported, %{source: :cache_policy_resolver}}
      end
    end
  end

  test "a private hint is never fresher than the verified access token" do
    server = start_server(cache_policy: [methods: %{"tools/list" => [ttl_ms: 60_000]}])
    register_catalog(server)

    exp = System.system_time(:second) + 5

    response =
      dispatch(server, "tools/list", %{}, %{
        principal: "token-user",
        attesto_mcp_claims: %{"exp" => exp}
      })

    assert hints(response)["cacheScope"] == "private"
    assert hints(response)["ttlMs"] <= 5_000

    expired =
      dispatch(server, "tools/list", %{}, %{
        principal: "token-user",
        attesto_mcp_claims: %{"exp" => System.system_time(:second) - 10}
      })

    assert hints(expired)["ttlMs"] == 0
  end

  test "legacy results never carry modern cache fields" do
    server =
      start_server(
        cache_policy: [methods: %{"resources/read" => [ttl_ms: 5_000]}],
        allow_public_cache: true
      )

    assert :ok =
             Server.register_resource(server, "urn:legacy", %{
               handler: text_resource("urn:legacy", %{"ttlMs" => 5, "cacheScope" => "public"})
             })

    assert :ok =
             Server.register_prompt(server, "legacy", %{
               handler: fn _input, _context ->
                 {:ok,
                  %{
                    "messages" => [
                      %{"role" => "user", "content" => %{"type" => "text", "text" => "hi"}}
                    ],
                    "ttlMs" => 5,
                    "cacheScope" => "public"
                  }}
               end
             })

    for version <- [@legacy, "2025-06-18"] do
      for response <- [
            ServerTest.read_resource(server, "urn:legacy", protocol_version: version),
            ServerTest.get_prompt(server, "legacy", %{}, protocol_version: version),
            ServerTest.list_tools(server, protocol_version: version),
            ServerTest.list_resources(server, protocol_version: version)
          ] do
        assert is_map(response["result"]), inspect(response)
        assert hints(response) == %{}
        refute Map.has_key?(response["result"], "resultType")
      end
    end
  end

  test "cache telemetry is bounded to method, outcome, and policy source" do
    parent = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:attesto_mcp_server, :cache, :choice],
        &__MODULE__.forward_cache_event/4,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    server =
      start_server(
        page_size: 1,
        cache_policy: [methods: %{"tools/list" => [ttl_ms: 1_000]}]
      )

    for name <- ["a", "b"],
        do:
          assert(:ok = Server.register_tool(server, name, %{handler: fn _, _ -> {:ok, name} end}))

    secret_principal = "telemetry-principal-7f3a"
    secret_meta = "telemetry-meta-value-91c2"

    first =
      ServerTest.list_tools(server,
        principal: secret_principal,
        meta: %{"com.example/request-purpose" => secret_meta}
      )

    cursor = first["result"]["nextCursor"]
    ServerTest.list_tools(server, principal: secret_principal, cursor: cursor)

    events = collect_cache_events([])
    assert length(events) >= 2

    for {measurements, metadata} <- events do
      assert measurements == %{count: 1}
      assert Map.keys(metadata) |> Enum.sort() == [:method, :outcome, :source]
      assert metadata.method in ["tools/list", "server/discover", "resources/read"]
      assert metadata.outcome in ["private", "public"]
      assert is_atom(metadata.source)
      rendered = inspect(metadata)
      refute rendered =~ secret_principal
      refute rendered =~ secret_meta
      refute rendered =~ cursor
    end

    assert Enum.any?(events, fn {_m, metadata} ->
             metadata == %{method: "tools/list", outcome: "private", source: :method}
           end)
  end

  defp collect_cache_events(acc) do
    receive do
      {:cache_choice, measurements, metadata} ->
        collect_cache_events([{measurements, metadata} | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  defp form_input_request do
    %{
      "method" => "elicitation/create",
      "params" => %{
        "message" => "answer",
        "requestedSchema" => %{
          "type" => "object",
          "properties" => %{"value" => %{"type" => "string"}},
          "required" => ["value"]
        }
      }
    }
  end

  @doc false
  def allow(_context), do: true

  @doc false
  def forward_cache_event(_event, measurements, metadata, parent),
    do: send(parent, {:cache_choice, measurements, metadata})
end
