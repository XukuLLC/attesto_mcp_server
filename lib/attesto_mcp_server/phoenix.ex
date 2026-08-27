defmodule AttestoMCP.Server.Phoenix do
  @moduledoc """
  Narrow integration helpers for Phoenix hosts.

  `attesto_mcp_server` remains the protected resource and does not mount or
  configure an authorization server. When a host already uses
  `attesto_phoenix`, `attesto_config/1` derives the core `Attesto.Config` from
  that package's validated application configuration without introducing a
  hard dependency in this package.
  """

  @doc """
  Derives an Attesto verifier configuration from an installed
  `attesto_phoenix` host.

  The host must configure `AttestoPhoenix.Config` under `otp_app`. This helper
  fails closed when the optional package or its supported configuration API is
  unavailable.
  """
  @spec attesto_config(atom()) :: term()
  def attesto_config(otp_app) when is_atom(otp_app) do
    config_module = Module.concat([AttestoPhoenix, Config])

    if Code.ensure_loaded?(config_module) and
         function_exported?(config_module, :from_otp_app, 1) and
         function_exported?(config_module, :to_attesto_config, 1) do
      config_module
      |> apply(:from_otp_app, [otp_app])
      |> then(&apply(config_module, :to_attesto_config, [&1]))
    else
      raise ArgumentError,
            "attesto_phoenix with Config.from_otp_app/1 and Config.to_attesto_config/1 " <>
              "is required for automatic authorization-server config reuse"
    end
  end

  def attesto_config(_otp_app),
    do: raise(ArgumentError, "otp_app must be an atom")
end
