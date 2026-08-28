defmodule AttestoMCP.Server.P3AuthAcceptanceTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AttestoMCP.Server

  @resource "https://mcp.example.com/mcp"
  @version "2026-07-28"

  setup do
    {:ok, server} =
      DynamicSupervisor.start_child(AttestoMCP.Server.DynamicSupervisor, {Server, []})

    config = AttestoMCP.Test.Factory.config()

    on_exit(fn ->
      DynamicSupervisor.terminate_child(AttestoMCP.Server.DynamicSupervisor, server)
    end)

    %{server: server, config: config}
  end

  @tag :t16
  @tag :t17
  test "missing authorization is challenged before the handler and valid auth is fresh per request",
       %{
         server: server,
         config: config
       } do
    parent = self()

    assert :ok =
             Server.register_tool(server, "auth_context", %{
               handler: fn _arguments, context ->
                 send(parent, {:auth_context, context})
                 {:ok, "accepted"}
               end
             })

    plug = plug(server, config)

    denied = http_call(plug, nil, "tools/call", %{"name" => "auth_context", "arguments" => %{}})
    assert denied.status == 401
    assert [challenge] = get_resp_header(denied, "www-authenticate")

    assert challenge =~
             ~s(Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp")

    refute_receive {:auth_context, _}

    token = AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_call()])

    first = http_call(plug, token, "tools/call", %{"name" => "auth_context", "arguments" => %{}})
    second = http_call(plug, token, "tools/call", %{"name" => "auth_context", "arguments" => %{}})
    assert first.status == 200
    assert second.status == 200

    assert_receive {:auth_context, first_context}
    assert_receive {:auth_context, second_context}
    assert first_context.attesto_mcp_claims["iss"] == "https://auth.example.com"
    assert first_context.attesto_mcp_claims["aud"] == @resource
    assert first_context.attesto_mcp_scopes == [AttestoMCP.Scopes.tools_call()]
    assert first_context.attesto_mcp_sender == %{binding: :bearer}
    assert first_context.attesto_mcp_principal == "usr_123"
    assert first_context.attesto_context.principal == "usr_123"
    assert first_context.principal == second_context.principal
  end

  @tag :t18
  @tag :t19
  test "expired, wrong issuer, wrong audience, query, and body credentials fail closed", %{
    server: server,
    config: config
  } do
    parent = self()

    assert :ok =
             Server.register_tool(server, "auth_context", %{
               handler: fn _arguments, _context ->
                 send(parent, :unexpected_handler)
                 {:ok, "accepted"}
               end
             })

    plug = plug(server, config)
    valid = AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_call()])

    query =
      conn(:post, "/mcp?access_token=" <> valid, Jason.encode!(body("tools/call", 1)))
      |> request_headers()
      |> AttestoMCP.Server.Plug.call(plug)

    assert query.status == 401

    body_token =
      conn(:post, "/mcp", Jason.encode!(Map.put(body("tools/call", 2), "access_token", valid)))
      |> request_headers()
      |> AttestoMCP.Server.Plug.call(plug)

    assert body_token.status == 401

    wrong_audience =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [AttestoMCP.Scopes.tools_call()],
        audience: "https://other.example/mcp"
      )

    assert http_call(plug, wrong_audience, "tools/call", %{
             "name" => "auth_context",
             "arguments" => %{}
           }).status == 401

    wrong_issuer_config = %{config | issuer: "https://wrong.example.com"}

    wrong_issuer_token =
      AttestoMCP.Test.Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_call()])

    wrong_issuer_plug = plug(server, wrong_issuer_config)

    assert http_call(wrong_issuer_plug, wrong_issuer_token, "tools/call", %{
             "name" => "auth_context",
             "arguments" => %{}
           }).status == 401

    principal = %{
      claims: %{"client_id" => "client-1"},
      kind: "user",
      scopes: [AttestoMCP.Scopes.tools_call()],
      sub: "usr_123"
    }

    {:ok, %{access_token: expired}} =
      Attesto.Token.mint(config, principal,
        lifetime: 1,
        now: DateTime.add(DateTime.utc_now(), -10, :second)
      )

    assert http_call(plug, expired, "tools/call", %{"name" => "auth_context", "arguments" => %{}}).status ==
             401

    [header, claims, signature] = String.split(valid, ".")

    forged_signature =
      if(String.first(signature) == "A", do: "B", else: "A") <> String.slice(signature, 1..-1//1)

    forged = Enum.join([header, claims, forged_signature], ".")

    assert http_call(plug, forged, "tools/call", %{"name" => "auth_context", "arguments" => %{}}).status ==
             401

    {:ok, refresh} =
      Attesto.Token.mint(
        config,
        %{
          claims: %{"client_id" => "client-1"},
          kind: "user",
          scopes: [AttestoMCP.Scopes.tools_call()],
          sub: "usr_123"
        },
        typ: "refresh"
      )

    assert http_call(plug, refresh.access_token, "tools/call", %{
             "name" => "auth_context",
             "arguments" => %{}
           }).status == 401

    refute_receive :unexpected_handler
  end

  @tag :t20
  test "DPoP validates method, URI, ath, replay, and key binding", %{
    server: server,
    config: config
  } do
    assert :ok = Server.register_tool(server, "dpop", %{handler: fn _, _ -> {:ok, "ok"} end})
    replay_check = AttestoMCP.Test.DPoPReplay.callback()
    plug = plug(server, config, replay_check: replay_check, htu: fn _conn -> @resource end)
    jwk = floor_compatible_dpop_jwk()
    {_unused, jkt} = AttestoMCP.Test.Factory.dpop_proof("placeholder", jwk: jwk)

    token =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [AttestoMCP.Scopes.tools_call()],
        dpop_jkt: jkt
      )

    bearer_bound =
      http_call(plug, token, "tools/call", %{
        "name" => "dpop",
        "arguments" => %{}
      })

    assert bearer_bound.status == 401
    assert [bearer_challenge] = get_resp_header(bearer_bound, "www-authenticate")
    assert String.starts_with?(bearer_challenge, ~s(DPoP error="invalid_token"))

    assert bearer_challenge =~
             ~s(resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp")

    assert Jason.decode!(bearer_bound.resp_body)["error_description"] == "dpop_proof_required"

    fallback_plug =
      plug(server, config,
        replay_check: replay_check,
        htu: fn _ -> @resource end,
        credential_from_conn: fn _ -> {:ok, :dpop, token} end
      )

    fallback_bound =
      http_call(fallback_plug, nil, "tools/call", %{
        "name" => "dpop",
        "arguments" => %{}
      })

    assert fallback_bound.status == 401
    assert [fallback_challenge] = get_resp_header(fallback_bound, "www-authenticate")
    assert String.starts_with?(fallback_challenge, ~s(DPoP error="invalid_dpop_proof"))
    assert Jason.decode!(fallback_bound.resp_body)["error_description"] == "missing_proof"

    {valid_proof, ^jkt} = AttestoMCP.Test.Factory.dpop_proof(token, jwk: jwk, htu: @resource)

    valid =
      http_call(plug, {:dpop, token, valid_proof}, "tools/call", %{
        "name" => "dpop",
        "arguments" => %{}
      })

    assert valid.status == 200

    insufficient_token =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [],
        dpop_jkt: jkt
      )

    {insufficient_proof, ^jkt} =
      AttestoMCP.Test.Factory.dpop_proof(insufficient_token, jwk: jwk, htu: @resource)

    insufficient =
      http_call(plug, {:dpop, insufficient_token, insufficient_proof}, "tools/call", %{
        "name" => "dpop",
        "arguments" => %{}
      })

    assert insufficient.status == 403
    assert [insufficient_challenge] = get_resp_header(insufficient, "www-authenticate")
    assert String.starts_with?(insufficient_challenge, ~s(DPoP error="insufficient_scope"))
    assert insufficient_challenge =~ ~s(scope="mcp:tools:call")

    assert insufficient_challenge =~
             ~s(resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp")

    replay =
      http_call(plug, {:dpop, token, valid_proof}, "tools/call", %{
        "name" => "dpop",
        "arguments" => %{}
      })

    assert replay.status == 401
    assert [replay_challenge] = get_resp_header(replay, "www-authenticate")
    assert String.starts_with?(replay_challenge, ~s(DPoP error="invalid_dpop_proof"))

    assert replay_challenge =~
             ~s(resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp")

    assert Jason.decode!(replay.resp_body)["error_description"] == "replay"

    for flaw <- [:wrong_htm, :wrong_htu, :missing_ath, :expired] do
      proof = Attesto.Test.DPoP.invalid_proof(jwk, flaw, "POST", @resource, access_token: token)

      failed =
        http_call(plug, {:dpop, token, proof}, "tools/call", %{
          "name" => "dpop",
          "arguments" => %{}
        })

      assert failed.status == 401
    end

    other_key = floor_compatible_dpop_jwk()

    {wrong_key_proof, _other_jkt} =
      AttestoMCP.Test.Factory.dpop_proof(token, jwk: other_key, htu: @resource)

    assert http_call(plug, {:dpop, token, wrong_key_proof}, "tools/call", %{
             "name" => "dpop",
             "arguments" => %{}
           }).status == 401
  end

  @tag :t21
  test "DPoP nonce and mTLS bindings use the approved Attesto callbacks", %{
    server: server,
    config: config
  } do
    assert :ok = Server.register_tool(server, "bound", %{handler: fn _, _ -> {:ok, "ok"} end})

    replay_check = AttestoMCP.Test.DPoPReplay.callback()

    nonce_plug =
      plug(server, config,
        replay_check: replay_check,
        htu: fn _ -> @resource end,
        nonce_check: fn
          nil -> {:error, :use_dpop_nonce}
          _ -> :ok
        end,
        nonce_issue: fn -> "nonce-1" end
      )

    jwk = floor_compatible_dpop_jwk()
    {_unused, jkt} = AttestoMCP.Test.Factory.dpop_proof("placeholder", jwk: jwk)

    token =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [AttestoMCP.Scopes.tools_call()],
        dpop_jkt: jkt
      )

    {proof, ^jkt} = AttestoMCP.Test.Factory.dpop_proof(token, jwk: jwk, htu: @resource)

    nonce_response =
      http_call(nonce_plug, {:dpop, token, proof}, "tools/call", %{
        "name" => "bound",
        "arguments" => %{}
      })

    assert nonce_response.status == 401
    assert get_resp_header(nonce_response, "dpop-nonce") == ["nonce-1"]
    assert [nonce_challenge] = get_resp_header(nonce_response, "www-authenticate")
    assert String.starts_with?(nonce_challenge, ~s(DPoP error="use_dpop_nonce"))

    cert = AttestoMCP.Test.Factory.self_signed_cert_der()
    {:ok, thumbprint} = Attesto.MTLS.compute_thumbprint(cert)
    mtls_plug = plug(server, config, cert_der: fn _ -> cert end)

    mtls_token =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [AttestoMCP.Scopes.tools_call()],
        mtls_cert_thumbprint: thumbprint
      )

    assert http_call(mtls_plug, mtls_token, "tools/call", %{"name" => "bound", "arguments" => %{}}).status ==
             200

    mismatch_plug =
      plug(server, config, cert_der: fn _ -> AttestoMCP.Test.Factory.self_signed_cert_der() end)

    assert http_call(mismatch_plug, mtls_token, "tools/call", %{
             "name" => "bound",
             "arguments" => %{}
           }).status == 401

    failed_callback_plug =
      plug(server, config, cert_der: fn _ -> raise "certificate callback failure" end)

    assert http_call(failed_callback_plug, mtls_token, "tools/call", %{
             "name" => "bound",
             "arguments" => %{}
           }).status == 401
  end

  # The approved Attesto test factory delegates key generation to an optional
  # test-only helper that is not present on the declared OTP/Elixir floor.
  # Generate the same P-256 DPoP key through the public JOSE API instead; the
  # proof, replay, nonce, and binding assertions remain unchanged.
  defp floor_compatible_dpop_jwk do
    JOSE.JWK.generate_key({:ec, :secp256r1})
  end

  defp plug(server, config, extra_auth \\ []) do
    Server.Plug.init(
      server: server,
      path: "/mcp",
      auth: Keyword.merge([config: config, resource: @resource], extra_auth)
    )
  end

  defp http_call(plug, token, method, params) do
    payload = body(method, 1, params)
    name = get_in(payload, ["params", "name"]) || "auth_context"
    conn = conn(:post, "/mcp", Jason.encode!(payload)) |> request_headers(name)

    conn =
      case token do
        {:dpop, access_token, proof} ->
          conn
          |> put_req_header("authorization", "DPoP " <> access_token)
          |> put_req_header("dpop", proof)

        token when is_binary(token) ->
          put_req_header(conn, "authorization", "Bearer " <> token)

        nil ->
          conn
      end

    Server.Plug.call(conn, plug)
  end

  defp request_headers(conn, name \\ "auth_context") do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("mcp-protocol-version", @version)
    |> put_req_header("mcp-method", "tools/call")
    |> put_req_header("mcp-name", name)
  end

  defp body(method, id, params \\ %{}) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" =>
        Map.merge(
          %{
            "_meta" => %{
              "io.modelcontextprotocol/protocolVersion" => @version,
              "io.modelcontextprotocol/clientCapabilities" => %{}
            }
          },
          params
        )
    }
  end
end
