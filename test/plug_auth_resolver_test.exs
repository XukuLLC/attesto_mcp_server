defmodule AttestoMCP.Server.PlugAuthResolverTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AttestoMCP.Server

  @resource "https://mcp.example.com/mcp"
  @version "2026-07-28"

  defmodule Resolver do
    @moduledoc false

    def protected_resource_options(fixture) do
      Agent.get_and_update(fixture, fn state ->
        options = [
          config: state.config,
          replay_check: state.replay_check,
          htu: &__MODULE__.htu/1
        ]

        {options, Map.update!(state, :calls, &(&1 + 1))}
      end)
    end

    def htu(_conn), do: "https://mcp.example.com/mcp"

    def raise_error(fixture) do
      Agent.update(fixture, &Map.update!(&1, :calls, fn calls -> calls + 1 end))
      raise "runtime auth configuration unavailable"
    end

    def invalid_options, do: :not_a_keyword

    def counting_options(fixture) do
      Agent.update(fixture, &Map.update!(&1, :calls, fn calls -> calls + 1 end))
      [issuer: "https://issuer.example"]
    end

    def conflicting_options do
      [base_url: "https://other.example.com", config: :configured]
    end

    def noncanonical_assign_options(key),
      do: [{key, :host_owned}, issuer: "https://issuer.example"]

    def non_header_options,
      do: [issuer: "https://issuer.example", bearer_methods: [:body]]

    def wrong_resource_path,
      do: [issuer: "https://issuer.example", resource_path: "/other"]
  end

  setup do
    {:ok, server} =
      DynamicSupervisor.start_child(
        AttestoMCP.Server.DynamicSupervisor,
        {Server, []}
      )

    on_exit(fn ->
      DynamicSupervisor.terminate_child(AttestoMCP.Server.DynamicSupervisor, server)
    end)

    %{config: AttestoMCP.Test.Factory.config(), server: server}
  end

  test "runtime resolver is re-evaluated while DPoP replay protection remains effective", %{
    config: config,
    server: server
  } do
    assert :ok = Server.register_tool(server, "dpop", %{handler: fn _, _ -> {:ok, "ok"} end})
    replay_check = AttestoMCP.Test.DPoPReplay.callback()
    fixture = start_fixture(%{calls: 0, config: config, replay_check: replay_check})

    plug =
      Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: {Resolver, :protected_resource_options, [fixture]},
        resource: "/mcp",
        base_url: "https://mcp.example.com"
      )

    assert fixture_calls(fixture) == 0

    jwk = JOSE.JWK.generate_key({:ec, :secp256r1})
    {_unused, jkt} = AttestoMCP.Test.Factory.dpop_proof("placeholder", jwk: jwk)

    token =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [AttestoMCP.Scopes.tools_call()],
        dpop_jkt: jkt
      )

    {proof, ^jkt} =
      AttestoMCP.Test.Factory.dpop_proof(token, jwk: jwk, htu: @resource)

    assert dpop_call(plug, token, proof).status == 200
    assert fixture_calls(fixture) == 1

    replay = dpop_call(plug, token, proof)
    assert replay.status == 401
    assert fixture_calls(fixture) == 2
    assert Jason.decode!(replay.resp_body)["error_description"] == "replay"
  end

  test "resolver exceptions and malformed results fail only applicable requests closed", %{
    server: server
  } do
    fixture = start_fixture(%{calls: 0})

    raising =
      Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: {Resolver, :raise_error, [fixture]},
        resource: "/mcp",
        base_url: "https://mcp.example.com"
      )

    unrelated = conn(:get, "/other") |> Server.Plug.call(raising)
    assert unrelated.status == 404
    assert fixture_calls(fixture) == 0

    first_failure = request() |> Server.Plug.call(raising)
    second_failure = request() |> Server.Plug.call(raising)

    assert first_failure.status == 500
    assert first_failure.resp_body == "internal server error"
    assert second_failure.status == 500
    assert fixture_calls(fixture) == 2

    malformed =
      Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: {Resolver, :invalid_options, []},
        resource: "/mcp",
        base_url: "https://mcp.example.com"
      )

    assert (request() |> Server.Plug.call(malformed)).status == 500
  end

  test "resolver auth requires a static top-level pin and preserves conflict checks", %{
    server: server
  } do
    assert_raise ArgumentError, ~r/resolver-backed auth requires a statically pinned/, fn ->
      Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: {Resolver, :invalid_options, []},
        resource: "/mcp"
      )
    end

    conflicting =
      Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: {Resolver, :conflicting_options, []},
        resource: "/mcp",
        base_url: "https://mcp.example.com"
      )

    assert (request() |> Server.Plug.call(conflicting)).status == 500

    for key <- [:claims_key, :context_key, :principal_key, :scopes_key, :sender_key] do
      noncanonical_assign =
        Server.Plug.init(
          server: server,
          path: "/mcp",
          auth: {Resolver, :noncanonical_assign_options, [key]},
          resource: "/mcp",
          base_url: "https://mcp.example.com"
        )

      assert (request() |> Server.Plug.call(noncanonical_assign)).status == 500
    end

    non_header =
      Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: {Resolver, :non_header_options},
        resource: "/mcp",
        base_url: "https://mcp.example.com"
      )

    assert (request() |> Server.Plug.call(non_header)).status == 500

    wrong_resource_path =
      Server.Plug.init(
        server: server,
        path: "/mcp",
        auth: {Resolver, :wrong_resource_path},
        resource: "/mcp",
        base_url: "https://mcp.example.com"
      )

    assert (request() |> Server.Plug.call(wrong_resource_path)).status == 500

    static =
      Server.Plug.init(
        server: server,
        auth: [
          issuer: "https://issuer.example",
          claims_key: :host_claims,
          context_key: :host_context,
          principal_key: :host_principal,
          scopes_key: :host_scopes,
          sender_key: :host_sender
        ],
        resource: "/mcp",
        base_url: "https://mcp.example.com"
      )

    assert static.auth_opts[:claims_key] == :host_claims
    assert static.auth_opts[:context_key] == :host_context
    assert static.auth_opts[:principal_key] == :host_principal
    assert static.auth_opts[:scopes_key] == :host_scopes
    assert static.auth_opts[:sender_key] == :host_sender
  end

  test "resolver accepts only external zero-arity callbacks or MFA and remains deferred", %{
    server: server
  } do
    assert_raise ArgumentError, ~r/zero-arity remote callback\/MFA/, fn ->
      Server.Plug.init(
        server: server,
        auth: fn -> [issuer: "https://issuer.example"] end,
        resource: "/mcp",
        base_url: "https://mcp.example.com"
      )
    end

    local_callback = &local_options/0

    assert_raise ArgumentError, ~r/zero-arity remote callback\/MFA/, fn ->
      Server.Plug.init(
        server: server,
        auth: local_callback,
        resource: "/mcp",
        base_url: "https://mcp.example.com"
      )
    end

    state =
      Server.Plug.init(
        server: server,
        auth: &Resolver.invalid_options/0,
        resource: "/mcp",
        base_url: "https://mcp.example.com"
      )

    assert state.auth_opts == nil
    assert state.auth_boundary == nil
    assert is_tuple(Macro.escape(state))
    assert (request() |> Server.Plug.call(state)).status == 500

    assert_raise ArgumentError, ~r/portable compile-time literals/, fn ->
      Server.Plug.init(
        server: server,
        auth: {Resolver, :invalid_options, [self()]},
        resource: "/mcp",
        base_url: "https://mcp.example.com"
      )
    end

    unsafe_closure = fn -> :not_portable end

    assert_raise ArgumentError, ~r/portable compile-time literals/, fn ->
      Server.Plug.init(
        server: server,
        auth: {Resolver, :invalid_options, [unsafe_closure]},
        resource: "/mcp",
        base_url: "https://mcp.example.com"
      )
    end
  end

  test "server, header-budget, and method checks precede runtime auth resolution", %{
    server: server
  } do
    fixture = start_fixture(%{calls: 0})

    options = [
      path: "/mcp",
      auth: {Resolver, :counting_options, [fixture]},
      resource: "/mcp",
      base_url: "https://mcp.example.com"
    ]

    unavailable = Server.Plug.init([server: :missing_runtime_auth_server] ++ options)
    assert (conn(:get, "/mcp") |> Server.Plug.call(unavailable)).status == 503

    available = Server.Plug.init([server: server] ++ options)
    assert (conn(:put, "/mcp") |> Server.Plug.call(available)).status == 405

    oversized =
      conn(:post, "/mcp", "")
      |> put_req_header("x-oversized", String.duplicate("a", 8_193))
      |> Server.Plug.call(available)

    assert oversized.status == 431
    assert fixture_calls(fixture) == 0

    assert (conn(:get, "/mcp") |> Server.Plug.call(available)).status == 401
    assert fixture_calls(fixture) == 1
  end

  defp start_fixture(state) do
    name = Module.concat(__MODULE__, "Fixture#{System.unique_integer([:positive])}")
    {:ok, _fixture} = Agent.start_link(fn -> state end, name: name)
    name
  end

  defp fixture_calls(fixture), do: Agent.get(fixture, & &1.calls)

  defp local_options, do: [issuer: "https://issuer.example"]

  defp dpop_call(plug, token, proof) do
    request()
    |> put_req_header("authorization", "DPoP " <> token)
    |> put_req_header("dpop", proof)
    |> Server.Plug.call(plug)
  end

  defp request do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{
        "name" => "dpop",
        "arguments" => %{},
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
    |> put_req_header("mcp-method", "tools/call")
    |> put_req_header("mcp-name", "dpop")
  end
end
