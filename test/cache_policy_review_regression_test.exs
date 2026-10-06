defmodule AttestoMCP.Server.CachePolicyReviewRegressionTest do
  use ExUnit.Case, async: true

  alias AttestoMCP.Server

  @modern "2026-07-28"
  @server_info "io.modelcontextprotocol/serverInfo"

  defp start_server(opts),
    do: start_supervised!(Supervisor.child_spec({Server, opts}, id: make_ref()))

  defp request(server, method, params \\ %{}, context \\ %{}) do
    id = System.unique_integer([:positive])

    {^id, response} =
      Server.dispatch(
        server,
        %{
          kind: :request,
          id: id,
          method: method,
          params:
            Map.put(params, "_meta", %{
              "io.modelcontextprotocol/protocolVersion" => @modern,
              "io.modelcontextprotocol/clientCapabilities" => %{}
            })
        },
        Map.merge(%{principal: "caller-one", scopes: [], public_catalog: true}, context),
        version: @modern
      )

    response
  end

  defp hints(response), do: Map.take(response["result"], ["ttlMs", "cacheScope"])

  defp fixed_resource(uri, extra \\ %{}),
    do: %{"contents" => [%{"uri" => uri, "text" => "fixed"}]} |> Map.merge(extra)

  for global_scope <- [:public, :private] do
    test "definition policies work without cache_policy under #{global_scope} defaults" do
      server =
        start_server(cache_scope: unquote(global_scope), allow_public_cache: true)

      assert :ok =
               Server.register_resource(server, "urn:example:private", %{
                 cache: [ttl_ms: 0, scope: :private],
                 handler: fn _, _ -> {:ok, fixed_resource("urn:example:private")} end
               })

      assert :ok =
               Server.register_resource_template(server, "urn:example:item/{id}", %{
                 cache: [ttl_ms: 0, scope: :private],
                 handler: fn %{uri: uri}, _ -> {:ok, fixed_resource(uri)} end
               })

      for uri <- ["urn:example:private", "urn:example:item/one"] do
        assert hints(request(server, "resources/read", %{"uri" => uri})) ==
                 %{"ttlMs" => 0, "cacheScope" => "private"}
      end
    end
  end

  test "unconfigured definitions retain legacy handler-hint precedence" do
    server = start_server(cache_scope: :public, allow_public_cache: true)

    assert :ok =
             Server.register_resource(server, "urn:example:unconfigured", %{
               handler: fn _, _ ->
                 {:ok,
                  fixed_resource("urn:example:unconfigured", %{
                    "ttlMs" => 0,
                    "cacheScope" => "private"
                  })}
               end
             })

    assert hints(request(server, "resources/read", %{"uri" => "urn:example:unconfigured"})) ==
             %{"ttlMs" => 30_000, "cacheScope" => "public"}
  end

  test "a standalone definition policy applies restrictive handler hints" do
    server = start_server(allow_public_cache: true)

    assert :ok =
             Server.register_resource(server, "urn:example:short", %{
               cache: [ttl_ms: 10_000, scope: :public],
               handler: fn _, _ ->
                 {:ok,
                  fixed_resource("urn:example:short", %{
                    "ttlMs" => 100,
                    "cacheScope" => "private"
                  })}
               end
             })

    assert hints(request(server, "resources/read", %{"uri" => "urn:example:short"})) ==
             %{"ttlMs" => 100, "cacheScope" => "private"}
  end

  test "personalized authored identity is private and capped at token expiry" do
    server =
      start_server(
        allow_public_cache: true,
        cache_policy: [methods: %{"resources/read" => [ttl_ms: 60_000, scope: :public]}]
      )

    assert :ok =
             Server.register_resource(server, "urn:example:metadata", %{
               handler: fn _, context ->
                 {:ok,
                  fixed_resource("urn:example:metadata", %{
                    "_meta" => %{
                      @server_info => %{
                        "name" => "example-server",
                        "version" => "1",
                        "title" => context.principal
                      }
                    }
                  })}
               end
             })

    for caller <- ["caller-one", "caller-two"] do
      response =
        request(server, "resources/read", %{"uri" => "urn:example:metadata"}, %{
          principal: caller,
          attesto_mcp_claims: %{"exp" => System.system_time(:second) + 5}
        })

      assert response["result"]["_meta"][@server_info]["title"] == caller
      assert hints(response)["cacheScope"] == "private"
      assert hints(response)["ttlMs"] in 0..5_000
    end
  end

  test "arbitrary result and content metadata stay private without an explicit TTL" do
    server = start_server(cache_scope: :public, allow_public_cache: true)

    for {uri, result} <- [
          {"urn:example:top-meta",
           fixed_resource("urn:example:top-meta", %{"_meta" => %{"com.example/user" => "one"}})},
          {"urn:example:content-meta",
           %{
             "contents" => [
               %{
                 "uri" => "urn:example:content-meta",
                 "text" => "fixed",
                 "_meta" => %{"com.example/user" => "one"}
               }
             ]
           }}
        ] do
      assert :ok = Server.register_resource(server, uri, %{handler: fn _, _ -> {:ok, result} end})

      assert hints(request(server, "resources/read", %{"uri" => uri})) ==
               %{"ttlMs" => 0, "cacheScope" => "private"}
    end
  end

  test "constant configured identity remains eligible for public hints" do
    identity = %{"name" => "example-server", "version" => "1"}

    server =
      start_server(
        server_name: identity["name"],
        server_version: identity["version"],
        allow_public_cache: true,
        cache_policy: [methods: %{"resources/read" => [ttl_ms: 1_000, scope: :public]}]
      )

    assert :ok =
             Server.register_resource(server, "urn:example:constant", %{
               handler: fn _, _ ->
                 {:ok,
                  fixed_resource("urn:example:constant", %{"_meta" => %{@server_info => identity}})}
               end
             })

    response = request(server, "resources/read", %{"uri" => "urn:example:constant"})
    assert response["result"]["_meta"][@server_info] == identity
    assert hints(response) == %{"ttlMs" => 1_000, "cacheScope" => "public"}
  end

  for {method, type, field} <- [
        {"tools/list", :tool, "tools"},
        {"resources/list", :resource, "resources"},
        {"resources/templates/list", :template, "resourceTemplates"},
        {"prompts/list", :prompt, "prompts"}
      ] do
    test "#{method} keeps every paginated page private and rejects another caller's cursor" do
      method = unquote(method)
      type = unquote(type)
      field = unquote(field)

      server =
        start_server(
          page_size: 1,
          allow_public_cache: true,
          cache_policy: [methods: %{method => [ttl_ms: 1_000, scope: :public]}]
        )

      register_list_entry(server, type, "a")
      register_list_entry(server, type, "b")

      first = request(server, method)
      cursor = first["result"]["nextCursor"]
      assert is_binary(cursor)
      assert length(first["result"][field]) == 1
      assert hints(first)["cacheScope"] == "private"

      for context <- [%{principal: "caller-two"}, %{tenant: "another-tenant"}] do
        assert %{"error" => %{"code" => -32602, "data" => %{"reason" => "invalid_cursor"}}} =
                 request(server, method, %{"cursor" => cursor}, context)
      end

      last = request(server, method, %{"cursor" => cursor})
      assert length(last["result"][field]) == 1
      refute Map.has_key?(last["result"], "nextCursor")
      assert hints(last)["cacheScope"] == "private"
    end
  end

  test "legacy public options also keep paginated catalogs private" do
    server = start_server(page_size: 1, cache_scope: :public, allow_public_cache: true)
    register_list_entry(server, :tool, "a")
    register_list_entry(server, :tool, "b")
    first = request(server, "tools/list")
    last = request(server, "tools/list", %{"cursor" => first["result"]["nextCursor"]})

    assert hints(first) == %{"ttlMs" => 30_000, "cacheScope" => "private"}
    assert hints(last) == %{"ttlMs" => 30_000, "cacheScope" => "private"}
  end

  defp register_list_entry(server, :tool, name),
    do: Server.register_tool(server, name, %{handler: fn _, _ -> {:ok, "ok"} end})

  defp register_list_entry(server, :resource, name) do
    uri = "urn:example:" <> name
    Server.register_resource(server, uri, %{handler: fn _, _ -> {:ok, fixed_resource(uri)} end})
  end

  defp register_list_entry(server, :template, name),
    do:
      Server.register_resource_template(server, "urn:example:" <> name <> "/{id}", %{
        handler: fn %{uri: uri}, _ -> {:ok, fixed_resource(uri)} end
      })

  defp register_list_entry(server, :prompt, name),
    do:
      Server.register_prompt(server, name, %{
        handler: fn _, _ ->
          {:ok, [%{"role" => "user", "content" => %{"type" => "text", "text" => "fixed"}}]}
        end
      })
end
