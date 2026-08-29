defmodule InstallerHostWeb.Router do
  use Phoenix.Router
  use AttestoPhoenix.Router

  pipeline :attesto_config do
    plug(AttestoPhoenix.Plug.PutConfig, otp_app: :installer_host)
  end

  pipe_through(:attesto_config)

  post("/unrelated-json", InstallerHostWeb.ParsedBodyProbe, :accept)
  post("/unrelated-form", InstallerHostWeb.ParsedBodyProbe, :accept)

  attesto_routes(protected_resource_paths: ["/mcp"])
end
