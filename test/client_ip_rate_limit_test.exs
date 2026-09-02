defmodule AttestoMCP.Server.ClientIPRateLimitTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AttestoMCP.Server

  @resource "https://mcp.example.com/mcp"
  @modern "2026-07-28"

  defmodule Callbacks do
    @moduledoc false

    def client_ip(conn), do: conn.private[:test_client_ip]
    def direct_client_ip(conn), do: conn.private[:test_client_ip]
    def prefixed_client_ip(_prefix, conn), do: conn.private[:test_client_ip]
    def throw_client_ip(_conn), do: throw(:private_client_ip_detail)
    def exit_client_ip(_conn), do: exit(:private_client_ip_detail)
  end

  def client_ip_failure_handler(event, measurements, metadata, owner) do
    send(owner, {:client_ip_failure, event, measurements, metadata})
  end

  setup do
    {:ok, config: AttestoMCP.Test.Factory.config()}
  end

  test "client_ip accepts IPv4 and IPv6 tuples and isolates authenticated buckets", %{
    config: config
  } do
    {:ok, server} = start_server()
    plug = init_plug(server, config, client_ip: &Callbacks.client_ip/1)
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())

    assert authenticated_request(plug, token, {127, 0, 0, 1}).status == 200
    assert authenticated_request(plug, token, {127, 0, 0, 1}).status == 429
    assert authenticated_request(plug, token, {127, 0, 0, 2}).status == 200

    assert authenticated_request(plug, token, {0, 0, 0, 0, 0, 0, 0, 1}).status == 200
    assert authenticated_request(plug, token, {0, 0, 0, 0, 0, 0, 0, 1}).status == 429
    assert authenticated_request(plug, token, {0, 0, 0, 0, 0, 0, 0, 2}).status == 200

    stop_server(server)
  end

  test "client_ip MFA is used for authenticated buckets", %{config: config} do
    {:ok, server} = start_server()
    plug = init_plug(server, config, client_ip: {Callbacks, :prefixed_client_ip, [:trusted]})
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())

    assert authenticated_request(plug, token, {198, 51, 100, 10}).status == 200
    assert authenticated_request(plug, token, {198, 51, 100, 10}).status == 429

    stop_server(server)
  end

  test "client_ip accepts a two-element MFA for authenticated buckets", %{config: config} do
    {:ok, server} = start_server()
    plug = init_plug(server, config, client_ip: {Callbacks, :direct_client_ip})
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())

    assert authenticated_request(plug, token, {198, 51, 100, 10}).status == 200
    assert authenticated_request(plug, token, {198, 51, 100, 10}).status == 429

    stop_server(server)
  end

  test "omitting client_ip retains conn.remote_ip for authenticated buckets", %{
    config: config
  } do
    {:ok, server} = start_server()
    plug = init_plug(server, config)
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())

    assert authenticated_request(plug, token, {203, 0, 113, 10}).status == 200
    assert authenticated_request(plug, token, {203, 0, 113, 10}).status == 429
    assert authenticated_request(plug, token, {203, 0, 113, 11}).status == 200

    stop_server(server)
  end

  test "client_ip isolates failed-authentication buckets for IPv4 and IPv6", %{
    config: config
  } do
    {:ok, server} = start_server()
    plug = init_plug(server, config, client_ip: &Callbacks.client_ip/1)

    assert failed_request(plug, {192, 0, 2, 10}).status == 401
    assert failed_request(plug, {192, 0, 2, 10}).status == 429
    assert failed_request(plug, {192, 0, 2, 11}).status == 401

    ipv6 = {0, 0, 0, 0, 0, 0, 0, 10}
    other_ipv6 = {0, 0, 0, 0, 0, 0, 0, 11}
    assert failed_request(plug, ipv6).status == 401
    assert failed_request(plug, ipv6).status == 429
    assert failed_request(plug, other_ipv6).status == 401

    stop_server(server)
  end

  test "omitting client_ip preserves non-IP remote peers in both buckets", %{config: config} do
    {:ok, server} = start_server()
    plug = init_plug(server, config)
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())
    peer = {:local, "/tmp/mcp.sock"}
    other_peer = {:undefined, :peer}

    assert authenticated_request(plug, token, peer).status == 200
    assert authenticated_request(plug, token, peer).status == 429
    assert authenticated_request(plug, token, other_peer).status == 200

    assert failed_request(plug, peer).status == 401
    assert failed_request(plug, peer).status == 429
    assert failed_request(plug, other_peer).status == 401

    stop_server(server)
  end

  test "client_ip rejects invalid configuration at Plug init", %{config: config} do
    {:ok, server} = start_server()

    assert_raise ArgumentError, ~r/:client_ip must be a supported one-argument callback/, fn ->
      init_plug(server, config, client_ip: fn _conn, _extra -> {127, 0, 0, 1} end)
    end

    assert_raise ArgumentError, ~r/:client_ip must be a supported one-argument callback/, fn ->
      init_plug(server, config, client_ip: {__MODULE__, :missing_client_ip})
    end

    assert_raise ArgumentError, ~r/:client_ip must be configured at most once/, fn ->
      init_plug(server, config,
        client_ip: &Callbacks.client_ip/1,
        client_ip: &Callbacks.direct_client_ip/1
      )
    end

    stop_server(server)
  end

  test "invalid client_ip returns fail closed without exposing a callback value", %{
    config: config
  } do
    {:ok, server} = start_server()
    plug = init_plug(server, config, client_ip: fn _conn -> "private-invalid-address" end)
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())
    event = [:attesto_mcp_server, :client_ip, :exception]
    handler_id = {__MODULE__, :invalid_client_ip, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        &__MODULE__.client_ip_failure_handler/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    response = authenticated_request(plug, token, {127, 0, 0, 1})
    assert response.status == 429
    refute response.resp_body =~ "private-invalid-address"

    assert_receive {:client_ip_failure, ^event, %{count: 1},
                    %{outcome: :invalid_return} = metadata}

    assert metadata.transport == :http
    refute Map.has_key?(metadata, :reason)
    refute Map.has_key?(metadata, :error)

    assert get_in(Jason.decode!(response.resp_body), ["error", "data", "reason"]) ==
             "rate_limited"

    stop_server(server)
  end

  test "client_ip callback exceptions fail closed on authenticated and failed auth paths", %{
    config: config
  } do
    {:ok, server} = start_server()
    plug = init_plug(server, config, client_ip: fn _conn -> raise "private-client-ip-detail" end)
    token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())

    authenticated = authenticated_request(plug, token, {127, 0, 0, 1})
    failed = failed_request(plug, {127, 0, 0, 1})

    assert authenticated.status == 429
    assert failed.status == 429
    refute authenticated.resp_body =~ "private-client-ip-detail"
    refute failed.resp_body =~ "private-client-ip-detail"

    assert get_in(Jason.decode!(authenticated.resp_body), ["error", "data", "reason"]) ==
             "rate_limited"

    assert Jason.decode!(failed.resp_body) == %{"error" => "rate_limited"}

    stop_server(server)
  end

  test "client_ip callback throws and exits emit neutral telemetry", %{config: config} do
    event = [:attesto_mcp_server, :client_ip, :exception]
    handler_id = {__MODULE__, :client_ip_failure, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        &__MODULE__.client_ip_failure_handler/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    for callback <- [&Callbacks.throw_client_ip/1, &Callbacks.exit_client_ip/1] do
      {:ok, server} = start_server()
      plug = init_plug(server, config, client_ip: callback)
      token = AttestoMCP.Test.Factory.access_token(config, scopes: AttestoMCP.Scopes.all())

      assert authenticated_request(plug, token, {127, 0, 0, 1}).status == 429
      assert_receive {:client_ip_failure, ^event, %{count: 1}, %{outcome: :exception} = metadata}
      assert metadata.transport == :http
      refute Map.has_key?(metadata, :reason)
      refute Map.has_key?(metadata, :error)

      assert failed_request(plug, {127, 0, 0, 1}).status == 429
      assert_receive {:client_ip_failure, ^event, %{count: 1}, %{outcome: :exception} = metadata}
      assert metadata.transport == :http
      refute Map.has_key?(metadata, :reason)
      refute Map.has_key?(metadata, :error)

      stop_server(server)
    end
  end

  test "invalid client_ip returns fail closed on failed auth", %{config: config} do
    {:ok, server} = start_server()
    plug = init_plug(server, config, client_ip: fn _conn -> {:ok, {127, 0, 0, 1}} end)

    response = failed_request(plug, {127, 0, 0, 1})
    assert response.status == 429
    refute response.resp_body =~ "127"
    assert Jason.decode!(response.resp_body) == %{"error" => "rate_limited"}

    stop_server(server)
  end

  defp start_server do
    Server.start_link(
      rate_limits: %{
        calls: %{burst: 1, window_ms: 60_000},
        auth_failures: %{burst: 1, window_ms: 60_000}
      }
    )
  end

  defp stop_server(server) do
    if Process.alive?(server), do: GenServer.stop(server)
  end

  defp init_plug(server, config, extra \\ []) do
    Server.Plug.init(
      [
        server: server,
        path: "/mcp",
        auth: [config: config, resource: @resource]
      ] ++ extra
    )
  end

  defp authenticated_request(plug, token, remote_peer) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list",
        "params" => %{
          "_meta" => %{
            "io.modelcontextprotocol/protocolVersion" => @modern,
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }
        }
      })

    conn(:post, "/mcp", body)
    |> then(fn conn -> %{conn | remote_ip: remote_peer} end)
    |> put_private(:test_client_ip, remote_peer)
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("mcp-protocol-version", @modern)
    |> put_req_header("mcp-method", "tools/list")
    |> Server.Plug.call(plug)
  end

  defp failed_request(plug, remote_peer) do
    conn(:post, "/mcp", "not-json")
    |> then(fn conn -> %{conn | remote_ip: remote_peer} end)
    |> put_private(:test_client_ip, remote_peer)
    |> put_req_header("authorization", "Bearer invalid-token")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("mcp-protocol-version", @modern)
    |> put_req_header("mcp-method", "tools/list")
    |> Server.Plug.call(plug)
  end
end
