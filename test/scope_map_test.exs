defmodule AttestoMCP.Server.ScopeMapTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server
  alias AttestoMCP.Server.{Plug, ScopeMap}

  @resource "https://mcp.example.com/mcp"

  @supported_methods [
    "completion/complete",
    "initialize",
    "logging/setLevel",
    "ping",
    "prompts/get",
    "prompts/list",
    "resources/list",
    "resources/read",
    "resources/subscribe",
    "resources/templates/list",
    "resources/unsubscribe",
    "server/discover",
    "subscriptions/listen",
    "tools/call",
    "tools/list"
  ]

  test "accepts only the exact supported method set" do
    assert ScopeMap.supported_methods() == @supported_methods

    assert :ok =
             ScopeMap.validate(
               Map.new(@supported_methods, &{&1, ["scope:#{String.replace(&1, "/", ":")}"]})
             )

    for method <- [
          "arbitrary/method",
          "tasks/list",
          "tasks/get",
          "tasks/result",
          "tasks/cancel",
          "notifications/initialized",
          "notifications/cancelled",
          "notifications/progress",
          "notifications/message",
          "notifications/tools/list_changed",
          "notifications/prompts/list_changed",
          "notifications/resources/list_changed",
          "notifications/resources/updated",
          "notifications/subscriptions/acknowledged"
        ] do
      assert {:error, :invalid_scope_map} = ScopeMap.validate(%{method => ["scope:read"]})
    end

    assert {:error, :invalid_scope_map} = ScopeMap.validate(%{ping: ["scope:read"]})
  end

  test "accepts nil, empty maps, and explicit empty scope lists" do
    assert :ok = ScopeMap.validate(nil)
    assert :ok = ScopeMap.validate(%{})
    assert :ok = ScopeMap.validate(%{"ping" => []})
    assert :ok = ScopeMap.validate!(%{"ping" => ["scope:read"]})
  end

  test "publishes the HTTP method defaults from one shared table" do
    assert ScopeMap.default_scopes("tools/list") == [AttestoMCP.Scopes.tools_read()]
    assert ScopeMap.default_scopes("tools/call") == [AttestoMCP.Scopes.tools_call()]

    for method <- [
          "resources/list",
          "resources/read",
          "resources/templates/list",
          "resources/subscribe",
          "resources/unsubscribe"
        ] do
      assert ScopeMap.default_scopes(method) == [AttestoMCP.Scopes.resources_read()]
    end

    for method <- ["prompts/list", "prompts/get", "completion/complete"] do
      assert ScopeMap.default_scopes(method) == [AttestoMCP.Scopes.prompts_read()]
    end

    for method <- ["initialize", "ping", "logging/setLevel", "server/discover"] do
      assert ScopeMap.default_scopes(method) == []
    end
  end

  test "HTTP dispatch enforces shared defaults while stdio keeps its local fallback" do
    server = start_supervised!({Server, []})

    request = %{
      kind: :request,
      id: 71,
      method: "tools/list",
      params: %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    assert {71,
            %{
              "error" => %{
                "code" => -32003,
                "data" => %{"required_scopes" => ["mcp:tools:read"]}
              }
            }} =
             Server.dispatch(server, request, %{principal: "http"},
               version: "2026-07-28",
               transport: :http
             )

    assert {71, %{"result" => %{"tools" => []}}} =
             Server.dispatch(
               server,
               request,
               %{principal: "http", scopes: [AttestoMCP.Scopes.tools_read()]},
               version: "2026-07-28",
               transport: :http
             )

    assert {71, %{"result" => %{"tools" => []}}} =
             Server.dispatch(server, request, %{principal: "stdio", scopes: []},
               version: "2026-07-28",
               transport: :stdio
             )
  end

  test "direct HTTP dispatch applies params-dependent completion and subscription scopes" do
    server = start_supervised!({Server, []})

    completion = %{
      kind: :request,
      id: 73,
      method: "completion/complete",
      params: %{
        "ref" => %{"type" => "ref/resource", "uri" => "file:///catalog"},
        "argument" => %{"name" => "query", "value" => "attesto"},
        "_meta" => request_meta()
      }
    }

    assert {73,
            %{
              "error" => %{
                "code" => -32003,
                "data" => %{"required_scopes" => ["mcp:resources:read"]}
              }
            }} =
             Server.dispatch(server, completion, %{principal: "http"},
               version: "2026-07-28",
               transport: :http
             )

    subscription = %{
      kind: :request,
      id: 74,
      method: "subscriptions/listen",
      params: %{
        "notifications" => %{"toolsListChanged" => true},
        "_meta" => request_meta()
      }
    }

    assert {74,
            %{
              "error" => %{
                "code" => -32003,
                "data" => %{"required_scopes" => ["mcp:tools:read"]}
              }
            }} =
             Server.dispatch(server, subscription, %{principal: "http"},
               version: "2026-07-28",
               transport: :http
             )
  end

  test "stdio still enforces explicitly configured server scopes" do
    server = start_supervised!({Server, scope_map: %{"tools/list" => ["stdio:tools:read"]}})

    request = %{
      kind: :request,
      id: 72,
      method: "tools/list",
      params: %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    assert {72,
            %{
              "error" => %{
                "code" => -32003,
                "data" => %{"required_scopes" => ["stdio:tools:read"]}
              }
            }} =
             Server.dispatch(server, request, %{principal: "stdio", scopes: []},
               version: "2026-07-28",
               transport: :stdio
             )
  end

  test "rejects invalid, improper, duplicate, control, and non-UTF-8 scope lists" do
    invalid_maps = [
      %{"ping" => "scope:read"},
      %{"ping" => ["scope:read" | :improper_tail]},
      %{"ping" => ["scope:read", "scope:read"]},
      %{"ping" => [nil]},
      %{"ping" => [:scope]},
      %{"ping" => [""]},
      %{"ping" => ["scope with spaces"]},
      %{"ping" => ["scope:é"]},
      %{"ping" => [<<255>>]}
    ]

    for scope_map <- invalid_maps do
      assert {:error, :invalid_scope_map} = ScopeMap.validate(scope_map)
    end

    for byte <- Enum.to_list(0..31) ++ [127] do
      scope = "scope:a" <> <<byte>> <> "b"
      assert {:error, :invalid_scope_map} = ScopeMap.validate(%{"ping" => [scope]})
    end

    assert_raise ArgumentError, ~r/:scope_map must map supported MCP methods/, fn ->
      ScopeMap.validate!(%{"ping" => ["scope:read", "scope:read"]})
    end
  end

  test "enforces the method-count and per-method scope-count limits without truncation" do
    scopes = Enum.map(1..128, &"scope:#{&1}")

    assert :ok = ScopeMap.validate(%{"ping" => scopes})

    assert {:error, :invalid_scope_map} =
             ScopeMap.validate(%{"ping" => scopes ++ ["scope:129"]})

    oversized_map = Map.new(1..129, &{"unsupported/#{&1}", ["scope:read"]})
    assert {:error, :invalid_scope_map} = ScopeMap.validate(oversized_map)
  end

  test "enforces per-scope and per-method byte limits without truncation" do
    assert :ok = ScopeMap.validate(%{"ping" => [String.duplicate("a", 256)]})

    assert {:error, :invalid_scope_map} =
             ScopeMap.validate(%{"ping" => [String.duplicate("a", 257)]})

    exact_method_limit = sized_scopes(32, 256)
    assert Enum.sum(Enum.map(exact_method_limit, &byte_size/1)) == 8_192
    assert :ok = ScopeMap.validate(%{"ping" => exact_method_limit})

    assert {:error, :invalid_scope_map} =
             ScopeMap.validate(%{"ping" => exact_method_limit ++ ["a"]})
  end

  test "enforces the aggregate scope-byte limit across methods" do
    exact_method_limit = sized_scopes(32, 256)
    methods = Enum.take(@supported_methods, 9)

    exact_total_limit = Map.new(Enum.take(methods, 8), &{&1, exact_method_limit})
    assert :ok = ScopeMap.validate(exact_total_limit)

    above_total_limit = Map.put(exact_total_limit, Enum.at(methods, 8), ["a"])
    assert {:error, :invalid_scope_map} = ScopeMap.validate(above_total_limit)
  end

  test "Server and Plug apply identical scope-map validation" do
    plug_server = start_supervised!({Server, []})

    exact_method_limit = sized_scopes(32, 256)

    cases = [
      {nil, :accepted},
      {%{}, :accepted},
      {%{"ping" => []}, :accepted},
      {%{"tools/list" => ["scope:read"]}, :accepted},
      {%{"ping" => exact_method_limit}, :accepted},
      {%{"unknown" => ["scope:read"]}, :rejected},
      {%{"tasks/list" => ["scope:read"]}, :rejected},
      {%{"notifications/initialized" => ["scope:read"]}, :rejected},
      {%{"ping" => ["scope:read", "scope:read"]}, :rejected},
      {%{"ping" => [<<255>>]}, :rejected},
      {%{"ping" => exact_method_limit ++ ["a"]}, :rejected}
    ]

    for {scope_map, expected} <- cases do
      assert server_validation(scope_map) == expected
      assert plug_validation(plug_server, scope_map) == expected
    end
  end

  defp sized_scopes(count, bytes_per_scope) do
    Enum.map(1..count, fn index ->
      prefix = "scope:#{index}:"
      prefix <> String.duplicate("a", bytes_per_scope - byte_size(prefix))
    end)
  end

  defp request_meta do
    %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }
  end

  defp server_validation(scope_map) do
    parent = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)

        result =
          case Server.start_link(scope_map: scope_map) do
            {:ok, server} ->
              GenServer.stop(server)
              :accepted

            {:error, {%ArgumentError{}, _stacktrace}} ->
              :rejected

            {:error, %ArgumentError{}} ->
              :rejected

            other ->
              {:unexpected, other}
          end

        send(parent, {ref, result})
      end)

    assert_receive {^ref, result}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
    result
  end

  defp plug_validation(server, scope_map) do
    opts = [
      server: server,
      path: "/mcp",
      auth: [config: AttestoMCP.Test.Factory.config(), resource: @resource],
      scope_map: scope_map
    ]

    Plug.init(opts)
    :accepted
  rescue
    ArgumentError -> :rejected
  end
end
