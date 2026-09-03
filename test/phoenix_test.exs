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

        def with_request_config(config, fun) do
          fault = Process.get(:attesto_phoenix_test_binding_fault)

          case fault do
            :setup_raise -> raise "request config setup failed"
            :setup_throw -> throw(:request_config_setup_failed)
            :setup_exit -> exit(:request_config_setup_failed)
            _ -> :ok
          end

          previous = Process.get(:attesto_phoenix_test_request_config, :missing)
          Process.put(:attesto_phoenix_test_request_config, config)

          try do
            fun.()
          after
            if previous == :missing do
              Process.delete(:attesto_phoenix_test_request_config)
            else
              Process.put(:attesto_phoenix_test_request_config, previous)
            end

            case fault do
              :restore_raise -> raise "request config restore failed"
              :restore_throw -> throw(:request_config_restore_failed)
              :restore_exit -> exit(:request_config_restore_failed)
              _ -> :ok
            end
          end
        end

        def notify_request_config(kind) do
          if Process.get(:attesto_phoenix_test_probe) do
            case Process.get(:attesto_phoenix_test_request_config) do
              {:validated, app, owner} ->
                send(
                  owner,
                  {:request_config_seen, app, kind,
                   Process.get(:attesto_phoenix_test_request_config)}
                )

              _other ->
                :ok
            end
          end
        end

        def load_principal_fun({:validated, _app, owner}),
          do: {__MODULE__, :load_principal, [owner]}

        def load_principal(subject, owner) do
          send(owner, {:load_principal, subject})

          if subject == "request-local", do: notify_request_config(:principal)

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
        def protected_resource_opts({:validated, :defaults, _owner}) do
          [
            replay_check: &__MODULE__.replay_check/2,
            htu: &__MODULE__.htu/1,
            host_app: :defaults
          ]
        end

        def protected_resource_opts({:validated, :invalid_adapter, _owner}) do
          [replay_check: &__MODULE__.invalid_replay_check/1]
        end

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

        defp notify_request_config(kind) do
          if Process.get(:attesto_phoenix_test_probe) do
            case Process.get(:attesto_phoenix_test_request_config) do
              {:validated, app, owner} ->
                send(
                  owner,
                  {:request_config_seen, app, kind,
                   Process.get(:attesto_phoenix_test_request_config)}
                )

              _other ->
                :ok
            end
          end
        end

        def replay_check(key, ttl) do
          notify_request_config(:replay)

          case key do
            "concurrent-hold" ->
              {:validated, app, owner} =
                Process.get(:attesto_phoenix_test_request_config)

              send(
                owner,
                {:request_config_waiting, app, self(),
                 Process.get(:attesto_phoenix_test_request_config)}
              )

              receive do
                {:release_request_config, ^app} -> {key, ttl}
              after
                1_000 -> raise "timed out waiting to release request config"
              end

            "raise-request" ->
              raise "replay callback failed"

            "throw-request" ->
              throw(:replay_callback_failed)

            "exit-request" ->
              exit(:replay_callback_failed)

            _ ->
              {key, ttl}
          end
        end

        def invalid_replay_check(_key), do: :ok

        def nonce_check(_nonce) do
          notify_request_config(:nonce_check)
          :ok
        end

        def nonce_issue do
          notify_request_config(:nonce_issue)
          "nonce"
        end

        def cert_der(_conn) do
          notify_request_config(:cert_der)
          nil
        end

        def htu(_conn) do
          notify_request_config(:htu)
          "https://mcp.example.com/mcp"
        end
      end,
      Macro.Env.location(__ENV__)
    )

    Module.create(
      protected_resource_module,
      quote do
        def access_token_revoked?({:validated, _app, owner}, claims) do
          send(owner, {:revocation_checked, claims["jti"]})

          if claims["jti"] == "request-local" do
            if Process.get(:attesto_phoenix_test_probe) do
              {:validated, app, _owner} = Process.get(:attesto_phoenix_test_request_config)

              send(
                owner,
                {:request_config_seen, app, :revocation,
                 Process.get(:attesto_phoenix_test_request_config)}
              )
            end
          end

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
      Process.put(:attesto_phoenix_test_request_config, :outer)

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
      assert Process.get(:attesto_phoenix_test_request_config) == :outer
      Process.delete(:attesto_phoenix_test_request_config)
    end

    Process.put(:attesto_phoenix_test_request_config, :outer)

    assert options[:principal].(
             %{"jti" => "active", "sub" => "restored-success"},
             %{binding: :bearer}
           ) == {:ok, %{subject: "restored-success"}}

    assert_receive {:revocation_checked, "active"}
    assert_receive {:load_principal, "restored-success"}
    assert Process.get(:attesto_phoenix_test_request_config) == :outer
    Process.delete(:attesto_phoenix_test_request_config)

    for {fault, expected_error, callbacks_ran} <- [
          {:setup_raise, :exception, false},
          {:setup_throw, :throw, false},
          {:setup_exit, :exit, false},
          {:restore_raise, :exception, true},
          {:restore_throw, :throw, true},
          {:restore_exit, :exit, true}
        ] do
      Process.put(:attesto_phoenix_test_request_config, :outer)
      Process.put(:attesto_phoenix_test_binding_fault, fault)

      assert options[:principal].(
               %{"jti" => "binding-fault", "sub" => "binding-fault"},
               %{binding: :bearer}
             ) == {:error, :authorization_check_failed}

      if callbacks_ran do
        assert_receive {:revocation_checked, "binding-fault"}
        assert_receive {:load_principal, "binding-fault"}
      else
        refute_receive {:revocation_checked, "binding-fault"}
        refute_receive {:load_principal, "binding-fault"}
      end

      assert Process.get(:attesto_phoenix_test_request_config) == :outer
      assert_policy_failure(telemetry_event, expected_error)
      Process.delete(:attesto_phoenix_test_binding_fault)
      Process.delete(:attesto_phoenix_test_request_config)
    end

    first_options = Phoenix.protected_resource_options(:first)
    second_options = Phoenix.protected_resource_options(:second)
    default_options = Phoenix.protected_resource_options(:defaults)

    Process.put(:attesto_phoenix_test_probe, true)

    assert default_options[:replay_check].("request-local", 60) == {"request-local", 60}
    assert_receive {:request_config_seen, :defaults, :replay, {:validated, :defaults, _owner}}
    assert default_options[:htu].(%{}) == "https://mcp.example.com/mcp"
    assert_receive {:request_config_seen, :defaults, :htu, {:validated, :defaults, _owner}}
    refute Keyword.has_key?(default_options, :nonce_check)
    refute Keyword.has_key?(default_options, :nonce_issue)
    refute Keyword.has_key?(default_options, :cert_der)

    for {app, options} <- [first: first_options, second: second_options] do
      callbacks = [
        {:replay, fn -> options[:replay_check].("request-local", 60) end, {"request-local", 60}},
        {:nonce_check, fn -> options[:nonce_check].("request-local") end, :ok},
        {:nonce_issue, fn -> options[:nonce_issue].() end, "nonce"},
        {:cert_der, fn -> options[:cert_der].(%{}) end, nil},
        {:htu, fn -> options[:htu].(%{}) end, "https://mcp.example.com/mcp"}
      ]

      for {kind, callback, expected} <- callbacks do
        assert callback.() == expected
        assert_receive {:request_config_seen, ^app, ^kind, {:validated, ^app, _owner}}
      end
    end

    assert first_options[:principal].(
             %{"jti" => "request-local", "sub" => "request-local"},
             %{binding: :bearer}
           ) == {:ok, %{subject: "request-local"}}

    assert_receive {:revocation_checked, "request-local"}
    assert_receive {:request_config_seen, :first, :revocation, {:validated, :first, _owner}}
    assert_receive {:load_principal, "request-local"}
    assert_receive {:request_config_seen, :first, :principal, {:validated, :first, _owner}}

    assert second_options[:principal].(
             %{"jti" => "request-local", "sub" => "request-local"},
             %{binding: :bearer}
           ) == {:ok, %{subject: "request-local"}}

    assert_receive {:revocation_checked, "request-local"}
    assert_receive {:request_config_seen, :second, :revocation, {:validated, :second, _owner}}
    assert_receive {:load_principal, "request-local"}
    assert_receive {:request_config_seen, :second, :principal, {:validated, :second, _owner}}

    concurrent =
      for {app, concurrent_options} <- [first: first_options, second: second_options] do
        task =
          Task.async(fn ->
            Process.put(:attesto_phoenix_test_probe, true)
            Process.put(:attesto_phoenix_test_request_config, {:outer, app})

            result = concurrent_options[:replay_check].("concurrent-hold", 60)
            {result, Process.get(:attesto_phoenix_test_request_config)}
          end)

        {app, task}
      end

    waiting =
      for {app, task} <- concurrent do
        assert_receive {:request_config_waiting, ^app, caller, {:validated, ^app, _owner}}, 1_000
        {app, task, caller}
      end

    Enum.each(waiting, fn {app, _task, caller} ->
      send(caller, {:release_request_config, app})
    end)

    for {app, task, _caller} <- waiting do
      assert Task.await(task) == {{"concurrent-hold", 60}, {:outer, app}}
    end

    Process.put(:attesto_phoenix_test_request_config, :outer)

    assert_raise RuntimeError, "replay callback failed", fn ->
      first_options[:replay_check].("raise-request", 60)
    end

    assert_receive {:request_config_seen, :first, :replay, {:validated, :first, _owner}}
    assert Process.get(:attesto_phoenix_test_request_config) == :outer

    assert catch_throw(first_options[:replay_check].("throw-request", 60)) ==
             :replay_callback_failed

    assert_receive {:request_config_seen, :first, :replay, {:validated, :first, _owner}}
    assert Process.get(:attesto_phoenix_test_request_config) == :outer

    assert catch_exit(first_options[:replay_check].("exit-request", 60)) ==
             :replay_callback_failed

    assert_receive {:request_config_seen, :first, :replay, {:validated, :first, _owner}}
    assert Process.get(:attesto_phoenix_test_request_config) == :outer
    Process.delete(:attesto_phoenix_test_request_config)
    Process.delete(:attesto_phoenix_test_probe)

    assert_raise ArgumentError, ~r/replay_check callback must be a function of arity 2/, fn ->
      Phoenix.protected_resource_options(:invalid_adapter)
    end

    :code.purge(config_module)
    :code.delete(config_module)

    assert_raise UndefinedFunctionError, fn ->
      first_options[:replay_check].("module-reloaded", 60)
    end

    assert first_options[:principal].(
             %{"jti" => "module-reloaded", "sub" => "module-reloaded"},
             %{binding: :bearer}
           ) == {:error, :authorization_check_failed}

    assert_policy_failure(telemetry_event, :exception)
  end

  test "uses the direct callback path for an AttestoPhoenix 2.14-style API" do
    config_module = Module.concat([AttestoPhoenix, Config])
    adapter_module = Module.concat([AttestoPhoenix, DPoP, Adapter])
    protected_resource_module = Module.concat([AttestoPhoenix, ProtectedResource])
    callback_module = Module.concat([AttestoPhoenix, Callback])

    on_exit(fn ->
      for module <- [callback_module, protected_resource_module, adapter_module, config_module] do
        :code.purge(module)
        :code.delete(module)
      end
    end)

    Module.create(
      config_module,
      quote do
        def from_otp_app(app), do: {:legacy, app, self()}
        def to_attesto_config({:legacy, app, _owner}), do: {:attesto, app}
        def load_principal_fun({:legacy, _app, owner}), do: {__MODULE__, :load_principal, [owner]}

        def load_principal(subject, owner) do
          send(
            owner,
            {:legacy_seen, :legacy, :principal, Process.get(:attesto_phoenix_test_request_config)}
          )

          {:ok, %{subject: subject}}
        end
      end,
      Macro.Env.location(__ENV__)
    )

    Module.create(
      adapter_module,
      quote do
        def protected_resource_opts({:legacy, app, owner}) do
          [
            replay_check: fn key, ttl ->
              send(
                owner,
                {:legacy_seen, app, :replay, Process.get(:attesto_phoenix_test_request_config)}
              )

              {key, ttl}
            end,
            nonce_check: fn _nonce ->
              send(
                owner,
                {:legacy_seen, app, :nonce_check,
                 Process.get(:attesto_phoenix_test_request_config)}
              )

              :ok
            end,
            nonce_issue: fn ->
              send(
                owner,
                {:legacy_seen, app, :nonce_issue,
                 Process.get(:attesto_phoenix_test_request_config)}
              )

              "legacy-nonce"
            end,
            cert_der: fn _conn ->
              send(
                owner,
                {:legacy_seen, app, :cert_der, Process.get(:attesto_phoenix_test_request_config)}
              )

              nil
            end,
            htu: fn _conn ->
              send(
                owner,
                {:legacy_seen, app, :htu, Process.get(:attesto_phoenix_test_request_config)}
              )

              "legacy-htu"
            end
          ]
        end
      end,
      Macro.Env.location(__ENV__)
    )

    Module.create(
      protected_resource_module,
      quote do
        def access_token_revoked?({:legacy, app, owner}, claims) do
          send(
            owner,
            {:legacy_seen, app, :revocation, Process.get(:attesto_phoenix_test_request_config)}
          )

          false
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

    options = Phoenix.protected_resource_options(:legacy)

    callbacks = [
      {:replay, fn -> options[:replay_check].("key", 60) end, {"key", 60}},
      {:nonce_check, fn -> options[:nonce_check].("nonce") end, :ok},
      {:nonce_issue, fn -> options[:nonce_issue].() end, "legacy-nonce"},
      {:cert_der, fn -> options[:cert_der].(%{}) end, nil},
      {:htu, fn -> options[:htu].(%{}) end, "legacy-htu"}
    ]

    for {kind, callback, expected} <- callbacks do
      assert callback.() == expected
      assert_receive {:legacy_seen, :legacy, ^kind, nil}
    end

    assert options[:principal].(%{"jti" => "active", "sub" => "legacy-sub"}, %{}) ==
             {:ok, %{subject: "legacy-sub"}}

    assert_receive {:legacy_seen, :legacy, :revocation, nil}
    assert_receive {:legacy_seen, :legacy, :principal, nil}
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
