ExUnit.start()

Application.put_env(
  :oauth_host,
  :signing_pem,
  JOSE.JWK.generate_key({:rsa, 2048}) |> JOSE.JWK.to_pem() |> elem(1)
)

for module <- [Attesto.CodeStore.ETS, Attesto.DPoP.NonceStore.ETS, Attesto.DPoP.ReplayCache] do
  case module.start_link() do
    {:ok, _pid} -> :ok
    {:error, {:already_started, _pid}} -> :ok
  end
end
