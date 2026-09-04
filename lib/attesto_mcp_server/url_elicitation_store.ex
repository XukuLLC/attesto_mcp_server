defmodule AttestoMCP.Server.UrlElicitationStore do
  @moduledoc """
  Durable storage contract for staged URL elicitation records.

  Records are JSON-compatible string-keyed maps with the following fields:
  `"id"`, `"namespace"`, `"subject_hash"`, `"action"`, `"fields"`,
  `"created_at_ms"`, `"expires_at_ms"`, and `"consumed_at_ms"` (nil until consumed).

  Adapters must guarantee that `consume/5` is atomic: a record is consumed at
  most once even under concurrent calls. The store must verify that the subject
  hash matches before revealing state or content. A foreign subject mismatch
  returns `{:error, :foreign}` and takes precedence over consumed or expired
  status so an unauthorized caller learns nothing about the record state.
  `cleanup_expired/2` sweeps expired records and returns at most 1,000 IDs per
  call.
  """

  @type store :: term()
  @type id :: String.t()
  @type namespace :: String.t()
  @type subject_hash :: String.t()
  @type now_ms :: non_neg_integer()
  @type elicitation_record :: %{
          required(String.t()) => term()
        }

  @typedoc "A configured adapter module and its opaque store handle."
  @type adapter :: {module(), store()}

  @callback put(store(), elicitation_record()) :: :ok | {:error, term()}
  @callback fetch(store(), namespace(), id()) ::
              {:ok, elicitation_record()} | :not_found | {:error, term()}
  @callback consume(store(), namespace(), id(), subject_hash(), now_ms()) ::
              {:ok, elicitation_record()}
              | :not_found
              | {:error, :expired | :consumed | :foreign | term()}
  @callback cleanup_expired(store(), now_ms()) :: {:ok, [id()]} | {:error, term()}
end
