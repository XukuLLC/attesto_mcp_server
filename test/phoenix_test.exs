defmodule AttestoMCP.Server.PhoenixTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server.Phoenix

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

  test "derives runtime protected-resource callbacks through the public adapter" do
    config_module = Module.concat([AttestoPhoenix, Config])
    adapter_module = Module.concat([AttestoPhoenix, DPoP, Adapter])

    on_exit(fn ->
      for module <- [adapter_module, config_module] do
        :code.purge(module)
        :code.delete(module)
      end
    end)

    Module.create(
      config_module,
      quote do
        def from_otp_app(app), do: {:validated, app}
        def to_attesto_config({:validated, app}), do: {:attesto, app}
      end,
      Macro.Env.location(__ENV__)
    )

    Module.create(
      adapter_module,
      quote do
        def protected_resource_opts({:validated, app}) do
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

    options = Phoenix.protected_resource_options(:sample)

    assert options[:config] == {:attesto, :sample}
    assert options[:host_app] == :sample
    assert options[:replay_check].("key", 60) == {"key", 60}
    assert options[:nonce_check].(nil) == :ok
    assert options[:nonce_issue].() == "nonce"
    assert options[:cert_der].(%{}) == nil
    assert options[:htu].(%{}) == "https://mcp.example.com/mcp"
  end

  test "fails closed when the protected-resource adapter contract is unavailable" do
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
end
