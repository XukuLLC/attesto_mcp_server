defmodule AttestoMCP.Server.Phoenix do
  @moduledoc """
  Narrow integration helpers for Phoenix hosts.

  `attesto_mcp_server` remains the protected resource and does not mount or
  configure an authorization server. When a host already uses
  `attesto_phoenix`, `attesto_config/1` derives the core `Attesto.Config` from
  that package's validated application configuration, while
  `protected_resource_options/1` also derives its runtime DPoP and mTLS
  callbacks, access-token revocation check, and principal loader. Neither
  helper introduces a hard dependency in this package.
  """

  alias AttestoMCP.Server.Telemetry

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

  @doc """
  Derives the complete protected-resource authentication options from an
  installed `attesto_phoenix` host.

  The returned keyword contains the core `Attesto.Config` plus the runtime
  DPoP replay, nonce, canonical-URL, and mTLS certificate callbacks enabled by
  the host's validated `AttestoPhoenix.Config`. Its principal callback checks
  the access-token `jti` through the host's revocation store before resolving
  the verified subject through `load_principal`. Resolve it at request time:
  the adapter callbacks close over the current validated configuration and
  must not be baked into a compiled Phoenix router.

  This helper fails closed when the optional package or its supported public
  configuration/adapter API is unavailable.
  """
  @spec protected_resource_options(atom()) :: keyword()
  def protected_resource_options(otp_app) when is_atom(otp_app) do
    config_module = Module.concat([AttestoPhoenix, Config])
    adapter_module = Module.concat([AttestoPhoenix, DPoP, Adapter])
    protected_resource_module = Module.concat([AttestoPhoenix, ProtectedResource])
    callback_module = Module.concat([AttestoPhoenix, Callback])

    if Code.ensure_loaded?(config_module) and
         function_exported?(config_module, :from_otp_app, 1) and
         function_exported?(config_module, :to_attesto_config, 1) and
         function_exported?(config_module, :load_principal_fun, 1) and
         Code.ensure_loaded?(adapter_module) and
         function_exported?(adapter_module, :protected_resource_opts, 1) and
         Code.ensure_loaded?(protected_resource_module) and
         function_exported?(protected_resource_module, :access_token_revoked?, 2) and
         Code.ensure_loaded?(callback_module) and
         function_exported?(callback_module, :invoke, 2) do
      phoenix_config = apply(config_module, :from_otp_app, [otp_app])
      attesto_config = apply(config_module, :to_attesto_config, [phoenix_config])
      adapter_options = apply(adapter_module, :protected_resource_opts, [phoenix_config])

      principal = fn claims, _sender ->
        try do
          case apply(protected_resource_module, :access_token_revoked?, [phoenix_config, claims]) do
            true ->
              {:error, :revoked}

            false ->
              case claims["sub"] do
                subject when is_binary(subject) and subject != "" ->
                  load_principal = apply(config_module, :load_principal_fun, [phoenix_config])

                  case apply(callback_module, :invoke, [load_principal, [subject]]) do
                    {:ok, principal} when not is_nil(principal) -> {:ok, principal}
                    {:error, _reason} = rejected -> rejected
                    _other -> {:error, :principal_load_failed}
                  end

                _missing_subject ->
                  {:error, :principal_load_failed}
              end

            _other ->
              authorization_check_failed(:invalid_revocation_result)
          end
        rescue
          _error -> authorization_check_failed(:exception)
        catch
          kind, _reason -> authorization_check_failed(kind)
        end
      end

      if Keyword.keyword?(adapter_options) do
        adapter_options
        |> Keyword.delete(:config)
        |> Keyword.put(:config, attesto_config)
        |> Keyword.put(:principal, principal)
      else
        raise ArgumentError,
              "attesto_phoenix DPoP.Adapter.protected_resource_opts/1 must return a keyword list"
      end
    else
      raise ArgumentError,
            "attesto_phoenix with Config.from_otp_app/1, Config.to_attesto_config/1, " <>
              "Config.load_principal_fun/1, DPoP.Adapter.protected_resource_opts/1, " <>
              "ProtectedResource.access_token_revoked?/2, and Callback.invoke/2 are required " <>
              "for automatic protected-resource config reuse"
    end
  end

  def protected_resource_options(_otp_app),
    do: raise(ArgumentError, "otp_app must be an atom")

  defp authorization_check_failed(error) do
    Telemetry.execute(
      [:auth, :policy_failure],
      %{count: 1},
      %{category: :principal_policy, error: error}
    )

    {:error, :authorization_check_failed}
  end
end
