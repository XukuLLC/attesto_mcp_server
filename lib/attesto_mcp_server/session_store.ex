defmodule AttestoMCP.Server.SessionStore do
  @moduledoc """
  Durable legacy-session storage contract.

  Keys are `{namespace, session_id}` data tuples. Adapters must never convert
  either component to an atom. `update/3`, `update_ttl/3`, and
  `cleanup_expired/1` must be atomic with respect to one another. Records are
  the versioned JSON-compatible maps documented by
  `AttestoMCP.Server.Session.to_record/1`; unknown fields must be preserved by
  an adapter and ignored by the server. `update_ttl/3` must delete an already
  expired record and return `:not_found` rather than renewing it. On success it
  must set `"last_seen_ms"` exactly to the supplied timestamp and return that
  updated record.
  """

  @type store :: term()
  @type key :: {String.t(), String.t()}
  @type session_record :: map()
  @type update_fun ::
          (session_record() -> {:ok, session_record()} | :delete | {:error, term()})

  @callback save(store(), key(), session_record()) :: :ok | {:error, term()}
  @callback load(store(), key()) :: {:ok, session_record()} | :not_found | {:error, term()}
  @callback delete(store(), key()) :: :ok | {:error, term()}
  @callback list_active(store()) :: {:ok, [{key(), session_record()}]} | {:error, term()}
  @callback update_ttl(store(), key(), non_neg_integer()) ::
              {:ok, session_record()} | :not_found | {:error, term()}
  @callback update(store(), key(), update_fun()) ::
              {:ok, session_record()} | :not_found | {:error, term()}
  @callback cleanup_expired(store()) :: {:ok, [key()]} | {:error, term()}

  @typedoc "A configured adapter module and its opaque store handle."
  @type adapter :: {module(), store()}
end
