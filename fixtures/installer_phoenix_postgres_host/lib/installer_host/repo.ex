defmodule InstallerHost.Repo do
  use Ecto.Repo,
    otp_app: :installer_host,
    adapter: Ecto.Adapters.Postgres
end
