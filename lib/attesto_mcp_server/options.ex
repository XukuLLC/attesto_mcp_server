defmodule AttestoMCP.Server.Options do
  @moduledoc false

  alias AttestoMCP.Server.{
    CachePolicy,
    HostCallback,
    Icons,
    Implementation,
    Presentation,
    Protocol,
    RequestMeta,
    Schema,
    ScopeMap,
    Session,
    Stores,
    Telemetry
  }

  @private_keys [
    :cursor_secret,
    :request_state_secret,
    :request_state_instance,
    :request_state_store,
    :request_store,
    :request_store_external,
    :session_store,
    :url_elicitation_store
  ]
  @derived_keys [:server_implementation]
  @allowed_keys [
    :name,
    :protocol_versions,
    :max_concurrency,
    :per_principal_concurrency,
    :request_timeout,
    :max_request_timeout,
    :client_request_timeout,
    :legacy_initialized_grace_ms,
    :session_idle_timeout,
    :session_absolute_timeout,
    :max_sessions_per_principal,
    :max_legacy_streams_per_session,
    :max_json_bytes,
    :schema_formats,
    :output_canonicalization,
    :tool_argument_keys,
    :max_body_bytes,
    :max_message_bytes,
    :max_queue,
    :stream_keepalive_ms,
    :legacy_keepalive_ms,
    :stream_queue_size,
    :subscription_queue_size,
    :subscription_timeout,
    :rate_limits,
    :cursor_secret,
    :cursor_ttl,
    :request_state_secret,
    :request_state_instance,
    :request_state_store,
    :clustered,
    :request_state_ttl,
    :scope_map,
    :default_scopes,
    :registrations,
    :session_store,
    :session_namespace,
    :session_clustered,
    :url_elicitation_store,
    :url_elicitation_max_entries,
    :url_elicitation_max_bytes,
    :telemetry_metadata,
    :exception_reporter,
    :handler_task_init,
    :initialize_callback,
    :instructions,
    :server_name,
    :server_version,
    :capabilities,
    :modern_tasks,
    :legacy_tasks,
    :page_size,
    :cache_ttl_ms,
    :cache_scope,
    :allow_public_cache,
    :cache_policy,
    :max_request_meta_bytes,
    :instructions_provider,
    :tool_presentation,
    :server_icons,
    :export_schema_dialect
  ]
  @rate_defaults %{
    calls: %{burst: 600, window_ms: 60_000},
    completion: %{burst: 300, window_ms: 60_000},
    subscriptions: %{burst: 100, window_ms: 60_000},
    auth_checks: %{burst: 1_024, window_ms: 60_000},
    auth_failures: %{burst: 120, window_ms: 60_000}
  }

  @doc false
  def normalize(opts) do
    normalized =
      Application.get_all_env(:attesto_mcp_server)
      |> Keyword.merge(opts)
      |> merge_rate_limit_defaults()
      |> Keyword.put_new(:protocol_versions, Protocol.versions())
      |> Keyword.put_new(:max_concurrency, 64)
      |> Keyword.put_new(:per_principal_concurrency, 16)
      |> Keyword.put_new(:max_sessions_per_principal, 128)
      |> Keyword.put_new(:max_legacy_streams_per_session, 8)
      |> Keyword.put_new(:request_timeout, 30_000)
      |> Keyword.put_new(:client_request_timeout, 30_000)
      |> Keyword.put_new(:legacy_initialized_grace_ms, 50)
      |> Keyword.put_new(:max_request_timeout, 120_000)
      |> Keyword.put_new(:request_state_ttl, 120_000)
      |> Keyword.put_new(
        :url_elicitation_max_entries,
        AttestoMCP.Server.UrlElicitationStore.ETS.default_max_entries()
      )
      |> Keyword.put_new(
        :url_elicitation_max_bytes,
        AttestoMCP.Server.UrlElicitationStore.ETS.default_max_bytes()
      )
      |> Keyword.put_new(:max_json_bytes, Schema.default_instance_bytes())
      |> Keyword.put_new(:schema_formats, true)
      |> Keyword.put_new(:output_canonicalization, :strict)
      |> Keyword.put_new(:tool_argument_keys, :strings)
      |> Keyword.put_new(:stream_keepalive_ms, 15_000)
      |> Keyword.put_new(:max_queue, 128)
      |> Keyword.put_new(:rate_limits, @rate_defaults)
      |> Keyword.put(:modern_tasks, false)
      |> Keyword.put(:legacy_tasks, false)
      |> normalize_cache_scope()

    normalized =
      normalized
      |> put_default_if_nil(:stream_queue_size, normalized[:max_queue])
      |> put_default_if_nil(:subscription_queue_size, normalized[:max_queue])
      |> put_default_if_nil(:legacy_keepalive_ms, normalized[:stream_keepalive_ms])
      |> put_default_if_nil(:session_idle_timeout, 1_800_000)
      |> put_default_if_nil(:session_absolute_timeout, 86_400_000)

    validate!(normalized)
    normalized = normalize_presentation!(normalized)

    unless is_integer(normalized[:request_state_ttl]) and normalized[:request_state_ttl] > 0 and
             normalized[:request_state_ttl] <= 120_000 do
      raise ArgumentError, ":request_state_ttl must be between 1 and 120000 milliseconds"
    end

    normalized
  end

  @doc false
  def session_timeouts(session_opts, opts) when is_list(session_opts) do
    if Keyword.keyword?(session_opts) do
      absolute_timeout =
        Keyword.get(session_opts, :absolute_timeout, opts[:session_absolute_timeout])

      idle_timeout = Keyword.get(session_opts, :idle_timeout, opts[:session_idle_timeout])

      cond do
        not Session.valid_timeout?(absolute_timeout) ->
          {:error, {:invalid_session_timeout, :absolute_timeout}}

        not Session.valid_timeout?(idle_timeout) ->
          {:error, {:invalid_session_timeout, :idle_timeout}}

        true ->
          {:ok, absolute_timeout, idle_timeout}
      end
    else
      {:error, {:invalid_session_timeout, :options}}
    end
  end

  def session_timeouts(_session_opts, _opts),
    do: {:error, {:invalid_session_timeout, :options}}

  @doc false
  def put_default_if_nil(opts, key, default) do
    if is_nil(Keyword.get(opts, key)), do: Keyword.put(opts, key, default), else: opts
  end

  @doc false
  def public(opts), do: Keyword.drop(opts, @private_keys ++ @derived_keys)

  @doc false
  def redacted(opts), do: Keyword.drop(opts, @private_keys)

  defp normalize_presentation!(opts) do
    Presentation.validate_options!(opts)

    icons =
      case Keyword.get(opts, :server_icons) do
        nil ->
          nil

        icons ->
          case Icons.normalize(icons) do
            {:ok, icons} -> icons
            {:error, reason} -> raise ArgumentError, ":server_icons are invalid: #{reason}"
          end
      end

    meta_bytes = Keyword.get(opts, :max_request_meta_bytes)

    unless is_nil(meta_bytes) or
             (is_integer(meta_bytes) and meta_bytes >= Schema.min_allowed_instance_bytes() and
                meta_bytes <= opts[:max_json_bytes]) do
      raise ArgumentError,
            ":max_request_meta_bytes must be between #{Schema.min_allowed_instance_bytes()} and :max_json_bytes"
    end

    unless is_boolean(Keyword.get(opts, :export_schema_dialect, false)),
      do: raise(ArgumentError, ":export_schema_dialect must be boolean")

    opts =
      opts
      |> Keyword.put(:server_icons, icons)
      |> Keyword.put_new(:export_schema_dialect, false)
      |> put_default_if_nil(
        :max_request_meta_bytes,
        min(RequestMeta.default_max_bytes(), opts[:max_json_bytes])
      )
      |> Keyword.put(:cache_policy, CachePolicy.normalize_config!(opts[:cache_policy]))

    Keyword.put(opts, :server_implementation, Implementation.build(opts))
  end

  defp normalize_cache_scope(opts) do
    case Keyword.get(opts, :cache_scope) do
      :private -> Keyword.put(opts, :cache_scope, "private")
      :public -> Keyword.put(opts, :cache_scope, "public")
      _ -> opts
    end
  end

  defp merge_rate_limit_defaults(opts) do
    cond do
      not Keyword.has_key?(opts, :rate_limits) ->
        Keyword.put(opts, :rate_limits, @rate_defaults)

      opts[:rate_limits] == false ->
        opts

      is_map(opts[:rate_limits]) ->
        Keyword.put(opts, :rate_limits, Map.merge(@rate_defaults, opts[:rate_limits]))

      true ->
        opts
    end
  end

  defp validate!(opts) do
    unknown = Keyword.keys(opts) -- @allowed_keys

    if unknown != [],
      do: raise(ArgumentError, "unknown server option(s): #{inspect(Enum.uniq(unknown))}")

    case Keyword.get(opts, :name) do
      nil -> :ok
      name when is_atom(name) -> :ok
      _other -> raise ArgumentError, ":name must be an atom when present"
    end

    validate_numeric_options!(opts)
    json_budget = validate_json_budget!(opts)

    unless opts[:output_canonicalization] in [:strict, :json, :jason],
      do: raise(ArgumentError, ":output_canonicalization must be :strict, :json, or :jason")

    unless opts[:tool_argument_keys] in [:strings, :atoms],
      do: raise(ArgumentError, ":tool_argument_keys must be :strings or :atoms")

    unless is_boolean(opts[:schema_formats]),
      do: raise(ArgumentError, ":schema_formats must be boolean")

    validate_transport_budgets!(opts, json_budget)
    validate_paging_and_cache!(opts)
    validate_protocol_and_identity!(opts)
    ScopeMap.validate!(Keyword.get(opts, :scope_map))
    validate_default_scopes!(Keyword.get(opts, :default_scopes))
    validate_capabilities!(Keyword.get(opts, :capabilities), json_budget)
    Telemetry.validate_trusted_metadata!(Keyword.get(opts, :telemetry_metadata))
    validate_callbacks!(opts)
    validate_cluster_options!(opts)
    Stores.validate_options!(opts)

    if opts[:session_clustered] == true and
         (is_nil(opts[:session_store]) or is_nil(opts[:session_namespace])) do
      raise ArgumentError,
            ":session_clustered requires an explicit shared :session_store and :session_namespace"
    end

    validate_request_state_options!(opts)

    if Keyword.get(opts, :request_timeout) > Keyword.get(opts, :max_request_timeout),
      do: raise(ArgumentError, ":request_timeout cannot exceed :max_request_timeout")

    validate_rate_limits!(opts[:rate_limits])
    validate_replica_options!(opts)
    :ok
  end

  defp validate_numeric_options!(opts) do
    positive = [
      :max_concurrency,
      :per_principal_concurrency,
      :max_request_timeout,
      :client_request_timeout,
      :max_queue,
      :stream_queue_size,
      :subscription_queue_size,
      :session_idle_timeout,
      :session_absolute_timeout,
      :max_sessions_per_principal,
      :max_legacy_streams_per_session,
      :url_elicitation_max_entries,
      :url_elicitation_max_bytes
    ]

    nonnegative = [
      :request_timeout,
      :legacy_initialized_grace_ms,
      :stream_keepalive_ms,
      :legacy_keepalive_ms,
      :cursor_ttl,
      :subscription_timeout
    ]

    Enum.each(positive, fn key ->
      case Keyword.get(opts, key) do
        value when key in [:session_idle_timeout, :session_absolute_timeout] ->
          unless Session.valid_timeout?(value) do
            raise ArgumentError,
                  "#{key} must be between 1 and #{Session.max_timeout_ms()} milliseconds"
          end

        value when is_integer(value) and value > 0 ->
          :ok

        _ ->
          raise ArgumentError, "#{key} must be a positive integer"
      end
    end)

    Enum.each(nonnegative, fn key ->
      case Keyword.get(opts, key) do
        nil -> :ok
        value when is_integer(value) and value >= 0 -> :ok
        _ -> raise ArgumentError, "#{key} must be a non-negative integer"
      end
    end)
  end

  defp validate_json_budget!(opts) do
    json_budget = Keyword.fetch!(opts, :max_json_bytes)

    unless is_integer(json_budget) and json_budget >= Schema.min_allowed_instance_bytes() and
             json_budget <= Schema.max_allowed_instance_bytes() do
      raise ArgumentError,
            ":max_json_bytes must be between #{Schema.min_allowed_instance_bytes()} and #{Schema.max_allowed_instance_bytes()} bytes"
    end

    json_budget
  end

  defp validate_transport_budgets!(opts, json_budget) do
    Enum.each([:max_body_bytes, :max_message_bytes], fn key ->
      case Keyword.get(opts, key) do
        nil ->
          :ok

        value when is_integer(value) and value > 0 ->
          if value > json_budget,
            do:
              raise(
                ArgumentError,
                "#{key} cannot exceed the #{json_budget}-byte JSON value budget"
              )

        _ ->
          raise ArgumentError, "#{key} must be a positive integer"
      end
    end)
  end

  defp validate_paging_and_cache!(opts) do
    page_size = Keyword.get(opts, :page_size)

    if not is_nil(page_size) and not (is_integer(page_size) and page_size in 1..100),
      do: raise(ArgumentError, ":page_size must be between 1 and 100")

    cache_ttl = Keyword.get(opts, :cache_ttl_ms)

    if not is_nil(cache_ttl) and
         not (is_integer(cache_ttl) and cache_ttl >= 0 and
                cache_ttl <= CachePolicy.max_safe_integer()),
       do: raise(ArgumentError, ":cache_ttl_ms must be a JSON-safe non-negative integer")

    cache_scope = Keyword.get(opts, :cache_scope)

    if not is_nil(cache_scope) and cache_scope not in [:private, :public, "private", "public"],
      do: raise(ArgumentError, ":cache_scope must be :private or :public")

    allow_public_cache = Keyword.get(opts, :allow_public_cache)

    if not is_nil(allow_public_cache) and not is_boolean(allow_public_cache),
      do: raise(ArgumentError, ":allow_public_cache must be boolean")
  end

  defp validate_protocol_and_identity!(opts) do
    versions = Keyword.get(opts, :protocol_versions)

    unless is_list(versions) and versions != [] and Enum.uniq(versions) == versions and
             Enum.all?(versions, &(&1 in Protocol.versions())) do
      raise ArgumentError, ":protocol_versions must be a non-empty list of supported versions"
    end

    Enum.each([:server_name, :server_version, :instructions], fn key ->
      case Keyword.get(opts, key) do
        nil -> :ok
        value when is_binary(value) and byte_size(value) > 0 -> :ok
        _ -> raise ArgumentError, "#{key} must be a non-empty string"
      end
    end)
  end

  defp validate_default_scopes!(nil), do: :ok

  defp validate_default_scopes!(scopes) when is_list(scopes) and scopes != [] do
    unless length(scopes) == length(Enum.uniq(scopes)) and
             Enum.all?(scopes, &(is_binary(&1) and byte_size(&1) in 1..256)) do
      raise ArgumentError, ":default_scopes must be a non-empty list of unique scopes"
    end
  end

  defp validate_default_scopes!(_scopes),
    do: raise(ArgumentError, ":default_scopes must be a non-empty list of unique scopes")

  defp validate_capabilities!(nil, _max_bytes), do: :ok

  defp validate_capabilities!(capabilities, max_bytes) when is_map(capabilities) do
    if Schema.json_value(capabilities, max_bytes: max_bytes) == :ok do
      :ok
    else
      raise ArgumentError, ":capabilities must contain only bounded JSON values"
    end
  end

  defp validate_capabilities!(_capabilities, _max_bytes),
    do: raise(ArgumentError, ":capabilities must be a JSON map")

  defp validate_callbacks!(opts) do
    Enum.each([{:exception_reporter, 1}, {:handler_task_init, 2}], fn {key, arity} ->
      case Keyword.get(opts, key) do
        nil ->
          :ok

        callback ->
          unless HostCallback.valid?(callback, arity),
            do: raise(ArgumentError, "#{key} must be a supported #{arity}-argument callback")
      end
    end)

    case Keyword.get(opts, :initialize_callback) do
      nil -> :ok
      callback when is_function(callback, 2) -> :ok
      _ -> raise ArgumentError, ":initialize_callback must be a two-argument function"
    end
  end

  defp validate_cluster_options!(opts) do
    Enum.each([:clustered, :session_clustered], fn key ->
      case Keyword.get(opts, key) do
        nil -> :ok
        value when is_boolean(value) -> :ok
        _ -> raise ArgumentError, ":#{key} must be boolean"
      end
    end)

    case Keyword.get(opts, :session_namespace) do
      nil ->
        :ok

      value when is_binary(value) ->
        unless valid_session_key?(value) do
          raise ArgumentError,
                ":session_namespace must be a non-empty valid UTF-8 string up to 256 bytes without NUL bytes"
        end

      _ ->
        raise ArgumentError,
              ":session_namespace must be a non-empty valid UTF-8 string up to 256 bytes without NUL bytes"
    end
  end

  defp validate_request_state_options!(opts) do
    case Keyword.get(opts, :request_state_store) do
      nil -> :ok
      store when is_pid(store) -> :ok
      _ -> raise ArgumentError, ":request_state_store must be a supervised pid"
    end

    Enum.each([:cursor_secret, :request_state_secret], fn key ->
      case Keyword.get(opts, key) do
        nil -> :ok
        value when is_binary(value) and byte_size(value) > 0 -> :ok
        _ -> raise ArgumentError, "#{key} must be a non-empty binary"
      end
    end)

    if opts[:session_clustered] == true and
         not (is_binary(opts[:cursor_secret]) and byte_size(opts[:cursor_secret]) >= 16) do
      raise ArgumentError,
            ":session_clustered requires an explicit shared :cursor_secret of at least 16 bytes (32 bytes recommended)"
    end
  end

  defp validate_rate_limits!(false), do: :ok

  defp validate_rate_limits!(settings) when is_map(settings) do
    allowed = [:calls, :completion, :subscriptions, :auth_checks, :auth_failures]

    Enum.each(settings, fn {category, setting} ->
      category = if is_binary(category), do: String.to_existing_atom(category), else: category

      if category not in allowed or (not valid_rate_setting?(setting) and setting != false),
        do: raise(ArgumentError, "invalid rate_limits configuration")
    end)
  rescue
    ArgumentError -> reraise(ArgumentError, __STACKTRACE__)
    _ -> raise ArgumentError, "invalid rate_limits configuration"
  end

  defp validate_rate_limits!(_settings),
    do: raise(ArgumentError, "rate_limits must be a map")

  defp valid_rate_setting?(setting) when is_map(setting) do
    burst = Map.get(setting, :burst, Map.get(setting, "burst"))
    window = Map.get(setting, :window_ms, Map.get(setting, "window_ms"))
    is_integer(burst) and burst > 0 and is_integer(window) and window > 0
  end

  defp valid_rate_setting?(_setting), do: false

  defp validate_replica_options!(opts) do
    if opts[:clustered] == true do
      required = [
        :request_state_secret,
        :cursor_secret,
        :request_state_instance,
        :request_state_store
      ]

      unless Enum.all?(required, fn key ->
               case Keyword.get(opts, key) do
                 value when key == :request_state_store -> is_pid(value)
                 value -> is_binary(value) and byte_size(value) >= 16
               end
             end) do
        raise ArgumentError,
              ":clustered requires shared request_state_secret, cursor_secret, request_state_instance, and request_state_store"
      end
    end
  end

  defp valid_session_key?(value) do
    byte_size(value) >= 1 and byte_size(value) <= 256 and valid_utf8?(value) and
      :binary.match(value, <<0>>) == :nomatch
  end

  defp valid_utf8?(value) do
    is_binary(:unicode.characters_to_binary(value, :utf8, :utf8))
  end
end
