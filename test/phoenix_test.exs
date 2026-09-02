defmodule AttestoMCP.Server.PhoenixTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server.Phoenix

  def policy_failure_handler(event, measurements, metadata, owner) do
    send(owner, {:policy_failure, event, measurements, metadata})
  end

  test "rejects a non-atom OTP application" do
    assert_raise ArgumentError, "otp_app must be an atom", fn ->
      Phoenix.attesto_config("sample")
    end
  end

  test "fails closed when the optional integration is unavailable" do
    refute Code.ensure_loaded?(Module.concat([AttestoPhoenix, Config]))

    assert_raise ArgumentError,
                 ~r/required for automatic authorization-server config reuse/,
                 fn ->
                   Phoenix.attesto_config(:sample)
                 end
  end

  test "converts validated optional host configuration through its public API" do
    config_module = Module.concat([AttestoPhoenix, Config])

    on_exit(fn ->
      :code.purge(config_module)
      :code.delete(config_module)
    end)

    Module.create(
      config_module,
      quote do
        def from_otp_app(app), do: {:validated, app}
        def to_attesto_config({:validated, app}), do: {:attesto, app}
      end,
      Macro.Env.location(__ENV__)
    )

    assert Phoenix.attesto_config(:sample) == {:attesto, :sample}
  end

  test "derives runtime protected-resource callbacks and host principals through public APIs" do
    config_module = Module.concat([AttestoPhoenix, Config])
    adapter_module = Module.concat([AttestoPhoenix, DPoP, Adapter])
    protected_resource_module = Module.concat([AttestoPhoenix, ProtectedResource])
    callback_module = Module.concat([AttestoPhoenix, Callback])
    telemetry_event = [:attesto_mcp_server, :auth, :policy_failure]
    telemetry_handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        telemetry_handler,
        telemetry_event,
        &__MODULE__.policy_failure_handler/4,
        self()
      )

    on_exit(fn ->
      :telemetry.detach(telemetry_handler)

      for module <- [callback_module, protected_resource_module, adapter_module, config_module] do
        :code.purge(module)
        :code.delete(module)
      end
    end)

    Module.create(
      config_module,
      quote do
        def from_otp_app(app), do: {:validated, app, self()}
        def to_attesto_config({:validated, app, _owner}), do: {:attesto, app}

        def load_principal_fun({:validated, _app, owner}),
          do: {__MODULE__, :load_principal, [owner]}

        def load_principal(subject, owner) do
          send(owner, {:load_principal, subject})

          case subject do
            "malformed" -> :malformed
            "nil-principal" -> {:ok, nil}
            "raise-loader" -> raise "loader failed"
            "throw-loader" -> throw(:loader_failed)
            "exit-loader" -> exit(:loader_failed)
            _ -> {:ok, %{subject: subject}}
          end
        end
      end,
      Macro.Env.location(__ENV__)
    )

    Module.create(
      adapter_module,
      quote do
        def protected_resource_opts({:validated, app, _owner}) do
          [
            replay_check: &__MODULE__.replay_check/2,
            nonce_check: &__MODULE__.nonce_check/1,
            nonce_issue: &__MODULE__.nonce_issue/0,
            cert_der: &__MODULE__.cert_der/1,
            htu: &__MODULE__.htu/1,
            host_app: app,
            config: :must_not_override_core_config
          ]
        end

        def replay_check(key, ttl), do: {key, ttl}
        def nonce_check(_nonce), do: :ok
        def nonce_issue, do: "nonce"
        def cert_der(_conn), do: nil
        def htu(_conn), do: "https://mcp.example.com/mcp"
      end,
      Macro.Env.location(__ENV__)
    )

    Module.create(
      protected_resource_module,
      quote do
        def access_token_revoked?({:validated, _app, owner}, claims) do
          send(owner, {:revocation_checked, claims["jti"]})

          case claims["jti"] do
            "revoked" -> true
            "indeterminate" -> nil
            "raise-revocation" -> raise "revocation check failed"
            "throw-revocation" -> throw(:revocation_check_failed)
            "exit-revocation" -> exit(:revocation_check_failed)
            _ -> false
          end
        end
      end,
      Macro.Env.location(__ENV__)
    )

    Module.create(
      callback_module,
      quote do
        def invoke({module, function, extra}, args), do: apply(module, function, args ++ extra)
      end,
      Macro.Env.location(__ENV__)
    )

    options = Phoenix.protected_resource_options(:sample)

    assert options[:config] == {:attesto, :sample}
    assert options[:host_app] == :sample
    assert options[:replay_check].("key", 60) == {"key", 60}
    assert options[:nonce_check].(nil) == :ok
    assert options[:nonce_issue].() == "nonce"
    assert options[:cert_der].(%{}) == nil
    assert options[:htu].(%{}) == "https://mcp.example.com/mcp"

    assert options[:principal].(
             %{"jti" => "active", "sub" => "principal-123"},
             %{binding: :bearer}
           ) == {:ok, %{subject: "principal-123"}}

    assert_receive {:revocation_checked, "active"}
    assert_receive {:load_principal, "principal-123"}

    owner = self()

    wrapped_options =
      Phoenix.protected_resource_options(:sample,
        principal: fn loaded_principal, claims, sender ->
          send(owner, {:principal_wrapped, loaded_principal, claims["sub"], sender})
          {:ok, Map.put(loaded_principal, :sender_binding, sender.binding)}
        end
      )

    assert wrapped_options[:principal].(
             %{"jti" => "active", "sub" => "wrapped-principal"},
             %{binding: :bearer}
           ) ==
             {:ok, %{subject: "wrapped-principal", sender_binding: :bearer}}

    assert_receive {:revocation_checked, "active"}
    assert_receive {:load_principal, "wrapped-principal"}

    assert_receive {:principal_wrapped, %{subject: "wrapped-principal"}, "wrapped-principal",
                    %{binding: :bearer}}

    assert wrapped_options[:principal].(
             %{"jti" => "revoked", "sub" => "wrapped-revoked"},
             %{binding: :bearer}
           ) == {:error, :revoked}

    assert_receive {:revocation_checked, "revoked"}
    refute_receive {:load_principal, "wrapped-revoked"}
    refute_receive {:principal_wrapped, _, "wrapped-revoked", _}

    invalid_wrapper =
      Phoenix.protected_resource_options(:sample, principal: fn _, _, _ -> :invalid end)

    assert invalid_wrapper[:principal].(
             %{"jti" => "active", "sub" => "invalid-wrapper"},
             %{binding: :bearer}
           ) == {:error, :principal_wrapper_failed}

    assert_receive {:revocation_checked, "active"}
    assert_receive {:load_principal, "invalid-wrapper"}

    rejecting_wrapper =
      Phoenix.protected_resource_options(:sample,
        principal: fn _, _, _ -> {:error, :host_rejected} end
      )

    assert rejecting_wrapper[:principal].(
             %{"jti" => "active", "sub" => "rejected-wrapper"},
             %{binding: :bearer}
           ) == {:error, :host_rejected}

    assert_receive {:revocation_checked, "active"}
    assert_receive {:load_principal, "rejected-wrapper"}

    raising_wrapper =
      Phoenix.protected_resource_options(:sample,
        principal: fn _, _, _ -> raise "wrapper failed" end
      )

    assert raising_wrapper[:principal].(
             %{"jti" => "active", "sub" => "raising-wrapper"},
             %{binding: :bearer}
           ) == {:error, :authorization_check_failed}

    assert_receive {:revocation_checked, "active"}
    assert_receive {:load_principal, "raising-wrapper"}
    assert_policy_failure(telemetry_event, :exception)

    assert options[:principal].(
             %{"jti" => "revoked", "sub" => "principal-revoked"},
             %{binding: :bearer}
           ) == {:error, :revoked}

    assert_receive {:revocation_checked, "revoked"}
    refute_receive {:load_principal, "principal-revoked"}

    assert options[:principal].(
             %{"jti" => "indeterminate", "sub" => "principal-indeterminate"},
             %{binding: :bearer}
           ) == {:error, :authorization_check_failed}

    assert_receive {:revocation_checked, "indeterminate"}
    refute_receive {:load_principal, "principal-indeterminate"}

    assert_policy_failure(telemetry_event, :invalid_revocation_result)

    assert options[:principal].(
             %{"jti" => "active", "sub" => "malformed"},
             %{binding: :bearer}
           ) == {:error, :principal_load_failed}

    assert_receive {:revocation_checked, "active"}
    assert_receive {:load_principal, "malformed"}

    assert options[:principal].(
             %{"jti" => "active", "sub" => "nil-principal"},
             %{binding: :bearer}
           ) == {:error, :principal_load_failed}

    assert_receive {:revocation_checked, "active"}
    assert_receive {:load_principal, "nil-principal"}

    for missing_subject <- [%{"jti" => "active"}, %{"jti" => "active", "sub" => ""}] do
      assert options[:principal].(missing_subject, %{binding: :bearer}) ==
               {:error, :principal_load_failed}

      assert_receive {:revocation_checked, "active"}
      refute_receive {:load_principal, _subject}
    end

    for jti <- ["raise-revocation", "throw-revocation", "exit-revocation"] do
      assert options[:principal].(
               %{"jti" => jti, "sub" => "principal-unavailable"},
               %{binding: :bearer}
             ) == {:error, :authorization_check_failed}

      assert_receive {:revocation_checked, ^jti}
      refute_receive {:load_principal, "principal-unavailable"}

      expected_error =
        case jti do
          "raise-revocation" -> :exception
          "throw-revocation" -> :throw
          "exit-revocation" -> :exit
        end

      assert_policy_failure(telemetry_event, expected_error)
    end

    for subject <- ["raise-loader", "throw-loader", "exit-loader"] do
      assert options[:principal].(
               %{"jti" => "active", "sub" => subject},
               %{binding: :bearer}
             ) == {:error, :authorization_check_failed}

      assert_receive {:revocation_checked, "active"}
      assert_receive {:load_principal, ^subject}

      expected_error =
        case subject do
          "raise-loader" -> :exception
          "throw-loader" -> :throw
          "exit-loader" -> :exit
        end

      assert_policy_failure(telemetry_event, expected_error)
    end
  end

  test "fails closed when the protected-resource integration contract is unavailable" do
    config_module = Module.concat([AttestoPhoenix, Config])

    on_exit(fn ->
      :code.purge(config_module)
      :code.delete(config_module)
    end)

    Module.create(
      config_module,
      quote do
        def from_otp_app(app), do: {:validated, app}
        def to_attesto_config({:validated, app}), do: {:attesto, app}
      end,
      Macro.Env.location(__ENV__)
    )

    assert_raise ArgumentError, ~r/DPoP.Adapter.protected_resource_opts\/1/, fn ->
      Phoenix.protected_resource_options(:sample)
    end
  end

  test "rejects a non-atom protected-resource OTP application" do
    assert_raise ArgumentError, "otp_app must be an atom", fn ->
      Phoenix.protected_resource_options("sample")
    end
  end

  test "validates protected-resource principal composition options before integration" do
    assert_raise ArgumentError, ~r/protected-resource options must be a keyword list/, fn ->
      Phoenix.protected_resource_options(:sample, :invalid)
    end

    assert_raise ArgumentError, ~r/unknown protected-resource option/, fn ->
      Phoenix.protected_resource_options(:sample, unknown: true)
    end

    assert_raise ArgumentError, ~r/must not contain duplicate keys/, fn ->
      Phoenix.protected_resource_options(:sample,
        principal: fn _, _, _ -> {:ok, :first} end,
        principal: fn _, _, _ -> {:ok, :second} end
      )
    end

    assert_raise ArgumentError, ~r/:principal must be a supported three-argument callback/, fn ->
      Phoenix.protected_resource_options(:sample, principal: fn _ -> {:ok, :invalid} end)
    end
  end

  defp assert_policy_failure(event, expected_error) do
    assert_receive {:policy_failure, ^event, measurements, metadata}
    assert measurements == %{count: 1}
    assert metadata == %{category: :principal_policy, error: expected_error}
  end
end
