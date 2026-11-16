defmodule AttestoMCP.Server.PhoenixPrincipalUnavailableTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AttestoMCP.Server.{AuthOutcome, Phoenix}

  setup do
    modules = [
      AttestoPhoenix.Config,
      AttestoPhoenix.DPoP.Adapter,
      AttestoPhoenix.ProtectedResource,
      AttestoPhoenix.Callback
    ]

    on_exit(fn ->
      for module <- modules do
        :code.purge(module)
        :code.delete(module)
      end
    end)

    Module.create(
      AttestoPhoenix.Config,
      quote do
        def from_otp_app(_), do: :config
        def to_attesto_config(_), do: :remote
        def with_request_config(_, fun), do: fun.()
        def load_principal_fun(_), do: Process.get(:test_loader, fn _ -> {:ok, :principal} end)
      end,
      Macro.Env.location(__ENV__)
    )

    Module.create(
      AttestoPhoenix.DPoP.Adapter,
      quote do
        def protected_resource_opts(_), do: []
      end,
      Macro.Env.location(__ENV__)
    )

    Module.create(
      AttestoPhoenix.ProtectedResource,
      quote do
        def access_token_revoked?(_, _), do: Process.get(:test_revocation, fn -> false end).()
      end,
      Macro.Env.location(__ENV__)
    )

    Module.create(
      AttestoPhoenix.Callback,
      quote do
        def invoke(fun, args), do: apply(fun, args)
      end,
      Macro.Env.location(__ENV__)
    )

    id = {__MODULE__, make_ref()}

    :telemetry.attach_many(
      id,
      [
        [:attesto_mcp_server, :auth, :policy_failure],
        [:attesto_mcp_server, :auth, :principal_unavailable],
        [:attesto_mcp, :authenticate, :stop]
      ],
      &__MODULE__.handle_event/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(id) end)
    :ok
  end

  def handle_event(event, measurements, metadata, owner),
    do: send(owner, {:event, event, measurements, metadata})

  for step <- [:revocation, :loader],
      {module, postgres, status} <- [
        {DBConnection.ConnectionError, nil, 503},
        {Postgrex.Error, %{pg_code: "08000"}, 503},
        {Postgrex.Error, %{pg_code: "08006"}, 503},
        {Postgrex.Error, %{pg_code: "08P01"}, 503},
        {Postgrex.Error, %{pg_code: "57P01"}, 503},
        {Postgrex.Error, %{pg_code: "57P02"}, 503},
        {Postgrex.Error, %{pg_code: "57P03"}, 503},
        {Postgrex.Error, %{pg_code: "23505"}, 401},
        {Postgrex.Error, %{pg_code: "57014"}, 401},
        {Postgrex.Error, %{pg_code: :connection_failure}, 401},
        {Postgrex.Error, %{code: :connection_failure}, 401},
        {Postgrex.Error, nil, 401},
        {RuntimeError, nil, 401}
      ] do
    # Built here, not in the test body: there `module` is a literal, and the
    # type checker warns about comparing two distinct module atoms.
    fields = [message: "private-exception-message"]
    fields = if module == Postgrex.Error, do: fields ++ [postgres: postgres], else: fields

    test "#{step} #{inspect(module)} #{inspect(postgres)} answers #{status}" do
      module = unquote(module)
      exception = struct!(module, unquote(Macro.escape(fields)))

      case unquote(step) do
        :revocation -> Process.put(:test_revocation, fn -> raise exception end)
        :loader -> Process.put(:test_loader, fn _ -> raise exception end)
      end

      response = authenticate()
      status = unquote(status)
      assert response.halted
      assert response.status == status
      expected_error = if status == 503, do: "temporarily_unavailable", else: "invalid_token"
      assert JSON.decode!(response.resp_body) == %{"error" => expected_error}
      refute Map.has_key?(response.assigns, :attesto_mcp_principal)
      refute Map.has_key?(response.assigns, :attesto_context)
      assert get_resp_header(response, "retry-after") == []

      event = if status == 503, do: :principal_unavailable, else: :policy_failure
      assert_receive {:event, [:attesto_mcp_server, :auth, ^event], %{count: 1}, metadata}
      assert metadata == %{category: :principal_policy, error: :exception, exception: module}
      refute inspect(metadata) =~ "private-exception-message"
      outcome = if status == 503, do: :principal_unavailable, else: :policy_rejected
      assert AuthOutcome.refusal(response) == outcome
      assert_stop(outcome, status)
      refute_receive {:event, _, _, _}
      if status == 503, do: assert(get_resp_header(response, "www-authenticate") == [])
    end
  end

  test "host outage result is passed through unchanged and answers 503" do
    result = {:error, {:temporarily_unavailable, %{private: "private-reason"}}}
    Process.put(:test_loader, fn _ -> result end)

    assert Phoenix.protected_resource_options(:host)[:principal].(%{"sub" => "subject"}, %{}) ==
             result

    response = authenticate()
    assert response.status == 503
    assert response.halted
    assert JSON.decode!(response.resp_body) == %{"error" => "temporarily_unavailable"}
    assert AuthOutcome.refusal(response) == :principal_unavailable
    assert_stop(:principal_unavailable, 503)
    refute_receive {:event, _, _, _}
  end

  test "a non-boolean revocation result still fails closed" do
    Process.put(:test_revocation, fn -> {:error, {:temporarily_unavailable, "private-reason"}} end)

    response = authenticate()
    assert response.status == 401

    assert_receive {:event, [:attesto_mcp_server, :auth, :policy_failure], %{count: 1},
                    %{category: :principal_policy, error: :invalid_revocation_result}}

    assert_stop(:policy_rejected, 401)
    refute_receive {:event, _, _, _}
  end

  defp assert_stop(outcome, status) do
    assert_receive {:event, [:attesto_mcp, :authenticate, :stop], _, metadata}

    assert Map.delete(metadata, :telemetry_span_context) == %{
             outcome: outcome,
             status: status,
             binding: nil
           }
  end

  defp authenticate do
    options = Phoenix.protected_resource_options(:host)

    opts =
      AttestoMCP.Plug.Authenticate.init(
        config: :remote,
        resource_audience: "https://api.example/resource",
        verify: fn _, _, _ -> {:ok, %{"sub" => "private-subject", "jti" => "private-jti"}} end,
        principal: options[:principal]
      )

    conn(:get, "/resource")
    |> put_req_header("authorization", "Bearer private-token")
    |> AttestoMCP.Plug.Authenticate.call(opts)
  end
end
