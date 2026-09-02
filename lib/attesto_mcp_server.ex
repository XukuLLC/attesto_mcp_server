defmodule AttestoMCP.Server.API do
  @moduledoc """
  Stable host-facing facade for `AttestoMCP.Server`.

  Registration is performed before serving traffic. Definitions use JSON-style
  string keys for schemas and wire values. Handler callbacks receive a
  primitive-specific input plus an authorization context and return
  `{:ok, result}`, `{:error, reason}`, or the modern
  `{:input_required, requests}` MRTR form.

  The facade intentionally exposes no task profile in this release. Calls that
  would enable modern or legacy Tasks return the dated method-not-found result.

  Two-arity handler callbacks use `handler.(input, context)`; one-arity handlers
  receive only `input`, and MFA handlers follow the same input/context order. A
  tool's input is its arguments map. A prompt receives
  `%{name: name, arguments: arguments}`. A resource receives
  `%{uri: uri, params: template_params}`, and a completion receives
  `%{ref: ref, argument: argument, value: value, context: context}`. These
  envelopes use atom keys for their declared fields; a resource MRTR retry also
  carries its string-keyed input-response entries at the top level. Nested MCP
  values retain their JSON string keys by default. The server-wide
  `tool_argument_keys: :atoms` opt-in converts only literal, schema-declared
  property keys that already exist as atoms; it never creates atoms from
  schemas or client input. The callback context contains the
  complete authenticated principal, tenant, scopes, transport, negotiated
  version, request ID, `trace_context`, progress callback, and an optional
  stable `:principal_binding` supplied by the transport. The HTTP Plug always
  supplies that field, defaulting it to the complete principal when no binding
  callback is configured. It also supplies the Attesto assigns (`:attesto_mcp_claims`,
  `:attesto_mcp_scopes`, `:attesto_mcp_sender`, `:attesto_mcp_principal`, and
  `:attesto_context`) when the Plug boundary is used. The context also exposes
  the supervised server's `:max_json_bytes`, `:output_canonicalization`, and
  `:tool_argument_keys` values. `AttestoMCP.Server.Result.tool_from_context/2,3`
  consumes the first two automatically; low-level constructors can still use
  them as explicit options. A successful callback
  returns `{:ok, result}`, an application failure returns `{:error, reason}`,
  and an interactive callback returns `{:input_required, request_map}` with
  typed MRTR request entries. An HTTP `context_builder` contributes only the
  nested `:host_context` map. Use `AttestoMCP.Server.Result.error/2` when an
  error message and stable code are intentionally safe to disclose.
  """

  @typedoc "A supervised server pid or a registered server name."
  @type server :: pid() | atom()

  @typedoc "A cache scope; string values are restricted to `\"private\"` or `\"public\"`."
  @type cache_scope :: :private | :public | String.t()

  @typedoc "One primitive registration accepted by the atomic batch and startup APIs."
  @type registration :: {atom(), String.t(), map() | keyword()}

  @typedoc "A supported server startup option and its value."
  @type server_option ::
          {:name, atom()}
          | {:protocol_versions, [String.t()]}
          | {:max_concurrency, pos_integer()}
          | {:per_principal_concurrency, pos_integer()}
          | {:request_timeout, non_neg_integer()}
          | {:max_request_timeout, pos_integer()}
          | {:client_request_timeout, pos_integer()}
          | {:legacy_initialized_grace_ms, non_neg_integer()}
          | {:session_idle_timeout, pos_integer()}
          | {:session_absolute_timeout, pos_integer()}
          | {:max_json_bytes, pos_integer()}
          | {:output_canonicalization, :strict | :json | :jason}
          | {:tool_argument_keys, :strings | :atoms}
          | {:max_body_bytes, pos_integer()}
          | {:max_message_bytes, pos_integer()}
          | {:max_queue, pos_integer()}
          | {:stream_keepalive_ms, non_neg_integer()}
          | {:legacy_keepalive_ms, non_neg_integer()}
          | {:stream_queue_size, pos_integer()}
          | {:subscription_queue_size, pos_integer()}
          | {:rate_limits, map()}
          | {:cursor_secret, binary()}
          | {:cursor_ttl, pos_integer()}
          | {:request_state_secret, binary()}
          | {:request_state_instance, binary()}
          | {:request_state_store, pid()}
          | {:clustered, boolean()}
          | {:request_state_ttl, pos_integer()}
          | {:scope_map, map()}
          | {:default_scopes, [String.t()]}
          | {:registrations, [registration()]}
          | {:session_store, AttestoMCP.Server.SessionStore.adapter()}
          | {:session_namespace, String.t()}
          | {:session_clustered, boolean()}
          | {:telemetry_metadata, map()}
          | {:exception_reporter, term()}
          | {:handler_task_init, term()}
          | {:subscription_timeout, pos_integer()}
          | {:page_size, pos_integer()}
          | {:cache_ttl_ms, non_neg_integer()}
          | {:cache_scope, cache_scope()}
          | {:allow_public_cache, boolean()}
          | {:initialize_callback, (map(), map() -> :ok | {:error, term()})}
          | {:instructions, String.t()}
          | {:server_name, String.t()}
          | {:server_version, String.t()}
          | {:capabilities, map()}
          | {:modern_tasks, false}
          | {:legacy_tasks, false}
  @typedoc "Keyword options accepted by `start_link/1`; task flags are disabled in this release."
  @type server_opts :: [server_option()]

  @typedoc "One conjunctive scope clause used by a primitive definition."
  @type scope_set :: [String.t()]

  @typedoc "A registered primitive definition with JSON-compatible fields. `required_scopes` is the primary all-of clause and `alternative_scope_sets` supplies bounded alternative all-of clauses."
  @type definition :: map() | keyword()

  @typedoc "Authorization and transport context passed to handlers."
  @type handler_context :: map()

  @typedoc "A text, image, audio, resource-link, or embedded-resource item."
  @type content_item :: map()

  @typedoc "A normalized tool result with content and optional structured output."
  @type tool_result :: map()

  @typedoc "A prompt message with a user or assistant role and content item."
  @type prompt_message :: map()

  @typedoc "A text or Base64 resource content entry."
  @type resource_content :: map()

  @typedoc "A modern result carrying resultType and protocol metadata."
  @type modern_result :: map()

  @typedoc "A normal, failed, or interactive handler return."
  @type handler_return ::
          {:ok, term()}
          | {:error, term()}
          | {:input_required, %{optional(String.t()) => map()}}

  @typedoc "A decoded JSON-RPC request, notification, or response."
  @type request :: map()

  @typedoc "Modern subscription category/resource filters."
  @type subscription_filter :: %{optional(String.t()) => boolean() | [String.t()]}

  @typedoc "A per-publication authorization callback applied to every matching subscriber."
  @type publish_option :: {:authorize, (map() -> boolean())}

  @typedoc "Interactive request-state and input-response payloads."
  @type mrtr_payload :: %{optional(String.t()) => term()}

  @doc """
  Starts the supervised, transport-neutral MCP server.

      iex> {:ok, server} = AttestoMCP.Server.API.start_link([])
      iex> is_pid(server)
      true
      iex> GenServer.stop(server)
      :ok
  """
  @spec start_link(server_opts()) :: GenServer.on_start()
  defdelegate start_link(opts \\ []), to: AttestoMCP.Server

  @doc "Returns a supervision child spec keyed by the optional registered server name."
  @spec child_spec(server_opts()) :: Supervisor.child_spec()
  defdelegate child_spec(opts \\ []), to: AttestoMCP.Server

  @doc "Registers a tool definition and publishes a modern catalog invalidation."
  @spec register_tool(server(), String.t(), definition()) :: :ok | {:error, term()}
  defdelegate register_tool(server, name, definition), to: AttestoMCP.Server

  @doc "Registers a static resource definition."
  @spec register_resource(server(), String.t(), definition()) :: :ok | {:error, term()}
  defdelegate register_resource(server, uri, definition), to: AttestoMCP.Server

  @doc "Registers a URI-template resource definition."
  @spec register_resource_template(server(), String.t(), definition()) ::
          :ok | {:error, term()}
  defdelegate register_resource_template(server, template, definition), to: AttestoMCP.Server

  @doc """
  Registers a prompt definition, including required and optional arguments.

  The handler input is `%{name: name, arguments: arguments}`. A definition may
  match an argument directly when it declares that argument as required, for
  example:

      handler: fn %{arguments: %{"topic" => topic}}, _context ->
        {:ok, [%{"role" => "user", "content" => %{"type" => "text", "text" => topic}}]}
      end

  Use `Map.get(arguments, "topic")` instead when the argument is optional.
  """
  @spec register_prompt(server(), String.t(), definition()) :: :ok | {:error, term()}
  defdelegate register_prompt(server, name, definition), to: AttestoMCP.Server

  @doc "Registers a completion handler tied to an explicit prompt/template reference."
  @spec register_completion(server(), String.t(), definition()) :: :ok | {:error, term()}
  defdelegate register_completion(server, name, definition), to: AttestoMCP.Server

  @doc "Registers one primitive of a supported type."
  @spec register(server(), atom(), String.t(), definition()) :: :ok | {:error, term()}
  def register(server, type, identity, definition),
    do: AttestoMCP.Server.register(server, type, identity, definition)

  @doc "Atomically registers a bounded primitive batch with coalesced invalidations."
  @spec register_all(server(), [registration()]) :: :ok | {:error, term()}
  defdelegate register_all(server, registrations), to: AttestoMCP.Server

  @doc "Atomically replaces the complete primitive catalog from one bounded batch."
  @spec replace_catalog(server(), [registration()]) :: :ok | {:error, term()}
  defdelegate replace_catalog(server, registrations), to: AttestoMCP.Server

  @doc "Dispatches one decoded request through the shared protocol core."
  @spec dispatch(server(), request(), handler_context(), keyword()) :: term()
  def dispatch(server, request, context \\ %{}, opts \\ []),
    do: AttestoMCP.Server.dispatch(server, request, context, opts)

  @doc "Returns the registered primitive snapshot."
  @spec snapshot(server()) :: map()
  def snapshot(server), do: AttestoMCP.Server.snapshot(server)

  @doc "Returns bounded public counters for active work and transport state."
  @spec stats(server()) :: map()
  def stats(server), do: AttestoMCP.Server.stats(server)

  @doc "Returns one bounded page of active legacy session IDs for operator tooling."
  @spec active_session_ids(server(), keyword()) ::
          {:ok, %{session_ids: [String.t()], next_cursor: String.t() | nil}}
          | {:error, :invalid_options | :session_store_unavailable | :unsupported}
  def active_session_ids(server, opts \\ []),
    do: AttestoMCP.Server.active_session_ids(server, opts)

  @doc "Returns normalized startup options used by Plug and stdio adapters."
  @spec options(server()) :: keyword()
  def options(server), do: AttestoMCP.Server.options(server)

  @doc "Creates a principal-binding/tenant-bound legacy session."
  @spec new_session(server(), term(), term(), keyword()) :: {:ok, struct()} | {:error, term()}
  def new_session(server, principal, tenant \\ nil, opts \\ []),
    do: AttestoMCP.Server.new_session(server, principal, tenant, opts)

  @doc "Looks up a session only for its principal binding and tenant."
  @spec get_session(server(), String.t(), term(), term()) :: {:ok, struct()} | {:error, term()}
  def get_session(server, id, principal, tenant \\ nil),
    do: AttestoMCP.Server.get_session(server, id, principal, tenant)

  @doc "Deletes a legacy session and its owned streams."
  @spec delete_session(server(), String.t()) :: :ok | {:error, term()}
  defdelegate delete_session(server, id), to: AttestoMCP.Server

  @doc """
  Queues a filtered modern notification and publishes its legacy event.

  An optional `:authorize` callback is combined with each stream's captured
  delivery authorization for both modern and legacy subscribers. Only a
  literal `true` permits delivery; callback failures suppress it. Its context
  keeps `required_scopes` as the primary all-of clause and adds
  `required_scope_sets` with every accepted clause.
  """
  @spec publish(server(), map(), [publish_option()]) :: :ok | {:error, term()}
  def publish(server, notification, opts \\ []),
    do: AttestoMCP.Server.publish(server, notification, opts)

  @doc "Closes a modern subscription."
  @spec close_subscription(server(), term()) :: :ok | {:error, term()}
  defdelegate close_subscription(server, id), to: AttestoMCP.Server

  @doc "Closes a modern subscription owned by the given sink process."
  @spec close_subscription(server(), term(), pid()) :: :ok | {:error, term()}
  defdelegate close_subscription(server, id, owner), to: AttestoMCP.Server

  @doc "Cancels a modern subscription."
  @spec cancel_subscription(server(), term()) :: :ok | {:error, term()}
  defdelegate cancel_subscription(server, id), to: AttestoMCP.Server

  @doc "Cancels a modern subscription owned by the given sink process."
  @spec cancel_subscription(server(), term(), pid()) :: :ok | {:error, term()}
  defdelegate cancel_subscription(server, id, owner), to: AttestoMCP.Server

  @doc """
  Cancels a request owned by the supplied principal binding.

  When the transport configures `:principal_binding`, pass the derived binding
  rather than the complete loaded principal. Otherwise pass the principal used
  when the request started.
  """
  @spec cancel_request(server(), term(), term()) :: :ok | {:error, term()}
  defdelegate cancel_request(server, principal, request_id), to: AttestoMCP.Server
end
