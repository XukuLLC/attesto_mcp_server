defmodule AttestoMCP.Server.IconsCompatibilityTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server
  alias AttestoMCP.Server.{Icons, Implementation}
  alias AttestoMCP.Server.Test, as: ServerTest

  @identity "io.modelcontextprotocol/serverInfo"
  @icon %{"src" => "https://example.com/icon.png"}

  defp start_server(opts) do
    start_supervised!(Supervisor.child_spec({Server, opts}, id: make_ref()))
  end

  defp authored_response(server, name, authored) do
    assert :ok =
             Server.register_tool(server, name, %{
               handler: fn _args, _context ->
                 {:ok, %{"content" => [], "_meta" => %{@identity => authored}}}
               end
             })

    ServerTest.call_tool(server, name, %{})["result"]["_meta"][@identity]
  end

  test "empty configured icons and HTTP icons survive discovery" do
    empty = start_server(server_icons: [])
    assert ServerTest.discover(empty)["result"]["_meta"][@identity]["icons"] == []

    icons = [%{"src" => "http://example.com/icon.png", "sizes" => []}]
    server = start_server(server_icons: icons)
    assert ServerTest.discover(server)["result"]["_meta"][@identity]["icons"] == icons
  end

  test "empty authored optional fields preserve identity rather than restoring configured icons" do
    server = start_server(server_name: "configured", server_icons: [@icon])

    authored = %{
      "name" => "custom",
      "version" => "1",
      "title" => "",
      "description" => "",
      "icons" => []
    }

    assert authored_response(server, "empty-identity", authored) == authored
  end

  test "authored wire size and media-type fields do not acquire configuration-only restrictions" do
    server = start_server(server_name: "configured", server_icons: [@icon])

    icons = [
      %{"src" => "http://example.com/icon.png", "sizes" => []},
      Map.put(@icon, "sizes", ["100000x1"]),
      Map.merge(@icon, %{"mimeType" => "application/octet-stream", "sizes" => ["48"]})
    ]

    authored = %{"name" => "custom", "version" => "1", "icons" => icons}
    assert authored_response(server, "wire-identity", authored) == authored

    assert {:ok, _icons} = Icons.normalize([Map.put(@icon, "sizes", ["100000x1"])])

    assert {:error, :invalid_icon_mime_type} =
             Icons.normalize([List.last(icons)])
  end

  test "presentation can clear registered icons without changing the shared definition" do
    for icons <- [[], [%{"src" => "http://example.com/icon.png", "sizes" => []}]] do
      server =
        start_server(tool_presentation: fn _descriptor, _context -> {:ok, %{icons: icons}} end)

      assert :ok = Server.register_tool(server, "clear-icons", %{icons: [@icon]})

      assert [%{"name" => "clear-icons", "icons" => ^icons}] =
               ServerTest.list_tools(server)["result"]["tools"]

      assert Server.snapshot(server).tool["clear-icons"]["icons"] == [@icon]
    end
  end

  test "trailing control characters are rejected by configured and authored icon validation" do
    invalid = [
      {Map.put(@icon, "mimeType", "image/png\n"), :invalid_icon_mime_type},
      {Map.put(@icon, "sizes", ["48x48\n"]), :invalid_icon_sizes},
      {%{"src" => "data:image/png;base64,AA==\n"}, :invalid_icon_src}
    ]

    for {icon, reason} <- invalid do
      assert {:error, ^reason} = Icons.normalize([icon])
      refute Implementation.valid?(%{"name" => "custom", "version" => "1", "icons" => [icon]})
    end
  end

  test "shared count and byte bounds still reject oversized wire metadata" do
    long_icon = %{"src" => "https://example.com/" <> String.duplicate("x", 60_000)}

    invalid = [
      List.duplicate(@icon, 17),
      [Map.put(@icon, "sizes", List.duplicate("any", 17))],
      [Map.put(@icon, "sizes", [String.duplicate("1", 128) <> "x1"])],
      List.duplicate(long_icon, 3)
    ]

    for icons <- invalid do
      assert {:error, _reason} = Icons.normalize(icons)
      refute Icons.valid_wire_list?(icons)
    end

    assert {:ok, _icons} = Icons.normalize(List.duplicate(long_icon, 2))
    assert Icons.valid_wire_list?(List.duplicate(long_icon, 2))
  end
end
