defmodule OAuthHost.IntegrationTest do
  use ExUnit.Case, async: false

  alias AttestoClient.{AuthorizationCode, OAuthHTTP}
  alias AttestoClient.AuthorizationTransaction.Store.ETS, as: TransactionStore
  alias AttestoMCP.Server

  setup do
    server = start_supervised!({Server, server_name: "oauth-fixture"})
    owner = self()

    :ok =
      Server.register_tool(server, "whoami", %{
        input_schema: %{"type" => "object"},
        handler: fn _args, context ->
          send(owner, :tool_invoked)
          {:ok, "authorized:" <> context.attesto_mcp_claims["client_id"]}
        end
      })

    transactions = start_supervised!(TransactionStore)
    %{server: server, store: {TransactionStore, transactions}}
  end

  for era <- ["2025-11-25", "2026-07-28"] do
    @era era
    test "#{era}: discovery, native loopback PKCE, verified ID Token and authenticated MCP",
         ctx do
      host = OAuthHost.build(ctx.server, self())
      opts = transport(host, @era)

      assert {:ok, response} = Req.get(OAuthHost.resource(), opts)
      assert response.status == 401
      assert [challenge] = Req.Response.get_header(response, "www-authenticate")
      assert challenge =~ "resource_metadata="

      assert {:ok, resource} =
               OAuthHTTP.get_json(
                 "https://mcp.oauth-fixture.example/.well-known/oauth-protected-resource/mcp",
                 req_options: opts
               )

      assert resource["resource"] == OAuthHost.resource()
      assert resource["authorization_servers"] == [OAuthHost.issuer()]

      assert {:ok, metadata} =
               OAuthHTTP.get_json(
                 OAuthHost.issuer() <> "/.well-known/oauth-authorization-server",
                 req_options: opts
               )

      assert metadata["code_challenge_methods_supported"] == ["S256"]

      {callback, result} = authorize(ctx.store, host, opts)
      assert result.id_token_claims["iss"] == OAuthHost.issuer()
      assert result.id_token_claims["sub"] == "fixture"
      assert {:ok, claims} = Attesto.Token.verify(host.protocol, result.tokens.access_token)
      assert claims["aud"] == OAuthHost.resource()
      assert claims["client_id"] == OAuthHost.client_id()

      initialization = initialize(@era)

      assert {:ok, init} =
               Req.post(
                 OAuthHost.resource(),
                 Keyword.merge(with_method(opts, initialization["method"]),
                   json: initialization,
                   auth: {:bearer, result.tokens.access_token}
                 )
               )

      assert init.status == 200

      if @era == "2026-07-28",
        do: assert(@era in init.body["result"]["supportedVersions"]),
        else: assert(init.body["result"]["protocolVersion"] == @era)

      opts = with_legacy_session(opts, init, result.tokens.access_token, @era)

      assert {:ok, %{"result" => %{"content" => [%{"text" => "authorized:oauth-fixture"}]}}} =
               OAuthHTTP.post_json(OAuthHost.resource(), tool(@era), result.tokens.access_token,
                 req_options: opts
               )

      assert_received :tool_invoked

      assert {:error, {:invalid_state, :not_found}} =
               AuthorizationCode.callback(ctx.store, callback,
                 browser_binding: "fixture-browser",
                 req_options: opts
               )

      assert_received {:oauth_request, "GET", "/.well-known/openid-configuration"}
      assert_received {:oauth_request, "GET", "/.well-known/jwks.json"}
      assert_received {:oauth_request, "POST", "/oauth/token"}
    end
  end

  test "wrong PKCE and authorization-code replay fail at the real token endpoint", ctx do
    host = OAuthHost.build(ctx.server, self())
    opts = transport(host, "2026-07-28")
    {params, transaction} = authorization_response(ctx.store, host, opts)
    form = redemption(params, transaction.code_verifier)

    assert {:error, {:oauth_error, 400, %{"error" => "invalid_grant"}}} =
             OAuthHTTP.post_form(
               OAuthHost.issuer() <> "/oauth/token",
               Map.put(form, "code_verifier", String.duplicate("x", 43)),
               client_id: OAuthHost.client_id(),
               req_options: opts
             )

    {params, transaction} = authorization_response(ctx.store, host, opts)
    form = redemption(params, transaction.code_verifier)

    assert {:ok, %{"access_token" => _}} =
             OAuthHTTP.post_form(OAuthHost.issuer() <> "/oauth/token", form,
               client_id: OAuthHost.client_id(),
               req_options: opts
             )

    assert {:error, {:oauth_error, 400, %{"error" => "invalid_grant"}}} =
             OAuthHTTP.post_form(OAuthHost.issuer() <> "/oauth/token", form,
               client_id: OAuthHost.client_id(),
               req_options: opts
             )

    refute_received :tool_invoked
  end

  test "resource substitution is rejected and a token for another API cannot reach MCP", ctx do
    host = OAuthHost.build(ctx.server, self())
    opts = transport(host, "2026-07-28")
    {params, transaction} = authorization_response(ctx.store, host, opts)

    form =
      redemption(params, transaction.code_verifier)
      |> Map.put("resource", OAuthHost.other_resource())

    assert {:error, {:oauth_error, 400, %{"error" => "invalid_target"}}} =
             OAuthHTTP.post_form(OAuthHost.issuer() <> "/oauth/token", form,
               client_id: OAuthHost.client_id(),
               req_options: opts
             )

    {_params, result} = authorize(ctx.store, host, opts, resource: OAuthHost.other_resource())

    assert {:error, {:oauth_error, 401, _}} =
             OAuthHTTP.post_json(OAuthHost.resource(), tool(), result.tokens.access_token,
               req_options: opts
             )

    refute_received :tool_invoked
  end

  test "DPoP code binding, token/resource nonce retries, key binding and proof replay", ctx do
    host = OAuthHost.build(ctx.server, self(), dpop: true)
    opts = transport(host, "2026-07-28")
    key = JOSE.JWK.generate_key({:ec, "P-256"})
    {_params, result} = authorize(ctx.store, host, opts, dpop: key)
    assert result.tokens.token_type == "DPoP"

    assert {:ok, %{"result" => _}} =
             OAuthHTTP.post_json(OAuthHost.resource(), tool(), result.tokens.access_token,
               dpop: key,
               req_options: opts
             )

    assert_received :tool_invoked

    nonce = Attesto.DPoP.NonceStore.ETS.issue()

    {:ok, proof} =
      AttestoClient.DPoP.proof(key, "POST", OAuthHost.resource(),
        access_token: result.tokens.access_token,
        nonce: nonce
      )

    headers = [{"authorization", "DPoP " <> result.tokens.access_token}, {"dpop", proof}]

    assert {:ok, %{status: 200}} =
             Req.post(
               OAuthHost.resource(),
               Keyword.merge(opts, json: tool(), headers: headers ++ opts[:headers])
             )

    assert_received :tool_invoked

    assert {:ok, %{status: 401}} =
             Req.post(
               OAuthHost.resource(),
               Keyword.merge(opts, json: tool(), headers: headers ++ opts[:headers])
             )

    refute_received :tool_invoked

    for {proof_key, method, uri, token} <- [
          {JOSE.JWK.generate_key({:ec, "P-256"}), "POST", OAuthHost.resource(),
           result.tokens.access_token},
          {key, "GET", OAuthHost.resource(), result.tokens.access_token},
          {key, "POST", OAuthHost.other_resource(), result.tokens.access_token},
          {key, "POST", OAuthHost.resource(), "wrong-access-token"}
        ] do
      {:ok, invalid} =
        AttestoClient.DPoP.proof(proof_key, method, uri, access_token: token, nonce: nonce)

      headers =
        [{"authorization", "DPoP " <> result.tokens.access_token}, {"dpop", invalid}] ++
          opts[:headers]

      assert {:ok, %{status: 401}} =
               Req.post(OAuthHost.resource(), Keyword.merge(opts, json: tool(), headers: headers))

      refute_received :tool_invoked
    end

    {params, transaction} =
      authorization_response(ctx.store, host, opts, %{"dpop_jkt" => JOSE.JWK.thumbprint(key)})

    assert {:error, {:oauth_error, 400, %{"error" => "invalid_grant"}}} =
             OAuthHTTP.post_form(
               OAuthHost.issuer() <> "/oauth/token",
               redemption(params, transaction.code_verifier),
               client_id: OAuthHost.client_id(),
               dpop: JOSE.JWK.generate_key({:ec, "P-256"}),
               req_options: opts
             )

    refute_received :tool_invoked
  end

  defp authorize(store, _host, opts, options \\ []) do
    key = Keyword.get(options, :dpop)
    extra = %{"resource" => Keyword.get(options, :resource, OAuthHost.resource())}
    extra = if key, do: Map.put(extra, "dpop_jkt", JOSE.JWK.thumbprint(key)), else: extra
    assert {:ok, %{url: url}} = AuthorizationCode.start(store, start_options(opts, extra))
    assert {:ok, response} = Req.get(url, Keyword.put(opts, :redirect, false))
    assert response.status == 302
    [location] = Req.Response.get_header(response, "location")
    callback = URI.decode_query(URI.parse(location).query)

    assert {:ok, result} =
             AuthorizationCode.callback(store, callback,
               browser_binding: "fixture-browser",
               req_options: opts,
               dpop: key
             )

    {callback, result}
  end

  defp authorization_response({TransactionStore, pid} = store, _host, opts, extra \\ %{}) do
    assert {:ok, %{url: url, state: state}} =
             AuthorizationCode.start(
               store,
               start_options(opts, Map.merge(%{"resource" => OAuthHost.resource()}, extra))
             )

    assert {:ok, transaction} = TransactionStore.take(pid, state)
    assert {:ok, response} = Req.get(url, Keyword.put(opts, :redirect, false))
    assert response.status == 302
    [location] = Req.Response.get_header(response, "location")
    {URI.decode_query(URI.parse(location).query), transaction}
  end

  defp start_options(opts, extra),
    do: [
      issuer: OAuthHost.issuer(),
      client_id: OAuthHost.client_id(),
      redirect_uri: OAuthHost.redirect_uri(),
      browser_binding: "fixture-browser",
      scopes: ["openid" | AttestoMCP.Scopes.all()],
      id_token_alg: "RS256",
      authorization_params: extra,
      req_options: opts
    ]

  defp redemption(params, verifier),
    do: %{
      "grant_type" => "authorization_code",
      "code" => params["code"],
      "redirect_uri" => OAuthHost.redirect_uri(),
      "code_verifier" => verifier
    }

  defp transport(host, era),
    do: [
      plug: fn conn -> OAuthHost.call(conn, host) end,
      retry: false,
      redirect: false,
      headers: [
        {"accept", "application/json, text/event-stream"},
        {"mcp-protocol-version", era},
        {"mcp-method", "tools/call"},
        {"mcp-name", "whoami"}
      ]
    ]

  defp initialize("2026-07-28" = era),
    do: %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "server/discover",
      "params" => meta(%{}, era)
    }

  defp initialize(era),
    do: %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" =>
        meta(
          %{
            "protocolVersion" => era,
            "capabilities" => %{},
            "clientInfo" => %{"name" => "oauth-fixture", "version" => "1"}
          },
          era
        )
    }

  defp tool(era \\ "2026-07-28"),
    do: %{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "tools/call",
      "params" => meta(%{"name" => "whoami", "arguments" => %{}}, era)
    }

  defp meta(params, "2025-11-25"), do: params

  defp meta(params, era),
    do:
      Map.put(params, "_meta", %{
        "io.modelcontextprotocol/protocolVersion" => era,
        "io.modelcontextprotocol/clientCapabilities" => %{}
      })

  defp with_method(opts, method) do
    headers = Enum.reject(opts[:headers], fn {name, _} -> name in ["mcp-method", "mcp-name"] end)
    Keyword.put(opts, :headers, [{"mcp-method", method} | headers])
  end

  defp with_legacy_session(opts, _init, _token, "2026-07-28"), do: opts

  defp with_legacy_session(opts, init, token, "2025-11-25") do
    [session] = Req.Response.get_header(init, "mcp-session-id")
    opts = Keyword.update!(opts, :headers, &[{"mcp-session-id", session} | &1])
    notification = %{"jsonrpc" => "2.0", "method" => "notifications/initialized", "params" => %{}}

    assert :ok =
             OAuthHTTP.post_json_unit(OAuthHost.resource(), notification, token,
               req_options: with_method(opts, "notifications/initialized")
             )

    opts
  end
end
