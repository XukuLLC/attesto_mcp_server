ExUnit.start()

Application.put_env(
  :oauth_host,
  :signing_pem,
  JOSE.JWK.generate_key({:rsa, 2048}) |> JOSE.JWK.to_pem() |> elem(1)
)

for child <- [
      Attesto.CodeStore.ETS,
      Attesto.DPoP.NonceStore.ETS,
      {Attesto.DPoP.ReplayCache, single_node?: true},
      Attesto.RefreshStore.ETS
    ] do
  {module, opts} = if is_tuple(child), do: child, else: {child, []}

  case module.start_link(opts) do
    {:ok, _pid} -> :ok
    {:error, {:already_started, _pid}} -> :ok
  end
end
