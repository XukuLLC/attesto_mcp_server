defmodule AttestoMCP.Server.CachePolicy do
  @moduledoc """
  Cache-hint policy for cacheable MCP results.

  The server emits `ttlMs` and `cacheScope` hints on modern complete results.
  It does not cache responses itself. Without a `:cache_policy` option the
  2.3 behaviour is kept: `:cache_ttl_ms` (default `30_000`) and a private
  scope, with `"public"` only when `cache_scope: :public`,
  `allow_public_cache: true`, and the dispatch context's trusted
  `:public_catalog` flag are all present.

  ## Granular policy

      cache_policy: [
        methods: %{
          "server/discover" => [ttl_ms: 300_000],
          "tools/list" => [ttl_ms: 60_000, scope: :public],
          "resources/read" => [ttl_ms: 5_000]
        },
        resolver: {MyApp.MCPCache, :policy, []},
        max_ttl_ms: 600_000
      ]

  `:methods` accepts the standard cacheable operations: `server/discover`,
  `tools/list`, `prompts/list`, `resources/list`, `resources/templates/list`,
  and `resources/read`. A resource or resource-template definition may carry
  its own `cache: [ttl_ms: ..., scope: ...]` policy for `resources/read`. Each
  policy may set `:ttl_ms` (a non-negative integer), `:scope` (`:private` or
  `:public`), or both; an unset field inherits the lower-precedence value.

  The optional `:resolver` callback receives
  `%{method: method, definition: nil | %{type: type, identity: identity}, policy: policy}`
  and the trusted request context. It returns `{:ok, policy}` to override the
  fields it sets or `:default` to keep the static result. It runs in the
  request worker under the request deadline. An exception, exit, throw, or
  invalid return produces a zero-TTL private hint for that response; it never
  falls back to a public or longer-lived policy.

  Resolution order is: global default, method policy, definition policy,
  resolver output, then valid handler hints on `resources/read` (which may
  shorten `ttlMs` or select `"private"` but cannot lengthen or promote), and
  finally the mandatory constraints below.

  ## Mandatory constraints

  These apply with or without a granular policy:

    * Interim `input_required` results carry no hints, and complete results
      from a multi-round retry use `ttlMs: 0` and `"private"`.
    * `"public"` requires `allow_public_cache: true` and an explicit host
      choice (a granular `:public` policy, or the 2.3 options above), and the
      complete response must be caller-independent. A catalog is
      caller-independent only when every registered definition of that type
      has no required scopes, alternative scope sets, or `authorize` callback,
      no HTTP definition policy applies, and no presentation callback is
      configured. A resource read additionally requires the selected definition
      to be unrestricted. Otherwise the scope is `"private"`. Method-level
      scope requirements do not make a result caller-dependent, so a public
      hint lets shared caches serve it to callers without those scopes.
    * Output from `:instructions_provider` or `:tool_presentation` is
      private, and its TTL is `0` unless a method policy, definition policy, or
      resolver explicitly supplies one.
    * A list page carrying `nextCursor` is never fresher than the cursor's
      lifetime, and a private hint is never fresher than the remaining
      lifetime of the verified access token in `:attesto_mcp_claims`.
    * TTLs never exceed `:max_ttl_ms` or the largest JSON-safe integer.

  All pages of one list request receive the same scope; continuation cursors
  are bound to it and are rejected if the effective scope changes.

  MCP cache hints do not change HTTP caching. Protected HTTP responses keep
  `Cache-Control: private, no-store`.
  """

  alias AttestoMCP.Server.HostCallback

  @max_safe_integer 9_007_199_254_740_991
  @default_ttl_ms 30_000
  @cacheable_methods [
    "server/discover",
    "tools/list",
    "prompts/list",
    "resources/list",
    "resources/templates/list",
    "resources/read"
  ]
  @config_keys [:methods, :resolver, :max_ttl_ms]
  @policy_keys %{"ttl_ms" => :ttl_ms, "scope" => :scope}

  @typedoc "A normalized policy; `nil` fields inherit lower-precedence values."
  @type policy :: %{ttl_ms: non_neg_integer() | nil, scope: String.t() | nil}

  @doc false
  def cacheable_methods, do: @cacheable_methods

  @doc false
  def max_safe_integer, do: @max_safe_integer

  @doc false
  @spec normalize_config!(term()) :: map() | nil
  def normalize_config!(nil), do: nil

  def normalize_config!(config) when is_list(config) or is_map(config) do
    entries = entries!(config, ":cache_policy")

    Enum.each(entries, fn {key, _value} ->
      unless key in @config_keys,
        do: raise(ArgumentError, ":cache_policy contains unsupported key #{inspect(key)}")
    end)

    config = Map.new(entries)

    %{
      methods: normalize_methods!(Map.get(config, :methods, %{})),
      resolver: normalize_resolver!(Map.get(config, :resolver)),
      max_ttl_ms: normalize_max_ttl!(Map.get(config, :max_ttl_ms, @max_safe_integer))
    }
  end

  def normalize_config!(_config),
    do: raise(ArgumentError, ":cache_policy must be a keyword list or map")

  @doc "Validates a static or resolver-supplied policy."
  @spec normalize_policy(term()) :: {:ok, policy()} | {:error, :invalid_cache_policy}
  def normalize_policy(%{ttl_ms: ttl, scope: scope} = policy)
      when map_size(policy) == 2 and (is_nil(ttl) or is_integer(ttl)) and
             (is_nil(scope) or scope in ["private", "public"]) do
    if is_nil(ttl) or ttl in 0..@max_safe_integer,
      do: {:ok, policy},
      else: {:error, :invalid_cache_policy}
  end

  def normalize_policy(policy) when is_list(policy) or is_map(policy) do
    with {:ok, entries} <- policy_entries(policy),
         false <- entries == [],
         {:ok, ttl} <- policy_ttl(Keyword.get(entries, :ttl_ms)),
         {:ok, scope} <- policy_scope(Keyword.get(entries, :scope)) do
      {:ok, %{ttl_ms: ttl, scope: scope}}
    else
      _invalid -> {:error, :invalid_cache_policy}
    end
  end

  def normalize_policy(_policy), do: {:error, :invalid_cache_policy}

  @doc false
  @spec resolve(map()) :: {map(), atom()}
  def resolve(input) do
    opts = input.opts
    config = opts[:cache_policy]

    {ttl, scope, explicit_ttl?, source} =
      if config, do: granular(input, config), else: legacy(input)

    {ttl, scope, source} = constrain(input, opts, config, ttl, scope, explicit_ttl?, source)
    {%{"ttlMs" => ttl, "cacheScope" => scope}, source}
  end

  defp legacy(input) do
    {global_ttl(input.opts), global_scope(input), false, :global}
  end

  defp granular(input, config) do
    candidate = %{ttl_ms: global_ttl(input.opts), scope: global_scope(input)}

    if input[:standard?] == false do
      {candidate.ttl_ms, candidate.scope, false, :global}
    else
      {candidate, explicit, source} =
        {candidate, false, :global}
        |> apply_policy(Map.get(config.methods, input.method), :method)
        |> apply_policy(definition_policy(input[:definition]), :definition)

      case run_resolver(config.resolver, input, candidate) do
        :default ->
          {candidate.ttl_ms, candidate.scope, explicit, source}

        {:ok, policy} ->
          {resolved, explicit, _source} = apply_policy({candidate, explicit, source}, policy, nil)
          {resolved.ttl_ms, resolved.scope, explicit or not is_nil(policy.ttl_ms), :resolver}

        :error ->
          {0, "private", true, :resolver_error}
      end
      |> apply_handler_hints(input[:handler_hints])
    end
  end

  defp apply_policy(acc, nil, _source), do: acc

  defp apply_policy({candidate, explicit, current}, policy, source) do
    candidate =
      candidate
      |> maybe_replace(:ttl_ms, policy.ttl_ms)
      |> maybe_replace(:scope, policy.scope)

    {candidate, explicit or not is_nil(policy.ttl_ms), source || current}
  end

  defp maybe_replace(map, _key, nil), do: map
  defp maybe_replace(map, key, value), do: Map.put(map, key, value)

  defp definition_policy(%{cache: policy}) when is_map(policy), do: policy
  defp definition_policy(_definition), do: nil

  defp run_resolver(nil, _input, _candidate), do: :default

  defp run_resolver(resolver, input, candidate) do
    request = %{
      method: input.method,
      definition: resolver_definition(input[:definition_type], input[:definition]),
      policy: %{ttl_ms: candidate.ttl_ms, scope: String.to_existing_atom(candidate.scope)}
    }

    case HostCallback.invoke(resolver, [request, input.context]) do
      :default ->
        :default

      {:ok, policy} ->
        case normalize_policy(policy) do
          {:ok, policy} -> {:ok, policy}
          {:error, _reason} -> resolver_failure(input, :error, :invalid_return, [])
        end

      other ->
        resolver_failure(input, :error, {:invalid_return, other}, [])
    end
  catch
    kind, reason -> resolver_failure(input, kind, reason, __STACKTRACE__)
  end

  defp resolver_failure(input, kind, reason, stacktrace) do
    AttestoMCP.Server.Telemetry.report_exception(
      Map.get(input.context, :exception_reporter),
      :cache_policy_resolver,
      kind,
      reason,
      stacktrace,
      %{method: input.method, telemetry_metadata: Map.get(input.context, :telemetry_metadata)}
    )

    :error
  end

  defp resolver_definition(type, %{identity: identity}) when type in [:resource, :template],
    do: %{type: type, identity: identity}

  defp resolver_definition(_type, _definition), do: nil

  defp apply_handler_hints({ttl, scope, explicit, source}, hints) when is_map(hints) do
    ttl =
      case Map.get(hints, "ttlMs") do
        hint when is_integer(hint) and hint >= 0 -> min(ttl, hint)
        _other -> ttl
      end

    scope = if Map.get(hints, "cacheScope") == "private", do: "private", else: scope
    {ttl, scope, explicit, source}
  end

  defp apply_handler_hints(result, _hints), do: result

  defp constrain(%{retry?: true}, _opts, _config, _ttl, _scope, _explicit_ttl?, source),
    do: {0, "private", source}

  defp constrain(input, opts, config, ttl, scope, explicit_ttl?, source) do
    personalized? = input[:personalized?] == true

    scope =
      if scope == "public" and opts[:allow_public_cache] == true and
           input[:invariant?] == true and not personalized?,
         do: "public",
         else: "private"

    ttl = if personalized? and not explicit_ttl?, do: 0, else: ttl

    ttl =
      ttl
      |> cap(input[:ceiling_ms])
      |> cap(if(scope == "private", do: token_remaining_ms(input.context)))
      |> cap(if(config, do: config.max_ttl_ms))
      |> cap(@max_safe_integer)
      |> max(0)

    {ttl, scope, source}
  end

  defp cap(ttl, nil), do: ttl
  defp cap(ttl, ceiling) when is_integer(ceiling), do: min(ttl, max(ceiling, 0))

  defp token_remaining_ms(context) do
    case Map.get(context, :attesto_mcp_claims) do
      %{"exp" => exp} when is_integer(exp) ->
        exp * 1_000 - System.system_time(:millisecond)

      _other ->
        nil
    end
  end

  defp global_ttl(opts), do: max(opts[:cache_ttl_ms] || @default_ttl_ms, 0)

  defp global_scope(input) do
    if input.opts[:cache_scope] == "public" and
         Map.get(input.context, :public_catalog, false) == true,
       do: "public",
       else: "private"
  end

  defp normalize_methods!(methods) do
    methods
    |> entries!(":cache_policy :methods", false)
    |> Map.new(fn {method, policy} ->
      unless method in @cacheable_methods do
        raise ArgumentError,
              ":cache_policy :methods supports only #{Enum.join(@cacheable_methods, ", ")}"
      end

      case normalize_policy(policy) do
        {:ok, policy} ->
          {method, policy}

        {:error, _reason} ->
          raise ArgumentError, "invalid :cache_policy for #{method}"
      end
    end)
  end

  defp normalize_resolver!(nil), do: nil

  defp normalize_resolver!(resolver) do
    if HostCallback.valid?(resolver, 2),
      do: resolver,
      else:
        raise(ArgumentError, ":cache_policy :resolver must be a supported 2-argument callback")
  end

  defp normalize_max_ttl!(value) when is_integer(value) and value in 0..@max_safe_integer,
    do: value

  defp normalize_max_ttl!(_value),
    do: raise(ArgumentError, ":cache_policy :max_ttl_ms must be a JSON-safe non-negative integer")

  defp entries!(value, label, atom_keys? \\ true)

  defp entries!(value, label, atom_keys?) when is_map(value),
    do: entries!(Map.to_list(value), label, atom_keys?)

  defp entries!(value, label, atom_keys?) when is_list(value) do
    valid? =
      Enum.all?(value, fn
        {key, _value} when atom_keys? -> is_atom(key)
        {key, _value} -> is_binary(key)
        _entry -> false
      end)

    keys = Enum.map(value, &elem(&1, 0))

    if valid? and length(keys) == length(Enum.uniq(keys)),
      do: value,
      else:
        raise(
          ArgumentError,
          "#{label} must have unique #{if atom_keys?, do: "atom", else: "string"} keys"
        )
  rescue
    error in ArgumentError -> reraise error, __STACKTRACE__
    _error -> raise ArgumentError, "#{label} is malformed"
  end

  defp policy_entries(policy) do
    entries = if is_map(policy), do: Map.to_list(policy), else: policy

    Enum.reduce_while(entries, {:ok, []}, fn
      {key, value}, {:ok, acc} when is_atom(key) or is_binary(key) ->
        canonical = Map.get(@policy_keys, to_string(key))

        if is_nil(canonical) or Keyword.has_key?(acc, canonical),
          do: {:halt, :error},
          else: {:cont, {:ok, Keyword.put(acc, canonical, value)}}

      _entry, _acc ->
        {:halt, :error}
    end)
  rescue
    _error -> :error
  end

  defp policy_ttl(nil), do: {:ok, nil}
  defp policy_ttl(ttl) when is_integer(ttl) and ttl in 0..@max_safe_integer, do: {:ok, ttl}
  defp policy_ttl(_ttl), do: :error

  defp policy_scope(nil), do: {:ok, nil}
  defp policy_scope(scope) when scope in [:private, "private"], do: {:ok, "private"}
  defp policy_scope(scope) when scope in [:public, "public"], do: {:ok, "public"}
  defp policy_scope(_scope), do: :error
end
