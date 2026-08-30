defmodule AttestoMCP.Server.CatalogReplacementTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server
  alias AttestoMCP.Server.API
  alias AttestoMCP.Server.Registry
  alias AttestoMCP.Server.Subscriptions

  @modern "2026-07-28"
  @legacy "2025-11-25"

  test "the stable facade replaces, removes, clears, and no-ops one complete catalog" do
    {:ok, server} = Server.start_link([])
    registry = registry(server)
    tool_handler = fn _arguments, _context -> {:ok, "tool"} end
    resource_handler = fn _input, _context -> {:ok, %{"contents" => []}} end

    catalog = [
      {:tool, "replace-tool", %{description: "replace", handler: tool_handler}},
      {:resource, "urn:replace:item", %{handler: resource_handler}}
    ]

    assert Registry.revision(registry) == 0
    assert :ok = API.replace_catalog(server, catalog)
    assert Registry.revision(registry) == 1
    assert Map.keys(API.snapshot(server).tool) == ["replace-tool"]
    assert Map.keys(API.snapshot(server).resource) == ["urn:replace:item"]

    first = API.snapshot(server)

    assert :ok = API.replace_catalog(server, Enum.reverse(catalog))
    assert Registry.revision(registry) == 1
    assert API.snapshot(server) == first

    assert :ok = API.replace_catalog(server, [hd(catalog)])
    assert Registry.revision(registry) == 2
    assert Map.keys(API.snapshot(server).tool) == ["replace-tool"]
    assert API.snapshot(server).resource == %{}

    assert :ok = API.replace_catalog(server, [])
    assert Registry.revision(registry) == 3
    assert Enum.all?(API.snapshot(server), fn {_type, definitions} -> definitions == %{} end)

    assert :ok = API.replace_catalog(server, [])
    assert Registry.revision(registry) == 3
  end

  test "invalid, duplicate, and oversized replacements roll back without advancing revision" do
    {:ok, server} = Server.start_link([])
    handler = fn _arguments, _context -> {:ok, "stable"} end
    stable = [{:tool, "stable", %{handler: handler}}]

    assert :ok = Server.replace_catalog(server, stable)
    before = Server.snapshot(server)
    revision = Registry.revision(registry(server))

    failures = [
      {
        [{:tool, "bad name", %{}}],
        {:error, {:invalid_definition, :identity}}
      },
      {
        [
          {:tool, "duplicate", %{}},
          {:tool, "duplicate", %{description: "second"}}
        ],
        {:error, {:duplicate, :tool, "duplicate"}}
      },
      {
        List.duplicate({:tool, "bounded", %{}}, 1_001),
        {:error, :too_many_registrations}
      }
    ]

    Enum.each(failures, fn {replacement, expected} ->
      assert Server.replace_catalog(server, replacement) == expected
      assert Server.snapshot(server) == before
      assert Registry.revision(registry(server)) == revision
    end)

    assert :ok = Server.register_tool(server, "after-rollback", %{handler: handler})

    assert Server.snapshot(server).tool |> Map.keys() |> Enum.sort() == [
             "after-rollback",
             "stable"
           ]
  end

  test "no-op and rejected replacements preserve cursors while an effective replacement revokes them" do
    handler = fn _arguments, _context -> {:ok, "ok"} end
    {:ok, server} = Server.start_link(page_size: 1, cursor_secret: "replacement-cursor")

    catalog = [
      {:tool, "alpha", %{description: "first", handler: handler}},
      {:tool, "beta", %{description: "before", handler: handler}}
    ]

    assert :ok = Server.replace_catalog(server, catalog)
    assert {1, %{"result" => %{"nextCursor" => cursor}}} = list_tools(server, 1)

    assert :ok = Server.replace_catalog(server, Enum.reverse(catalog))

    assert {2, %{"result" => %{"tools" => [%{"name" => "beta"}]}}} =
             list_tools(server, 2, cursor)

    assert {:error, {:duplicate, :tool, "alpha"}} =
             Server.replace_catalog(server, [hd(catalog), hd(catalog)])

    assert {3, %{"result" => %{"tools" => [%{"name" => "beta"}]}}} =
             list_tools(server, 3, cursor)

    changed =
      List.replace_at(catalog, 1, {:tool, "beta", %{description: "after", handler: handler}})

    assert :ok = Server.replace_catalog(server, changed)

    assert {4, %{"error" => %{"code" => -32602, "data" => %{"reason" => "invalid_cursor"}}}} =
             list_tools(server, 4, cursor)
  end

  test "effective replacements coalesce public invalidations and completion-only changes are silent" do
    {:ok, server} = Server.start_link([])
    subscriptions = GenServer.call(server, :subscriptions)

    assert {:ok, subscription_id} =
             Subscriptions.open(
               subscriptions,
               "catalog-owner",
               nil,
               "catalog-replacement",
               %{
                 "toolsListChanged" => true,
                 "promptsListChanged" => true,
                 "resourcesListChanged" => true
               },
               self(),
               :replacement,
               nil
             )

    assert_receive {:mcp_subscription, :replacement, "catalog-replacement", _ack}

    {:ok, session} = Server.new_session(server, "catalog-owner", nil)
    assert :ok = Server.negotiate_session(server, session.id, "catalog-owner", nil, @legacy, %{})
    assert :ok = Server.mark_initialized(server, session.id)

    assert {:ok, legacy_stream} =
             Server.open_legacy_stream(server, session.id, "catalog-owner", nil, self())

    tool_handler = fn _arguments, _context -> {:ok, "tool"} end
    prompt_handler = fn _input, _context -> {:ok, %{"messages" => []}} end
    resource_handler = fn _input, _context -> {:ok, %{"contents" => []}} end
    completion_handler = fn _input, _context -> {:ok, []} end

    catalog = [
      {:tool, "catalog-tool", %{handler: tool_handler}},
      {:prompt, "catalog-prompt", %{handler: prompt_handler}},
      {:resource, "urn:catalog:item", %{handler: resource_handler}},
      {:template, "urn:catalog:{id}", %{handler: resource_handler}},
      {:completion, "catalog-completion",
       %{
         ref: %{"type" => "ref/prompt", "name" => "catalog-prompt"},
         handler: completion_handler
       }}
    ]

    assert :ok = Server.replace_catalog(server, catalog)
    assert_catalog_invalidations(legacy_stream)

    assert :ok = Server.replace_catalog(server, Enum.reverse(catalog))
    refute_catalog_invalidation(legacy_stream)

    changed_completion = fn _input, _context -> {:ok, ["changed"]} end

    completion_only =
      Enum.map(catalog, fn
        {:completion, identity, definition} ->
          {:completion, identity, %{definition | handler: changed_completion}}

        registration ->
          registration
      end)

    assert :ok = Server.replace_catalog(server, completion_only)
    refute_catalog_invalidation(legacy_stream)

    assert :ok = Server.replace_catalog(server, [])
    assert_catalog_invalidations(legacy_stream)

    assert :ok = Subscriptions.close(subscriptions, subscription_id, self())
    assert :ok = Server.close_legacy_stream(server, legacy_stream)
  end

  test "failed replacement is notification-silent" do
    {:ok, server} = Server.start_link([])
    subscriptions = GenServer.call(server, :subscriptions)

    assert {:ok, subscription_id} =
             Subscriptions.open(
               subscriptions,
               "owner",
               nil,
               "failed-replacement",
               %{
                 "toolsListChanged" => true,
                 "promptsListChanged" => true,
                 "resourcesListChanged" => true
               },
               self(),
               :failed,
               nil
             )

    assert_receive {:mcp_subscription, :failed, "failed-replacement", _ack}

    failures = [
      [
        {:tool, "duplicate", %{}},
        {:tool, "duplicate", %{}}
      ],
      [{:tool, "bad name", %{}}],
      List.duplicate({:tool, "bounded", %{}}, 1_001)
    ]

    Enum.each(failures, fn replacement ->
      assert {:error, _reason} = Server.replace_catalog(server, replacement)
      refute_receive {:mcp_subscription, :failed, "failed-replacement", _event}, 100
    end)

    assert :ok = Subscriptions.close(subscriptions, subscription_id, self())
  end

  test "a registry crash restores the exact replacement without publishing invalidations" do
    {:ok, server} = Server.start_link([])
    subscriptions = GenServer.call(server, :subscriptions)

    assert {:ok, subscription_id} =
             Subscriptions.open(
               subscriptions,
               "owner",
               nil,
               "replacement-recovery",
               %{
                 "toolsListChanged" => true,
                 "promptsListChanged" => true,
                 "resourcesListChanged" => true
               },
               self(),
               :recovery,
               nil
             )

    assert_receive {:mcp_subscription, :recovery, "replacement-recovery", _ack}

    tool_handler = fn _arguments, _context -> {:ok, "restored"} end

    catalog = [
      {:tool, "restored-tool",
       %{
         required_scopes: ["records.read"],
         alternative_scope_sets: [["records.admin"]],
         handler: tool_handler
       }},
      {:resource, "urn:restored:item", %{handler: fn _, _ -> {:ok, %{"contents" => []}} end}}
    ]

    assert :ok = Server.replace_catalog(server, catalog)
    assert_receive {:mcp_subscription, :recovery, "replacement-recovery", _tool_event}
    assert_receive {:mcp_subscription, :recovery, "replacement-recovery", _resource_event}

    expected = Server.snapshot(server)
    old_registry = registry(server)
    Process.exit(old_registry, :kill)

    assert eventually(fn ->
             replacement = registry(server)
             replacement != old_registry and Server.snapshot(server) == expected
           end)

    refute_receive {:mcp_subscription, :recovery, "replacement-recovery", _event}, 100

    revision = Registry.revision(registry(server))
    assert :ok = Server.replace_catalog(server, Enum.reverse(catalog))
    assert Registry.revision(registry(server)) == revision
    assert Server.snapshot(server) == expected

    assert :ok = Subscriptions.close(subscriptions, subscription_id, self())
  end

  test "a registry crash cannot recycle a revision and resurrect an invalidated cursor" do
    handler = fn _arguments, _context -> {:ok, "ok"} end

    original = [
      {:tool, "alpha", %{description: "unchanged", handler: handler}},
      {:tool, "beta", %{description: "before", handler: handler}}
    ]

    {:ok, server} =
      Server.start_link(
        registrations: original,
        page_size: 1,
        cursor_secret: "recovery-revision-cursor"
      )

    assert Registry.revision(registry(server)) == 2
    assert {1, %{"result" => %{"nextCursor" => cursor}}} = list_tools(server, 1)

    replacement =
      List.replace_at(original, 1, {:tool, "beta", %{description: "after", handler: handler}})

    assert :ok = Server.replace_catalog(server, replacement)
    assert Registry.revision(registry(server)) == 3

    assert {2, %{"error" => %{"data" => %{"reason" => "invalid_cursor"}}}} =
             list_tools(server, 2, cursor)

    old_registry = registry(server)
    Process.exit(old_registry, :kill)

    assert eventually(fn ->
             recovered = registry(server)
             recovered != old_registry and Registry.revision(recovered) == 3
           end)

    assert {3, %{"error" => %{"data" => %{"reason" => "invalid_cursor"}}}} =
             list_tools(server, 3, cursor)
  end

  test "a registry crash restores a cumulative catalog larger than one public batch" do
    {:ok, server} = Server.start_link([])

    first_batch =
      Enum.map(1..1_000, fn index ->
        {:tool, "batch-tool-#{index}", %{}}
      end)

    assert :ok = Server.register_all(server, first_batch)
    assert :ok = Server.register_tool(server, "batch-tool-1001", %{})

    expected = Server.snapshot(server)
    assert map_size(expected.tool) == 1_001
    assert Registry.revision(registry(server)) == 1_001

    old_registry = registry(server)
    Process.exit(old_registry, :kill)

    assert eventually(fn ->
             recovered = registry(server)

             recovered != old_registry and Registry.revision(recovered) == 1_001 and
               Server.snapshot(server) == expected
           end)

    assert Process.alive?(server)
  end

  test "a selected in-flight handler finishes while later calls use the replacement" do
    {:ok, server} = Server.start_link(max_concurrency: 4)
    parent = self()

    old_handler = fn _arguments, _context ->
      send(parent, {:old_handler_started, self()})

      receive do
        :finish_old_handler -> {:ok, "old"}
      end
    end

    new_handler = fn _arguments, _context ->
      send(parent, :new_handler_called)
      {:ok, "new"}
    end

    assert :ok = Server.replace_catalog(server, [{:tool, "switch", %{handler: old_handler}}])

    in_flight =
      Task.async(fn ->
        call_tool(server, 1, "switch")
      end)

    assert_receive {:old_handler_started, old_worker}, 1_000

    assert :ok = Server.replace_catalog(server, [{:tool, "switch", %{handler: new_handler}}])

    assert {2, %{"result" => %{"isError" => false}}} = call_tool(server, 2, "switch")
    assert_receive :new_handler_called

    send(old_worker, :finish_old_handler)
    assert {1, %{"result" => %{"isError" => false}}} = Task.await(in_flight, 1_000)
    refute_receive :new_handler_called
  end

  defp registry(server), do: GenServer.call(server, :registry)

  defp list_tools(server, id, cursor \\ nil) do
    params = if cursor, do: Map.put(modern_params(), "cursor", cursor), else: modern_params()

    Server.dispatch(
      server,
      %{kind: :request, id: id, method: "tools/list", params: params},
      %{principal: "catalog", scopes: []},
      version: @modern
    )
  end

  defp call_tool(server, id, name) do
    Server.dispatch(
      server,
      %{
        kind: :request,
        id: id,
        method: "tools/call",
        params: Map.merge(modern_params(), %{"name" => name, "arguments" => %{}})
      },
      %{principal: "catalog", scopes: []},
      version: @modern
    )
  end

  defp modern_params do
    %{
      "_meta" => %{
        "io.modelcontextprotocol/protocolVersion" => @modern,
        "io.modelcontextprotocol/clientCapabilities" => %{}
      }
    }
  end

  defp assert_catalog_invalidations(legacy_stream) do
    for method <- [
          "notifications/tools/list_changed",
          "notifications/prompts/list_changed",
          "notifications/resources/list_changed"
        ] do
      assert_receive {:mcp_subscription, :replacement, "catalog-replacement",
                      %{"method" => ^method}},
                     1_000

      assert_receive {:mcp_legacy_event, ^legacy_stream, _, %{"method" => ^method}}, 1_000
    end

    refute_catalog_invalidation(legacy_stream)
  end

  defp refute_catalog_invalidation(legacy_stream) do
    refute_receive {:mcp_subscription, :replacement, "catalog-replacement", _event}, 75
    refute_receive {:mcp_legacy_event, ^legacy_stream, _, _event}, 75
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if safe_call(fun) do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp safe_call(fun) do
    fun.()
  catch
    :exit, _reason -> false
  end
end
