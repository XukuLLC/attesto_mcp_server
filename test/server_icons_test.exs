defmodule AttestoMCP.Server.ServerIconsTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server
  alias AttestoMCP.Server.Test, as: ServerTest

  @modern "2026-07-28"
  @legacy "2025-11-25"
  @legacy_2025_06_18 "2025-06-18"
  @server_info "io.modelcontextprotocol/serverInfo"
  @png_icon %{"src" => "https://example.com/icons/server.png", "mimeType" => "image/png"}
  @tiny_png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

  defp start_server(opts) do
    start_supervised!({Server, opts}, id: make_ref())
  end

  defp initialize(server, version) do
    {1, response} =
      Server.dispatch(
        server,
        %{
          kind: :request,
          id: 1,
          method: "initialize",
          params: %{
            "protocolVersion" => version,
            "capabilities" => %{},
            "clientInfo" => %{"name" => "icon-test", "version" => "1.0"}
          }
        },
        %{principal: "icons"},
        version: version
      )

    response
  end

  test "configured icons appear consistently in discovery, result stamps, and 2025-11-25 initialize" do
    server =
      start_server(
        server_name: "example-catalog",
        server_version: "4.2.0",
        server_icons: [
          %{
            src: "https://example.com/icons/server.png",
            mime_type: "image/png",
            sizes: ["48x48"]
          },
          %{"src" => "data:image/png;base64," <> @tiny_png, "theme" => "dark", "sizes" => ["any"]}
        ]
      )

    assert :ok =
             Server.register_tool(server, "echo", %{handler: fn _args, _ctx -> {:ok, "ok"} end})

    expected = %{
      "name" => "example-catalog",
      "version" => "4.2.0",
      "icons" => [
        %{
          "src" => "https://example.com/icons/server.png",
          "mimeType" => "image/png",
          "sizes" => ["48x48"]
        },
        %{"src" => "data:image/png;base64," <> @tiny_png, "theme" => "dark", "sizes" => ["any"]}
      ]
    }

    discovered = ServerTest.discover(server)["result"]["_meta"][@server_info]
    stamped = ServerTest.call_tool(server, "echo", %{})["result"]["_meta"][@server_info]
    listed = ServerTest.list_tools(server)["result"]["_meta"][@server_info]

    assert discovered == expected
    assert stamped == expected
    assert listed == expected

    assert %{"result" => %{"serverInfo" => ^expected}} = initialize(server, @legacy)
  end

  test "2025-06-18 initialize omits implementation icons" do
    server = start_server(server_icons: [@png_icon], server_name: "example-catalog")

    assert %{"result" => %{"serverInfo" => info, "protocolVersion" => @legacy_2025_06_18}} =
             initialize(server, @legacy_2025_06_18)

    assert info["name"] == "example-catalog"
    refute Map.has_key?(info, "icons")
  end

  test "default identity is unchanged when no icons are configured" do
    server = start_server([])
    info = ServerTest.discover(server)["result"]["_meta"][@server_info]

    assert info["name"] == "attesto_mcp_server"
    assert is_binary(info["version"]) and info["version"] != ""
    refute Map.has_key?(info, "icons")
  end

  test "malformed configured icons fail startup" do
    oversized = "data:image/png;base64," <> String.duplicate("AAAA", 40_000)

    invalid = [
      "https://example.com/icon.png",
      [%{"src" => "javascript:alert(1)"}],
      [%{"src" => "/icons/server.png"}],
      [%{"src" => "https://user:pass@example.com/icon.png"}],
      [%{"src" => "https://example.com/icon one.png"}],
      [%{"mimeType" => "image/png"}],
      [%{"src" => "https://example.com/icon.png", "alt" => "logo"}],
      [%{"src" => "https://example.com/icon.png", "mimeType" => "text/html"}],
      [%{"src" => "https://example.com/icon.png", "mimeType" => ""}],
      [%{"src" => "https://example.com/icon.png", "sizes" => ["48"]}],
      [%{"src" => "https://example.com/icon.png", "theme" => "blue"}],
      [%{src: "https://example.com/icon.png", mimeType: "image/png", mime_type: "image/png"}],
      [%{"src" => "data:image/png;base64,not base64!"}],
      [%{"src" => "data:text/html;base64," <> @tiny_png}],
      [%{"src" => "data:image/png;base64,"}],
      [%{"src" => oversized}],
      List.duplicate(@png_icon, 17)
    ]

    Process.flag(:trap_exit, true)

    for icons <- invalid do
      assert {:error, {%ArgumentError{message: message}, _stack}} =
               Server.start_link(server_icons: icons)

      assert message =~ "server_icons"
    end
  end

  test "valid handler-authored implementation information is preserved" do
    authored = %{
      "name" => "delegate",
      "version" => "9.9.9",
      "title" => "Delegate",
      "description" => "Answers on behalf of a delegate service.",
      "websiteUrl" => "https://example.com/delegate",
      "icons" => [%{"src" => "https://example.com/delegate.png", "sizes" => ["32x32"]}]
    }

    server = start_server(server_icons: [@png_icon])

    assert :ok =
             Server.register_tool(server, "authored", %{
               handler: fn _args, _ctx ->
                 {:ok,
                  %{
                    "content" => [%{"type" => "text", "text" => "ok"}],
                    "_meta" => %{@server_info => authored}
                  }}
               end
             })

    assert ServerTest.call_tool(server, "authored", %{})["result"]["_meta"][@server_info] ==
             authored
  end

  test "malformed handler-authored implementation information is replaced by the configured value" do
    server = start_server(server_name: "configured", server_icons: [@png_icon])
    configured = ServerTest.discover(server)["result"]["_meta"][@server_info]

    malformed = [
      %{"name" => "x", "version" => "1", "icons" => [%{"src" => "javascript:alert(1)"}]},
      %{"name" => "x", "version" => "1", "icons" => "https://example.com/icon.png"},
      %{"name" => "x", "version" => "1", "websiteUrl" => "ftp://example.com"},
      %{"name" => "x", "version" => "1", "build" => "123"},
      %{"name" => "", "version" => "1"},
      "not-a-map"
    ]

    for {authored, index} <- Enum.with_index(malformed) do
      name = "authored-#{index}"

      assert :ok =
               Server.register_tool(server, name, %{
                 handler: fn _args, _ctx ->
                   {:ok,
                    %{
                      "content" => [%{"type" => "text", "text" => "ok"}],
                      "_meta" => %{@server_info => authored}
                    }}
                 end
               })

      assert ServerTest.call_tool(server, name, %{})["result"]["_meta"][@server_info] ==
               configured
    end
  end

  test "simultaneous servers keep separate identities" do
    first = start_server(server_name: "first", server_icons: [@png_icon])

    second =
      start_server(
        server_name: "second",
        server_icons: [
          %{"src" => "https://example.com/second.svg", "mimeType" => "image/svg+xml"}
        ]
      )

    results =
      [first, second, first, second]
      |> Enum.map(fn server -> Task.async(fn -> ServerTest.discover(server) end) end)
      |> Enum.map(&Task.await/1)
      |> Enum.map(& &1["result"]["_meta"][@server_info])

    assert [
             %{"name" => "first", "icons" => [@png_icon]},
             %{"name" => "second", "icons" => [%{"src" => "https://example.com/second.svg"}]},
             %{"name" => "first"},
             %{"name" => "second"}
           ] = results
  end

  test "component icons keep their 2.3 registration checks" do
    server = start_server([])

    assert :ok =
             Server.register_tool(server, "relative-icon", %{
               icons: [%{"src" => "/icons/tool.png", "sizes" => ["48"]}],
               handler: fn _args, _ctx -> {:ok, "ok"} end
             })

    assert [%{"icons" => [%{"src" => "/icons/tool.png"}]}] =
             ServerTest.list_tools(server)["result"]["tools"]

    assert {:error, {:invalid_definition, :icons}} =
             Server.register_tool(server, "missing-src", %{
               icons: [%{"mimeType" => "image/png"}],
               handler: fn _args, _ctx -> {:ok, "ok"} end
             })
  end

  test "implementation identity does not affect authorization or caching" do
    server = start_server(server_name: "identity-a", server_icons: [@png_icon])

    assert :ok =
             Server.register_tool(server, "scoped", %{
               required_scopes: ["items.read"],
               handler: fn _args, _ctx -> {:ok, "ok"} end
             })

    assert %{"error" => %{"code" => -32602}} =
             ServerTest.call_tool(server, "scoped", %{},
               meta: %{@server_info => %{"name" => "identity-a", "version" => "1"}}
             )

    assert %{"result" => %{"cacheScope" => "private", "tools" => []}} =
             ServerTest.list_tools(server)
  end

  test "modern results stay valid MCP results with icons" do
    server = start_server(server_icons: [@png_icon])
    response = ServerTest.discover(server, request_id: "discover-1")

    assert %{"id" => "discover-1", "result" => %{"resultType" => "complete"}} = response
    assert response["result"]["supportedVersions"] == [@modern, @legacy, @legacy_2025_06_18]
  end
end
