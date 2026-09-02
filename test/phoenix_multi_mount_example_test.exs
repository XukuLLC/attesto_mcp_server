defmodule AttestoMCP.Server.MultiMountExampleRouter do
  use Phoenix.Router
  use AttestoMCP.Router

  scope "/" do
    attesto_mcp_protected_resource_metadata("/mcp/catalog",
      scopes: ["catalog.mcp"],
      base_url: "https://mcp.example.com",
      root: false
    )

    attesto_mcp_protected_resource_metadata("/mcp/operations",
      scopes: ["operations.mcp"],
      base_url: "https://mcp.example.com",
      root: false
    )

    attesto_mcp_protected_resource_metadata("/mcp/preview",
      scopes: ["preview.mcp"],
      base_url: "https://mcp.example.com",
      root: false
    )
  end

  forward("/mcp/catalog", AttestoMCP.Server.Plug,
    server: AttestoMCP.Server.MultiMountCatalog,
    path: "/mcp/catalog",
    scopes_supported: ["catalog.mcp"],
    default_scopes: ["catalog.mcp"],
    auth: {AttestoMCP.Server.Phoenix, :protected_resource_options, [:my_app]},
    resource: "/mcp/catalog",
    base_url: "https://mcp.example.com"
  )

  forward("/mcp/operations", AttestoMCP.Server.Plug,
    server: AttestoMCP.Server.MultiMountOperations,
    path: "/mcp/operations",
    scopes_supported: ["operations.mcp"],
    default_scopes: ["operations.mcp"],
    auth: {AttestoMCP.Server.Phoenix, :protected_resource_options, [:my_app]},
    resource: "/mcp/operations",
    base_url: "https://mcp.example.com"
  )

  forward("/mcp/preview", AttestoMCP.Server.Plug,
    server: AttestoMCP.Server.MultiMountPreview,
    path: "/mcp/preview",
    scopes_supported: ["preview.mcp"],
    default_scopes: ["preview.mcp"],
    auth: {AttestoMCP.Server.Phoenix, :protected_resource_options, [:my_app]},
    resource: "/mcp/preview",
    base_url: "https://mcp.example.com"
  )
end

defmodule AttestoMCP.Server.PhoenixMultiMountExampleTest do
  use ExUnit.Case, async: true

  alias AttestoMCP.Server.MultiMountExampleRouter

  test "the documented router has three MCP forwards and three path metadata routes" do
    routes = Phoenix.Router.routes(MultiMountExampleRouter)

    forwards =
      Enum.filter(routes, fn route ->
        route.plug == AttestoMCP.Server.Plug
      end)

    assert Enum.map(forwards, & &1.path) == [
             "/mcp/catalog",
             "/mcp/operations",
             "/mcp/preview"
           ]

    metadata_paths =
      routes
      |> Enum.map(& &1.path)
      |> Enum.filter(&String.starts_with?(&1, "/.well-known/oauth-protected-resource/mcp/"))

    assert metadata_paths == [
             "/.well-known/oauth-protected-resource/mcp/catalog",
             "/.well-known/oauth-protected-resource/mcp/operations",
             "/.well-known/oauth-protected-resource/mcp/preview"
           ]

    refute Enum.any?(routes, &(&1.path == "/.well-known/oauth-protected-resource"))
  end
end
