defmodule AttestoMCP.Server.PresentationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Plug.Conn
  import Plug.Test

  alias AttestoMCP.Server
  alias AttestoMCP.Server.Stdio
  alias AttestoMCP.Server.Test, as: ServerTest

  @modern "2026-07-28"
  @legacy "2025-11-25"
  @legacy_2025_06_18 "2025-06-18"
  @resource "https://mcp.example.com/mcp"

  defp start_server(opts) do
    start_supervised!(Supervisor.child_spec({Server, opts}, id: make_ref()))
  end

  defp reporter(parent), do: fn report -> send(parent, {:reported, report.source}) end

  defp modern(server, method, context, params \\ %{}) do
    id = System.unique_integer([:positive])

    request = %{
      kind: :request,
      id: id,
      method: method,
      params:
        Map.put(params, "_meta", %{
          "io.modelcontextprotocol/protocolVersion" => @modern,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        })
    }

    {^id, response} = Server.dispatch(server, request, context, version: @modern)
    response
  end

  defp initialize(server, version, context, opts \\ []) do
    id = System.unique_integer([:positive])

    request = %{
      kind: :request,
      id: id,
      method: "initialize",
      params: %{
        "protocolVersion" => version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "presentation-test", "version" => "1.0"}
      }
    }

    {^id, response} =
      Server.dispatch(server, request, context, Keyword.merge([version: version], opts))

    response
  end

  defp tools(response), do: get_in(response, ["result", "tools"])
  defp names(response), do: response |> tools() |> Enum.map(& &1["name"])

  defp error_reason(response), do: get_in(response, ["error", "data", "reason"])

  describe "without providers" do
    test "static instructions and scoped catalogs keep their existing output" do
      server = start_server(instructions: "Use the item tools for item lookups.")

      assert :ok = Server.register_tool(server, "open_tool", %{})

      assert :ok =
               Server.register_tool(server, "scoped_tool", %{required_scopes: ["items.read"]})

      discover = ServerTest.discover(server)

      assert %{
               "instructions" => "Use the item tools for item lookups.",
               "cacheScope" => "private",
               "ttlMs" => 30_000
             } = discover["result"]

      for version <- [@legacy, @legacy_2025_06_18] do
        assert %{"result" => %{"instructions" => "Use the item tools for item lookups."}} =
                 initialize(server, version, %{principal: "static-user"})
      end

      unscoped = ServerTest.list_tools(server)
      assert names(unscoped) == ["open_tool"]
      assert %{"cacheScope" => "private", "ttlMs" => 30_000} = unscoped["result"]

      scoped = ServerTest.list_tools(server, scopes: ["items.read"])
      assert names(scoped) == ["open_tool", "scoped_tool"]

      assert [
               %{
                 "name" => "open_tool",
                 "description" => "Tool open_tool",
                 "inputSchema" => %{"type" => "object"},
                 "annotations" => %{}
               } = open_tool,
               _scoped
             ] = tools(scoped)

      refute Map.has_key?(open_tool, "title")
      refute Map.has_key?(open_tool, "_meta")
    end
  end

  describe "per-request guidance" do
    test "principals receive different instructions and tool descriptors without changing definitions" do
      server =
        start_server(
          instructions: "Static guidance.",
          instructions_provider: fn context ->
            {:ok, "Guidance for #{context.principal}."}
          end,
          tool_presentation: fn tool, context ->
            {:ok,
             %{
               "title" => "#{tool["title"]} for #{context.principal}",
               "description" => "Looks up records visible to #{context.principal}.",
               "icons" => [
                 %{
                   "src" => "https://example.com/icons/#{context.principal}.png",
                   "mimeType" => "image/png",
                   "sizes" => ["48x48"]
                 }
               ],
               "_meta" => %{"com.example/audience" => context.principal}
             }}
          end
        )

      assert :ok =
               Server.register_tool(server, "lookup", %{
                 title: "Lookup",
                 description: "Looks up records.",
                 _meta: %{"com.example/registered" => true}
               })

      before = Server.snapshot(server)

      for {principal, other} <- [{"alice", "bob"}, {"bob", "alice"}] do
        discover = ServerTest.discover(server, principal: principal)
        assert discover["result"]["instructions"] == "Guidance for #{principal}."
        refute discover["result"]["instructions"] =~ other

        for version <- [@legacy, @legacy_2025_06_18] do
          assert %{"result" => %{"instructions" => instructions}} =
                   initialize(server, version, %{principal: principal})

          assert instructions == "Guidance for #{principal}."
        end

        assert [tool] = tools(ServerTest.list_tools(server, principal: principal))
        assert tool["name"] == "lookup"
        assert tool["title"] == "Lookup for #{principal}"
        assert tool["description"] == "Looks up records visible to #{principal}."

        assert tool["icons"] == [
                 %{
                   "src" => "https://example.com/icons/#{principal}.png",
                   "mimeType" => "image/png",
                   "sizes" => ["48x48"]
                 }
               ]

        assert tool["_meta"] == %{
                 "com.example/registered" => true,
                 "com.example/audience" => principal
               }
      end

      assert Server.snapshot(server) == before
      assert %{"lookup" => %{description: "Looks up records."}} = before.tool
    end

    test "request metadata reaches providers separately from the verified principal" do
      parent = self()

      server =
        start_server(
          instructions_provider: fn context ->
            send(parent, {:provider_context, context.principal, context.request_meta})
            {:ok, "Guidance."}
          end
        )

      assert %{"result" => %{"instructions" => "Guidance."}} =
               ServerTest.discover(server,
                 principal: "verified-user",
                 meta: %{"com.example/request-purpose" => "audit", "principal" => "other-user"}
               )

      assert_receive {:provider_context, "verified-user",
                      %{
                        "com.example/request-purpose" => "audit",
                        "principal" => "other-user"
                      }}
    end
  end

  describe "instruction precedence and failures" do
    test "a provider replaces static text and :omit removes it" do
      provided =
        start_server(
          instructions: "Static.",
          instructions_provider: fn _ -> {:ok, "Dynamic."} end
        )

      assert ServerTest.discover(provided)["result"]["instructions"] == "Dynamic."

      omitted = start_server(instructions: "Static.", instructions_provider: fn _ -> :omit end)

      refute Map.has_key?(ServerTest.discover(omitted)["result"], "instructions")

      for version <- [@legacy, @legacy_2025_06_18] do
        assert %{"result" => result} = initialize(omitted, version, %{principal: "omit-user"})
        refute Map.has_key?(result, "instructions")
        assert result["protocolVersion"] == version
      end
    end

    test "failing providers return a controlled error and never fall back to static text" do
      parent = self()

      providers = [
        fn _ -> {:error, :not_available} end,
        fn _ -> raise "provider failure" end,
        fn _ -> throw(:provider_throw) end,
        fn _ -> exit(:provider_exit) end,
        fn _ -> :unexpected end,
        fn _ -> {:ok, 42} end,
        fn _ -> {:ok, ""} end,
        fn _ -> {:ok, String.duplicate("a", 65_537)} end,
        fn _ -> {:ok, <<0xFF, 0xFE>>} end
      ]

      for provider <- providers do
        server =
          start_server(
            instructions: "Static fallback text.",
            instructions_provider: provider,
            exception_reporter: reporter(parent)
          )

        assert :ok = Server.register_tool(server, "still_works", %{})

        discover = ServerTest.discover(server)
        refute Map.has_key?(discover, "result")
        assert discover["error"]["code"] == -32603
        assert error_reason(discover) == "instructions_provider_failure"
        refute Jason.encode!(discover) =~ "Static fallback text."
        assert_receive {:reported, :instructions_provider}

        for version <- [@legacy, @legacy_2025_06_18] do
          legacy = initialize(server, version, %{principal: "failure-user"})
          assert legacy["error"]["code"] == -32603
          assert error_reason(legacy) == "instructions_provider_failure"
          refute Jason.encode!(legacy) =~ "Static fallback text."
          assert_receive {:reported, :instructions_provider}
        end

        assert names(ServerTest.list_tools(server)) == ["still_works"]
      end
    end

    test "a provider that outlives the request deadline times out and later requests work" do
      {:ok, delay} = Agent.start_link(fn -> 500 end)

      server =
        start_server(
          instructions_provider: fn _ ->
            Process.sleep(Agent.get(delay, & &1))
            {:ok, "Eventually."}
          end
        )

      assert :ok = Server.register_tool(server, "after_timeout", %{})

      timed_out = ServerTest.discover(server, timeout: 50)
      assert timed_out["error"]["code"] == -32603
      assert error_reason(timed_out) == "timeout"
      refute Jason.encode!(timed_out) =~ "Eventually."

      assert names(ServerTest.list_tools(server)) == ["after_timeout"]

      Agent.update(delay, fn _ -> 0 end)
      assert ServerTest.discover(server)["result"]["instructions"] == "Eventually."
    end
  end

  describe "tool presentation boundaries" do
    test "hidden tools are not presented and stay denied when called" do
      parent = self()

      server =
        start_server(
          tool_presentation: fn tool, _context ->
            send(parent, {:presented, tool["name"]})
            {:ok, %{"description" => "Presented #{tool["name"]}."}}
          end
        )

      assert :ok = Server.register_tool(server, "visible", %{handler: fn _, _ -> {:ok, "ok"} end})

      assert :ok =
               Server.register_tool(server, "scoped", %{
                 required_scopes: ["items.write"],
                 handler: fn _, _ ->
                   send(parent, :scoped_handler)
                   {:ok, "scoped"}
                 end
               })

      assert :ok =
               Server.register_tool(server, "authorized", %{
                 authorize: fn context -> context.principal == "admin" end,
                 handler: fn _, _ ->
                   send(parent, :authorized_handler)
                   {:ok, "authorized"}
                 end
               })

      listed = ServerTest.list_tools(server, principal: "member")
      assert names(listed) == ["visible"]
      assert [%{"description" => "Presented visible."}] = tools(listed)
      assert_receive {:presented, "visible"}
      refute_receive {:presented, "scoped"}
      refute_receive {:presented, "authorized"}

      for name <- ["scoped", "authorized"] do
        denied = ServerTest.call_tool(server, name, %{}, principal: "member")
        assert denied["error"]["code"] == -32602
      end

      refute_receive :scoped_handler
      refute_receive :authorized_handler
      refute_receive {:presented, _name}

      admin = ServerTest.list_tools(server, principal: "admin", scopes: ["items.write"])
      assert names(admin) == ["authorized", "scoped", "visible"]
    end

    test "unsupported or invalid overrides fail the whole list without a partial catalog" do
      parent = self()

      overrides = [
        %{"name" => "renamed"},
        %{"inputSchema" => %{"type" => "object"}},
        %{"outputSchema" => %{"type" => "object"}},
        %{"annotations" => %{"readOnlyHint" => true}},
        %{"execution" => %{"taskSupport" => "forbidden"}},
        %{handler: fn _, _ -> {:ok, "replaced"} end},
        %{required_scopes: []},
        %{authorize: fn _ -> true end},
        %{"com.example/unknown" => true},
        %{"_meta" => %{"io.modelcontextprotocol/serverInfo" => %{}}},
        %{"_meta" => %{"dev.mcp/flag" => true}},
        %{"_meta" => %{"progressToken" => 1}},
        %{
          "_meta" => %{"traceparent" => "00-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902b7-01"}
        },
        %{"_meta" => %{"_private" => true}},
        %{"_meta" => "not-a-map"},
        %{"icons" => [%{"src" => "javascript:alert(1)"}]},
        %{"icons" => [%{"src" => "ftp://example.com/icon.png"}]},
        %{"icons" => [%{"src" => "https://example.com/icon", "mimeType" => "text/html"}]},
        %{:title => "Atom title", "title" => "String title"},
        %{"title" => ""},
        %{"description" => "   "}
      ]

      returns =
        Enum.map(overrides, &{:ok, &1}) ++
          [{:error, :denied}, :unexpected, {:ok, :not_a_map}, :raise, :throw]

      for returned <- returns do
        server =
          start_server(
            exception_reporter: reporter(parent),
            tool_presentation: fn tool, _context ->
              cond do
                tool["name"] == "first" -> {:ok, %{"description" => "First is valid."}}
                returned == :raise -> raise "presentation failure"
                returned == :throw -> throw(:presentation_throw)
                true -> returned
              end
            end
          )

        assert :ok =
                 Server.register_tool(server, "first", %{handler: fn _, _ -> {:ok, "one"} end})

        assert :ok = Server.register_tool(server, "second", %{})

        listed = ServerTest.list_tools(server)
        refute Map.has_key?(listed, "result"), inspect(returned)
        assert listed["error"]["code"] == -32603
        assert error_reason(listed) == "tool_presentation_failure"
        refute Jason.encode!(listed) =~ "First is valid."
        assert_receive {:reported, :tool_presentation}

        assert %{"result" => %{"content" => [%{"text" => "one"}]}} =
                 ServerTest.call_tool(server, "first", %{})

        assert Server.snapshot(server).tool["second"].description == "Tool second"
      end
    end

    test "atom keys are accepted, :default keeps the registered descriptor, and _meta merges" do
      {:ok, mode} = Agent.start_link(fn -> :atoms end)

      server =
        start_server(
          tool_presentation: fn _tool, _context ->
            case Agent.get(mode, & &1) do
              :atoms ->
                {:ok,
                 %{
                   title: "Atom title",
                   description: "Atom description.",
                   icons: [%{src: "https://example.com/tool.svg", mime_type: "image/svg+xml"}],
                   _meta: %{"com.example/added" => 1, "com.example/registered" => "replaced"}
                 }}

              :default ->
                :default

              :empty ->
                {:ok, %{}}
            end
          end
        )

      assert :ok =
               Server.register_tool(server, "described", %{
                 description: "Registered description.",
                 _meta: %{"com.example/registered" => "original", "com.example/kept" => true}
               })

      assert [tool] = tools(ServerTest.list_tools(server))
      assert tool["title"] == "Atom title"
      assert tool["description"] == "Atom description."

      assert tool["icons"] == [
               %{"src" => "https://example.com/tool.svg", "mimeType" => "image/svg+xml"}
             ]

      assert tool["_meta"] == %{
               "com.example/added" => 1,
               "com.example/registered" => "replaced",
               "com.example/kept" => true
             }

      for value <- [:default, :empty] do
        Agent.update(mode, fn _ -> value end)
        assert [unchanged] = tools(ServerTest.list_tools(server))
        assert unchanged["description"] == "Registered description."
        refute Map.has_key?(unchanged, "title")
        refute Map.has_key?(unchanged, "icons")

        assert unchanged["_meta"] == %{
                 "com.example/registered" => "original",
                 "com.example/kept" => true
               }
      end
    end

    test "2025-06-18 catalogs omit presented icons" do
      server =
        start_server(
          tool_presentation: fn _tool, _context ->
            {:ok, %{"icons" => [%{"src" => "https://example.com/tool.png"}]}}
          end
        )

      assert :ok = Server.register_tool(server, "iconic", %{})

      assert [modern] = tools(ServerTest.list_tools(server))
      assert modern["icons"] == [%{"src" => "https://example.com/tool.png"}]

      assert [legacy] = tools(ServerTest.list_tools(server, protocol_version: @legacy))
      assert legacy["icons"] == [%{"src" => "https://example.com/tool.png"}]

      assert [older] = tools(ServerTest.list_tools(server, protocol_version: @legacy_2025_06_18))
      refute Map.has_key?(older, "icons")
    end
  end

  describe "authorization changes" do
    test "revoked authorization changes visibility on later requests and calls recheck it" do
      {:ok, allowed} = Agent.start_link(fn -> true end)

      server =
        start_server(
          tool_presentation: fn tool, context ->
            {:ok, %{"description" => "#{tool["name"]} for #{context.principal}."}}
          end
        )

      assert :ok =
               Server.register_tool(server, "revocable", %{
                 authorize: fn _context -> Agent.get(allowed, & &1) end,
                 handler: fn _, _ -> {:ok, "allowed"} end
               })

      assert [%{"description" => "revocable for member."}] =
               tools(ServerTest.list_tools(server, principal: "member"))

      assert %{"result" => %{"content" => [%{"text" => "allowed"}]}} =
               ServerTest.call_tool(server, "revocable", %{}, principal: "member")

      Agent.update(allowed, fn _ -> false end)

      assert tools(ServerTest.list_tools(server, principal: "member")) == []

      assert %{"error" => %{"code" => -32602}} =
               ServerTest.call_tool(server, "revocable", %{}, principal: "member")
    end

    test "a narrower HTTP token hides scoped tools on a later request" do
      config = AttestoMCP.Test.Factory.config()

      server =
        start_server(
          tool_presentation: fn tool, _context ->
            {:ok, %{"description" => "Presented #{tool["name"]}."}}
          end
        )

      assert :ok = Server.register_tool(server, "reports", %{required_scopes: ["reports.read"]})

      assert :ok =
               Server.register_tool(server, "documents", %{required_scopes: ["documents.read"]})

      plug =
        Server.Plug.init(
          server: server,
          path: "/mcp",
          auth: [config: config, resource: @resource],
          scope_policy: %{
            "tools/list" => :visible_definitions,
            "tools/call" => :selected_definition
          }
        )

      broad =
        AttestoMCP.Test.Factory.access_token(config, scopes: ["reports.read", "documents.read"])

      narrow = AttestoMCP.Test.Factory.access_token(config, scopes: ["documents.read"])

      first = http_list(plug, broad)
      assert first.status == 200
      broad_tools = Jason.decode!(first.resp_body)["result"]["tools"]
      assert Enum.map(broad_tools, & &1["name"]) == ["documents", "reports"]
      assert Enum.all?(broad_tools, &String.starts_with?(&1["description"], "Presented "))

      second = http_list(plug, narrow)
      assert second.status == 200
      narrow_tools = Jason.decode!(second.resp_body)["result"]["tools"]
      assert Enum.map(narrow_tools, & &1["name"]) == ["documents"]
      assert get_resp_header(second, "cache-control") == ["private, no-store"]
    end
  end

  describe "pagination" do
    test "cursors work for an unchanged catalog and are bound to the caller and presentation" do
      {:ok, variant} = Agent.start_link(fn -> "first" end)

      server =
        start_server(
          page_size: 1,
          tool_presentation: fn tool, context ->
            {:ok,
             %{
               "description" =>
                 "#{Agent.get(variant, & &1)} #{tool["name"]} for #{context.principal}."
             }}
          end
        )

      for name <- ["alpha", "bravo", "charlie"] do
        assert :ok = Server.register_tool(server, name, %{})
      end

      first = ServerTest.list_tools(server, principal: "alice")
      assert [%{"name" => "alpha", "description" => "first alpha for alice."}] = tools(first)
      cursor = first["result"]["nextCursor"]
      assert is_binary(cursor)

      second = ServerTest.list_tools(server, principal: "alice", cursor: cursor)
      assert names(second) == ["bravo"]
      assert names(ServerTest.list_tools(server, principal: "alice", cursor: cursor)) == ["bravo"]

      third =
        ServerTest.list_tools(server,
          principal: "alice",
          cursor: second["result"]["nextCursor"]
        )

      assert names(third) == ["charlie"]
      refute Map.has_key?(third["result"], "nextCursor")

      foreign = ServerTest.list_tools(server, principal: "bob", cursor: cursor)
      assert foreign["error"]["code"] == -32602
      assert error_reason(foreign) == "invalid_cursor"

      Agent.update(variant, fn _ -> "second" end)

      stale = ServerTest.list_tools(server, principal: "alice", cursor: cursor)
      assert stale["error"]["code"] == -32602
      assert error_reason(stale) == "invalid_cursor"

      restarted = ServerTest.list_tools(server, principal: "alice")
      assert [%{"description" => "second alpha for alice."}] = tools(restarted)

      assert names(
               ServerTest.list_tools(server,
                 principal: "alice",
                 cursor: restarted["result"]["nextCursor"]
               )
             ) == ["bravo"]
    end
  end

  describe "legacy initialization recovery" do
    test "a failed direct initialize leaves the session unnegotiated" do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      server =
        start_server(
          instructions_provider: fn _context ->
            case Agent.get_and_update(attempts, &{&1, &1 + 1}) do
              0 -> {:error, :not_ready}
              _ -> {:ok, "Ready."}
            end
          end
        )

      {:ok, session} = Server.new_session(server, "session-user", nil)

      context = %{
        principal: "session-user",
        session_id: session.id,
        protocol_version: nil,
        legacy_session_state: :unnegotiated
      }

      failed = initialize(server, @legacy, context)
      assert error_reason(failed) == "instructions_provider_failure"
      assert {:ok, %{version: nil}} = Server.get_session(server, session.id, "session-user", nil)

      assert %{"result" => %{"protocolVersion" => @legacy, "instructions" => "Ready."}} =
               initialize(server, @legacy, context)

      assert {:ok, %{version: @legacy}} =
               Server.get_session(server, session.id, "session-user", nil)
    end

    test "stdio retries initialization after a provider failure" do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      server =
        start_server(
          instructions_provider: fn _context ->
            case Agent.get_and_update(attempts, &{&1, &1 + 1}) do
              0 -> {:error, :not_ready}
              _ -> {:ok, "Ready."}
            end
          end
        )

      assert :ok = Server.register_tool(server, "after_retry", %{})

      output =
        run_stdio(server, [
          {0, initialize_frame(1)},
          {300, initialize_frame(2)},
          {300, %{"jsonrpc" => "2.0", "method" => "notifications/initialized", "params" => %{}}},
          {300, %{"jsonrpc" => "2.0", "id" => 3, "method" => "tools/list", "params" => %{}}}
        ])

      assert error_reason(output[1]) == "instructions_provider_failure"
      assert %{"protocolVersion" => @legacy, "instructions" => "Ready."} = output[2]["result"]
      assert names(output[3]) == ["after_retry"]
    end

    test "stdio rejects an initialize reply larger than the frame before negotiating" do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      server =
        start_server(
          instructions_provider: fn _context ->
            case Agent.get_and_update(attempts, &{&1, &1 + 1}) do
              0 -> {:ok, String.duplicate("long guidance ", 500)}
              _ -> {:ok, "Short."}
            end
          end
        )

      assert :ok = Server.register_tool(server, "after_oversize", %{})

      output =
        run_stdio(
          server,
          [
            {0, initialize_frame(1)},
            {300, initialize_frame(2)},
            {300,
             %{"jsonrpc" => "2.0", "method" => "notifications/initialized", "params" => %{}}},
            {300, %{"jsonrpc" => "2.0", "id" => 3, "method" => "tools/list", "params" => %{}}}
          ],
          max_message_bytes: 4_096
        )

      assert output[1]["error"]["code"] == -32603
      refute Jason.encode!(output[1]) =~ "long guidance"
      assert %{"protocolVersion" => @legacy, "instructions" => "Short."} = output[2]["result"]
      assert names(output[3]) == ["after_oversize"]
    end
  end

  describe "cache scope" do
    test "provider output stays private under global public settings" do
      providers = [
        instructions_provider: fn _ -> {:ok, "Guidance."} end,
        tool_presentation: fn _tool, _ -> {:ok, %{"description" => "Presented."}} end
      ]

      public_opts = [cache_scope: :public, allow_public_cache: true]
      context = %{principal: "cache-user", public_catalog: true}

      plain = start_server(public_opts)
      assert :ok = Server.register_tool(plain, "shared", %{})

      assert %{"cacheScope" => "public", "ttlMs" => 30_000} =
               modern(plain, "server/discover", context)["result"]

      assert %{"cacheScope" => "public", "ttlMs" => 30_000} =
               modern(plain, "tools/list", context)["result"]

      personalized = start_server(public_opts ++ providers)
      assert :ok = Server.register_tool(personalized, "shared", %{})

      assert %{"cacheScope" => "private", "ttlMs" => 0} =
               modern(personalized, "server/discover", context)["result"]

      assert %{"cacheScope" => "private", "ttlMs" => 0} =
               modern(personalized, "tools/list", context)["result"]
    end

    test "public method policies cannot publish provider output and explicit TTLs apply" do
      policy = [
        allow_public_cache: true,
        cache_policy: [
          methods: %{
            "server/discover" => [scope: :public, ttl_ms: 60_000],
            "tools/list" => [scope: :public]
          }
        ]
      ]

      context = %{principal: "policy-user"}

      plain = start_server(policy)
      assert :ok = Server.register_tool(plain, "shared", %{})

      assert %{"cacheScope" => "public", "ttlMs" => 60_000} =
               modern(plain, "server/discover", context)["result"]

      assert %{"cacheScope" => "public", "ttlMs" => 30_000} =
               modern(plain, "tools/list", context)["result"]

      personalized =
        start_server(
          policy ++
            [
              instructions_provider: fn _ -> {:ok, "Guidance."} end,
              tool_presentation: fn _tool, _ -> {:ok, %{"description" => "Presented."}} end
            ]
        )

      assert :ok = Server.register_tool(personalized, "shared", %{})

      assert %{"cacheScope" => "private", "ttlMs" => 60_000} =
               modern(personalized, "server/discover", context)["result"]

      assert %{"cacheScope" => "private", "ttlMs" => 0} =
               modern(personalized, "tools/list", context)["result"]
    end
  end

  defp initialize_frame(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @legacy,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "presentation-stdio", "version" => "1.0"}
      }
    }
  end

  defp run_stdio(server, lines, opts \\ []) do
    {:ok, source} = Agent.start_link(fn -> lines end)

    input = fn ->
      Agent.get_and_update(source, fn
        [{delay, line} | rest] ->
          Process.sleep(delay)
          {Jason.encode!(line) <> "\n", rest}

        [] ->
          Process.sleep(300)
          {:eof, []}
      end)
    end

    output =
      capture_io(fn ->
        Stdio.run(server, Keyword.merge([principal: "stdio-presentation", input: input], opts))
      end)

    output
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Map.new(&{&1["id"], &1})
  end

  defp http_list(plug, token) do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => "tools/list",
      "params" => %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @modern,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    conn(:post, "/mcp", Jason.encode!(payload))
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("mcp-protocol-version", @modern)
    |> put_req_header("mcp-method", "tools/list")
    |> Server.Plug.call(plug)
  end
end
