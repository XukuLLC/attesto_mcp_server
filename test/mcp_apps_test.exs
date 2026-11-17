defmodule AttestoMCP.Server.MCPAppsTest do
  use ExUnit.Case, async: true

  alias AttestoMCP.Server
  alias AttestoMCP.Server.API

  @modern "2026-07-28"
  @legacy "2025-11-25"
  @older "2025-06-18"
  @malformed_capabilities [
    %{"extensions" => nil},
    %{"extensions" => []},
    %{"extensions" => %{"io.modelcontextprotocol/ui" => true}},
    %{"extensions" => %{"io.modelcontextprotocol/ui" => []}},
    %{"extensions" => %{"unprefixed" => %{}}}
  ]
  @capabilities_key "io.modelcontextprotocol/clientCapabilities"
  @extension "io.modelcontextprotocol/ui"
  @mime "text/html;profile=mcp-app"
  @uri "ui://inventory/dashboard"
  @settings %{"mimeTypes" => [@mime]}
  @declared %{"extensions" => %{@extension => @settings}}
  @tool_ui %{"resourceUri" => @uri, "visibility" => ["model", "app"]}
  @resource_ui %{
    "csp" => %{"resourceDomains" => ["https://static.example.test"]},
    "permissions" => %{"clipboardWrite" => %{}},
    "domain" => "https://inventory.example.test",
    "prefersBorder" => false
  }
  @html "<!doctype html><html lang=\"en\"><title>Inventory</title><p>Inventory</p></html>"
  @spoofed %{"extensions" => %{@extension => %{"mimeTypes" => ["text/plain"]}}}

  for revision <- [@modern, @legacy] do
    @revision revision

    test "#{revision} exposes declared and absent client extension settings to handlers" do
      {server, ref} = marker_tool()

      for {capabilities, expected} <- [
            {@declared, {:ok, @settings}},
            {%{"extensions" => %{@extension => %{}}}, {:ok, %{}}},
            {%{"extensions" => %{"com.example/other" => %{}}}, :error},
            {%{}, :error}
          ] do
        endpoint = endpoint(server, @revision, capabilities)

        assert %{"result" => %{"content" => [_]}} =
                 request(endpoint, "tools/call", %{"name" => "check"})

        assert_receive {^ref, ^expected}
      end
    end

    test "#{revision} round-trips an MCP App capability, tool descriptor, and UI resource" do
      {:ok, server} = API.start_link(capabilities: %{"extensions" => %{@extension => %{}}})

      assert :ok =
               API.register_tool(server, "inventory", %{
                 _meta: %{"ui" => @tool_ui},
                 handler: fn _, _ -> {:ok, "Inventory is available"} end
               })

      resource = %{
        "uri" => @uri,
        "mimeType" => @mime,
        "text" => @html,
        "_meta" => %{"ui" => @resource_ui}
      }

      assert :ok =
               API.register_resource(server, @uri, %{
                 mime_type: @mime,
                 handler: fn _, _ -> {:ok, resource} end
               })

      {endpoint, handshake} = connect(server, @revision, @declared)

      assert %{"result" => %{"capabilities" => %{"extensions" => %{@extension => %{}}}}} =
               handshake

      assert %{
               "result" => %{
                 "tools" => [%{"name" => "inventory", "_meta" => %{"ui" => @tool_ui}}]
               }
             } =
               request(endpoint, "tools/list", %{})

      assert %{"result" => %{"contents" => [^resource]}} =
               request(endpoint, "resources/read", %{"uri" => @uri})
    end

    test "#{revision} can present the UI variant only to clients that declare its media type" do
      {:ok, server} = API.start_link(tool_presentation: &present_inventory/2)

      :ok =
        API.register_tool(server, "inventory", %{
          handler: fn _, _ -> {:ok, "Inventory is available"} end
        })

      with_ui = endpoint(server, @revision, @declared)
      without_ui = endpoint(server, @revision, @spoofed)

      assert %{"result" => %{"tools" => [%{"_meta" => %{"ui" => @tool_ui}}]}} =
               request(with_ui, "tools/list", %{})

      assert %{"result" => %{"tools" => [fallback]}} = request(without_ui, "tools/list", %{})
      refute Map.has_key?(fallback, "_meta")
    end
  end

  test "2026-07-28 rejects malformed extension declarations before calling a handler" do
    {server, ref} = marker_tool()

    for capabilities <- @malformed_capabilities do
      assert %{"error" => %{"code" => -32_602}} =
               request({server, @modern, capabilities}, "tools/call", %{"name" => "check"})

      refute_received {^ref, _}
    end
  end

  test "legacy revisions initialize and ignore malformed extension declarations in handlers" do
    {server, ref} = marker_tool()

    for revision <- [@legacy, @older],
        capabilities <-
          @malformed_capabilities ++
            [%{"extensions" => Map.put(@declared["extensions"], "unprefixed", %{})}] do
      endpoint = endpoint(server, revision, capabilities)

      assert %{"result" => %{"content" => [_]}} =
               request(endpoint, "tools/call", %{"name" => "check"})

      assert_receive {^ref, :error}
    end
  end

  test "the extension helper does not fall back to raw request metadata" do
    context = %{request_meta: %{@capabilities_key => @declared}}
    assert :error = API.client_extension(context, @extension)

    assert :error =
             API.client_extension(
               Map.put(context, :client_capabilities, %{"extensions" => []}),
               @extension
             )

    assert :error =
             API.client_extension(
               Map.put(context, :client_capabilities, %{"extensions" => %{@extension => nil}}),
               @extension
             )
  end

  defp present_inventory(_tool, context) do
    with {:ok, %{"mimeTypes" => types}} when is_list(types) <-
           API.client_extension(context, @extension),
         true <- @mime in types do
      {:ok, %{"_meta" => %{"ui" => @tool_ui}}}
    else
      _ -> :default
    end
  end

  defp marker_tool do
    {:ok, server} = API.start_link([])
    owner = self()
    ref = make_ref()

    :ok =
      API.register_tool(server, "check", %{
        handler: fn _, context ->
          send(owner, {ref, API.client_extension(context, @extension)})
          {:ok, "checked"}
        end
      })

    {server, ref}
  end

  defp endpoint(server, revision, capabilities) do
    {endpoint, _handshake} = connect(server, revision, capabilities)
    endpoint
  end

  defp connect(server, @modern, capabilities) do
    endpoint = {server, @modern, capabilities}
    {endpoint, request(endpoint, "server/discover", %{})}
  end

  defp connect(server, revision, capabilities) when revision in [@legacy, @older] do
    {:ok, session} = Server.new_session(server, "owner", nil)
    endpoint = {server, revision, session.id}

    assert %{"result" => %{"protocolVersion" => ^revision}} =
             response =
             request(endpoint, "initialize", %{
               "protocolVersion" => revision,
               "clientInfo" => %{"name" => "test-client", "version" => "1.0"},
               "capabilities" => capabilities
             })

    :ok = Server.mark_initialized(server, session.id)
    {endpoint, response}
  end

  defp request({server, @modern, capabilities}, method, params) do
    params =
      Map.put(params, "_meta", %{
        "io.modelcontextprotocol/protocolVersion" => @modern,
        @capabilities_key => capabilities
      })

    dispatch(server, @modern, method, params, %{client_capabilities: @spoofed})
  end

  defp request({server, revision, session_id}, method, params)
       when revision in [@legacy, @older] do
    params = Map.put(params, "_meta", %{@capabilities_key => @spoofed})

    dispatch(server, revision, method, params, %{
      session_id: session_id,
      client_capabilities: @spoofed
    })
  end

  defp dispatch(server, revision, method, params, context) do
    {1, response} =
      API.dispatch(
        server,
        %{kind: :request, id: 1, method: method, params: params},
        Map.put(context, :principal, "owner"),
        version: revision
      )

    response
  end
end
