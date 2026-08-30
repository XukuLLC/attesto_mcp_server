defmodule AttestoMCP.Server.Plug do
  @moduledoc """
  Plug-compatible Streamable HTTP boundary for modern and legacy MCP.

  Every protected MCP leg authenticates through `AttestoMCP.Plug.ProtectResource`
  before package-owned request decoding or registry dispatch. A host parser
  placed earlier in the endpoint runs before this Plug and must apply its own
  input limit. Metadata discovery is the one intentionally public route
  defined by RFC 9728. Hosts may select
  request-scoped tool streams with `stream_tools` or `stream_all_tools`; both
  options are validated during `init/1`.

  `:auth` accepts either a keyword list or a zero-arity remote callback/MFA
  returning one. Resolver-backed authentication is evaluated for every
  applicable MCP or metadata request, so runtime authorization configuration
  is not captured by router compilation. The trusted resolver may supply the
  canonical resource or origin at runtime; it is checked against the configured
  Plug path and reused for metadata and audience verification. A resolver may
  not replace the boundary's canonical assign keys, and failures fail the
  request closed.
  """
  import Plug.Conn

  alias AttestoMCP.Server
  alias AttestoMCP.Server.{Error, HostCallback, JSONRPC, Schema, ScopeMap, Telemetry}

  @behaviour Plug
  @modern "2026-07-28"
  @legacy "2025-11-25"
  @legacy_2025_06_18 "2025-06-18"
  @legacy_versions [@legacy, @legacy_2025_06_18]
  @max_safe_integer 9_007_199_254_740_991
  @max_request_headers 64
  @max_request_header_name_bytes 256
  @max_request_header_value_bytes 8_192
  @max_request_header_bytes 65_536
  @static_path_pattern ~r/\A\/(?:[A-Za-z0-9._~-]+(?:\/[A-Za-z0-9._~-]+)*)?\z/
  @resolver_assign_keys %{
    claims_key: :attesto_mcp_claims,
    context_key: :attesto_context,
    principal_key: :attesto_mcp_principal,
    scopes_key: :attesto_mcp_scopes,
    sender_key: :attesto_mcp_sender
  }
  @visible_definition_methods [
    "tools/list",
    "resources/list",
    "resources/templates/list"
  ]
  @selected_definition_methods [
    "tools/call",
    "resources/read"
  ]
  @allowed_plug_option_keys [
    :server,
    :path,
    :auth,
    :scope_map,
    :scope_policy,
    :default_scopes,
    :scopes_supported,
    :context_builder,
    :subscription_scopes,
    :max_body_bytes,
    :max_message_bytes,
    :allow_dynamic_origin,
    :origin,
    :base_url,
    :resource,
    :resource_audience,
    :stream_keepalive_ms,
    :legacy_keepalive_ms,
    :subscription_timeout,
    :stream_queue_size,
    :subscription_queue_size,
    :max_queue,
    :stream_all_tools,
    :stream_tools
  ]

  @typedoc "Supported Plug boundary options."
  @type auth_options_resolver ::
          (-> keyword())
          | {module(), atom()}
          | {module(), atom(), [term()]}

  @typedoc "An explicit definition-based authorization mode for one MCP method."
  @type scope_policy_mode :: :visible_definitions | :selected_definition

  @typedoc "Per-method opt-ins to definition-based HTTP authorization."
  @type scope_policy :: %{optional(String.t()) => scope_policy_mode()}

  @type plug_option ::
          {:server, pid() | atom()}
          | {:path, String.t()}
          | {:auth, keyword() | auth_options_resolver()}
          | {:scope_map, map()}
          | {:scope_policy, scope_policy()}
          | {:default_scopes, [String.t()]}
          | {:scopes_supported, [String.t()]}
          | {:context_builder,
             (Plug.Conn.t() -> map()) | {module(), atom()} | {module(), atom(), [term()]}}
          | {:subscription_scopes, [String.t()]}
          | {:max_body_bytes, pos_integer()}
          | {:max_message_bytes, pos_integer()}
          | {:allow_dynamic_origin, boolean()}
          | {:origin, String.t()}
          | {:base_url, String.t()}
          | {:resource, String.t()}
          | {:resource_audience, String.t()}
          | {:stream_keepalive_ms, pos_integer()}
          | {:legacy_keepalive_ms, pos_integer()}
          | {:subscription_timeout, pos_integer()}
          | {:stream_queue_size, pos_integer()}
          | {:subscription_queue_size, pos_integer()}
          | {:max_queue, pos_integer()}
          | {:stream_all_tools, boolean()}
          | {:stream_tools, [String.t()]}

  @doc "Initializes a Plug state for an already-supervised server and pinned auth boundary."
  @spec init([plug_option()]) :: map()
  @impl Plug
  def init(opts) do
    server =
      case Keyword.fetch(opts, :server) do
        {:ok, server} when is_pid(server) ->
          if Process.alive?(server), do: server, else: raise(ArgumentError, "server is not alive")

        {:ok, server} when is_atom(server) ->
          server

        {:ok, _server} ->
          raise ArgumentError, "server must be a supervised pid or registered name"

        :error ->
          raise ArgumentError, "server must be an already-supervised pid or registered name"
      end

    path = Keyword.get(opts, :path, "/mcp")
    validate_plug_options!(opts)
    validate_path!(path)

    {auth_opts, auth_boundary, auth_resolver} = initialize_authentication(opts, path)

    validate_stream_options!(opts)
    scope_map = Keyword.get(opts, :scope_map)
    scope_policy = Keyword.get(opts, :scope_policy)

    if Keyword.has_key?(opts, :scope_map),
      do: validate_scope_map_option!(scope_map)

    validate_scope_policy_option!(scope_policy)
    validate_effective_scope_policy_overlap!(server, opts, scope_policy)
    validate_scope_list_option!(opts, :default_scopes, allow_empty: false)
    validate_scope_list_option!(opts, :scopes_supported, allow_empty: false)
    validate_context_builder!(Keyword.get(opts, :context_builder))
    validate_subscription_scopes!(Keyword.get(opts, :subscription_scopes))

    %{
      server: server,
      path: path,
      auth_opts: auth_opts,
      auth_boundary: auth_boundary,
      auth_resolver: auth_resolver,
      auth_source_opts: opts,
      opts: opts
    }
  end

  defp validate_plug_options!(opts) do
    unknown = Keyword.keys(opts) -- @allowed_plug_option_keys

    if unknown != [],
      do: raise(ArgumentError, "unknown Plug option(s): #{inspect(Enum.uniq(unknown))}")
  end

  defp validate_path!(path) when is_binary(path) do
    invalid_segment? = Enum.any?(String.split(path, "/"), &(&1 in [".", ".."]))

    if path == "" or not Regex.match?(@static_path_pattern, path) or invalid_segment? do
      raise ArgumentError,
            ":path must be an absolute static ASCII path using only unreserved URI characters and slash separators"
    end
  end

  defp validate_path!(_), do: raise(ArgumentError, ":path must be an absolute string")

  defp validate_scope_map_option!(scope_map), do: ScopeMap.validate!(scope_map)

  defp validate_scope_policy_option!(nil), do: :ok

  defp validate_scope_policy_option!(scope_policy) when is_map(scope_policy) do
    valid? =
      Enum.all?(scope_policy, fn
        {method, :visible_definitions} -> method in @visible_definition_methods
        {method, :selected_definition} -> method in @selected_definition_methods
        _ -> false
      end)

    if valid? do
      :ok
    else
      raise ArgumentError,
            ":scope_policy must map supported string methods to :visible_definitions or :selected_definition"
    end
  end

  defp validate_scope_policy_option!(_),
    do: raise(ArgumentError, ":scope_policy must be a map")

  defp validate_scope_policy_overlap!(scope_map, scope_policy)
       when is_map(scope_map) and is_map(scope_policy) do
    overlap =
      Map.keys(scope_map)
      |> MapSet.new()
      |> MapSet.intersection(MapSet.new(Map.keys(scope_policy)))

    if MapSet.size(overlap) > 0 do
      raise ArgumentError,
            ":scope_policy cannot overlap :scope_map; choose one policy for each method"
    end
  end

  defp validate_scope_policy_overlap!(_scope_map, _scope_policy), do: :ok

  defp validate_effective_scope_policy_overlap!(_server, _opts, nil), do: :ok

  defp validate_effective_scope_policy_overlap!(server, opts, scope_policy)
       when is_map(scope_policy) do
    effective_scope_map =
      if Keyword.has_key?(opts, :scope_map) do
        Keyword.get(opts, :scope_map)
      else
        server_scope_map_at_init!(server)
      end

    validate_scope_policy_overlap!(effective_scope_map, scope_policy)
  end

  defp server_scope_map_at_init!(server) when is_pid(server) do
    if Process.alive?(server), do: fetch_server_scope_map!(server), else: nil
  end

  defp server_scope_map_at_init!(server) when is_atom(server) do
    if is_pid(Process.whereis(server)), do: fetch_server_scope_map!(server), else: nil
  end

  defp fetch_server_scope_map!(server) do
    server
    |> Server.options()
    |> Keyword.get(:scope_map)
  rescue
    _ -> raise ArgumentError, "cannot validate server :scope_map for :scope_policy"
  catch
    _kind, _reason -> raise ArgumentError, "cannot validate server :scope_map for :scope_policy"
  end

  defp validate_subscription_scopes!(nil), do: :ok

  defp validate_subscription_scopes!(scopes)
       when is_list(scopes) and scopes != [] do
    valid? =
      Enum.all?(scopes, &(is_binary(&1) and byte_size(&1) in 1..256)) and
        length(scopes) == length(Enum.uniq(scopes))

    if valid?, do: :ok, else: raise(ArgumentError, ":subscription_scopes must be unique strings")
  end

  defp validate_subscription_scopes!([]), do: :ok

  defp validate_subscription_scopes!(_),
    do: raise(ArgumentError, ":subscription_scopes must be a list of unique strings")

  defp validate_scope_list_option!(opts, key, validation_opts) do
    case Keyword.fetch(opts, key) do
      :error ->
        :ok

      {:ok, scopes} when is_list(scopes) ->
        allow_empty? = Keyword.fetch!(validation_opts, :allow_empty)

        valid? =
          (allow_empty? or scopes != []) and length(scopes) == length(Enum.uniq(scopes)) and
            Enum.all?(scopes, &(is_binary(&1) and byte_size(&1) in 1..256))

        unless valid?,
          do: raise(ArgumentError, ":#{key} must be a non-empty list of unique scopes")

      {:ok, _other} ->
        raise ArgumentError, ":#{key} must be a list of unique scopes"
    end
  end

  defp validate_context_builder!(nil), do: :ok

  defp validate_context_builder!(callback) do
    unless HostCallback.valid?(callback, 1),
      do: raise(ArgumentError, ":context_builder must be a supported one-argument callback")
  end

  defp initialize_authentication(opts, path) do
    case Keyword.get(opts, :auth, []) do
      nested when is_list(nested) ->
        auth_opts = normalize_auth_options(opts, path, nested)
        validate_auth_options!(auth_opts)
        {auth_opts, prepare_protect_resource(auth_opts), nil}

      resolver ->
        validate_auth_resolver!(resolver)
        validate_resolver_static_resource_options!(opts, path)
        {nil, nil, resolver}
    end
  end

  defp normalize_auth_options(opts, path, nested) do
    unless Keyword.keyword?(nested),
      do: raise(ArgumentError, ":auth must be a keyword list")

    validate_static_bearer_methods!(nested)

    top_keys = [
      :resource,
      :resource_audience,
      :base_url,
      :origin,
      :allow_dynamic_origin,
      :scopes_supported
    ]

    Enum.each(top_keys, fn key ->
      if Keyword.has_key?(opts, key) and Keyword.has_key?(nested, key) and
           Keyword.get(opts, key) != Keyword.get(nested, key) do
        raise ArgumentError, "conflicting top-level and auth option: #{key}"
      end
    end)

    top = Keyword.take(opts, top_keys)

    [resource_path: path]
    |> Keyword.merge(nested)
    |> Keyword.merge(top)
    |> Keyword.put(:bearer_methods, [:header])
    |> Keyword.put_new(:principal, &__MODULE__.default_principal/2)
  end

  defp validate_static_bearer_methods!(options) do
    bearer_methods = Keyword.get_values(options, :bearer_methods)

    if bearer_methods != [] and
         not Enum.all?(bearer_methods, &resolver_header_bearer_methods?/1) do
      raise ArgumentError,
            ":auth bearer_methods must contain only :header so protected-resource metadata remains exact"
    end
  end

  defp validate_auth_options!(auth_opts) do
    validate_auth_assign_keys!(auth_opts)
    validate_scope_list_option!(auth_opts, :scopes_supported, allow_empty: false)
    validate_resource_configuration!(auth_opts)

    if not pinned_resource?(auth_opts) do
      raise ArgumentError,
            "auth must pin :resource/:resource_audience or :base_url/:origin; " <>
              "set :allow_dynamic_origin only for explicitly local development"
    end

    if not usable_auth_configuration?(auth_opts) do
      raise ArgumentError,
            "auth must configure an executable Attesto verifier (config or issuer)"
    end

    :ok
  end

  defp validate_auth_assign_keys!(auth_opts) do
    configured =
      Enum.map(@resolver_assign_keys, fn {option, canonical_key} ->
        {option, canonical_key, Keyword.get(auth_opts, option, canonical_key)}
      end)

    configured_keys = Enum.map(configured, &elem(&1, 2))
    canonical_keys = Map.values(@resolver_assign_keys)

    valid? =
      Enum.all?(configured_keys, &valid_auth_assign_key?/1) and
        length(configured_keys) == length(Enum.uniq(configured_keys)) and
        Enum.all?(configured, fn {_option, canonical_key, configured_key} ->
          configured_key == canonical_key or configured_key not in canonical_keys
        end)

    unless valid? do
      raise ArgumentError,
            "auth assign keys must be distinct non-nil, non-boolean atoms and cannot reuse " <>
              "another package-owned key"
    end
  end

  defp valid_auth_assign_key?(key), do: is_atom(key) and key not in [nil, true, false]

  defp validate_auth_resolver!(resolver) when is_function(resolver, 0) do
    case Function.info(resolver, :type) do
      {:type, :external} -> :ok
      _ -> invalid_auth_resolver!()
    end
  end

  defp validate_auth_resolver!({module, function})
       when is_atom(module) and is_atom(function) do
    validate_portable_mfa!({module, function})
  end

  defp validate_auth_resolver!({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args) do
    validate_portable_mfa!({module, function, args})
  end

  defp validate_auth_resolver!(_resolver), do: invalid_auth_resolver!()

  defp invalid_auth_resolver! do
    raise ArgumentError,
          ":auth must be a keyword list or a zero-arity remote callback/MFA returning one"
  end

  defp validate_portable_mfa!(resolver) do
    if resolver |> Macro.escape() |> Macro.quoted_literal?() do
      :ok
    else
      raise ArgumentError,
            ":auth resolver MFA arguments must be portable compile-time literals"
    end
  rescue
    ArgumentError ->
      raise ArgumentError,
            ":auth resolver MFA arguments must be portable compile-time literals"
  end

  defp validate_resolver_static_resource_options!(opts, path) do
    top =
      [resource_path: path]
      |> Keyword.merge(Keyword.take(opts, [:resource, :resource_audience, :base_url, :origin]))

    validate_resource_configuration!(top)
  end

  defp resolve_authentication!(%{auth_resolver: nil} = state), do: state

  defp resolve_authentication!(%{auth_resolver: resolver} = state) do
    nested = invoke_auth_resolver(resolver)
    validate_resolver_boundary_options!(nested, state.path)
    auth_opts = normalize_auth_options(state.auth_source_opts, state.path, nested)
    validate_auth_options!(auth_opts)

    %{
      state
      | auth_opts: auth_opts,
        auth_boundary: prepare_protect_resource(auth_opts)
    }
  end

  defp invoke_auth_resolver(resolver) when is_function(resolver, 0), do: resolver.()

  defp invoke_auth_resolver({module, function})
       when is_atom(module) and is_atom(function),
       do: apply(module, function, [])

  defp invoke_auth_resolver({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args),
       do: apply(module, function, args)

  defp validate_resolver_boundary_options!(options, path) do
    unless Keyword.keyword?(options),
      do: raise(ArgumentError, ":auth resolver must return a keyword list")

    Enum.each(@resolver_assign_keys, fn {key, expected} ->
      if Enum.any?(Keyword.get_values(options, key), &(&1 != expected)) do
        raise ArgumentError,
              ":auth resolver cannot override #{inspect(key)}; expected #{inspect(expected)}"
      end
    end)

    bearer_methods = Keyword.get_values(options, :bearer_methods)

    if bearer_methods != [] and
         not Enum.all?(bearer_methods, &resolver_header_bearer_methods?/1) do
      raise ArgumentError,
            ":auth resolver bearer_methods must contain only :header so protected-resource metadata remains exact"
    end

    if Enum.any?(Keyword.get_values(options, :resource_path), &(&1 != path)) do
      raise ArgumentError,
            ":auth resolver cannot override resource_path; expected #{inspect(path)}"
    end
  end

  defp resolver_header_bearer_methods?(methods) when is_list(methods) and methods != [],
    do: Enum.all?(methods, &(&1 in [:header, "header"]))

  defp resolver_header_bearer_methods?(_methods), do: false

  @doc "Authenticates and serves one HTTP request through the MCP boundary."
  @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
  @impl Plug
  def call(conn, state) do
    started = System.monotonic_time()

    Telemetry.execute(
      [:http_request, :start],
      %{system_time: System.system_time()},
      %{method: conn.method, transport: :http}
    )

    try do
      result =
        cond do
          conn.method == "GET" and metadata_path?(conn, state.path) ->
            state = resolve_authentication!(state)
            metadata(conn, state)

          conn.request_path != state.path ->
            send_resp(conn, 404, "not found")

          true ->
            case resolve_server_state(state) do
              {:ok, state} ->
                validate_scope_policy_overlap!(
                  state.opts[:scope_map],
                  state.opts[:scope_policy]
                )

                cond do
                  request_headers_over_budget?(conn) ->
                    send_resp(conn, 431, "request headers too large")

                  conn.method not in ["POST", "GET", "DELETE"] ->
                    send_resp(conn, 405, "method not allowed")

                  true ->
                    state = resolve_authentication!(state)

                    if invalid_origin?(conn, state),
                      do: send_resp(conn, 403, "forbidden origin"),
                      else: protected(conn, state)
                end

              :unavailable ->
                send_resp(conn, 503, "service unavailable")
            end
        end

      Telemetry.execute([:http_request, :stop], %{duration: System.monotonic_time() - started}, %{
        method: conn.method,
        transport: :http,
        status: result.status
      })

      result
    rescue
      _error -> recover_http_failure(conn, started)
    catch
      _kind, _reason -> recover_http_failure(conn, started)
    end
  end

  defp recover_http_failure(conn, started) do
    Telemetry.execute(
      [:http_request, :exception],
      %{duration: System.monotonic_time() - started},
      %{
        method: conn.method,
        transport: :http,
        status: 500,
        outcome: :exception
      }
    )

    if conn.state in [:sent, :chunked],
      do: conn,
      else: send_resp(conn, 500, "internal server error")
  end

  defp resolve_server_state(%{server: server} = state) do
    available? =
      case server do
        pid when is_pid(pid) -> Process.alive?(pid)
        name when is_atom(name) -> is_pid(Process.whereis(name))
        _ -> false
      end

    if available? do
      options = Server.options(server)
      {:ok, %{state | opts: Keyword.merge(options, state.opts)}}
    else
      :unavailable
    end
  rescue
    _ -> :unavailable
  catch
    _kind, _reason -> :unavailable
  end

  defp protected(conn, state) do
    # POST scope requirements depend on the decoded MCP method/filter, so the
    # literal Attesto ProtectResource boundary is entered by process_post.
    # Session legs have no MCP operation scope and use the conservative read
    # scope as their protected-resource gate.
    case conn.method do
      "POST" ->
        protocol(conn, state)

      _ ->
        case protect_resource(conn, state, :authenticate_only) do
          {:ok, conn} ->
            protocol(conn, state)

          {:halt, auth_conn} ->
            auth_refusal(:invalid_credentials)
            auth_refusal_response(conn, auth_conn, state)
        end
    end
  end

  defp unauthorized(conn, auth_opts) do
    metadata_url = metadata_url(conn, auth_opts)

    body =
      case conn.assigns[:attesto_mcp_oauth_error] do
        error when is_map(error) -> error
        _ -> %{"error" => "invalid_token", "error_description" => "authentication required"}
      end

    conn
    |> put_authenticate_challenge(
      ~s(Bearer resource_metadata="#{metadata_url}"),
      anonymous_authentication?(conn, auth_opts)
    )
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("vary", "authorization")
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(body))
  rescue
    _ -> send_resp(conn, 401, Jason.encode!(%{"error" => "invalid_token"}))
  end

  defp put_authenticate_challenge(conn, challenge),
    do: put_authenticate_challenge(conn, challenge, false)

  defp put_authenticate_challenge(conn, challenge, true),
    do: put_resp_header(conn, "www-authenticate", challenge)

  defp put_authenticate_challenge(conn, challenge, false) do
    case get_resp_header(conn, "www-authenticate") do
      [] -> put_resp_header(conn, "www-authenticate", challenge)
      [_ | _] -> conn
    end
  end

  defp anonymous_authentication?(conn, auth_opts) do
    get_req_header(conn, "authorization") == [] and
      get_req_header(conn, "dpop") == [] and
      not Keyword.has_key?(auth_opts, :credential_from_conn) and
      not body_credential?(conn, auth_opts)
  end

  defp body_credential?(conn, auth_opts) do
    body_enabled? =
      auth_opts
      |> Keyword.get(:bearer_methods, [:header])
      |> List.wrap()
      |> Enum.any?(&(&1 in [:body, "body"]))

    body_enabled? and
      match?(%{"access_token" => token} when is_binary(token) and token != "", conn.body_params)
  end

  defp protocol(conn, state) do
    case conn.method do
      "POST" ->
        post(conn, state)

      "GET" ->
        if not legacy_get_request?(conn) do
          send_resp(conn, 405, "method not allowed")
        else
          case rate_limit_transport(conn, state, :calls) do
            :ok -> legacy_get(conn, state)
            {:error, error} -> error_response(conn, nil, error, state.auth_opts)
          end
        end

      "DELETE" ->
        if not legacy_delete_request?(conn) do
          send_resp(conn, 405, "method not allowed")
        else
          case rate_limit_transport(conn, state, :calls) do
            :ok -> legacy_delete(conn, state)
            {:error, error} -> error_response(conn, nil, error, state.auth_opts)
          end
        end
    end
  end

  defp post(conn, state) do
    # Authenticate before reading or decoding any body. The operation-specific
    # scope is checked again after the bounded decode in process_post/3.
    case protect_resource(conn, state, :authenticate_only) do
      {:ok, authenticated_conn} ->
        post_body(authenticated_conn, state)

      {:halt, auth_conn} ->
        auth_refusal(:invalid_credentials)
        auth_refusal_response(conn, auth_conn, state)
    end
  end

  defp auth_failure_response(conn, auth_conn, state) do
    cond do
      auth_conn.status == 403 -> auth_conn
      auth_conn.status == 401 and auth_conn.state == :sent -> auth_conn
      auth_conn.status == 401 -> unauthorized(auth_conn, state.auth_opts)
      true -> unauthorized(conn, state.auth_opts)
    end
  end

  defp post_body(conn, state) do
    case validate_content_type(conn) do
      :ok ->
        with {:ok, body, conn} <-
               read_body_bounded(conn, state.opts[:max_body_bytes] || 2_000_000) do
          case JSONRPC.decode(body, max_bytes: state.opts[:max_message_bytes] || 1_000_000) do
            {:ok, request} ->
              case process_post(conn, state, request) do
                {:error, %Error{} = error} ->
                  error_response(conn, Map.get(request, :id), error, state.auth_opts)

                {:scope_error, scope_conn, %Error{} = error} ->
                  error_response(scope_conn, Map.get(request, :id), error, state.auth_opts)

                {:auth_halt, auth_conn} ->
                  auth_refusal_response(conn, auth_conn, state)

                result ->
                  result
              end

            {:error, %Error{} = error} ->
              error_response(
                conn,
                JSONRPC.recover_id(body, max_bytes: state.opts[:max_message_bytes] || 1_000_000),
                error,
                state.auth_opts
              )
          end
        else
          {:error, %Error{} = error} -> error_response(conn, nil, error, [])
        end

      {:error, %Error{} = error} ->
        error_response(conn, nil, error, state.auth_opts)
    end
  end

  defp process_post(conn, state, request) do
    with era <- era_for(request, conn),
         result <-
           require_scopes(
             conn,
             state,
             http_required_scopes_for(state, request)
           ),
         {:ok, conn} <- result,
         :ok <- reject_client_response(request, era),
         :ok <- validate_content_type(conn),
         :ok <- accept_header(conn),
         :ok <- rate_limit_request(conn, state, request),
         :ok <- validate_modern_headers(conn, request, era, state),
         :ok <- validate_legacy_session(request, conn, state, era),
         {:ok, conn, session_id} <- maybe_initialize_session(conn, request, state, era),
         {:ok, session_context} <-
           session_context_for_post(state, session_id, conn, request, era),
         {:ok, base_context} <- handler_context(conn, state) do
      context =
        base_context
        |> Map.put(:session_id, session_id)
        |> Map.put(:scope_map, dispatch_scope_map(state, request))
        |> Map.put(:default_scopes, state.opts[:default_scopes])
        |> Map.put(
          :definition_scope_policy,
          scope_policy_for(request, state) in [:visible_definitions, :selected_definition]
        )
        |> Map.merge(session_context)
        |> maybe_subscription_authorizer(request, conn, state)
        |> Map.put(:owner, request_owner(era, session_id))

      cond do
        request.kind == :request and
          request.method == "subscriptions/listen" and
            not subscription_reauthorization_available?(state.auth_opts) ->
          error_response(
            conn,
            Map.get(request, :id),
            Error.internal(%{"reason" => "subscription_reauthorization_unavailable"}),
            state.auth_opts
          )

        request.kind == :response and era == @legacy ->
          dispatch_legacy_response(conn, state, request, session_id)

        request.kind == :notification ->
          dispatch_notification(
            state.server,
            request,
            context,
            era,
            conn,
            session_id,
            definition_scope_authorizer(conn, state, request)
          )

        true ->
          dispatch_response(
            conn,
            state,
            request,
            context,
            era,
            streaming_request?(request, state),
            session_id,
            definition_scope_authorizer(conn, state, request)
          )
      end
    else
      {:scope_halt, scope_conn, scopes} ->
        {:scope_error, scope_conn, Error.insufficient_scope(scopes)}

      {:halt, auth_conn} ->
        {:auth_halt, auth_conn}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  # Definition policies replace only the package-level HTTP gate for the
  # selected method. The core still receives the remaining configured scope
  # map, while its method-level authorization sees no synthetic policy atom.
  defp http_required_scopes_for(state, request) do
    case scope_policy_for(request, state) do
      mode when mode in [:visible_definitions, :selected_definition] -> []
      _ -> required_scopes_for(request, Keyword.merge(state.auth_opts, state.opts))
    end
  end

  defp dispatch_scope_map(state, request) do
    scope_map = state.opts[:scope_map] || %{}

    case scope_policy_for(request, state) do
      mode when mode in [:visible_definitions, :selected_definition] ->
        Map.delete(scope_map, request.method)

      _ ->
        scope_map
    end
  end

  defp scope_policy_for(%{method: method}, state) when is_binary(method) do
    case state.opts[:scope_policy] do
      policy when is_map(policy) -> Map.get(policy, method)
      _ -> nil
    end
  end

  defp scope_policy_for(_request, _state), do: nil

  defp definition_scope_authorizer(conn, state, request) do
    if scope_policy_for(request, state) in [:visible_definitions, :selected_definition] do
      fn required_scopes ->
        try do
          checked =
            AttestoMCP.Plug.ProtectResource.authorize(
              conn,
              state.auth_boundary,
              List.wrap(required_scopes)
            )

          if checked.halted, do: :denied, else: :ok
        rescue
          _ -> :denied
        catch
          _, _ -> :denied
        end
      end
    end
  end

  defp protect_resource(conn, state, _scopes) do
    conn = clear_auth_assigns(conn, state.auth_opts)

    try do
      checked = AttestoMCP.Plug.ProtectResource.authenticate(conn, state.auth_boundary)

      if checked.halted,
        do: {:halt, checked},
        else: {:ok, canonicalize_auth_assigns(checked, state.auth_opts)}
    rescue
      _error ->
        auth_policy_failure(:verifier, :exception)
        {:halt, auth_halt(conn, 401)}
    catch
      kind, _reason ->
        auth_policy_failure(:verifier, kind)
        {:halt, auth_halt(conn, 401)}
    end
  end

  # Authentication owns both the configured assign keys and the package's
  # canonical aliases. Clear any upstream values before verification so an
  # optional nil principal cannot inherit an attacker-controlled assign.
  defp clear_auth_assigns(conn, auth_opts) do
    configured_keys =
      Enum.map(@resolver_assign_keys, fn {option, canonical_key} ->
        Keyword.get(auth_opts, option, canonical_key)
      end)

    auth_keys = Enum.uniq(Map.values(@resolver_assign_keys) ++ configured_keys)
    %{conn | assigns: Map.drop(conn.assigns, auth_keys)}
  end

  # Static auth configuration may retain host-selected assign keys. Keep those
  # assigns intact while copying verified values to the package-owned keys used
  # for dispatch, ownership, rate limiting, and subscription reauthorization.
  # Resolver-backed auth already requires the canonical keys.
  defp canonicalize_auth_assigns(conn, auth_opts) do
    authenticated_assigns = conn.assigns

    Enum.reduce(@resolver_assign_keys, conn, fn {option, canonical_key}, conn ->
      configured_key = Keyword.get(auth_opts, option, canonical_key)

      cond do
        configured_key == canonical_key ->
          conn

        Map.has_key?(authenticated_assigns, configured_key) ->
          assign(conn, canonical_key, Map.fetch!(authenticated_assigns, configured_key))

        true ->
          %{conn | assigns: Map.delete(conn.assigns, canonical_key)}
      end
    end)
  end

  # The initial ProtectResource call authenticates before reading the body.
  # Route-aware scopes are then checked with Attesto's native RequireScopes
  # plug, avoiding a second DPoP proof verification/replay decision.
  defp require_scopes(conn, state, scopes) do
    checked =
      AttestoMCP.Plug.ProtectResource.authorize(
        conn,
        state.auth_boundary,
        List.wrap(scopes)
      )

    if checked.halted do
      auth_refusal(if(checked.status == 403, do: :insufficient_scope, else: :invalid_credentials))
      {:scope_halt, checked, List.wrap(scopes)}
    else
      {:ok, checked}
    end
  rescue
    _ ->
      auth_refusal(:invalid_credentials)
      {:halt, auth_halt(conn, 401)}
  end

  defp prepare_protect_resource(auth_opts) do
    endpoint_path = auth_opts[:resource_path] || "/mcp"
    explicit_resource = auth_opts[:resource]
    explicit_audience = auth_opts[:resource_audience]

    canonical_resource =
      cond do
        absolute_resource?(explicit_audience) -> explicit_audience
        absolute_resource?(explicit_resource) -> explicit_resource
        true -> nil
      end

    audience =
      cond do
        absolute_resource?(explicit_audience) -> explicit_audience
        absolute_resource?(explicit_resource) -> explicit_resource
        absolute_origin?(auth_opts[:base_url] || auth_opts[:origin]) -> :resource
        auth_opts[:allow_dynamic_origin] == true -> :resource
        true -> nil
      end

    auth_opts
    |> maybe_pin_resource_origin(canonical_resource)
    |> Keyword.delete(:scopes)
    |> Keyword.delete(:allow_dynamic_origin)
    |> Keyword.delete(:resource)
    |> Keyword.delete(:resource_audience)
    |> Keyword.put(:resource, endpoint_path)
    |> maybe_put_public_audience(audience)
    |> Keyword.put(:send_error, &__MODULE__.attesto_send_error/3)
    |> AttestoMCP.Plug.ProtectResource.prepare()
  end

  defp maybe_pin_resource_origin(opts, resource) when is_binary(resource) do
    if absolute_origin?(opts[:base_url] || opts[:origin]) do
      opts
    else
      %URI{scheme: scheme, host: host, port: port} = URI.parse(resource)

      Keyword.put(
        opts,
        :base_url,
        "#{scheme}://#{format_host(host)}#{origin_port_suffix(scheme, port)}"
      )
    end
  end

  defp maybe_pin_resource_origin(opts, _resource), do: opts

  defp maybe_put_public_audience(opts, nil), do: opts

  defp maybe_put_public_audience(opts, audience),
    do: Keyword.put(opts, :resource_audience, audience)

  defp auth_halt(conn, status) do
    conn
    |> put_status(status)
    |> halt()
  end

  @doc false
  @spec attesto_send_error(Plug.Conn.t(), integer(), term()) :: Plug.Conn.t()
  def attesto_send_error(conn, status, body) do
    conn
    |> assign(:attesto_mcp_oauth_error, body)
    |> put_status(status)
    |> halt()
  end

  defp auth_refusal(category) do
    Telemetry.execute([:auth, :refusal], %{count: 1}, %{category: category, transport: :http})
  end

  defp auth_policy_failure(category, error) do
    Telemetry.execute(
      [:auth, :policy_failure],
      %{count: 1},
      %{category: category, error: error}
    )
  end

  defp rate_limit_request(conn, state, request) do
    method = Map.get(request, :method)

    category =
      cond do
        method in ["completion/complete"] -> :completion
        method == "subscriptions/listen" -> :subscriptions
        true -> :calls
      end

    rate_limit_transport(conn, state, category)
  end

  defp rate_limit_transport(conn, state, category) do
    key = {:principal, principal(conn), conn.remote_ip}

    try do
      case Server.allow_rate(state.server, key, category) do
        :ok -> :ok
        {:error, :rate_limited} -> {:error, Error.rate_limited()}
      end
    rescue
      _ -> {:error, Error.rate_limited()}
    catch
      _, _ -> {:error, Error.rate_limited()}
    end
  end

  defp auth_refusal_response(conn, auth_conn, state) do
    # Consume the auth-failure bucket before rendering the refusal. This keeps
    # each attempt to one response and allows the first exhausted request to
    # become a clean 429 instead of trying to overwrite a sent 401.
    case consume_auth_failure(state.server, conn.remote_ip) do
      :rate_limited ->
        cond do
          conn.state in [:sent, :chunked] -> conn
          auth_conn.state in [:sent, :chunked] -> auth_conn
          true -> send_resp(conn, 429, Jason.encode!(%{"error" => "rate_limited"}))
        end

      :ok ->
        auth_failure_response(conn, auth_conn, state)
    end
  end

  defp consume_auth_failure(server, remote_ip) do
    case Server.allow_rate(server, {:ip, remote_ip}, :auth_failures) do
      :ok -> :ok
      {:error, :rate_limited} -> :rate_limited
    end
  rescue
    _ -> :rate_limited
  catch
    _, _ -> :rate_limited
  end

  defp dispatch_notification(
         conn_server,
         request,
         context,
         era,
         conn,
         session_id,
         definition_authorizer
       ) do
    _ =
      AttestoMCP.Server.dispatch(conn_server, request, context,
        version: dispatch_version(era, request, context),
        transport: :http,
        owner: context[:owner],
        definition_authorizer: definition_authorizer
      )

    if era == @legacy and request.method == "notifications/initialized" and session_id,
      do: AttestoMCP.Server.mark_initialized(conn_server, session_id)

    send_resp(conn, 202, "")
  end

  defp session_context(_state, nil, _conn, _request), do: {:ok, %{}}

  defp session_context(state, session_id, conn, request) do
    case legacy_session_lookup(
           state.server,
           session_id,
           principal(conn),
           tenant(conn),
           request
         ) do
      {:ok, session} ->
        {:ok,
         %{
           client_capabilities: session.client_capabilities,
           protocol_version: session.version,
           logging_level: session.logging_level
         }}

      _ ->
        {:error, Error.invalid_request(%{"reason" => "legacy_session_unavailable"})}
    end
  rescue
    _ -> {:error, Error.internal(%{"reason" => "legacy_session_lookup_failed"})}
  catch
    _, _ -> {:error, Error.internal(%{"reason" => "legacy_session_lookup_failed"})}
  end

  defp session_context_for_post(state, session_id, conn, request, era) do
    case session_context(state, session_id, conn, request) do
      {:ok, _context} = result ->
        result

      {:error, _error} = result ->
        if era == @legacy and request.kind == :request and request.method == "initialize" and
             is_binary(session_id) do
          _ = AttestoMCP.Server.delete_session(state.server, session_id)
        end

        result
    end
  end

  defp dispatch_version(@modern, _request, _context), do: @modern
  defp dispatch_version(@legacy, %{method: "initialize"}, _context), do: @legacy

  defp dispatch_version(@legacy, %{method: "ping"}, context)
       when not is_map_key(context, :protocol_version),
       do: @legacy

  defp dispatch_version(@legacy, _request, context), do: context[:protocol_version]

  defp dispatch_legacy_response(conn, state, request, session_id) do
    case AttestoMCP.Server.deliver_client_response(
           state.server,
           session_id,
           principal(conn),
           tenant(conn),
           request
         ) do
      :ok ->
        send_resp(conn, 202, "")

      {:error, {:client_error, _error}} ->
        send_resp(conn, 202, "")

      {:error, :invalid_response} ->
        error_response(
          conn,
          Map.get(request, :id),
          Error.invalid_request(%{"reason" => "invalid_client_response"}),
          state.auth_opts
        )

      {:error, :not_found} ->
        error_response(
          conn,
          Map.get(request, :id),
          Error.invalid_request(%{"reason" => "unsolicited_response"}),
          state.auth_opts
        )
    end
  end

  defp dispatch_response(
         conn,
         state,
         request,
         context,
         era,
         stream?,
         session_id,
         definition_authorizer
       ) do
    owner = request_owner(era, session_id)

    if stream? do
      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_header("vary", "authorization")
        |> put_resp_header("x-accel-buffering", "no")
        |> send_chunked(200)

      if request.method == "subscriptions/listen" and era == @modern do
        dispatch_subscription_stream(conn, state, request, context, era, session_id)
      else
        Process.put(:attesto_mcp_http_stream_conn, conn)

        on_event = fn
          :keepalive ->
            case chunk(Process.get(:attesto_mcp_http_stream_conn, conn), ": keepalive\n\n") do
              {:ok, updated} ->
                Process.put(:attesto_mcp_http_stream_conn, updated)
                :ok

              {:error, reason} ->
                {:error, reason}
            end

          event ->
            case chunk(Process.get(:attesto_mcp_http_stream_conn, conn), sse_event(event)) do
              {:ok, updated} ->
                Process.put(:attesto_mcp_http_stream_conn, updated)
                :ok

              {:error, reason} ->
                {:error, reason}
            end
        end

        case AttestoMCP.Server.dispatch(state.server, request, context,
               version: dispatch_version(era, request, context),
               transport: :http,
               owner: owner,
               on_event: on_event,
               keepalive_ms: state.opts[:stream_keepalive_ms],
               definition_authorizer: definition_authorizer
             ) do
          {_id, response} ->
            conn = Process.get(:attesto_mcp_http_stream_conn, conn)

            case chunk(conn, sse_event(response)) do
              {:error, _reason} ->
                Telemetry.execute([:stream, :exception], %{count: 1}, %{
                  transport: :http,
                  outcome: :delivery_failed
                })

              {:ok, _conn} ->
                :ok
            end

            maybe_touch(state.server, session_id)
            Process.delete(:attesto_mcp_http_stream_conn)
            conn

          _ ->
            Process.delete(:attesto_mcp_http_stream_conn)
            conn
        end
      end
    else
      case AttestoMCP.Server.dispatch(state.server, request, context,
             version: dispatch_version(era, request, context),
             transport: :http,
             owner: owner,
             definition_authorizer: definition_authorizer
           ) do
        {_id, response} ->
          status = if Map.has_key?(response, "error"), do: error_status(response, era), else: 200
          maybe_set_session_version(state.server, session_id, request, response, era)

          if era == @legacy and request.method == "initialize" and
               Map.has_key?(response, "error"),
             do: AttestoMCP.Server.delete_session(state.server, session_id)

          conn =
            if not is_nil(session_id) and
                 not (era == @legacy and request.method == "initialize" and
                        Map.has_key?(response, "error")),
               do: put_resp_header(conn, "mcp-session-id", session_id),
               else: conn

          send_json(conn, status, response)

        :notification ->
          send_resp(conn, 202, "")
      end
    end
  end

  defp dispatch_subscription_stream(conn, state, request, context, era, session_id) do
    request_ref = make_ref()
    parent = self()

    Telemetry.execute([:stream, :open], %{count: 1}, %{transport: :http, method: request.method})

    on_event = fn event -> send(parent, {:mcp_subscription_pre_ack, request_ref, event}) end

    result =
      AttestoMCP.Server.dispatch(state.server, request, context,
        version: dispatch_version(era, request, context),
        transport: :http,
        owner: self(),
        on_event: on_event,
        request_ref: request_ref
      )

    case result do
      {_id, response} ->
        subscription_id =
          get_in(response, ["result", "_meta", "io.modelcontextprotocol/subscriptionId"])

        conn = flush_subscription_pre_ack(conn, state, request_ref)

        if is_binary(subscription_id) or is_integer(subscription_id) do
          subscription_stream(conn, state, subscription_id, request_ref, session_id, response)
        else
          _ = chunk(conn, sse_event(response))
          maybe_touch(state.server, session_id)

          Telemetry.execute([:stream, :close], %{count: 1}, %{
            transport: :http,
            outcome: :completed
          })

          conn
        end

      _ ->
        Telemetry.execute([:stream, :close], %{count: 1}, %{
          transport: :http,
          outcome: :error
        })

        conn
    end
  end

  defp flush_subscription_pre_ack(conn, state, request_ref) do
    receive do
      {:mcp_subscription, ^request_ref, _subscription_id, event} ->
        case emit_subscription(conn, state.server, event_subscription_id(event), event) do
          {:ok, conn} ->
            if event["method"] != "notifications/subscriptions/acknowledged" do
              AttestoMCP.Server.ack_subscription(
                state.server,
                event_subscription_id(event),
                self()
              )
            end

            flush_subscription_pre_ack(conn, state, request_ref)

          {:closed, conn} ->
            conn
        end

      {:mcp_subscription_pre_ack, ^request_ref, event} ->
        case emit_subscription(conn, state.server, event_subscription_id(event), event) do
          {:ok, conn} -> flush_subscription_pre_ack(conn, state, request_ref)
          {:closed, conn} -> conn
        end
    after
      0 -> conn
    end
  end

  defp subscription_stream(conn, state, subscription_id, request_ref, session_id, final_response) do
    keepalive_ms = state.opts[:stream_keepalive_ms] || state.opts[:legacy_keepalive_ms]

    if is_integer(keepalive_ms) and keepalive_ms > 0 and
         is_nil(Process.get({:mcp_subscription_keepalive, request_ref})) do
      schedule_subscription_keepalive(request_ref, keepalive_ms)
    end

    receive do
      {:mcp_subscription_keepalive, ^request_ref} ->
        Process.delete({:mcp_subscription_keepalive, request_ref})

        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} ->
            if is_integer(keepalive_ms) and keepalive_ms > 0,
              do: schedule_subscription_keepalive(request_ref, keepalive_ms)

            subscription_stream(
              conn,
              state,
              subscription_id,
              request_ref,
              session_id,
              final_response
            )

          {:error, _reason} ->
            cancel_subscription_keepalive(request_ref)
            close_owned_subscription(state.server, subscription_id)
            conn
        end

      {:mcp_subscription, ^request_ref, ^subscription_id, event} ->
        case emit_subscription(conn, state.server, subscription_id, event) do
          {:ok, conn} ->
            if event["method"] != "notifications/subscriptions/acknowledged" do
              AttestoMCP.Server.ack_subscription(state.server, subscription_id, self())
            end

            subscription_stream(
              conn,
              state,
              subscription_id,
              request_ref,
              session_id,
              final_response
            )

          {:closed, conn} ->
            cancel_subscription_keepalive(request_ref)
            conn
        end

      {:mcp_subscription_pre_ack, ^request_ref, event} ->
        case emit_subscription(conn, state.server, subscription_id, event) do
          {:ok, conn} ->
            subscription_stream(
              conn,
              state,
              subscription_id,
              request_ref,
              session_id,
              final_response
            )

          {:closed, conn} ->
            cancel_subscription_keepalive(request_ref)
            conn
        end

      {:mcp_subscription_backpressure, ^subscription_id} ->
        subscription_stream(conn, state, subscription_id, request_ref, session_id, final_response)

      {:mcp_subscription_cancel, ^subscription_id} ->
        cancel_subscription_keepalive(request_ref)
        cancel_owned_subscription(state.server, subscription_id)
        maybe_touch(state.server, session_id)

        Telemetry.execute([:stream, :close], %{count: 1}, %{transport: :http, outcome: :cancelled})

        emit_final_subscription_response(conn, state.server, subscription_id, final_response)

      {:mcp_subscription_close, ^subscription_id} ->
        cancel_subscription_keepalive(request_ref)
        close_owned_subscription(state.server, subscription_id)
        maybe_touch(state.server, session_id)
        Telemetry.execute([:stream, :close], %{count: 1}, %{transport: :http, outcome: :closed})
        emit_final_subscription_response(conn, state.server, subscription_id, final_response)
    after
      state.opts[:subscription_timeout] || 300_000 ->
        cancel_subscription_keepalive(request_ref)
        close_owned_subscription(state.server, subscription_id)
        maybe_touch(state.server, session_id)
        Telemetry.execute([:stream, :close], %{count: 1}, %{transport: :http, outcome: :timeout})
        emit_final_subscription_response(conn, state.server, subscription_id, final_response)
    end
  end

  defp schedule_subscription_keepalive(request_ref, keepalive_ms) do
    timer = Process.send_after(self(), {:mcp_subscription_keepalive, request_ref}, keepalive_ms)
    Process.put({:mcp_subscription_keepalive, request_ref}, timer)
  end

  defp cancel_subscription_keepalive(request_ref) do
    case Process.delete({:mcp_subscription_keepalive, request_ref}) do
      timer when is_reference(timer) ->
        _ = Process.cancel_timer(timer)

        receive do
          {:mcp_subscription_keepalive, ^request_ref} -> :ok
        after
          0 -> :ok
        end

      _ ->
        :ok
    end
  end

  defp close_owned_subscription(server, subscription_id) do
    AttestoMCP.Server.close_subscription(server, subscription_id, self())
    drain_subscription_controls(subscription_id)
  end

  defp cancel_owned_subscription(server, subscription_id) do
    AttestoMCP.Server.cancel_subscription(server, subscription_id, self())
    drain_subscription_controls(subscription_id)
  end

  defp drain_subscription_controls(subscription_id) do
    receive do
      {:mcp_subscription_close, ^subscription_id} ->
        drain_subscription_controls(subscription_id)

      {:mcp_subscription_cancel, ^subscription_id} ->
        drain_subscription_controls(subscription_id)
    after
      0 -> :ok
    end
  end

  defp event_subscription_id(%{
         "params" => %{"_meta" => %{"io.modelcontextprotocol/subscriptionId" => id}}
       }),
       do: id

  defp event_subscription_id(_), do: nil

  defp emit_subscription(conn, server, subscription_id, event) do
    case chunk(conn, sse_event(event)) do
      {:ok, conn} ->
        {:ok, conn}

      {:error, _reason} ->
        Telemetry.execute([:stream, :exception], %{count: 1}, %{
          transport: :http,
          outcome: :closed
        })

        if not is_nil(subscription_id), do: close_owned_subscription(server, subscription_id)

        {:closed, conn}
    end
  end

  defp emit_final_subscription_response(conn, server, subscription_id, response) do
    case chunk(conn, sse_event(response)) do
      {:ok, conn} ->
        conn

      {:error, _reason} ->
        Telemetry.execute([:stream, :exception], %{count: 1}, %{
          transport: :http,
          outcome: :closed
        })

        if not is_nil(subscription_id), do: close_owned_subscription(server, subscription_id)

        conn
    end
  end

  defp legacy_get(conn, state) do
    with {:ok, session_id} <- header_session(conn),
         {:ok, session} <-
           AttestoMCP.Server.get_session(state.server, session_id, principal(conn), tenant(conn)) do
      cond do
        not session.initialized ->
          send_resp(conn, 404, "session not found")

        true ->
          case validate_legacy_version(conn, session) do
            :ok -> open_legacy_get_stream(conn, state, session_id)
            {:error, %Error{} = error} -> error_response(conn, nil, error, state.auth_opts)
          end
      end
    else
      _ -> send_resp(conn, 404, "session not found")
    end
  end

  defp open_legacy_get_stream(conn, state, session_id) do
    case AttestoMCP.Server.open_legacy_stream(
           state.server,
           session_id,
           principal(conn),
           tenant(conn),
           self(),
           legacy_stream_authorizer(conn, state)
         ) do
      {:ok, stream_ref} ->
        Telemetry.execute([:stream, :open], %{count: 1}, %{transport: :http, method: "legacy"})

        conn =
          conn
          |> put_resp_content_type("text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("vary", "authorization")
          |> put_resp_header("x-accel-buffering", "no")
          |> put_resp_header("connection", "close")
          |> send_chunked(200)

        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} ->
            legacy_stream_loop(conn, state, stream_ref)

          {:error, _reason} ->
            Telemetry.execute([:stream, :close], %{count: 1}, %{
              transport: :http,
              outcome: :closed
            })

            AttestoMCP.Server.close_legacy_stream(state.server, stream_ref)
            conn
        end

      _ ->
        send_resp(conn, 404, "session not found")
    end
  end

  defp legacy_stream_authorizer(conn, state) do
    token = access_token(conn)
    config = auth_config(state.auth_opts)
    canonical = canonical_resource(conn, state.auth_opts)
    initial_context = auth_context(conn)

    fn owner ->
      with {:ok, event_scope_sets} <- owner_required_scope_sets(owner),
           {:ok, required_scope_sets} <-
             prepend_required_scopes(
               legacy_event_scopes(owner[:event], state.opts),
               event_scope_sets
             ) do
        reauthorize_delivery?(
          token,
          config,
          canonical,
          initial_context,
          owner,
          required_scope_sets
        )
      else
        _ -> false
      end
    end
  end

  defp legacy_event_scopes(%{"method" => "notifications/tools/list_changed"}, _opts),
    do: [AttestoMCP.Scopes.tools_read()]

  defp legacy_event_scopes(%{"method" => "notifications/prompts/list_changed"}, _opts),
    do: [AttestoMCP.Scopes.prompts_read()]

  defp legacy_event_scopes(%{"method" => "notifications/resources/list_changed"}, _opts),
    do: [AttestoMCP.Scopes.resources_read()]

  defp legacy_event_scopes(%{"method" => "notifications/resources/updated"}, _opts),
    do: [AttestoMCP.Scopes.resources_read()]

  defp legacy_event_scopes(_, _opts), do: []

  defp legacy_stream_loop(conn, state, stream_ref) do
    receive do
      {:mcp_legacy_event, ^stream_ref, event_id, event} ->
        case chunk(conn, legacy_sse_event(event_id, event)) do
          {:ok, conn} ->
            AttestoMCP.Server.ack_legacy_stream(state.server, stream_ref)
            legacy_stream_loop(conn, state, stream_ref)

          {:error, _reason} ->
            Telemetry.execute([:stream, :exception], %{count: 1}, %{
              transport: :http,
              outcome: :closed
            })

            AttestoMCP.Server.close_legacy_stream(state.server, stream_ref)
            conn
        end

      {:mcp_legacy_close, ^stream_ref, _reason} ->
        Telemetry.execute([:stream, :close], %{count: 1}, %{transport: :http, outcome: :closed})
        AttestoMCP.Server.close_legacy_stream(state.server, stream_ref)
        conn
    after
      state.opts[:stream_keepalive_ms] || state.opts[:legacy_keepalive_ms] || 15_000 ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} ->
            legacy_stream_loop(conn, state, stream_ref)

          {:error, _reason} ->
            Telemetry.execute([:stream, :exception], %{count: 1}, %{
              transport: :http,
              outcome: :closed
            })

            AttestoMCP.Server.close_legacy_stream(state.server, stream_ref)
            conn
        end
    end
  end

  defp legacy_delete(conn, state) do
    with {:ok, session_id} <- header_session(conn),
         {:ok, session} <-
           AttestoMCP.Server.get_session(state.server, session_id, principal(conn), tenant(conn)) do
      case validate_legacy_version(conn, session) do
        :ok ->
          case AttestoMCP.Server.delete_session(state.server, session_id) do
            :ok -> send_resp(conn, 200, "")
            {:error, _reason} -> send_resp(conn, 503, "service unavailable")
          end

        {:error, %Error{} = error} ->
          error_response(conn, nil, error, state.auth_opts)
      end
    else
      _ -> send_resp(conn, 404, "session not found")
    end
  end

  defp maybe_initialize_session(conn, request, state, @legacy)
       when request.kind == :request and request.method == "initialize" do
    case AttestoMCP.Server.new_session(state.server, principal(conn), tenant(conn)) do
      {:ok, session} ->
        {:ok, conn, session.id}

      {:error, reason}
      when reason in [:nonportable_binding, :binding_too_large, :record_too_large] ->
        {:error, Error.internal(%{"reason" => "invalid_session_binding"})}

      _ ->
        {:error, Error.internal(%{"reason" => "session_create_failed"})}
    end
  end

  defp maybe_initialize_session(conn, _request, _state, @modern), do: {:ok, conn, nil}

  defp maybe_initialize_session(conn, _request, _state, _era),
    do: {:ok, conn, session_header(conn)}

  defp validate_legacy_session(_request, conn, _state, @modern) do
    if is_binary(session_header(conn)),
      do: {:error, Error.invalid_header(%{"reason" => "modern_session_forbidden"})},
      else: :ok
  end

  defp validate_legacy_session(request, conn, state, @legacy) do
    if request.kind == :request and request.method == "initialize" do
      with :ok <- validate_legacy_initialize_header(conn, state),
           {:error, :missing_session} <- header_session(conn) do
        :ok
      else
        {:ok, _id} ->
          {:error, Error.invalid_request(%{"reason" => "initialize_session_forbidden"})}

        {:error, %Error{} = error} ->
          {:error, error}
      end
    else
      if Map.get(request, :method) == "ping" and
           header_session(conn) == {:error, :missing_session} do
        :ok
      else
        validate_legacy_session_bound(request, conn, state)
      end
    end
  end

  defp validate_legacy_initialize_header(conn, state) do
    case get_req_header(conn, "mcp-protocol-version") do
      [] ->
        :ok

      [version] ->
        if version in @legacy_versions and version in state.opts[:protocol_versions],
          do: :ok,
          else:
            {:error, Error.invalid_header(%{"reason" => "unsupported_protocol_version_header"})}

      _ ->
        {:error, Error.invalid_header(%{"reason" => "unsupported_protocol_version_header"})}
    end
  end

  defp validate_legacy_session_bound(request, conn, state) do
    with {:ok, id} <- header_session(conn) do
      case legacy_session_lookup(
             state.server,
             id,
             principal(conn),
             tenant(conn),
             request
           ) do
        {:ok, session} ->
          with :ok <- validate_legacy_version(conn, session),
               :ok <-
                 validate_legacy_initialized(
                   request,
                   session,
                   state,
                   id,
                   principal(conn),
                   tenant(conn)
                 ) do
            :ok
          end

        {:error, :not_found} ->
          {:error, Error.session_not_found()}
      end
    else
      _ -> {:error, Error.invalid_request(%{"reason" => "legacy_session_required"})}
    end
  end

  defp legacy_session_lookup(server, id, principal, tenant, %{method: method})
       when method in ["resources/subscribe", "resources/unsubscribe"],
       do: AttestoMCP.Server.peek_session(server, id, principal, tenant)

  defp legacy_session_lookup(server, id, principal, tenant, _request),
    do: AttestoMCP.Server.get_session(server, id, principal, tenant)

  defp validate_legacy_initialized(request, session, state, id, principal, tenant) do
    if session.initialized or Map.get(request, :method) in ["notifications/initialized", "ping"] do
      :ok
    else
      case await_legacy_initialized(
             state.server,
             id,
             principal,
             tenant,
             state.opts[:legacy_initialized_grace_ms] || 50,
             request
           ) do
        :ok -> :ok
        _ -> {:error, Error.invalid_request(%{"reason" => "initialized_notification_required"})}
      end
    end
  end

  defp await_legacy_initialized(server, id, principal, tenant, timeout, %{method: method})
       when method in ["resources/subscribe", "resources/unsubscribe"],
       do:
         AttestoMCP.Server.await_initialized_without_touch(
           server,
           id,
           principal,
           tenant,
           timeout
         )

  defp await_legacy_initialized(server, id, principal, tenant, timeout, _request),
    do: AttestoMCP.Server.await_initialized(server, id, principal, tenant, timeout)

  defp validate_legacy_version(conn, session) do
    case get_req_header(conn, "mcp-protocol-version") do
      [] -> :ok
      [version] when version == session.version -> :ok
      [_] -> {:error, Error.invalid_header(%{"reason" => "negotiated_version_mismatch"})}
      _ -> {:error, Error.invalid_header(%{"reason" => "duplicate_protocol_version"})}
    end
  end

  defp required_scopes_for(%{method: "subscriptions/listen", params: params}, opts) do
    subscription_scope_for(params["notifications"], opts)
  end

  defp required_scopes_for(%{kind: :response}, _opts), do: []

  defp required_scopes_for(%{method: "completion/complete", params: params}, opts) do
    case configured_scope_for("completion/complete", opts) do
      {:ok, scopes} ->
        scopes

      :error ->
        case params["ref"] do
          %{"type" => "ref/resource"} -> default_scope_for("resources/read")
          _ -> default_scope_for("completion/complete")
        end
    end
  end

  defp required_scopes_for(%{method: method}, opts), do: scope_for(method, opts)
  defp required_scopes_for(_request, _opts), do: []

  defp subscription_scope_for(notifications, opts) when is_map(notifications) do
    category_scopes =
      case configured_default_scopes(opts) do
        {:ok, scopes} ->
          case configured_scope_for("subscriptions/listen", opts) do
            {:ok, _explicit_scopes} -> generic_subscription_category_scopes(notifications)
            :error -> scopes
          end

        :error ->
          generic_subscription_category_scopes(notifications)
      end

    Enum.uniq(category_scopes ++ configured_subscription_scopes(opts))
  end

  defp subscription_scope_for(_notifications, opts),
    do: configured_subscription_scopes(opts)

  defp generic_subscription_category_scopes(notifications) do
    [
      {"toolsListChanged", AttestoMCP.Scopes.tools_read()},
      {"promptsListChanged", AttestoMCP.Scopes.prompts_read()},
      {"resourcesListChanged", AttestoMCP.Scopes.resources_read()},
      {"resourceSubscriptions", AttestoMCP.Scopes.resources_read()}
    ]
    |> Enum.filter(fn {key, _scope} ->
      case key do
        "resourceSubscriptions" ->
          is_list(Map.get(notifications, key, Map.get(notifications, :resourceSubscriptions))) and
            Map.get(notifications, key, Map.get(notifications, :resourceSubscriptions)) != []

        _ ->
          Map.get(notifications, key, Map.get(notifications, filter_atom_key(key), false)) == true
      end
    end)
    |> Enum.map(&elem(&1, 1))
  end

  defp filter_atom_key("toolsListChanged"), do: :toolsListChanged
  defp filter_atom_key("promptsListChanged"), do: :promptsListChanged
  defp filter_atom_key("resourcesListChanged"), do: :resourcesListChanged

  defp configured_subscription_scopes(opts) do
    configured =
      case configured_scope_for("subscriptions/listen", opts) do
        {:ok, scopes} -> scopes
        :error -> configured_default_scopes_value(opts)
      end

    explicit = Keyword.get(opts, :subscription_scopes, [])
    Enum.filter(List.wrap(configured) ++ List.wrap(explicit), &is_binary/1)
  end

  defp scope_for(method, opts) do
    case configured_scope_for(method, opts) do
      {:ok, scopes} ->
        scopes

      :error ->
        case configured_default_scopes(opts) do
          {:ok, scopes} -> scopes
          :error -> default_scope_for(method)
        end
    end
  end

  defp configured_scope_for(method, opts) do
    case Map.get(opts[:scope_map] || %{}, method) do
      scopes when is_list(scopes) and scopes != [] -> {:ok, scopes}
      _ -> :error
    end
  end

  defp configured_default_scopes(opts) do
    case Keyword.get(opts, :default_scopes) do
      scopes when is_list(scopes) and scopes != [] -> {:ok, scopes}
      _ -> :error
    end
  end

  defp configured_default_scopes_value(opts) do
    case configured_default_scopes(opts) do
      {:ok, scopes} -> scopes
      :error -> []
    end
  end

  defp default_scope_for(method) when method in ["tools/list"],
    do: [AttestoMCP.Scopes.tools_read()]

  defp default_scope_for(method) when method in ["tools/call"],
    do: [AttestoMCP.Scopes.tools_call()]

  defp default_scope_for(method)
       when method in ["resources/list", "resources/read", "resources/templates/list"],
       do: [AttestoMCP.Scopes.resources_read()]

  defp default_scope_for(method)
       when method in ["resources/subscribe", "resources/unsubscribe"],
       do: [AttestoMCP.Scopes.resources_read()]

  defp default_scope_for(method)
       when method in ["prompts/list", "prompts/get", "completion/complete"],
       do: [AttestoMCP.Scopes.prompts_read()]

  defp default_scope_for(_), do: []

  defp validate_modern_headers(_conn, _request, @legacy, _state), do: :ok

  defp validate_modern_headers(conn, request, @modern, state) do
    meta = if is_map(request.params), do: Map.get(request.params, "_meta"), else: nil

    cond do
      not is_map(meta) ->
        {:error, Error.invalid_params(%{"reason" => "meta_required"})}

      not is_binary(meta["io.modelcontextprotocol/protocolVersion"]) ->
        {:error, Error.invalid_params(%{"reason" => "protocolVersion_required"})}

      not is_map(meta["io.modelcontextprotocol/clientCapabilities"]) ->
        {:error, Error.invalid_params(%{"reason" => "clientCapabilities_required"})}

      true ->
        body_version = meta["io.modelcontextprotocol/protocolVersion"]

        with {:ok, version} <- required_header(conn, "mcp-protocol-version"),
             true <- version == body_version,
             {:ok, method} <- required_header(conn, "mcp-method"),
             true <- method == request.method,
             :ok <- maybe_header_match(conn, "mcp-name", request_name(request)),
             :ok <- validate_declared_headers(conn, request, state) do
          :ok
        else
          _ -> {:error, Error.invalid_header(%{"reason" => "body_header_mismatch"})}
        end
    end
  end

  defp maybe_header_match(_conn, _name, nil), do: :ok

  defp maybe_header_match(conn, name, expected) do
    case request_header_values(conn, name) do
      [] ->
        {:error, :missing_header}

      [value] ->
        if sentinel_match?(decode_sentinel(value), expected), do: :ok, else: {:error, :mismatch}

      _ ->
        {:error, :duplicate_header}
    end
  end

  defp validate_declared_headers(conn, request, state) do
    declarations = registered_header_declarations(state.server, request)

    declared_names =
      MapSet.new(Enum.map(declarations, fn {name, _key} -> String.downcase(name) end))

    with :ok <- valid_declared_names(Enum.map(declarations, &{elem(&1, 0), nil})),
         :ok <- validate_registered_headers(conn, request, declarations),
         :ok <- reject_undeclared_param_headers(conn, declared_names) do
      :ok
    end
  end

  defp validate_registered_headers(conn, request, declarations) do
    arguments = request.params["arguments"] || %{}

    Enum.reduce_while(declarations, :ok, fn {name, path}, :ok ->
      expected = fetch_argument(arguments, path)
      normalized = String.downcase(name)

      case request_header_values(conn, normalized) do
        [] when expected in [:missing, {:ok, nil}] ->
          {:cont, :ok}

        [_value] when expected in [:missing, {:ok, nil}] ->
          {:halt, {:error, :declared_header_mismatch}}

        [value] ->
          if match?({:ok, _}, expected) and
               sentinel_match?(decode_sentinel(value), elem(expected, 1)),
             do: {:cont, :ok},
             else: {:halt, {:error, :declared_header_mismatch}}

        _ ->
          {:halt, {:error, :declared_header_mismatch}}
      end
    end)
  end

  defp reject_undeclared_param_headers(conn, declared_names) do
    conn.req_headers
    |> Enum.filter(fn {name, _value} ->
      String.starts_with?(String.downcase(name), "mcp-param-")
    end)
    |> Enum.reduce_while(:ok, fn {name, _value}, :ok ->
      if MapSet.member?(declared_names, String.downcase(name)),
        do: {:cont, :ok},
        else: {:halt, {:error, :undeclared_header}}
    end)
  end

  defp registered_header_declarations(server, %{method: "tools/call", params: params}) do
    tool_name = params["name"]

    with snapshot when is_map(snapshot) <- AttestoMCP.Server.snapshot(server),
         tools when is_map(tools) <- snapshot[:tool] || snapshot["tool"],
         tool when is_map(tool) <- tools[tool_name],
         schema when is_map(schema) <- tool[:input_schema] || tool["inputSchema"] do
      collect_runtime_header_declarations(schema, [])
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  defp registered_header_declarations(_server, _request), do: []

  defp collect_runtime_header_declarations(schema, path) when is_map(schema) do
    properties = Map.get(schema, "properties", Map.get(schema, :properties, %{}))

    if is_map(properties) do
      Enum.flat_map(properties, fn {property, property_schema} ->
        if is_binary(property) and is_map(property_schema) do
          header_annotations(property_schema, path ++ [property]) ++
            collect_runtime_header_declarations(property_schema, path ++ [property])
        else
          []
        end
      end)
    else
      []
    end
  end

  defp collect_runtime_header_declarations(_schema, _path), do: []

  defp header_annotations(property_schema, path)
       when is_map(property_schema) and is_list(path) do
    annotation = property_schema["x-mcp-header"] || property_schema[:"x-mcp-header"]

    if is_binary(annotation) and valid_header_suffix?(annotation) and
         property_primitive?(property_schema) do
      [{"mcp-param-" <> annotation, path}]
    else
      []
    end
  end

  defp header_annotations(_property_schema, _path), do: []

  defp valid_declared_names(entries) do
    names = Enum.map(entries, fn {name, _} -> String.downcase(name) end)

    cond do
      Enum.uniq(names) != names -> {:error, :duplicate_header_name}
      Enum.all?(entries, fn {name, _} -> valid_header_name?(name) end) -> :ok
      true -> {:error, :invalid_header_name}
    end
  end

  defp request_header_values(conn, name) do
    wanted = String.downcase(name)

    conn.req_headers
    |> Enum.filter(fn {header, _value} -> String.downcase(header) == wanted end)
    |> Enum.map(fn {_header, value} -> trim_ows(value) end)
  end

  defp trim_ows(value) when is_binary(value) do
    Regex.replace(~r/\A[ \t]+|[ \t]+\z/, value, "")
  end

  defp trim_ows(value), do: value

  defp valid_header_name?(name) when is_binary(name) and byte_size(name) in 1..256 do
    name
    |> String.to_charlist()
    |> Enum.all?(fn code ->
      code in ?a..?z or code in ?A..?Z or code in ?0..?9 or
        code in [?!, ?#, ?$, ?%, ?&, ?', ?*, ?+, ?-, ?., ?^, ?_, ?`, ?|, ?~]
    end) and
      String.downcase(name) not in [
        "authorization",
        "cookie",
        "host",
        "content-length",
        "transfer-encoding",
        "connection",
        "upgrade"
      ]
  end

  defp valid_header_name?(_), do: false

  defp valid_header_suffix?(suffix) when is_binary(suffix) and byte_size(suffix) in 1..128 do
    not String.starts_with?(String.downcase(suffix), "mcp-param-") and
      Regex.match?(~r/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/, suffix)
  end

  defp valid_header_suffix?(_), do: false

  defp property_primitive?(schema) when is_map(schema) do
    Map.get(schema, "type") in ["string", "integer", "boolean"] and
      not Map.has_key?(schema, "$ref") and
      not Map.has_key?(schema, "anyOf") and
      not Map.has_key?(schema, "oneOf") and
      not Map.has_key?(schema, "allOf") and
      not Map.has_key?(schema, "if") and
      not Map.has_key?(schema, "then") and
      not Map.has_key?(schema, "else")
  end

  defp fetch_argument(arguments, path) when is_map(arguments) and is_list(path) do
    Enum.reduce_while(path, {:ok, arguments}, fn key, {:ok, current} when is_map(current) ->
      case Map.fetch(current, key) do
        {:ok, value} -> {:cont, {:ok, value}}
        :error -> {:halt, :missing}
      end
    end)
  end

  defp fetch_argument(_arguments, _path), do: :missing

  defp request_name(%{params: params, method: method})
       when method in [
              "tasks/get",
              "tasks/update",
              "tasks/cancel"
            ],
       do: params["taskId"]

  defp request_name(%{params: params, method: method})
       when method in ["tools/call", "resources/read", "prompts/get"],
       do: params["name"] || params["uri"]

  defp request_name(_), do: nil

  defp required_header(conn, name) do
    case request_header_values(conn, name) do
      [value] when is_binary(value) and byte_size(value) > 0 ->
        {:ok, value}

      _ ->
        {:error, :missing_header}
    end
  end

  defp decode_sentinel("=?base64?" <> rest = value) do
    if String.ends_with?(rest, "?=") do
      encoded = binary_part(rest, 0, byte_size(rest) - 2)

      case Base.decode64(encoded, padding: true) do
        {:ok, decoded} -> decoded
        :error -> :invalid_sentinel
      end
    else
      value
    end
  end

  defp decode_sentinel(value), do: value

  defp sentinel_match?(decoded, expected) when is_binary(decoded) and is_number(expected) do
    with true <- safe_integer_value?(expected),
         {integer, ""} <- Integer.parse(decoded),
         true <- abs(integer) <= @max_safe_integer do
      integer == expected
    else
      _ -> false
    end
  end

  defp sentinel_match?(decoded, expected) when is_binary(decoded) and is_boolean(expected),
    do: decoded == to_string(expected)

  defp sentinel_match?(decoded, expected) when is_binary(decoded) and is_binary(expected),
    do: decoded == expected

  defp sentinel_match?(_, _), do: false

  defp safe_integer_value?(value) when is_integer(value),
    do: abs(value) <= @max_safe_integer

  defp safe_integer_value?(value) when is_float(value),
    do:
      value == value and value == trunc(value) and
        abs(value) <= @max_safe_integer

  defp accept_header(conn) do
    accepts = get_req_header(conn, "accept") |> Enum.join(",")

    with {:ok, ranges} <- parse_accept(accepts),
         true <- acceptable_media?(ranges, "application/json"),
         true <- acceptable_media?(ranges, "text/event-stream") do
      :ok
    else
      _ -> {:error, Error.invalid_header(%{"reason" => "accept_must_include_json_and_sse"})}
    end
  end

  defp parse_accept(value) when is_binary(value) and byte_size(value) > 0 do
    value
    |> String.split(",", trim: false)
    |> Enum.reduce_while({:ok, []}, fn range, {:ok, acc} ->
      case parse_media_range(range) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, ranges} ->
        media_types = Enum.map(ranges, &elem(&1, 0))

        if length(media_types) == length(Enum.uniq(media_types)), do: {:ok, ranges}, else: :error

      :error ->
        :error
    end
  end

  defp parse_accept(_), do: :error

  defp parse_media_range(range) do
    case String.split(range, ";", trim: false) do
      [media | parameters] ->
        media = String.downcase(String.trim(media))

        if Regex.match?(~r/^[^\s\/]+\/[^\s\/]+$/, media) do
          with {:ok, quality} <- parse_quality(parameters), do: {:ok, {media, quality}}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp parse_quality(parameters) do
    Enum.reduce_while(parameters, {:ok, 1.0, false}, fn parameter, {:ok, quality, seen_q} ->
      parameter = String.trim(parameter)

      case String.split(parameter, "=", parts: 2) do
        [key, value] ->
          key = String.trim(key)
          value = String.trim(value)

          cond do
            String.downcase(key) == "q" and not seen_q ->
              case quality_value(value) do
                {:ok, parsed} -> {:cont, {:ok, parsed, true}}
                :error -> {:halt, :error}
              end

            key != "" and value != "" and String.downcase(key) != "q" ->
              # Media-specific parameters are allowed, but must be syntactically
              # present rather than being mistaken for a quality directive.
              {:cont, {:ok, quality, seen_q}}

            true ->
              {:halt, :error}
          end

        _ ->
          {:halt, :error}
      end
    end)
    |> case do
      {:ok, quality, _seen_q} -> {:ok, quality}
      :error -> :error
    end
  end

  defp quality_value("0"), do: {:ok, 0.0}
  defp quality_value("1"), do: {:ok, 1.0}

  defp quality_value(<<whole::binary-size(1), ?., fraction::binary>>) when whole in ["0", "1"] do
    if byte_size(fraction) in 1..3 and all_ascii_digits?(fraction) and
         (whole == "0" or String.trim(fraction, "0") == "") do
      denominator = :math.pow(10, byte_size(fraction))
      value = String.to_integer(fraction) / denominator
      {:ok, value + if(whole == "1", do: 1.0, else: 0.0)}
    else
      :error
    end
  end

  defp quality_value(_), do: :error

  defp all_ascii_digits?(value),
    do: value != "" and value |> :binary.bin_to_list() |> Enum.all?(&(&1 in ?0..?9))

  defp acceptable_media?(ranges, media),
    do: Enum.any?(ranges, fn {candidate, quality} -> candidate == media and quality > 0 end)

  defp validate_content_type(conn) do
    case get_req_header(conn, "content-type") do
      [value] ->
        media = value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()

        if media == "application/json",
          do: :ok,
          else:
            {:error,
             Error.unsupported_media(%{"reason" => "content_type_must_be_application_json"})}

      _ ->
        {:error, Error.unsupported_media(%{"reason" => "content_type_required"})}
    end
  end

  defp reject_client_response(%{kind: :response}, @modern),
    do: {:error, Error.invalid_request(%{"reason" => "client_response_not_allowed"})}

  defp reject_client_response(_request, _era), do: :ok

  defp era_for(%{method: "initialize", params: params}, conn) do
    header = get_req_header(conn, "mcp-protocol-version")
    body = metadata_value(params, "io.modelcontextprotocol/protocolVersion")

    cond do
      @modern in header or body == @modern -> @modern
      Enum.any?(@legacy_versions, &(&1 in header or body == &1)) -> @legacy
      true -> @legacy
    end
  end

  defp era_for(%{method: method}, conn) when method in ["ping", "notifications/initialized"] do
    case get_req_header(conn, "mcp-protocol-version") do
      [@modern] -> @modern
      _ -> @legacy
    end
  end

  defp era_for(_request, conn) do
    case get_req_header(conn, "mcp-protocol-version") do
      [@modern] -> @modern
      [version] when version in @legacy_versions -> @legacy
      _ -> if session_header(conn), do: @legacy, else: @modern
    end
  end

  defp modern_request_header?(conn), do: get_req_header(conn, "mcp-protocol-version") == [@modern]

  defp legacy_get_request?(conn) do
    not modern_request_header?(conn) and is_binary(session_header(conn)) and
      get_req_header(conn, "last-event-id") == [] and
      only_sse_accept?(conn)
  end

  defp legacy_delete_request?(conn) do
    not modern_request_header?(conn) and is_binary(session_header(conn)) and
      get_req_header(conn, "last-event-id") == []
  end

  defp only_sse_accept?(conn) do
    accepts = get_req_header(conn, "accept") |> Enum.join(",")

    case parse_accept(accepts) do
      {:ok, ranges} ->
        acceptable_media?(ranges, "text/event-stream")

      :error ->
        false
    end
  end

  defp streaming_request?(%{method: "subscriptions/listen"}, _state), do: true

  defp streaming_request?(%{method: "tools/call"} = request, state) do
    stream_all = Keyword.get(state.opts, :stream_all_tools, false)
    stream_tools = Keyword.get(state.opts, :stream_tools, [])

    stream_all or get_in(request, [:params, "name"]) in stream_tools or
      streaming_request?(request)
  end

  defp streaming_request?(%{method: method, params: params}, _state)
       when method in ["resources/read", "prompts/get", "completion/complete"],
       do: metadata_value(params, "progressToken") != nil or params["stream"] == true

  defp streaming_request?(_request, _state), do: false

  defp streaming_request?(%{params: params}),
    do: metadata_value(params, "progressToken") != nil or params["stream"] == true

  defp streaming_request?(_request), do: false

  defp metadata_value(params, key) do
    case Map.get(params, "_meta") do
      metadata when is_map(metadata) -> Map.get(metadata, key)
      _ -> nil
    end
  end

  defp request_owner(@legacy, session_id) when is_binary(session_id),
    do: {:legacy_session, session_id}

  defp request_owner(_era, _session_id), do: self()

  defp validate_stream_options!(opts) do
    stream_all = Keyword.get(opts, :stream_all_tools, false)
    stream_tools = Keyword.get(opts, :stream_tools, [])

    unless is_boolean(stream_all) do
      raise ArgumentError, ":stream_all_tools must be a boolean"
    end

    unless is_list(stream_tools) and Enum.all?(stream_tools, &is_binary/1) and
             length(Enum.uniq(stream_tools)) == length(stream_tools) do
      raise ArgumentError,
            ":stream_tools must be a list of unique tool name strings"
    end

    for key <- [
          :max_body_bytes,
          :max_message_bytes,
          :stream_keepalive_ms,
          :legacy_keepalive_ms,
          :subscription_timeout,
          :stream_queue_size,
          :subscription_queue_size,
          :max_queue
        ],
        Keyword.has_key?(opts, key) do
      value = Keyword.get(opts, key)

      unless is_integer(value) and value > 0 do
        raise ArgumentError, ":#{key} must be a positive integer"
      end
    end

    for key <- [:max_body_bytes, :max_message_bytes], Keyword.has_key?(opts, key) do
      if Keyword.fetch!(opts, key) > Schema.max_instance_bytes() do
        raise ArgumentError,
              ":#{key} cannot exceed the #{Schema.max_instance_bytes()}-byte schema-instance ceiling"
      end
    end

    :ok
  end

  defp metadata(conn, state) do
    resource = canonical_resource(conn, state.auth_opts)

    doc =
      AttestoMCP.Metadata.protected_resource(
        resource: resource,
        authorization_servers: authorization_servers(state.auth_opts),
        scopes_supported:
          state.auth_opts[:scopes_supported] || state.opts[:scopes_supported] ||
            AttestoMCP.Scopes.all(),
        bearer_methods_supported: ["header"]
      )

    send_json(conn, 200, doc)
  rescue
    _ -> send_json(conn, 500, %{"error" => "metadata_unavailable"})
  end

  defp authorization_servers(opts) do
    explicit = opts[:authorization_servers]

    cond do
      is_list(explicit) and explicit != [] -> explicit
      is_binary(explicit) -> [explicit]
      is_binary(opts[:issuer]) -> [opts[:issuer]]
      is_binary(config_issuer(opts[:config])) -> [config_issuer(opts[:config])]
      true -> []
    end
  end

  defp config_issuer(config) when is_function(config, 0) do
    config |> then(& &1.()) |> config_issuer()
  rescue
    _ -> nil
  end

  defp config_issuer({module, function}) when is_atom(module) and is_atom(function),
    do: config_issuer(apply(module, function, []))

  defp config_issuer({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args),
       do: config_issuer(apply(module, function, args))

  defp config_issuer(config) when is_map(config) do
    Map.get(config, :issuer) || Map.get(config, "issuer") ||
      get_in(config, [:oauth, :issuer]) || get_in(config, ["oauth", "issuer"])
  end

  defp config_issuer(_), do: nil

  defp usable_auth_configuration?(opts) do
    case opts[:issuer] || opts[:config] do
      issuer when is_binary(issuer) ->
        String.trim(issuer) != ""

      config when is_map(config) ->
        is_binary(config_issuer(config))

      fun when is_function(fun, 0) ->
        true

      {module, function} when is_atom(module) and is_atom(function) ->
        true

      {module, function, args} when is_atom(module) and is_atom(function) and is_list(args) ->
        true

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp pinned_resource?(opts) do
    absolute_resource?(opts[:resource]) or absolute_resource?(opts[:resource_audience]) or
      absolute_origin?(opts[:base_url]) or absolute_origin?(opts[:origin]) or
      opts[:allow_dynamic_origin] == true
  end

  defp validate_resource_configuration!(opts) do
    resource = opts[:resource]
    audience = opts[:resource_audience]
    base_url = opts[:base_url]
    origin = opts[:origin]
    endpoint_path = opts[:resource_path] || "/mcp"

    if not is_nil(resource) and not is_binary(resource) do
      raise ArgumentError, ":resource must be an absolute URL or the configured Plug path"
    end

    if is_binary(resource) and not absolute_resource?(resource) and resource != endpoint_path do
      raise ArgumentError, "relative :resource must match the configured Plug :path"
    end

    if not is_nil(audience) and not absolute_resource?(audience) do
      raise ArgumentError, ":resource_audience must be an absolute URL"
    end

    if not is_nil(base_url) and not absolute_origin?(base_url),
      do: raise(ArgumentError, ":base_url must be an HTTP origin without a path")

    if not is_nil(origin) and not absolute_origin?(origin),
      do: raise(ArgumentError, ":origin must be an HTTP origin without a path")

    if absolute_origin?(base_url) and absolute_origin?(origin) and
         origin_key(base_url) != origin_key(origin) do
      raise ArgumentError, ":base_url and :origin must identify the same origin"
    end

    if absolute_resource?(resource) and absolute_resource?(audience) and resource != audience do
      raise ArgumentError, ":resource and :resource_audience must agree when both are absolute"
    end

    for configured <- [resource, audience], absolute_resource?(configured) do
      canonical_path = URI.parse(configured).path || "/"

      if canonical_path != endpoint_path do
        raise ArgumentError, "canonical resource path must match Plug :path"
      end
    end

    configured_absolute =
      cond do
        absolute_resource?(audience) -> audience
        absolute_resource?(resource) -> resource
        true -> nil
      end

    configured_origin = base_url || origin

    if not is_nil(configured_absolute) and absolute_origin?(configured_origin) and
         origin_key(configured_absolute) != origin_key(configured_origin) do
      raise ArgumentError, "canonical resource and base origin must agree"
    end

    :ok
  end

  defp origin_key(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, port: port} ->
        {String.downcase(scheme || ""), String.downcase(host || ""), effective_port(scheme, port)}
    end
  end

  defp effective_port("http", nil), do: 80
  defp effective_port("https", nil), do: 443
  defp effective_port(_scheme, port), do: port

  defp canonical_resource(conn, opts) do
    configured =
      cond do
        absolute_resource?(opts[:resource_audience]) -> opts[:resource_audience]
        absolute_resource?(opts[:resource]) -> opts[:resource]
        true -> nil
      end

    cond do
      absolute_resource?(configured) ->
        configured

      absolute_origin?(opts[:base_url] || opts[:origin]) ->
        AttestoMCP.Metadata.resource_identifier(conn, opts[:resource_path] || "/mcp", opts)

      opts[:allow_dynamic_origin] == true ->
        AttestoMCP.Metadata.resource_identifier(conn, opts[:resource_path] || "/mcp", opts)

      true ->
        raise ArgumentError, "canonical resource is not pinned"
    end
  end

  defp metadata_url(conn, opts) do
    resource = canonical_resource(conn, opts)
    %URI{scheme: scheme, host: host, port: port, path: resource_path} = URI.parse(resource)
    port_suffix = origin_port_suffix(scheme, port)

    path =
      if is_binary(resource_path) and resource_path != "",
        do: resource_path,
        else: opts[:resource_path] || "/mcp"

    "#{scheme}://#{format_host(host)}#{port_suffix}/.well-known/oauth-protected-resource#{path}"
  end

  defp absolute_resource?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil, path: path}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        String.valid?(value) and safe_uri_bytes?(value) and valid_percent_encoding?(value) and
          (is_nil(path) or String.starts_with?(path, "/"))

      _ ->
        false
    end
  end

  defp absolute_resource?(_), do: false

  defp absolute_origin?(value) do
    if absolute_resource?(value) do
      URI.parse(value).path in [nil, "", "/"]
    else
      false
    end
  rescue
    _ -> false
  end

  defp safe_uri_bytes?(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(fn byte -> byte >= 0x21 and byte != 0x7F and byte not in [?"] end)
  end

  defp valid_percent_encoding?(value) do
    bytes = :binary.bin_to_list(value)

    bytes
    |> Enum.with_index()
    |> Enum.all?(fn
      {?%, index} ->
        case Enum.drop(bytes, index + 1) do
          [a, b | _] -> hex_digit?(a) and hex_digit?(b)
          _ -> false
        end

      _ ->
        true
    end)
  end

  defp hex_digit?(byte) when byte in ?0..?9, do: true
  defp hex_digit?(byte) when byte in ?a..?f, do: true
  defp hex_digit?(byte) when byte in ?A..?F, do: true
  defp hex_digit?(_), do: false

  defp metadata_path?(conn, path) do
    expected = "/.well-known/oauth-protected-resource" <> path
    conn.request_path == expected
  end

  defp invalid_origin?(conn, state) do
    expected_origin =
      case URI.parse(canonical_resource(conn, state.auth_opts)) do
        %URI{scheme: scheme, host: host, port: port} when is_binary(host) ->
          port_suffix = origin_port_suffix(scheme, port)
          "#{scheme}://#{format_host(host)}#{port_suffix}"

        _ ->
          nil
      end

    case get_req_header(conn, "origin") do
      [] -> false
      [origin] -> is_nil(expected_origin) or origin != expected_origin
      _ -> true
    end
  rescue
    _ -> true
  end

  defp request_headers_over_budget?(conn) do
    headers = conn.req_headers

    length(headers) > @max_request_headers or
      Enum.any?(headers, fn {name, value} ->
        not is_binary(name) or not is_binary(value) or
          byte_size(name) > @max_request_header_name_bytes or
          byte_size(value) > @max_request_header_value_bytes
      end) or
      Enum.reduce(headers, 0, fn {name, value}, total ->
        total + byte_size(name) + byte_size(value) + 4
      end) > @max_request_header_bytes
  rescue
    _ -> true
  end

  defp format_host(host) when is_binary(host) do
    if String.contains?(host, ":") and not String.starts_with?(host, "["),
      do: "[" <> host <> "]",
      else: host
  end

  defp origin_port_suffix(_scheme, nil), do: ""
  defp origin_port_suffix("http", 80), do: ""
  defp origin_port_suffix("https", 443), do: ""
  defp origin_port_suffix(_scheme, port) when is_integer(port), do: ":#{port}"

  defp auth_context(conn) do
    Map.merge(conn.assigns[:attesto_context] || %{}, %{
      principal: principal(conn),
      tenant: tenant(conn),
      scopes: conn.assigns[:attesto_mcp_scopes] || [],
      attesto_mcp_claims: conn.assigns[:attesto_mcp_claims],
      attesto_mcp_scopes: conn.assigns[:attesto_mcp_scopes] || [],
      attesto_mcp_sender: conn.assigns[:attesto_mcp_sender],
      attesto_mcp_principal: conn.assigns[:attesto_mcp_principal],
      attesto_context: conn.assigns[:attesto_context]
    })
  end

  defp handler_context(conn, state) do
    case state.opts[:context_builder] do
      nil ->
        {:ok, auth_context(conn)}

      callback ->
        try do
          case HostCallback.invoke(callback, [conn]) do
            context when is_map(context) ->
              {:ok, Map.put(auth_context(conn), :host_context, context)}

            _other ->
              context_builder_failure(state, :invalid_return)
          end
        catch
          kind, reason ->
            Telemetry.report_exception(
              state.opts[:exception_reporter],
              :context_builder,
              kind,
              reason,
              __STACKTRACE__,
              telemetry_options(state, %{transport: :http})
            )

            context_builder_failure(state, :exception)
        end
    end
  end

  defp context_builder_failure(state, outcome) do
    Telemetry.execute(
      [:context_builder, :exception],
      %{count: 1},
      telemetry_options(state, %{transport: :http, outcome: outcome})
    )

    {:error, Error.internal(%{"reason" => "context_builder_failure"})}
  end

  defp telemetry_options(state, metadata) do
    Map.put(metadata, :telemetry_metadata, state.opts[:telemetry_metadata])
  end

  defp maybe_subscription_authorizer(
         context,
         %{method: "subscriptions/listen"} = request,
         conn,
         state
       ) do
    required = required_scopes_for(request, Keyword.merge(state.auth_opts, state.opts))
    token = access_token(conn)
    config = auth_config(state.auth_opts)
    canonical = canonical_resource(conn, state.auth_opts)

    Map.put(context, :subscription_authorize, fn owner ->
      with {:ok, event_scope_sets} <- owner_required_scope_sets(owner),
           {:ok, required_scope_sets} <- prepend_required_scopes(required, event_scope_sets) do
        reauthorize_delivery?(
          token,
          config,
          canonical,
          context,
          owner,
          required_scope_sets
        )
      else
        _ -> false
      end
    end)
  end

  defp maybe_subscription_authorizer(context, _request, _conn, _state), do: context

  defp subscription_reauthorization_available?(auth_opts) do
    match?(%Attesto.Config{}, auth_config(auth_opts))
  end

  defp reauthorize_delivery?(
         token,
         config,
         canonical,
         initial_context,
         owner,
         required_scope_sets
       )
       when is_binary(token) do
    claims = Map.get(initial_context, :attesto_mcp_claims) || %{}
    confirmation = Map.get(claims, "cnf", %{})
    sender = Map.get(initial_context, :attesto_mcp_sender)

    with %Attesto.Config{} <- config,
         sender_opts when is_list(sender_opts) <- sender_verification_opts(sender),
         verify_opts <-
           [expected_typ: "access", trusted_audiences: [canonical]] ++ sender_opts,
         {:ok, current_claims} <- Attesto.Token.verify(config, token, verify_opts),
         true <- Map.get(current_claims, "cnf", %{}) == confirmation,
         initial_actor when not is_nil(initial_actor) <- token_actor(claims),
         ^initial_actor <- token_actor(current_claims),
         current_tenant <- current_claims["tenant"],
         current_scopes when is_list(current_scopes) <- token_scopes(current_claims),
         true <- Map.get(initial_context, :principal) == owner_value(owner, :principal),
         true <- current_tenant == owner_value(owner, :tenant),
         true <- scope_sets_grant?(required_scope_sets, current_scopes) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp reauthorize_delivery?(_, _, _, _, _, _), do: false

  defp owner_required_scope_sets(owner) when is_map(owner) do
    case owner[:required_scope_sets] || owner["required_scope_sets"] do
      scope_sets when is_list(scope_sets) and scope_sets != [] ->
        if Enum.all?(scope_sets, &is_list/1), do: {:ok, scope_sets}, else: :error

      _ ->
        case owner[:required_scopes] || owner["required_scopes"] do
          scopes when is_list(scopes) -> {:ok, [scopes]}
          _ -> :error
        end
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp owner_required_scope_sets(_owner), do: :error

  defp prepend_required_scopes(required, scope_sets)
       when is_list(required) and is_list(scope_sets) and scope_sets != [] do
    {:ok, Enum.map(scope_sets, &Enum.uniq(required ++ &1))}
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp prepend_required_scopes(_required, _scope_sets), do: :error

  defp sender_verification_opts(%{binding: :bearer}), do: []

  defp sender_verification_opts(%{binding: :dpop, jkt: jkt})
       when is_binary(jkt) and jkt != "",
       do: [dpop_jkt: jkt]

  defp sender_verification_opts(%{binding: :mtls, x5t_s256: thumbprint})
       when is_binary(thumbprint) and thumbprint != "",
       do: [mtls_cert_thumbprint: thumbprint]

  defp sender_verification_opts(_sender), do: :error

  defp token_actor(%{"sub" => subject} = claims) when is_binary(subject) and subject != "" do
    case Map.fetch(claims, "client_id") do
      {:ok, client_id} when is_binary(client_id) and client_id != "" ->
        {:subject, subject, client_id}

      :error ->
        {:subject, subject, nil}

      _invalid ->
        nil
    end
  end

  defp token_actor(%{"client_id" => client_id}) when is_binary(client_id) and client_id != "",
    do: {:client, client_id}

  defp token_actor(_claims), do: nil

  defp owner_value(owner, key) when is_map(owner) do
    case Map.fetch(owner, key) do
      {:ok, value} -> value
      :error -> Map.get(owner, Atom.to_string(key))
    end
  end

  defp owner_value(_owner, _key), do: nil

  defp scopes_grant?([], _granted), do: true

  defp scopes_grant?(required, granted) when is_list(required) and is_list(granted) do
    catalog = Attesto.Scope.new_catalog(required)
    Attesto.Scope.grants_all?(catalog, granted, required)
  rescue
    _ -> false
  end

  defp scopes_grant?(_, _), do: false

  defp scope_sets_grant?(scope_sets, granted)
       when is_list(scope_sets) and scope_sets != [] and is_list(granted),
       do: Enum.any?(scope_sets, &scopes_grant?(&1, granted))

  defp scope_sets_grant?(_scope_sets, _granted), do: false

  defp auth_config(auth_opts) do
    case Keyword.get(auth_opts, :config) do
      config when is_function(config, 0) ->
        config.()

      {module, function} when is_atom(module) and is_atom(function) ->
        apply(module, function, [])

      {module, function, args} when is_atom(module) and is_atom(function) and is_list(args) ->
        apply(module, function, args)

      config ->
        config
    end
  rescue
    _ -> nil
  end

  defp access_token(conn) do
    case get_req_header(conn, "authorization") do
      [value] ->
        case String.split(value, " ", parts: 2) do
          [_scheme, token] when token != "" -> token
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp token_scopes(%{"scope" => value}) when is_binary(value),
    do: String.split(value, ~r/\s+/, trim: true)

  defp token_scopes(_), do: []

  defp principal(conn) do
    conn.assigns[:attesto_mcp_principal] ||
      get_in(conn.assigns[:attesto_context] || %{}, [:principal]) ||
      get_in(conn.assigns[:attesto_context] || %{}, ["principal"]) ||
      claim_value(conn, :sub) || claim_value(conn, "sub") ||
      claim_value(conn, :subject) || claim_value(conn, "subject") ||
      claim_value(conn, :client_id) || claim_value(conn, "client_id")
  end

  @doc false
  def default_principal(claims, _sender) when is_map(claims) do
    principal = claims["sub"] || claims["client_id"]

    if is_binary(principal) and principal != "",
      do: {:ok, principal},
      else: {:error, :missing_principal}
  end

  def default_principal(_claims, _sender), do: {:error, :missing_principal}

  defp tenant(conn),
    do:
      get_in(conn.assigns[:attesto_context] || %{}, [:tenant]) ||
        get_in(conn.assigns[:attesto_context] || %{}, ["tenant"]) || claim_value(conn, :tenant) ||
        claim_value(conn, "tenant")

  defp claim_value(conn, key), do: get_in(conn.assigns[:attesto_mcp_claims] || %{}, [key])

  defp header_session(conn) do
    case get_req_header(conn, "mcp-session-id") do
      [id] -> {:ok, id}
      _ -> {:error, :missing_session}
    end
  end

  defp session_header(conn) do
    case get_req_header(conn, "mcp-session-id") do
      [id] -> id
      _ -> nil
    end
  end

  defp maybe_touch(_server, nil), do: :ok

  defp maybe_touch(server, id) do
    AttestoMCP.Server.touch_session(server, id)
  catch
    :exit, _reason -> :ok
  end

  defp maybe_set_session_version(_server, _session_id, _request, _response, @modern), do: :ok

  defp maybe_set_session_version(server, session_id, request, response, @legacy)
       when is_binary(session_id) and request.method == "initialize" do
    case get_in(response, ["result", "protocolVersion"]) do
      version when is_binary(version) ->
        AttestoMCP.Server.set_session_version(server, session_id, version)

      _ ->
        :ok
    end
  end

  defp maybe_set_session_version(_server, _session_id, _request, _response, _era), do: :ok

  defp read_body_bounded(conn, max) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} -> read_unparsed_body_bounded(conn, max)
      %{} = body when map_size(body) == 0 -> read_empty_parsed_body_bounded(conn, body, max)
      body when is_map(body) or is_list(body) -> read_parsed_body_bounded(conn, body, max)
      _other -> read_unparsed_body_bounded(conn, max)
    end
  end

  defp read_empty_parsed_body_bounded(conn, body, max) do
    case read_body(conn, length: max) do
      {:ok, "", conn} -> read_parsed_body_bounded(conn, body, max)
      {:ok, raw_body, conn} -> {:ok, raw_body, conn}
      {:more, _body, _conn} -> {:error, Error.parse(%{"reason" => "body_too_large"})}
      {:error, _reason} -> {:error, Error.parse(%{"reason" => "body_read_failed"})}
    end
  end

  defp read_parsed_body_bounded(conn, body, max) do
    case Jason.encode(body) do
      {:ok, encoded} when byte_size(encoded) <= max -> {:ok, body, conn}
      {:ok, _encoded} -> {:error, Error.parse(%{"reason" => "body_too_large"})}
      {:error, _reason} -> {:error, Error.parse(%{"reason" => "body_read_failed"})}
    end
  end

  defp read_unparsed_body_bounded(conn, max) do
    case read_body(conn, length: max) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _body, _conn} -> {:error, Error.parse(%{"reason" => "body_too_large"})}
      {:error, _reason} -> {:error, Error.parse(%{"reason" => "body_read_failed"})}
    end
  end

  defp send_json(conn, status, data),
    do:
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("vary", "authorization")
      |> send_resp(status, JSONRPC.encode(data))

  defp error_response(conn, id, %Error{} = error, auth_opts) do
    Telemetry.execute([:protocol, :error], %{count: 1}, %{
      status: error.http_status,
      outcome: error.code,
      correlation_id: telemetry_correlation(id)
    })

    conn =
      if error.http_status == 403 and auth_opts != [] do
        resource_challenge(conn, auth_opts, error)
      else
        conn
      end

    send_json(conn, error.http_status, JSONRPC.error_response(id, error))
  end

  defp resource_challenge(conn, auth_opts, error) do
    metadata_url = metadata_url(conn, auth_opts)

    scope =
      case error.data do
        %{"required_scopes" => scopes} when is_list(scopes) ->
          ~s( scope="#{Enum.join(scopes, " ")}")

        _ ->
          ""
      end

    put_authenticate_challenge(
      conn,
      ~s(Bearer error="insufficient_scope"#{scope} resource_metadata="#{metadata_url}")
    )
  rescue
    _ -> conn
  end

  defp error_status(%{"error" => %{"code" => -32601}}, @modern), do: 404

  defp error_status(%{"error" => %{"code" => code}}, _era) when code in [-32020, -32021, -32022],
    do: 400

  defp error_status(%{"error" => %{"code" => -32603}}, _era), do: 500
  defp error_status(%{"error" => _}, _era), do: 200
  defp error_status(_, _era), do: 200

  defp telemetry_correlation(id) when is_binary(id), do: "string:" <> id
  defp telemetry_correlation(id) when is_integer(id), do: "integer:" <> Integer.to_string(id)
  defp telemetry_correlation(_id), do: nil

  defp sse_event(message), do: "event: message\ndata: " <> JSONRPC.encode(message) <> "\n\n"

  defp legacy_sse_event(event_id, message),
    do: "id: #{event_id}\nevent: message\ndata: " <> JSONRPC.encode(message) <> "\n\n"
end
