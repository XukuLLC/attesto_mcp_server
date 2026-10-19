defmodule AttestoMCP.Server.AuthTelemetryTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AttestoMCP.Server
  alias AttestoMCP.Server.AuthOutcome
  alias AttestoMCP.Test.Factory

  @resource "https://mcp.example.com/mcp"
  @version "2026-07-28"
  @events for stage <- [:start, :stop, :exception],
              do: [:attesto_mcp_server, :auth, :authenticate, stage]
  @allowed_metadata MapSet.new([
                      :transport,
                      :outcome,
                      :status,
                      :binding,
                      :duration,
                      :kind,
                      :source,
                      :error
                    ])

  defmodule Callbacks do
    @moduledoc false
    def raise_credential(_conn), do: raise("credential callback failed")
    def nil_binding(_principal), do: nil
  end

  setup do
    handler_id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach_many(handler_id, @events, &__MODULE__.handle_event/4, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, server} =
      DynamicSupervisor.start_child(AttestoMCP.Server.DynamicSupervisor, {Server, []})

    on_exit(fn ->
      DynamicSupervisor.terminate_child(AttestoMCP.Server.DynamicSupervisor, server)
    end)

    {:ok, server: server, config: Factory.config()}
  end

  def handle_event(event, measurements, metadata, owner) do
    send(owner, {:auth_telemetry, event, measurements, metadata})
  end

  defp plug(server, config, extra \\ []) do
    Server.Plug.init(
      server: server,
      path: "/mcp",
      auth: [config: config, resource: @resource] ++ extra
    )
  end

  defp request do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/list",
      "params" => %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @version,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    conn(:post, "/mcp", Jason.encode!(payload))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("mcp-protocol-version", @version)
    |> put_req_header("mcp-method", "tools/list")
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp mint(config, opts) do
    principal = %{
      claims: %{"client_id" => "client-1"},
      kind: "user",
      scopes: AttestoMCP.Scopes.all(),
      sub: "usr_123"
    }

    {:ok, token} = Attesto.Token.mint(config, principal, opts)
    token.access_token
  end

  defp assert_span(expected) do
    assert_receive {:auth_telemetry, [:attesto_mcp_server, :auth, :authenticate, :start], start,
                    start_metadata}

    assert is_integer(start.system_time)
    assert start_metadata.transport == :http

    assert_receive {:auth_telemetry, [:attesto_mcp_server, :auth, :authenticate, :stop], stop,
                    metadata}

    assert is_integer(stop.duration) and stop.duration >= 0
    assert MapSet.subset?(MapSet.new(Map.keys(metadata)), @allowed_metadata)
    refute Map.has_key?(metadata, :token)
    refute Map.has_key?(metadata, :claims)
    refute Map.has_key?(metadata, :principal)
    assert Map.take(metadata, Map.keys(expected)) == expected
    metadata
  end

  test "an authenticated request stops with :ok and its binding", %{
    server: server,
    config: config
  } do
    token = Factory.access_token(config, scopes: AttestoMCP.Scopes.all())
    response = request() |> bearer(token) |> Server.Plug.call(plug(server, config))

    assert response.status == 200
    assert_span(%{outcome: :ok, binding: :bearer, transport: :http})

    refute_received {:auth_telemetry, [:attesto_mcp_server, :auth, :authenticate, :exception], _,
                     _}
  end

  test "a request without credentials is :missing_credentials", %{server: server, config: config} do
    response = request() |> Server.Plug.call(plug(server, config))

    assert response.status == 401
    assert_span(%{outcome: :missing_credentials, status: 401})
  end

  test "an expired token, a token for another audience, and a garbled token are told apart", %{
    server: server,
    config: config
  } do
    plug = plug(server, config)
    now = System.os_time(:second)

    assert (request() |> bearer(mint(config, now: now - 86_400)) |> Server.Plug.call(plug)).status ==
             401

    assert_span(%{outcome: :token_expired, status: 401})

    other =
      Factory.access_token(config,
        scopes: AttestoMCP.Scopes.all(),
        audience: "https://other.example/api"
      )

    assert (request() |> bearer(other) |> Server.Plug.call(plug)).status == 401
    assert_span(%{outcome: :invalid_audience, status: 401})

    assert (request() |> bearer("not.a.jwt") |> Server.Plug.call(plug)).status == 401
    assert_span(%{outcome: :invalid_token, status: 401})
  end

  test "a DPoP-bound token presented as Bearer is :sender_constraint_mismatch", %{
    server: server,
    config: config
  } do
    jkt = Factory.dpop_jkt(Factory.dpop_jwk())
    token = Factory.access_token(config, scopes: AttestoMCP.Scopes.all(), dpop_jkt: jkt)

    assert (request() |> bearer(token) |> Server.Plug.call(plug(server, config))).status == 401
    assert_span(%{outcome: :sender_constraint_mismatch, status: 401})
  end

  test "a raising credential callback is :verifier_failure", %{server: server, config: config} do
    plug = plug(server, config, credential_from_conn: &Callbacks.raise_credential/1)
    response = request() |> Server.Plug.call(plug)

    assert response.status == 401
    assert_span(%{outcome: :verifier_failure, status: 401})
  end

  test "a principal binding callback that returns nothing is :principal_binding_failure", %{
    server: server,
    config: config
  } do
    plug =
      Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource],
        principal_binding: &Callbacks.nil_binding/1
      )

    token = Factory.access_token(config, scopes: AttestoMCP.Scopes.all())
    response = request() |> bearer(token) |> Server.Plug.call(plug)

    assert response.status == 500
    assert_span(%{outcome: :principal_binding_failure})
  end

  test "a missing route scope is reported by the scope refusal, not the span", %{
    server: server,
    config: config
  } do
    token = Factory.access_token(config, scopes: [AttestoMCP.Scopes.tools_call()])
    response = request() |> bearer(token) |> Server.Plug.call(plug(server, config))

    assert response.status == 403
    assert_span(%{outcome: :ok, binding: :bearer})
  end

  describe "AuthOutcome" do
    test "prefers the outcome AttestoMCP recorded on the connection" do
      conn =
        :post
        |> conn("/mcp")
        |> put_private(:attesto_mcp_auth_outcome, :dpop_replay)
        |> assign(:attesto_mcp_oauth_error, %{"error" => "invalid_token"})
        |> put_status(401)

      assert AuthOutcome.refusal(conn) == :dpop_replay
    end

    test "classifies a captured envelope when no outcome was recorded" do
      for {status, body, outcome} <- [
            {401, %{"error" => "invalid_token", "error_description" => "expired"},
             :token_expired},
            {401, %{"error" => "invalid_token", "error_description" => "mtls_cert_required"},
             :sender_constraint_mismatch},
            {401, %{"error" => "use_dpop_nonce"}, :dpop_nonce_required},
            {401, %{"error" => "invalid_dpop_proof", "error_description" => "replay"},
             :dpop_replay},
            {401, %{"error" => "insufficient_user_authentication"}, :step_up_required},
            {403, %{"error" => "insufficient_scope"}, :insufficient_scope},
            {503, %{"error" => "temporarily_unavailable"}, :verifier_unavailable},
            {401, nil, :invalid_token},
            {418, nil, :other}
          ] do
        conn =
          :post |> conn("/mcp") |> put_status(status) |> assign(:attesto_mcp_oauth_error, body)

        assert AuthOutcome.refusal(conn) == outcome, inspect({status, body})
      end
    end

    test "ignores an unrecognized recorded value" do
      conn =
        :post
        |> conn("/mcp")
        |> put_private(:attesto_mcp_auth_outcome, "not an outcome")
        |> put_status(403)

      assert AuthOutcome.refusal(conn) == :insufficient_scope
    end
  end
end
