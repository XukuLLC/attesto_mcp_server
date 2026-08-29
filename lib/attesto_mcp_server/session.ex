defmodule AttestoMCP.Server.Session do
  @moduledoc """
  Bounded legacy session records with principal binding and expiry.

  Durable adapters store the versioned JSON-compatible value returned by
  `to_record/1`. Live stream references are intentionally excluded and must be
  reopened after a server or node restart. Unknown record fields are ignored;
  unknown format versions and malformed or oversized records fail closed.
  """

  @record_version 1
  @max_binding_bytes 65_536
  @max_record_bytes 1_000_000
  @legacy_versions ["2025-11-25", "2025-06-18"]
  @log_levels ["debug", "info", "notice", "warning", "error", "critical", "alert", "emergency"]
  @max_resource_subscriptions 128
  @max_resource_uri_bytes 4_096

  defstruct [
    :id,
    :principal,
    :tenant,
    :version,
    :initialized,
    :created_at,
    :last_seen,
    :absolute_timeout,
    :idle_timeout,
    :streams,
    :client_capabilities,
    :resource_subscriptions,
    :logging_level
  ]

  def new(principal, tenant, opts \\ []) do
    now = System.system_time(:millisecond)

    %__MODULE__{
      id: random_id(),
      principal: principal,
      tenant: tenant,
      version: nil,
      initialized: false,
      created_at: now,
      last_seen: now,
      absolute_timeout: Keyword.get(opts, :absolute_timeout) || 86_400_000,
      idle_timeout: Keyword.get(opts, :idle_timeout) || 1_800_000,
      streams: %{},
      client_capabilities: %{},
      resource_subscriptions: %{},
      logging_level: nil
    }
  end

  def valid?(%__MODULE__{} = session, now \\ System.system_time(:millisecond)) do
    now - session.created_at <= session.absolute_timeout and
      now - session.last_seen <= session.idle_timeout
  end

  def touch(%__MODULE__{} = session), do: %{session | last_seen: System.system_time(:millisecond)}

  def same_principal?(%__MODULE__{principal: expected}, actual), do: expected == actual
  def same_tenant?(%__MODULE__{tenant: expected}, actual), do: expected == actual

  @doc "Serializes persistent session state without live processes or callbacks."
  @spec to_record(t()) :: {:ok, map()} | {:error, term()}
  def to_record(%__MODULE__{} = session) do
    with {:ok, principal} <- encode_binding(session.principal),
         {:ok, tenant} <- encode_binding(session.tenant) do
      record = %{
        "format_version" => @record_version,
        "id" => session.id,
        "principal" => principal,
        "tenant" => tenant,
        "protocol_version" => session.version,
        "initialized" => session.initialized,
        "created_at_ms" => session.created_at,
        "last_seen_ms" => session.last_seen,
        "absolute_timeout_ms" => session.absolute_timeout,
        "idle_timeout_ms" => session.idle_timeout,
        "client_capabilities" => session.client_capabilities,
        "resource_subscriptions" => session.resource_subscriptions,
        "logging_level" => session.logging_level
      }

      case Jason.encode(record) do
        {:ok, encoded} when byte_size(encoded) <= @max_record_bytes -> {:ok, record}
        _ -> {:error, :record_too_large}
      end
    end
  end

  @doc "Restores a durable session record with empty live-stream state."
  @spec from_record(map()) :: {:ok, t()} | {:error, term()}
  def from_record(%{"format_version" => @record_version} = record) do
    with :ok <- validate_record_size(record),
         :ok <- validate_record_fields(record),
         {:ok, principal} <- decode_binding(record["principal"]),
         {:ok, tenant} <- decode_binding(record["tenant"]) do
      {:ok,
       %__MODULE__{
         id: record["id"],
         principal: principal,
         tenant: tenant,
         version: record["protocol_version"],
         initialized: record["initialized"],
         created_at: record["created_at_ms"],
         last_seen: record["last_seen_ms"],
         absolute_timeout: record["absolute_timeout_ms"],
         idle_timeout: record["idle_timeout_ms"],
         streams: %{},
         client_capabilities: record["client_capabilities"],
         resource_subscriptions: record["resource_subscriptions"],
         logging_level: record["logging_level"]
       }}
    end
  end

  def from_record(%{"format_version" => _version}), do: {:error, :unknown_record_version}
  def from_record(_record), do: {:error, :invalid_record}

  @type t :: %__MODULE__{}

  defp validate_record_fields(record) do
    valid? =
      is_binary(record["id"]) and byte_size(record["id"]) in 1..256 and
        String.valid?(record["id"]) and
        record["protocol_version"] in [nil | @legacy_versions] and
        is_boolean(record["initialized"]) and valid_nonnegative?(record["created_at_ms"]) and
        valid_nonnegative?(record["last_seen_ms"]) and
        record["last_seen_ms"] >= record["created_at_ms"] and
        valid_positive?(record["absolute_timeout_ms"]) and
        valid_positive?(record["idle_timeout_ms"]) and
        is_map(record["client_capabilities"]) and
        valid_resource_subscriptions?(record["resource_subscriptions"]) and
        (is_nil(record["logging_level"]) or record["logging_level"] in @log_levels)

    if valid?, do: :ok, else: {:error, :invalid_record}
  end

  defp valid_nonnegative?(value), do: is_integer(value) and value >= 0
  defp valid_positive?(value), do: is_integer(value) and value > 0

  defp validate_record_size(record) do
    case Jason.encode(record) do
      {:ok, encoded} when byte_size(encoded) <= @max_record_bytes -> :ok
      _ -> {:error, :invalid_record}
    end
  end

  defp valid_resource_subscriptions?(subscriptions) when is_map(subscriptions) do
    map_size(subscriptions) <= @max_resource_subscriptions and
      Enum.all?(subscriptions, fn {uri, subscribed?} ->
        is_binary(uri) and byte_size(uri) in 1..@max_resource_uri_bytes and String.valid?(uri) and
          subscribed? == true
      end)
  end

  defp valid_resource_subscriptions?(_subscriptions), do: false

  defp encode_binding(term) do
    if portable_term?(term) do
      encoded = :erlang.term_to_binary(term)

      if byte_size(encoded) <= @max_binding_bytes,
        do: {:ok, Base.url_encode64(encoded, padding: false)},
        else: {:error, :binding_too_large}
    else
      {:error, :nonportable_binding}
    end
  rescue
    _ -> {:error, :nonportable_binding}
  end

  defp decode_binding(value) when is_binary(value) do
    with true <- byte_size(value) <= div(@max_binding_bytes * 4 + 2, 3),
         {:ok, binary} <- Base.url_decode64(value, padding: false),
         true <- byte_size(binary) <= @max_binding_bytes,
         false <- compressed_external_term?(binary),
         term <- :erlang.binary_to_term(binary, [:safe]),
         true <- portable_term?(term) do
      {:ok, term}
    else
      _ -> {:error, :invalid_binding}
    end
  rescue
    _ -> {:error, :invalid_binding}
  end

  defp decode_binding(_value), do: {:error, :invalid_binding}

  defp compressed_external_term?(<<131, 80, _rest::binary>>), do: true
  defp compressed_external_term?(_binary), do: false

  defp portable_term?(term), do: match?({:ok, _remaining}, portable_term(term, 0, 10_000))

  defp portable_term(_term, depth, _remaining) when depth > 32, do: :error
  defp portable_term(_term, _depth, remaining) when remaining <= 0, do: :error

  defp portable_term(term, _depth, remaining)
       when is_binary(term) or is_atom(term) or is_number(term),
       do: {:ok, remaining - 1}

  defp portable_term(term, depth, remaining) when is_list(term) do
    portable_children(term, depth, remaining - 1)
  end

  defp portable_term(term, depth, remaining) when is_tuple(term) do
    portable_children(Tuple.to_list(term), depth, remaining - 1)
  end

  defp portable_term(term, depth, remaining) when is_map(term) do
    term
    |> :maps.to_list()
    |> Enum.flat_map(fn {key, value} -> [key, value] end)
    |> portable_children(depth, remaining - 1)
  end

  defp portable_term(_term, _depth, _remaining), do: :error

  defp portable_children(children, depth, remaining) do
    Enum.reduce_while(children, {:ok, remaining}, fn child, {:ok, budget} ->
      case portable_term(child, depth + 1, budget) do
        {:ok, budget} -> {:cont, {:ok, budget}}
        :error -> {:halt, :error}
      end
    end)
  rescue
    _ -> :error
  end

  defp random_id do
    :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
  end
end
