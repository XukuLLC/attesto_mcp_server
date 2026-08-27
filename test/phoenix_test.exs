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
end
