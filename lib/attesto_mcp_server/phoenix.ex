defmodule AttestoMCP.Server.Phoenix do
  @moduledoc """
  Narrow integration helpers for Phoenix hosts.

  `attesto_mcp_server` remains the protected resource and does not mount or
  configure an authorization server. When a host already uses
  `attesto_phoenix`, `attesto_config/1` derives the core `Attesto.Config` from
  that package's validated application configuration, while
  `protected_resource_options/1` also derives its runtime DPoP and mTLS
  callbacks, access-token revocation check, and principal loader;
  `protected_resource_options/2` can compose a post-load principal callback
  without replacing those checks. These helpers introduce no hard dependency
  in this package.
  """

  alias AttestoMCP.Server.{HostCallback, Telemetry}

  @typedoc "A post-load callback that may transform or reject the AttestoPhoenix principal."
  @type principal_wrapper ::
          (term(), map(), term() -> {:ok, term()} | {:error, term()})
          | {module(), atom()}
          | {module(), atom(), [term()]}

  @typedoc "Options for composing the automatic protected-resource principal path."
  @type protected_resource_option :: {:principal, principal_wrapper()}

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

  `attesto_phoenix` 3.x binds each callback to the named profile loaded from
  the `otp_app` argument, so multiple named host profiles remain isolated.
  This helper does not select a profile from `conn.private`. The 2.14
  compatibility path supports one globally configured profile; using it for
  multiple profiles can route persistent replay or revocation reads through
  that global profile's store. Use `attesto_phoenix` 3.x when serving more than
  one named profile.

  This helper fails closed when the optional package or its supported public
  configuration/adapter API is unavailable.
  """
  @spec protected_resource_options(atom()) :: keyword()
  def protected_resource_options(otp_app), do: protected_resource_options(otp_app, [])

  @doc """
  Derives protected-resource options and composes a post-load principal callback.

  The optional `:principal` callback receives the loaded principal, verified
  claims, and sender information, in that order. It must return
  `{:ok, principal}` with a non-nil final principal or `{:error, reason}`. The
  automatic JTI revocation check and AttestoPhoenix `load_principal` callback
  always run first and cannot be replaced by this option.
  """
  @spec protected_resource_options(atom(), [protected_resource_option()]) :: keyword()
  def protected_resource_options(otp_app, opts) when is_atom(otp_app) and is_list(opts) do
    validate_protected_resource_options!(opts)
    principal_wrapper = Keyword.get(opts, :principal)
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
      request_config_binding? = function_exported?(config_module, :with_request_config, 2)

      principal = fn claims, sender ->
        try do
          with_request_config(request_config_binding?, config_module, phoenix_config, fn ->
            case apply(protected_resource_module, :access_token_revoked?, [phoenix_config, claims]) do
              true ->
                {:error, :revoked}

              false ->
                case claims["sub"] do
                  subject when is_binary(subject) and subject != "" ->
                    load_principal = apply(config_module, :load_principal_fun, [phoenix_config])

                    case apply(callback_module, :invoke, [load_principal, [subject]]) do
                      {:ok, principal} when not is_nil(principal) ->
                        apply_principal_wrapper(principal_wrapper, principal, claims, sender)

                      {:error, _reason} = rejected ->
                        rejected

                      _other ->
                        {:error, :principal_load_failed}
                    end

                  _missing_subject ->
                    {:error, :principal_load_failed}
                end

              _other ->
                authorization_check_failed(:invalid_revocation_result)
            end
          end)
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
        |> bind_request_callbacks(config_module, phoenix_config, request_config_binding?)
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

  def protected_resource_options(otp_app, _opts) when is_atom(otp_app),
    do: raise(ArgumentError, "protected-resource options must be a keyword list")

  def protected_resource_options(_otp_app, _opts),
    do: raise(ArgumentError, "otp_app must be an atom")

  defp validate_protected_resource_options!(opts) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "protected-resource options must be a keyword list")

    keys = Keyword.keys(opts)

    if keys != Enum.uniq(keys),
      do: raise(ArgumentError, "protected-resource options must not contain duplicate keys")

    unknown = keys -- [:principal]

    if unknown != [],
      do:
        raise(
          ArgumentError,
          "unknown protected-resource option(s): #{inspect(Enum.uniq(unknown))}"
        )

    case Keyword.get(opts, :principal) do
      nil ->
        :ok

      callback ->
        unless HostCallback.valid?(callback, 3),
          do: raise(ArgumentError, ":principal must be a supported three-argument callback")
    end
  end

  defp apply_principal_wrapper(nil, principal, _claims, _sender), do: {:ok, principal}

  defp apply_principal_wrapper(callback, principal, claims, sender) do
    case HostCallback.invoke(callback, [principal, claims, sender]) do
      {:ok, final_principal} when not is_nil(final_principal) -> {:ok, final_principal}
      {:error, _reason} = rejected -> rejected
      _other -> {:error, :principal_wrapper_failed}
    end
  end

  # AttestoPhoenix's stores intentionally resolve the current Repo and schema
  # prefix from request-local configuration. Protected-resource options may be
  # constructed for a named profile and invoked later or across requests, so
  # every callback must install that profile for the duration of its
  # invocation.
  defp bind_request_callbacks(options, config_module, phoenix_config, request_config_binding?) do
    validate_adapter_callbacks!(options)

    if request_config_binding? do
      options
      |> bind_request_callback(:replay_check, 2, config_module, phoenix_config)
      |> bind_request_callback(:nonce_check, 1, config_module, phoenix_config)
      |> bind_request_callback(:nonce_issue, 0, config_module, phoenix_config)
      |> bind_request_callback(:cert_der, 1, config_module, phoenix_config)
      |> bind_request_callback(:htu, 1, config_module, phoenix_config)
    else
      options
    end
  end

  defp validate_adapter_callbacks!(options) do
    for {key, arity} <- [replay_check: 2, nonce_check: 1, nonce_issue: 0, cert_der: 1, htu: 1] do
      case Keyword.fetch(options, key) do
        {:ok, callback} when is_function(callback, arity) ->
          :ok

        {:ok, _callback} ->
          raise ArgumentError,
                "attesto_phoenix adapter #{key} callback must be a function of arity #{arity}"

        :error ->
          :ok
      end
    end
  end

  defp bind_request_callback(options, key, arity, config_module, phoenix_config) do
    case Keyword.fetch(options, key) do
      {:ok, callback} ->
        Keyword.put(
          options,
          key,
          request_callback(callback, arity, config_module, phoenix_config)
        )

      :error ->
        options
    end
  end

  defp request_callback(callback, 0, config_module, phoenix_config) do
    fn ->
      with_request_config(true, config_module, phoenix_config, fn ->
        apply(callback, [])
      end)
    end
  end

  defp request_callback(callback, 1, config_module, phoenix_config) do
    fn argument ->
      with_request_config(true, config_module, phoenix_config, fn ->
        apply(callback, [argument])
      end)
    end
  end

  defp request_callback(callback, 2, config_module, phoenix_config) do
    fn first, second ->
      with_request_config(true, config_module, phoenix_config, fn ->
        apply(callback, [first, second])
      end)
    end
  end

  defp with_request_config(true, config_module, phoenix_config, fun),
    do: apply(config_module, :with_request_config, [phoenix_config, fun])

  defp with_request_config(false, _config_module, _phoenix_config, fun), do: fun.()

  defp authorization_check_failed(error) do
    Telemetry.execute(
      [:auth, :policy_failure],
      %{count: 1},
      %{category: :principal_policy, error: error}
    )

    {:error, :authorization_check_failed}
  end
end
