defmodule AttestoMCP.Server.SessionStore do
  @moduledoc """
  Durable session storage contract for the session-bound MCP revisions.

  Keys are `{namespace, session_id}` data tuples. Adapters must never convert
  either component to an atom. `update/3`, `update_ttl/3`, and
  `cleanup_expired/1` must be atomic with respect to one another. Records are
  the versioned JSON-compatible maps documented by
  `AttestoMCP.Server.Session.to_record/1`; unknown fields must be preserved by
  an adapter and ignored by the server. Records with a future
  `format_version` are opaque to an older node and must remain untouched by
  ordinary loads, updates, touches, and expiry cleanup. A preserved future
  record returned by `update/3` or `update_ttl/3` is reported as
  `{:ok, opaque_record}` so callers can distinguish it from an absent row.
  `update_ttl/3` must
  delete an already expired record with a version understood by the adapter
  and return `:not_found` rather than renewing it. On success it
  must return the updated record. If the supplied timestamp is older than the
  record's current `"last_seen_ms"`, adapters must retain the newer value; a
  successful touch must never rewind session activity. Adapters may implement
  `count_active/1` to let server stats count sessions without materializing
  bounded record pages; otherwise the server falls back to `list_active/1`.
  They may also implement `list_active_keys/4` to provide bounded, cursor-based
  operator visibility without loading principal bindings or complete session
  records. The returned keys must be scoped to the requested namespace, ordered
  by session ID in ascending binary/UTF-8 order, and accompanied by the last
  returned ID as `next_cursor` only when more keys remain. For externally
  supplied keys,
  `load/2`, `update/3`, and `update_ttl/3` should treat malformed or
  unrepresentable keys as absent, while `delete/2` should remain idempotent;
  valid keys from another configured namespace must still return the
  namespace-mismatch error.
  """

  @type store :: term()
  @type key :: {String.t(), String.t()}
  @type session_record :: map()
  @type active_key_page :: %{keys: [key()], next_cursor: String.t() | nil}
  @type update_fun ::
          (session_record() -> {:ok, session_record()} | :delete | {:error, term()})

  @callback save(store(), key(), session_record()) :: :ok | {:error, term()}
  @callback load(store(), key()) :: {:ok, session_record()} | :not_found | {:error, term()}
  @callback delete(store(), key()) :: :ok | {:error, term()}
  @callback list_active(store()) :: {:ok, [{key(), session_record()}]} | {:error, term()}
  @callback count_active(store()) :: {:ok, non_neg_integer()} | {:error, term()}
  @callback list_active_keys(store(), String.t(), String.t() | nil, pos_integer()) ::
              {:ok, active_key_page()} | {:error, term()}
  @callback update_ttl(store(), key(), non_neg_integer()) ::
              {:ok, session_record()} | :not_found | {:error, term()}
  @callback update(store(), key(), update_fun()) ::
              {:ok, session_record()} | :not_found | {:error, term()}
  @callback cleanup_expired(store()) :: {:ok, [key()]} | {:error, term()}

  @optional_callbacks count_active: 1, list_active_keys: 4

  @typedoc "A configured adapter module and its opaque store handle."
  @type adapter :: {module(), store()}
end
