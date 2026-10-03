defmodule OAuthHost do
  @moduledoc false

  import Plug.Conn

  alias AttestoPhoenix.Config

  alias AttestoPhoenix.Controller.{
    AuthorizeController,
    DiscoveryController,
    JWKSController,
    OpenIDConfigurationController,
    TokenController
  }

  @issuer "https://issuer.oauth-fixture.example"
  @resource "https://mcp.oauth-fixture.example/mcp"
  @other_resource "https://mcp.oauth-fixture.example/other-api"
  @client_id "oauth-fixture"
  @redirect_uri "http://127.0.0.1:39127/callback"

  defmodule Keystore do
    @moduledoc false
    @behaviour Attesto.Keystore
    def signing_pem, do: Application.fetch_env!(:oauth_host, :signing_pem)
    def verification_pems, do: [signing_pem()]
  end

  defmodule NoRepo do
    @moduledoc false
  end

  def issuer, do: @issuer
  def resource, do: @resource
  def other_resource, do: @other_resource
  def client_id, do: @client_id
  def redirect_uri, do: @redirect_uri

  def build(server, owner, options \\ []) do
    dpop? = Keyword.get(options, :dpop, false)
    issuer = Keyword.get(options, :issuer, @issuer)
    resource = Keyword.get(options, :resource, @resource)
    other_resource = Keyword.get(options, :other_resource, @other_resource)
    base_url = Keyword.get(options, :base_url, "https://mcp.oauth-fixture.example")
    client = %{id: @client_id, dpop?: dpop?}
    scopes = ["openid" | AttestoMCP.Scopes.all()]

    config =
      Config.new(
        issuer: issuer,
        audience: resource,
        keystore: Keystore,
        repo: NoRepo,
        principal_kinds: [Attesto.PrincipalKind.new("user", "usr_")],
        code_store: Attesto.CodeStore.ETS,
        token_endpoint_auth_methods_supported: ["none"],
        grant_types_supported: ["authorization_code"],
        scopes_supported: scopes,
        resource_indicators: [allowed_resources: [resource, other_resource]],
        load_client: fn id ->
          if id == @client_id, do: {:ok, client}, else: {:error, :not_found}
        end,
        verify_client_secret: fn _client, _secret -> false end,
        client_id: & &1.id,
        client_public?: fn _ -> true end,
        client_native?: fn _ -> true end,
        client_requires_dpop?: & &1.dpop?,
        client_redirect_uris: fn _ -> ["http://127.0.0.1:0/callback"] end,
        authorize_scope: fn _client, requested ->
          if Enum.all?(requested, &(&1 in scopes)),
            do: {:ok, requested},
            else: {:error, :invalid_scope}
        end,
        load_principal: fn sub -> {:ok, sub} end,
        authenticate_resource_owner: fn _conn, _request, _opts ->
          {:authenticated, %{subject: "fixture", auth_time: System.system_time(:second)}}
        end,
        consent: fn _conn, _request, subject -> {:consented, subject} end,
        build_principal: fn _client, subject, granted ->
          %{kind: "user", sub: "usr_" <> subject, scopes: granted, claims: %{}}
        end,
        issue_refresh_token?: fn _client, _scope -> false end,
        dpop_nonce_required: dpop?,
        nonce_store: Attesto.DPoP.NonceStore.ETS
      )

    protocol = Config.to_attesto_config(config)
    adapter = AttestoPhoenix.DPoP.Adapter

    auth = [
      config: protocol,
      resource: resource,
      base_url: base_url,
      load_principal: fn sub -> {:ok, sub} end,
      replay_check: adapter.replay_check(config)
    ]

    auth =
      if dpop?,
        do:
          auth ++
            [nonce_check: adapter.nonce_check(config), nonce_issue: adapter.nonce_issue(config)],
        else: auth

    plug = AttestoMCP.Server.Plug.init(server: server, path: "/mcp", auth: auth)
    %{config: config, protocol: protocol, mcp: plug, owner: owner}
  end

  # Req's supported in-process Plug transport exercises the actual controllers
  # and MCP authentication boundary without relaxing client DNS/TLS policy.
  # The fixed user and consent callbacks are fixture host policy. Access tokens
  # are obtained exclusively by authorization-code redemption at /oauth/token.
  def call(conn, host) do
    send(host.owner, {:oauth_request, conn.method, conn.request_path})

    if conn.request_path in ["/mcp", "/.well-known/oauth-protected-resource/mcp"] do
      AttestoMCP.Server.Plug.call(conn, host.mcp)
    else
      conn =
        conn
        |> fetch_query_params()
        |> Plug.Parsers.call(
          Plug.Parsers.init(parsers: [:urlencoded, :json], json_decoder: Jason)
        )
        |> put_private(:attesto_phoenix_config, host.config)
        |> put_private(:attesto_protocol_config, host.protocol)

      Config.with_request_config(host.config, fn ->
        case {conn.method, conn.request_path} do
          {"GET", "/.well-known/oauth-authorization-server"} ->
            DiscoveryController.show(conn, conn.params)

          {"GET", "/.well-known/openid-configuration"} ->
            OpenIDConfigurationController.show(conn, conn.params)

          {"GET", "/.well-known/jwks.json"} ->
            JWKSController.show(conn, conn.params)

          {"GET", "/oauth/authorize"} ->
            AuthorizeController.authorize(conn, conn.params)

          {"POST", "/oauth/token"} ->
            TokenController.create(conn, conn.params)

          _ ->
            send_resp(conn, 404, "not found")
        end
      end)
    end
  end
end
