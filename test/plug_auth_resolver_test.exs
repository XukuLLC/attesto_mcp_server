defmodule AttestoMCP.Server.PlugAuthResolverTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AttestoMCP.Server

  @resource "https://mcp.example.com/mcp"
  @version "2026-07-28"

  def telemetry_handler(event, measurements, metadata, owner) do
    send(owner, {:telemetry_event, event, measurements, metadata})
  end

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

    def duplicate_assign_options,
      do: [
        claims_key: :shared_auth,
        principal_key: :shared_auth,
        issuer: "https://issuer.example"
      ]

    def cross_owned_assign_options,
      do: [claims_key: :attesto_context, issuer: "https://issuer.example"]

    def non_header_options,
      do: [issuer: "https://issuer.example", bearer_methods: [:body]]

    def wrong_resource_path,
      do: [issuer: "https://issuer.example", resource_path: "/other"]

    def raise_credential(_conn), do: raise("credential callback failed")
    def throw_credential(_conn), do: throw(:credential_callback_failed)
    def exit_credential(_conn), do: exit(:credential_callback_failed)

    def principal_options(fixture) do
      Agent.get_and_update(fixture, fn state ->
        options = [
          config: state.config,
          principal: {__MODULE__, :composite_principal, [fixture]}
        ]

        {options, Map.update!(state, :calls, &(&1 + 1))}
      end)
    end

    def composite_principal(claims, _sender, fixture) do
      Agent.get_and_update(fixture, fn state ->
        state = record_event(state, {:revocation_check, claims["jti"]})

        if state.revoked? do
          {{:error, :revoked}, state}
        else
          state =
            state
            |> record_event(:load_principal)
            |> Map.update!(:loader_calls, &(&1 + 1))

          {state.loader_result, state}
        end
      end)
    end

    def record(fixture, event),
      do: Agent.update(fixture, &record_event(&1, event))

    defp record_event(state, event),
      do: Map.update!(state, :events, &(&1 ++ [event]))
  end

  defmodule BodyReadProbeAdapter do
    @moduledoc false

    def read_req_body({payload, fixture}, opts) do
      Resolver.record(fixture, :body_read)

      {result, body, next_payload} = Plug.Adapters.Test.Conn.read_req_body(payload, opts)
      {result, body, {next_payload, fixture}}
    end

    def send_resp({payload, fixture}, status, headers, body) do
      {:ok, sent_body, next_payload} =
        Plug.Adapters.Test.Conn.send_resp(payload, status, headers, body)

      {:ok, sent_body, {next_payload, fixture}}
    end
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

    for resolver <- [
          &Resolver.duplicate_assign_options/0,
          &Resolver.cross_owned_assign_options/0
        ] do
      invalid_assigns =
        Server.Plug.init(
          server: server,
          path: "/mcp",
          auth: resolver,
          resource: "/mcp",
          base_url: "https://mcp.example.com"
        )

      assert (request() |> Server.Plug.call(invalid_assigns)).status == 500
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

    for auth_options <- [
          [claims_key: :shared_auth, context_key: :shared_auth],
          [claims_key: :attesto_context],
          [principal_key: nil],
          [scopes_key: true],
          [sender_key: false]
        ] do
      assert_raise ArgumentError,
                   ~r/auth assign keys must be distinct non-nil, non-boolean atoms/,
                   fn ->
                     Server.Plug.init(
                       server: server,
                       auth: [issuer: "https://issuer.example"] ++ auth_options,
                       resource: "/mcp",
                       base_url: "https://mcp.example.com"
                     )
                   end
    end
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

  test "runtime revocation and principal rejection happen before request-body reads", %{
    config: config,
    server: server
  } do
    parent = self()

    assert :ok =
             Server.register_tool(server, "principal-context", %{
               handler: fn _, _ ->
                 send(parent, :unexpected_handler)
                 {:ok, "unexpected"}
               end
             })

    token =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [AttestoMCP.Scopes.tools_call()]
      )

    {:ok, claims} = Attesto.Token.verify(config, token)
    jti = claims["jti"]

    cases = [
      {:revoked, true, {:ok, %{id: "principal-1"}}, 0, [{:revocation_check, jti}]},
      {:loader_rejected, false, {:error, :principal_unavailable}, 1,
       [{:revocation_check, jti}, :load_principal]}
    ]

    challenges =
      for {label, revoked?, loader_result, loader_calls, expected_events} <- cases do
        fixture =
          start_fixture(%{
            calls: 0,
            config: config,
            events: [],
            loader_calls: 0,
            loader_result: loader_result,
            revoked?: revoked?
          })

        plug = principal_plug(server, fixture)

        response =
          "principal-context"
          |> raw_request("not-json")
          |> put_req_header("authorization", "Bearer " <> token)
          |> probe_body_reads(fixture)
          |> Server.Plug.call(plug)

        assert response.status == 401, inspect(label)
        assert Jason.decode!(response.resp_body) == %{"error" => "invalid_token"}, inspect(label)
        assert fixture_calls(fixture) == 1, inspect(label)
        assert fixture_value(fixture, :loader_calls) == loader_calls, inspect(label)
        assert fixture_value(fixture, :events) == expected_events, inspect(label)
        refute_receive :unexpected_handler

        assert [challenge] = get_resp_header(response, "www-authenticate")
        assert challenge =~ ~s(error="invalid_token")
        refute challenge =~ "error_description"
        refute challenge =~ "revoked"
        refute challenge =~ "principal_unavailable"
        challenge
      end

    assert length(Enum.uniq(challenges)) == 1
  end

  test "a successfully loaded principal precedes body reading and reaches the handler", %{
    config: config,
    server: server
  } do
    parent = self()
    loaded_principal = %{id: "principal-1", role: :operator}

    fixture =
      start_fixture(%{
        calls: 0,
        config: config,
        events: [],
        loader_calls: 0,
        loader_result: {:ok, loaded_principal},
        revoked?: false
      })

    assert :ok =
             Server.register_tool(server, "principal-context", %{
               handler: fn _, context ->
                 Resolver.record(fixture, :handler)
                 send(parent, {:handler_context, context})
                 {:ok, "accepted"}
               end
             })

    token =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [AttestoMCP.Scopes.tools_call()]
      )

    {:ok, claims} = Attesto.Token.verify(config, token)
    plug = principal_plug(server, fixture)

    response =
      "principal-context"
      |> request()
      |> put_req_header("authorization", "Bearer " <> token)
      |> probe_body_reads(fixture)
      |> Server.Plug.call(plug)

    assert response.status == 200
    assert fixture_calls(fixture) == 1
    assert fixture_value(fixture, :loader_calls) == 1

    assert fixture_value(fixture, :events) == [
             {:revocation_check, claims["jti"]},
             :load_principal,
             :body_read,
             :handler
           ]

    assert_receive {:handler_context, context}
    assert context.principal == loaded_principal
    assert context.attesto_mcp_principal == loaded_principal
    assert context.attesto_context.principal == loaded_principal
  end

  test "nil principal callbacks cannot inherit upstream default or custom principal assigns", %{
    config: config,
    server: server
  } do
    parent = self()

    assert :ok =
             Server.register_tool(server, "principal-fallback", %{
               handler: fn _, context ->
                 send(parent, {:principal_fallback_context, context})
                 {:ok, "accepted"}
               end
             })

    token =
      AttestoMCP.Test.Factory.access_token(config,
        scopes: [AttestoMCP.Scopes.tools_call()]
      )

    {:ok, claims} = Attesto.Token.verify(config, token)

    for {principal_options, custom_key?} <- [
          {[], false},
          {[principal_key: :host_principal], true}
        ] do
      plug =
        Server.Plug.init(
          server: server,
          path: "/mcp",
          auth: [config: config, resource: @resource, principal: nil] ++ principal_options
        )

      response =
        "principal-fallback"
        |> request()
        |> assign(:attesto_mcp_principal, :untrusted)
        |> assign(:host_principal, :untrusted)
        |> put_req_header("authorization", "Bearer " <> token)
        |> Server.Plug.call(plug)

      assert response.status == 200
      refute Map.has_key?(response.assigns, :attesto_mcp_principal)

      if custom_key?,
        do: refute(Map.has_key?(response.assigns, :host_principal)),
        else: assert(response.assigns.host_principal == :untrusted)

      assert_receive {:principal_fallback_context, context}
      assert context.principal == claims["sub"]
      assert context.attesto_mcp_principal == nil
      assert context.attesto_context.principal == nil
    end
  end

  test "authentication failures cannot restore upstream auth assigns", %{
    config: config,
    server: server
  } do
    telemetry_event = [:attesto_mcp_server, :auth, :policy_failure]
    telemetry_handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        telemetry_handler,
        telemetry_event,
        &__MODULE__.telemetry_handler/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(telemetry_handler) end)

    configured_keys = [
      :host_claims,
      :host_context,
      :host_principal,
      :host_scopes,
      :host_sender
    ]

    canonical_keys = [
      :attesto_mcp_claims,
      :attesto_context,
      :attesto_mcp_principal,
      :attesto_mcp_scopes,
      :attesto_mcp_sender
    ]

    for {credential_callback, expected_error} <- [
          {&Resolver.raise_credential/1, :exception},
          {&Resolver.throw_credential/1, :throw},
          {&Resolver.exit_credential/1, :exit}
        ] do
      plug =
        Server.Plug.init(
          server: server,
          path: "/mcp",
          auth: [
            config: config,
            resource: @resource,
            claims_key: :host_claims,
            context_key: :host_context,
            principal_key: :host_principal,
            scopes_key: :host_scopes,
            sender_key: :host_sender,
            credential_from_conn: credential_callback
          ]
        )

      response =
        Enum.reduce(configured_keys ++ canonical_keys, request(), fn key, conn ->
          assign(conn, key, :untrusted)
        end)
        |> assign(:host_marker, :preserved)
        |> Server.Plug.call(plug)

      assert response.status == 401
      assert response.assigns.host_marker == :preserved

      assert Enum.all?(
               configured_keys ++ canonical_keys,
               &(not Map.has_key?(response.assigns, &1))
             )

      assert_receive {:telemetry_event, ^telemetry_event, measurements, metadata}
      assert measurements == %{count: 1}
      assert metadata == %{category: :verifier, error: expected_error}
    end
  end

  defp start_fixture(state) do
    name = Module.concat(__MODULE__, "Fixture#{System.unique_integer([:positive])}")
    {:ok, _fixture} = Agent.start_link(fn -> state end, name: name)
    name
  end

  defp fixture_calls(fixture), do: Agent.get(fixture, & &1.calls)

  defp fixture_value(fixture, key), do: Agent.get(fixture, &Map.fetch!(&1, key))

  defp local_options, do: [issuer: "https://issuer.example"]

  defp dpop_call(plug, token, proof) do
    request()
    |> put_req_header("authorization", "DPoP " <> token)
    |> put_req_header("dpop", proof)
    |> Server.Plug.call(plug)
  end

  defp principal_plug(server, fixture) do
    Server.Plug.init(
      server: server,
      path: "/mcp",
      auth: {Resolver, :principal_options, [fixture]},
      resource: "/mcp",
      base_url: "https://mcp.example.com"
    )
  end

  defp request(name \\ "dpop") do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{
        "name" => name,
        "arguments" => %{},
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @version,
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    raw_request(name, Jason.encode!(payload))
  end

  defp raw_request(name, body) do
    conn(:post, "/mcp", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("mcp-protocol-version", @version)
    |> put_req_header("mcp-method", "tools/call")
    |> put_req_header("mcp-name", name)
  end

  defp probe_body_reads(%Plug.Conn{adapter: {Plug.Adapters.Test.Conn, payload}} = conn, fixture) do
    %{conn | adapter: {BodyReadProbeAdapter, {payload, fixture}}}
  end
end
