import Config

config :installer_host, AttestoPhoenix.Config,
  issuer: "https://auth.example.com",
  audience: "https://mcp.example.com/mcp",
  keystore: Attesto.Keystore.Static,
  repo: InstallerHost.Repo,
  principal_kinds: fn -> [Attesto.PrincipalKind.new("service", "svc_")] end,
  load_client: fn _client_id -> {:error, :not_found} end,
  verify_client_secret: fn _client, _presented_secret -> false end,
  load_principal: fn _subject_id -> {:error, :not_found} end

if signing_pem = System.get_env("INSTALLER_HOST_SIGNING_PEM") do
  config :attesto, Attesto.Keystore.Static, signing_pem: signing_pem
end
