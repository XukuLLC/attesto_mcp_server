defmodule OAuthHost.RegistrationRefreshTest do
  # Dynamic registration, consent, refresh, and MCP access through the real
  # controllers, with none of the attesto_phoenix 4.3 opt-outs configured
  # (:registration_grant_types, :client_assertion_audiences,
  # :introspection_authorize).
  use ExUnit.Case, async: false

  alias AttestoClient.{AuthorizationCode, OAuthHTTP, RefreshCoordinator, Token}
  alias AttestoClient.AuthorizationTransaction.Store.ETS, as: TransactionStore
  alias AttestoMCP.Server

  @redirect_uri "https://client.upgrade-fixture.example/callback"
  @era "2026-07-28"
  @scopes ["openid" | AttestoMCP.Scopes.all()]

  setup do
    server = start_supervised!({Server, server_name: "upgrade-fixture"})
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
    registry = start_supervised!({Agent, fn -> %{} end})
    coordinator = start_supervised!(RefreshCoordinator)
    host = OAuthHost.build(server, owner, registry: registry)

    for {key, value} <- [
          registration_grant_types: nil,
          client_assertion_audiences: nil,
          introspection_authorize: nil
        ] do
      assert Map.fetch!(host.config, key) == value
    end

    %{
      server: server,
      host: host,
      opts: transport(host),
      registry: registry,
      store: {TransactionStore, transactions},
      coordinator: coordinator
    }
  end

  test "registration, consent, MCP access, refresh rotation, and in-window retry", ctx do
    # Registration (RFC 7591) under the 4.3 default: code and refresh are admitted.
    assert {:ok, %{status: 201, body: registered}} =
             Req.post(
               OAuthHost.issuer() <> "/oauth/register",
               Keyword.merge(ctx.opts,
                 json: %{
                   "redirect_uris" => [@redirect_uri],
                   "grant_types" => ["authorization_code", "refresh_token"],
                   "response_types" => ["code"],
                   "token_endpoint_auth_method" => "none",
                   "client_name" => "Upgrade fixture",
                   "scope" => Enum.join(@scopes, " ")
                 }
               )
             )

    client_id = registered["client_id"]
    assert is_binary(client_id) and client_id != ""
    assert registered["grant_types"] == ["authorization_code", "refresh_token"]
    refute Map.has_key?(registered, "client_secret")

    # Authorization with consent, then the code redemption with PKCE.
    {_callback, result} = authorize(ctx, client_id)
    assert_received {:consent, %{subject: "fixture"}}
    assert is_binary(result.tokens.refresh_token)
    assert {:ok, claims} = Attesto.Token.verify(ctx.host.protocol, result.tokens.access_token)
    assert claims["client_id"] == client_id
    assert claims["aud"] == OAuthHost.resource()

    # MCP access with the first access token.
    assert_tool(ctx.opts, result.tokens.access_token, client_id)

    # Refresh (RFC 6749 §6) rotates both tokens; the new access token reaches MCP.
    assert {:ok, refreshed} =
             Token.refresh(ctx.coordinator, client_id, result.tokens,
               token_endpoint: OAuthHost.issuer() <> "/oauth/token",
               issuer: OAuthHost.issuer(),
               client_id: client_id,
               subject: result.id_token_claims["sub"],
               req_options: ctx.opts
             )

    assert refreshed.tokens.access_token != result.tokens.access_token
    assert refreshed.tokens.refresh_token != result.tokens.refresh_token
    assert_tool(ctx.opts, refreshed.tokens.access_token, client_id)

    # Inside the default 60-second idempotency window, a retry of the
    # just-rotated token (a client that lost the response) gets the same
    # successor rather than tripping reuse detection.
    assert {:ok, %{"refresh_token" => retried}} =
             refresh_form(ctx.opts, client_id, result.tokens.refresh_token)

    assert retried == refreshed.tokens.refresh_token
  end

  test "with no retry window, replaying a rotated refresh token revokes the family", ctx do
    host = OAuthHost.build(ctx.server, self(), registry: ctx.registry, refresh_grace: 0)
    ctx = %{ctx | host: host, opts: transport(host)}
    client_id = register(ctx.opts)
    {_callback, result} = authorize(ctx, client_id)

    assert {:ok, %{"refresh_token" => successor}} =
             refresh_form(ctx.opts, client_id, result.tokens.refresh_token)

    # Reuse (RFC 9700 §4.14.2): the replay fails and the whole family, the
    # successor included, is revoked.
    assert {:error, {:oauth_error, 400, %{"error" => "invalid_grant"}}} =
             refresh_form(ctx.opts, client_id, result.tokens.refresh_token)

    assert {:error, {:oauth_error, 400, %{"error" => "invalid_grant"}}} =
             refresh_form(ctx.opts, client_id, successor)
  end

  test "the 4.3 registration default refuses client_credentials without an opt-out", ctx do
    assert "client_credentials" in AttestoPhoenix.Config.grant_types_supported(ctx.host.config)

    assert {:ok, %{status: 400, body: %{"error" => "invalid_client_metadata"}}} =
             Req.post(
               OAuthHost.issuer() <> "/oauth/register",
               Keyword.merge(ctx.opts,
                 json: %{
                   "grant_types" => ["client_credentials"],
                   "token_endpoint_auth_method" => "none"
                 }
               )
             )

    assert Agent.get(ctx.registry, & &1) == %{}
  end

  defp register(opts) do
    assert {:ok, %{status: 201, body: %{"client_id" => client_id}}} =
             Req.post(
               OAuthHost.issuer() <> "/oauth/register",
               Keyword.merge(opts,
                 json: %{
                   "redirect_uris" => [@redirect_uri],
                   "grant_types" => ["authorization_code", "refresh_token"],
                   "token_endpoint_auth_method" => "none",
                   "scope" => Enum.join(@scopes, " ")
                 }
               )
             )

    client_id
  end

  defp authorize(ctx, client_id) do
    assert {:ok, %{url: url}} =
             AuthorizationCode.start(ctx.store,
               issuer: OAuthHost.issuer(),
               client_id: client_id,
               redirect_uri: @redirect_uri,
               browser_binding: "fixture-browser",
               scopes: @scopes,
               id_token_alg: "RS256",
               authorization_params: %{"resource" => OAuthHost.resource()},
               req_options: ctx.opts
             )

    assert {:ok, response} = Req.get(url, Keyword.put(ctx.opts, :redirect, false))
    assert response.status == 302
    [location] = Req.Response.get_header(response, "location")
    assert String.starts_with?(location, @redirect_uri)
    callback = URI.decode_query(URI.parse(location).query)

    assert {:ok, result} =
             AuthorizationCode.callback(ctx.store, callback,
               browser_binding: "fixture-browser",
               req_options: ctx.opts
             )

    {callback, result}
  end

  defp assert_tool(opts, access_token, client_id) do
    expected = "authorized:" <> client_id

    assert {:ok, %{"result" => %{"content" => [%{"text" => ^expected}]}}} =
             OAuthHTTP.post_json(OAuthHost.resource(), tool(), access_token, req_options: opts)

    assert_received :tool_invoked
  end

  defp refresh_form(opts, client_id, refresh_token) do
    OAuthHTTP.post_form(
      OAuthHost.issuer() <> "/oauth/token",
      %{"grant_type" => "refresh_token", "refresh_token" => refresh_token},
      client_id: client_id,
      req_options: opts
    )
  end

  defp transport(host),
    do: [
      plug: fn conn -> OAuthHost.call(conn, host) end,
      retry: false,
      redirect: false,
      headers: [
        {"accept", "application/json, text/event-stream"},
        {"mcp-protocol-version", @era},
        {"mcp-method", "tools/call"},
        {"mcp-name", "whoami"}
      ]
    ]

  defp tool,
    do: %{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "tools/call",
      "params" => %{
        "name" => "whoami",
        "arguments" => %{},
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @era,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }
end
