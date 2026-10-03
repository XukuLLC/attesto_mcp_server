# Official MCP conformance source c37eec888e1c6ff140af79987a40008548b7cc5f
# (includes PR #396). This AS scenario is unscored; it does not change the MCP
# server score. The caller supplies the built, pinned runner's dist/index.js.

defmodule OAuthHost.AuthorizationConformance do
  @expected_checks [
    "sep-1932-as-metadata-alg-values",
    "sep-1932-as-no-none-alg",
    "sep-1932-as-token-binding"
  ]

  def run(runner, output_dir) do
    unless File.regular?(runner), do: raise("built conformance runner does not exist")
    node = System.find_executable("node") || raise("node is required")
    openssl = System.find_executable("openssl") || raise("openssl is required")

    temporary =
      Path.join(System.tmp_dir!(), "attesto-oauth-as-#{System.unique_integer([:positive])}")

    File.mkdir!(temporary)
    File.chmod!(temporary, 0o700)

    try do
      certificate = certificate(openssl, temporary)
      initialize_stores()
      {:ok, server} = AttestoMCP.Server.start_link(server_name: "official-oauth-fixture")
      {:ok, state} = Agent.start_link(fn -> nil end)

      try do
        {:ok, bandit} =
          Bandit.start_link(
            plug: {OAuthHost.HTTP, state},
            scheme: :https,
            ip: {127, 0, 0, 1},
            port: 0,
            keyfile: Path.join(temporary, "key.pem"),
            certfile: certificate,
            startup_log: false
          )

        try do
          {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)
          issuer = "https://127.0.0.1:#{port}"
          resource = issuer <> "/mcp"

          host =
            OAuthHost.build(server, self(),
              dpop: true,
              issuer: issuer,
              resource: resource,
              other_resource: issuer <> "/other-api",
              base_url: issuer
            )

          Agent.update(state, fn _ -> host end)
          settings = Path.join(temporary, "settings.json")

          File.write!(
            settings,
            Jason.encode!(%{
              url: issuer,
              clientId: OAuthHost.client_id(),
              port: 39127,
              resource: resource
            })
          )

          args = [
            runner,
            "authorization",
            "--file",
            settings,
            "--scenario",
            "dpop",
            "--spec-version",
            "2026-07-28",
            "--output-dir",
            output_dir
          ]

          {output, status} =
            System.cmd(node, args,
              env: [{"NODE_EXTRA_CA_CERTS", certificate}, {"NODE_TLS_REJECT_UNAUTHORIZED", nil}],
              stderr_to_stdout: true
            )

          IO.binwrite(output)
          if status != 0, do: raise("official authorization dpop scenario failed: #{status}")
          verify_checks!(output_dir)
          requests = collect_requests([])
          verify_flow!(requests)

          File.write!(
            Path.join(output_dir, "oauth-flow.json"),
            Jason.encode!(%{scenario: "dpop", unscored: true, requests: requests}, pretty: true)
          )

          IO.puts(
            "Official AS dpop: 3 successful checks, 0 skipped; PKCE and DPoP nonce flow verified"
          )
        after
          Supervisor.stop(bandit)
        end
      after
        Agent.stop(state)
        GenServer.stop(server)
      end
    after
      File.rm_rf!(temporary)
    end
  end

  defp certificate(openssl, temporary) do
    config = Path.join(temporary, "openssl.cnf")
    certificate = Path.join(temporary, "cert.pem")
    key = Path.join(temporary, "key.pem")

    File.write!(config, """
    [req]
    distinguished_name = subject
    x509_extensions = extensions
    prompt = no
    [subject]
    CN = 127.0.0.1
    [extensions]
    subjectAltName = IP:127.0.0.1
    basicConstraints = critical,CA:TRUE
    keyUsage = critical,digitalSignature,keyEncipherment,keyCertSign
    extendedKeyUsage = serverAuth
    """)

    {_output, status} =
      System.cmd(
        openssl,
        [
          "req",
          "-x509",
          "-newkey",
          "rsa:2048",
          "-nodes",
          "-days",
          "1",
          "-config",
          config,
          "-keyout",
          key,
          "-out",
          certificate
        ],
        stderr_to_stdout: true
      )

    if status != 0, do: raise("temporary TLS certificate generation failed")
    File.chmod!(key, 0o600)
    certificate
  end

  defp initialize_stores do
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
  end

  defp verify_checks!(output_dir) do
    checks =
      output_dir
      |> Path.join("**/checks.json")
      |> Path.wildcard()
      |> Enum.flat_map(&(File.read!(&1) |> Jason.decode!()))

    actual = Enum.map(checks, & &1["id"]) |> Enum.sort()

    unless actual == Enum.sort(@expected_checks) and
             Enum.all?(checks, &(&1["status"] == "SUCCESS")) do
      raise("expected exactly three successful official AS DPoP checks with no skips")
    end
  end

  defp collect_requests(requests) do
    receive do
      {:oauth_network_response, method, path, status, error} ->
        request = %{method: method, path: path, status: status, error: error}
        collect_requests([request | requests])
    after
      0 -> Enum.reverse(requests)
    end
  end

  defp verify_flow!(requests) do
    expected = [
      {"GET", "/.well-known/oauth-authorization-server", 200, nil},
      {"GET", "/oauth/authorize", 302, nil},
      {"POST", "/oauth/token", 400, "use_dpop_nonce"},
      {"POST", "/oauth/token", 200, nil}
    ]

    actual = Enum.map(requests, &{&1.method, &1.path, &1.status, &1.error})

    unless actual == expected,
      do: raise("official runner did not complete the expected nonce flow")
  end
end

case Enum.drop_while(System.argv(), &(&1 == "--")) do
  [runner, output_dir] ->
    OAuthHost.AuthorizationConformance.run(Path.expand(runner), Path.expand(output_dir))

  _ ->
    raise("usage: mix run run_authorization_conformance.exs -- RUNNER_DIST_INDEX_JS OUTPUT_DIR")
end
