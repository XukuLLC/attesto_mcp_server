defmodule AttestoMCP.Server.Session do
  @moduledoc """
  Bounded session records for session-bound MCP revisions, with principal
  binding and expiry.

  Durable adapters store the versioned JSON-compatible value returned by
  `to_record/1`. Live stream references are intentionally excluded and must be
  reopened after a server or node restart. Unknown record fields are ignored;
  malformed or oversized current-version records fail closed. Higher integer
  format versions remain opaque and are preserved by the bundled stores.

  The `principal` field stores an identity binding, not necessarily the richer
  principal value exposed to request handlers. Principal and tenant bindings
  may contain existing atoms because they are
  encoded as bounded Erlang terms. Safe restoration never creates atoms from
  persisted data, so an atom-bearing binding can be used only on nodes where
  those atoms already exist. A node that cannot safely decode such a binding
  reports `:binding_unavailable`; durable adapters must preserve the record and
  callers should treat it as unavailable until the required atoms are loaded.
  """

  @record_version 1
  # Leave ample headroom below PostgreSQL's signed BIGINT ceiling for the
  # current epoch-millisecond timestamp when deriving expiry columns.
  @max_timeout_ms 9_000_000_000_000_000_000
  @max_binding_bytes 65_536
  @max_record_bytes 1_000_000
  @max_binding_scan_budget 10_000
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

  @doc "Returns the largest session timeout accepted by all session stores."
  @spec max_timeout_ms() :: pos_integer()
  def max_timeout_ms, do: @max_timeout_ms

  @doc "Checks the common positive, signed-BIGINT-safe session timeout range."
  @spec valid_timeout?(term()) :: boolean()
  def valid_timeout?(value), do: is_integer(value) and value in 1..@max_timeout_ms

  @doc false
  @spec record_version_status(term()) :: :current | :future | :invalid
  def record_version_status(%{"format_version" => version})
      when is_integer(version) and version > @record_version,
      do: :future

  def record_version_status(%{"format_version" => @record_version}), do: :current
  def record_version_status(_record), do: :invalid

  def touch(%__MODULE__{} = session) do
    %{session | last_seen: max(session.last_seen, System.system_time(:millisecond))}
  end

  def same_principal?(%__MODULE__{principal: expected}, actual), do: expected == actual
  def same_tenant?(%__MODULE__{tenant: expected}, actual), do: expected == actual

  @doc false
  @spec validate_binding(term()) :: :ok | {:error, :binding_too_large | :nonportable_binding}
  def validate_binding(binding) do
    case encode_binding(binding) do
      {:ok, _encoded} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc "Serializes persistent session state without live processes or callbacks."
  @spec to_record(t()) :: {:ok, map()} | {:error, term()}
  def to_record(%__MODULE__{} = session) do
    with true <- valid_timeout?(session.absolute_timeout),
         true <- valid_timeout?(session.idle_timeout),
         {:ok, principal} <- encode_binding(session.principal),
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
    else
      false -> {:error, :invalid_session_timeout}
      error -> error
    end
  end

  @doc "Restores a durable session record with empty live-stream state."
  @spec from_record(map()) :: {:ok, t()} | {:error, term()}
  def from_record(record) when is_map(record) do
    case record_version_status(record) do
      :current ->
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

      :future ->
        {:error, :unknown_record_version}

      :invalid ->
        {:error, :invalid_record}
    end
  end

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
        valid_timeout?(record["absolute_timeout_ms"]) and
        valid_timeout?(record["idle_timeout_ms"]) and
        is_map(record["client_capabilities"]) and
        valid_resource_subscriptions?(record["resource_subscriptions"]) and
        (is_nil(record["logging_level"]) or record["logging_level"] in @log_levels)

    if valid?, do: :ok, else: {:error, :invalid_record}
  end

  defp valid_nonnegative?(value), do: is_integer(value) and value >= 0

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
         false <- compressed_external_term?(binary) do
      case safe_decode_binding(binary) do
        {:ok, term} -> {:ok, term}
        {:error, :binding_unavailable} -> {:error, :binding_unavailable}
        {:error, :invalid_binding} -> {:error, :invalid_binding}
      end
    else
      _ -> {:error, :invalid_binding}
    end
  rescue
    _ -> {:error, :invalid_binding}
  end

  defp decode_binding(_value), do: {:error, :invalid_binding}

  defp compressed_external_term?(<<131, 80, _rest::binary>>), do: true
  defp compressed_external_term?(_binary), do: false

  defp safe_decode_binding(binary) do
    try do
      term = :erlang.binary_to_term(binary, [:safe])

      if portable_term?(term), do: {:ok, term}, else: {:error, :invalid_binding}
    rescue
      _exception ->
        if unavailable_atom_term?(binary),
          do: {:error, :binding_unavailable},
          else: {:error, :invalid_binding}
    catch
      _kind, _reason ->
        if unavailable_atom_term?(binary),
          do: {:error, :binding_unavailable},
          else: {:error, :invalid_binding}
    end
  end

  # `binary_to_term(..., [:safe])` rejects an atom that is not already loaded
  # in this VM. The exception does not identify that case, so inspect only the
  # bounded, portable subset of ETF to distinguish it from malformed input.
  # The scanner uses `binary_to_existing_atom/2`; it never creates atoms from
  # persisted data.
  defp unavailable_atom_term?(<<131, rest::binary>>) do
    case scan_portable_term(rest, 0, @max_binding_scan_budget) do
      {:ok, <<>>, :unavailable, _budget} -> true
      _ -> false
    end
  end

  defp unavailable_atom_term?(_binary), do: false

  defp scan_portable_term(_binary, depth, _budget) when depth > 32,
    do: :invalid

  defp scan_portable_term(_binary, _depth, budget) when budget <= 0,
    do: :invalid

  defp scan_portable_term(<<97, _value, rest::binary>>, _depth, budget),
    do: {:ok, rest, :known, budget - 1}

  defp scan_portable_term(<<98, _value::binary-size(4), rest::binary>>, _depth, budget),
    do: {:ok, rest, :known, budget - 1}

  defp scan_portable_term(<<70, value::binary-size(8), rest::binary>>, _depth, budget) do
    if valid_float_external_term?(70, value),
      do: {:ok, rest, :known, budget - 1},
      else: :invalid
  end

  defp scan_portable_term(<<99, value::binary-size(31), rest::binary>>, _depth, budget) do
    if valid_float_external_term?(99, value),
      do: {:ok, rest, :known, budget - 1},
      else: :invalid
  end

  defp scan_portable_term(<<110, size, sign, rest::binary>>, _depth, budget)
       when sign in 0..1 and size <= byte_size(rest) do
    <<_digits::binary-size(^size), tail::binary>> = rest
    {:ok, tail, :known, budget - 1}
  end

  defp scan_portable_term(<<111, size::unsigned-big-32, sign, rest::binary>>, _depth, budget)
       when sign in 0..1 and size <= byte_size(rest) do
    <<_digits::binary-size(^size), tail::binary>> = rest
    {:ok, tail, :known, budget - 1}
  end

  defp scan_portable_term(<<109, size::unsigned-big-32, rest::binary>>, _depth, budget)
       when size <= byte_size(rest) do
    <<_value::binary-size(^size), tail::binary>> = rest
    {:ok, tail, :known, budget - 1}
  end

  defp scan_portable_term(<<77, size::unsigned-big-32, bits, rest::binary>>, _depth, budget)
       when bits == 8 and size > 0 and size <= byte_size(rest) do
    <<_value::binary-size(^size), tail::binary>> = rest
    {:ok, tail, :known, budget - 1}
  end

  defp scan_portable_term(<<107, size::unsigned-big-16, rest::binary>>, _depth, budget)
       when size <= byte_size(rest) and size + 1 <= budget do
    <<_value::binary-size(^size), tail::binary>> = rest
    {:ok, tail, :known, budget - size - 1}
  end

  defp scan_portable_term(<<106, rest::binary>>, _depth, budget),
    do: {:ok, rest, :known, budget - 1}

  defp scan_portable_term(<<100, size::unsigned-big-16, rest::binary>>, _depth, budget)
       when size <= byte_size(rest) do
    <<value::binary-size(^size), tail::binary>> = rest
    scan_atom(value, :latin1, tail, budget - 1)
  end

  defp scan_portable_term(<<115, size, rest::binary>>, _depth, budget)
       when size <= byte_size(rest) do
    <<value::binary-size(^size), tail::binary>> = rest
    scan_atom(value, :latin1, tail, budget - 1)
  end

  defp scan_portable_term(<<118, size::unsigned-big-16, rest::binary>>, _depth, budget)
       when size <= byte_size(rest) do
    <<value::binary-size(^size), tail::binary>> = rest
    scan_atom(value, :utf8, tail, budget - 1)
  end

  defp scan_portable_term(<<119, size, rest::binary>>, _depth, budget)
       when size <= byte_size(rest) do
    <<value::binary-size(^size), tail::binary>> = rest
    scan_atom(value, :utf8, tail, budget - 1)
  end

  defp scan_portable_term(<<104, size, rest::binary>>, depth, budget),
    do: scan_terms(rest, size, depth + 1, budget - 1, :known)

  defp scan_portable_term(<<105, size::unsigned-big-32, rest::binary>>, depth, budget)
       when size <= byte_size(rest) do
    scan_terms(rest, size, depth + 1, budget - 1, :known)
  end

  defp scan_portable_term(<<108, size::unsigned-big-32, rest::binary>>, depth, budget)
       when size <= byte_size(rest) do
    with {:ok, tail, status, budget} <-
           scan_terms(rest, size, depth + 1, budget - 1, :known),
         <<106, remaining::binary>> <- tail do
      {:ok, remaining, status, budget}
    else
      _ -> :invalid
    end
  end

  defp scan_portable_term(<<116, size::unsigned-big-32, rest::binary>>, depth, budget)
       when size <= div(byte_size(rest), 2) do
    scan_terms(rest, size * 2, depth + 1, budget - 1, :known)
  end

  defp scan_portable_term(_binary, _depth, _budget), do: :invalid

  defp scan_terms(rest, 0, _depth, budget, status),
    do: {:ok, rest, status, budget}

  defp scan_terms(rest, count, depth, budget, status) when count > 0 do
    case scan_portable_term(rest, depth, budget) do
      {:ok, remaining, child_status, child_budget} ->
        scan_terms(
          remaining,
          count - 1,
          depth,
          child_budget,
          merge_atom_status(status, child_status)
        )

      :invalid ->
        :invalid
    end
  end

  defp scan_atom(value, encoding, rest, budget) do
    if valid_atom_bytes?(value, encoding) do
      status = if existing_atom?(value, encoding), do: :known, else: :unavailable
      {:ok, rest, status, budget}
    else
      :invalid
    end
  end

  defp valid_float_external_term?(tag, value) when tag in [70, 99] do
    case :erlang.binary_to_term(<<131, tag, value::binary>>, [:safe]) do
      decoded when is_float(decoded) -> true
      _ -> false
    end
  rescue
    _ -> false
  catch
    _kind, _reason -> false
  end

  defp valid_atom_bytes?(value, encoding) do
    converted = :unicode.characters_to_binary(value, encoding, :utf8)
    is_binary(converted) and String.valid?(converted) and String.length(converted) <= 255
  rescue
    _ -> false
  end

  defp existing_atom?(value, encoding) do
    _ = :erlang.binary_to_existing_atom(value, encoding)
    true
  rescue
    _ -> false
  catch
    _kind, _reason -> false
  end

  defp merge_atom_status(:unavailable, _other), do: :unavailable
  defp merge_atom_status(_other, :unavailable), do: :unavailable
  defp merge_atom_status(_left, _right), do: :known

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
