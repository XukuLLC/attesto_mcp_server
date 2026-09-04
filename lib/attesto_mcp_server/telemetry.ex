defmodule AttestoMCP.Server.Telemetry do
  @moduledoc """
  Telemetry helpers for protocol, auth, handler, and transport events.

  The `[:attesto_mcp_server, :auth, :policy_failure]` event reports an invalid
  revocation result, a caught host-policy callback failure, or an HTTP verifier
  failure without including the callback reason, token claims, or principal.

  The `[:attesto_mcp_server, :session_store, :failure]` event reports a
  session-store operation that failed or a corrupt persisted row discarded by
  the bundled Ecto adapter. Its failure-specific metadata contains only the
  bounded operation atom in `:source` and a neutral `:unavailable` or
  `:corrupt_discarded` outcome.

  The `[:attesto_mcp_server, :client_ip, :exception]` event reports an invalid
  return or caught failure from an explicitly configured client-address
  callback. It contains only the HTTP transport and a neutral outcome; callback
  values and failure details are not attached.

  The `[:attesto_mcp_server, :session_store, :cleanup]` heartbeat emits a
  `:start` event for every periodic expiry pass and a `:stop` event after the
  cleanup operation. The stop measurements contain a non-negative elapsed
  `:duration` for the store call, bounded return normalization, failure
  reporting, and namespace filtering, plus the bounded `:count` of sessions
  reaped for this server namespace. Start-event dispatch, local stream closing,
  and clustered close broadcast are excluded. Stop metadata reports `:success`
  or `:unavailable`. The cleanup implementation never adds session keys,
  records, principals, tenants, or adapter error details; explicitly configured
  trusted `telemetry_metadata` remains attached. A failed pass still emits the
  existing `session_store/failure` event.

  The `[:attesto_mcp_server, :url_elicitation_store, :cleanup]` heartbeat emits
  a `:start` event for every periodic expiry pass and a `:stop` event after the
  cleanup operation. The stop measurements contain a non-negative elapsed
  `:duration` for the store call, bounded return normalization, and failure
  reporting, plus the bounded `:count` of URL elicitations reaped for this
  server namespace. Stop metadata reports `:success` or `:unavailable`. The
  cleanup implementation never adds elicitation IDs, action names, staged fields,
  subject hashes, or adapter error details; explicitly configured trusted
  `telemetry_metadata` remains attached. A failed pass still emits the
  `[:attesto_mcp_server, :url_elicitation_store, :failure]` event.

  The `[:attesto_mcp_server, :url_elicitation_store, :failure]` event reports a
  URL-elicitation-store operation that failed. Its failure-specific metadata
  contains only the bounded operation atom in `:source` and a neutral
  `:unavailable` outcome.
  """

  @prefix [:attesto_mcp_server]
  @allowed_metadata ~w(
    version protocol_version method transport status outcome duration count
    correlation_id category reason error kind source server primitive_type
    primitive_identity
  )a
  @reserved_metadata MapSet.new(@allowed_metadata ++ [:telemetry_metadata])
  @max_trusted_entries 16
  @max_trusted_key_bytes 64
  @max_trusted_value_bytes 256
  @known_methods MapSet.new([
                   "GET",
                   "POST",
                   "DELETE",
                   "ping",
                   "server/discover",
                   "initialize",
                   "notifications/initialized",
                   "notifications/cancelled",
                   "tools/list",
                   "tools/call",
                   "resources/list",
                   "resources/read",
                   "resources/templates/list",
                   "resources/subscribe",
                   "resources/unsubscribe",
                   "prompts/list",
                   "prompts/get",
                   "completion/complete",
                   "subscriptions/listen",
                   "logging/setLevel",
                   "catalog",
                   "legacy",
                   "handler",
                   "request_state_store"
                 ])

  @doc "Emits a safe event after removing credential and private payload fields."
  @spec execute(atom() | [atom()], map(), map()) :: :ok
  def execute(event, measurements \\ %{}, metadata \\ %{}) do
    :telemetry.execute(@prefix ++ List.wrap(event), measurements, safe_metadata(metadata))
  end

  @doc "Emits start/stop (or exception) events around a callback."
  @spec span(atom() | [atom()], map(), (-> {term(), map()}), keyword()) :: term()
  def span(event, metadata, fun, opts \\ []) do
    started = System.monotonic_time()
    execute([event, :start], %{system_time: System.system_time()}, metadata)

    try do
      {result, extra} = fun.()
      duration = System.monotonic_time() - started
      execute([event, :stop], %{duration: duration}, Map.merge(metadata, safe_metadata(extra)))
      result
    catch
      kind, reason ->
        duration = System.monotonic_time() - started
        stacktrace = __STACKTRACE__
        source = event |> List.wrap() |> List.first()

        execute(
          [event, :exception],
          %{duration: duration},
          metadata
          |> Map.put(:error, :exception)
          |> Map.put(:kind, kind)
          |> Map.put(:source, source)
        )

        report_exception(
          Keyword.get(opts, :exception_reporter),
          source,
          kind,
          reason,
          stacktrace,
          metadata
        )

        :erlang.raise(kind, reason, stacktrace)
    end
  end

  @doc "Invokes an explicitly trusted host exception reporter without changing request behavior."
  @spec report_exception(term(), atom() | nil, atom(), term(), list(), map()) :: :ok
  def report_exception(nil, _source, _kind, _reason, _stacktrace, _metadata), do: :ok

  def report_exception(reporter, source, kind, reason, stacktrace, metadata) do
    report = %{
      source: source,
      kind: kind,
      reason: reason,
      stacktrace: stacktrace,
      metadata: safe_metadata(metadata)
    }

    try do
      invoke_reporter(reporter, report)
      :ok
    catch
      _kind, _reason ->
        execute(
          [:exception_reporter, :failure],
          %{count: 1},
          metadata
          |> Map.put(:source, source)
          |> Map.put(:outcome, :reporter_failure)
        )

        :ok
    end
  end

  @doc "Validates bounded host metadata that may be attached to every server event."
  @spec validate_trusted_metadata!(map() | nil) :: :ok
  def validate_trusted_metadata!(nil), do: :ok

  def validate_trusted_metadata!(metadata) when is_map(metadata) do
    valid? =
      map_size(metadata) <= @max_trusted_entries and
        Enum.all?(metadata, fn {key, value} ->
          valid_trusted_key?(key) and not reserved_metadata_key?(key) and
            valid_trusted_value?(value)
        end)

    if valid?,
      do: :ok,
      else:
        raise(
          ArgumentError,
          ":telemetry_metadata must contain at most 16 bounded scalar entries and no reserved keys"
        )
  end

  def validate_trusted_metadata!(_metadata) do
    raise ArgumentError, ":telemetry_metadata must be a map"
  end

  @doc false
  @spec protocol_method(term()) :: String.t() | :unknown
  def protocol_method(method) when is_binary(method) do
    if MapSet.member?(@known_methods, method), do: method, else: :unknown
  end

  def protocol_method(_method), do: :unknown

  defp safe_metadata(metadata) when is_map(metadata) do
    safe =
      metadata
      |> Map.take(@allowed_metadata)
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        Map.put(acc, key, safe_field(key, value))
      end)

    Map.merge(trusted_metadata(Map.get(metadata, :telemetry_metadata)), safe)
  end

  defp safe_metadata(_), do: %{}

  defp safe_field(:correlation_id, value) when is_binary(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp safe_field(:reason, value) when is_atom(value), do: value
  defp safe_field(:category, value) when is_atom(value), do: value
  defp safe_field(:error, value) when is_atom(value), do: value
  defp safe_field(:kind, value) when is_atom(value), do: value
  defp safe_field(:source, value) when is_atom(value), do: value
  defp safe_field(:server, value) when is_atom(value), do: value

  defp safe_field(:primitive_type, value)
       when value in [:tool, :prompt, :resource, :template, :completion],
       do: value

  defp safe_field(:primitive_identity, value) when is_binary(value),
    do: safe(value)

  defp safe_field(_key, value), do: safe(value)

  defp safe(value) when is_binary(value) and byte_size(value) > 256,
    do: String.slice(value, 0, 256)

  defp safe(value) when is_binary(value), do: value

  defp safe(value) when is_atom(value) or is_number(value) or is_boolean(value) or is_nil(value),
    do: value

  defp safe(value) when is_list(value), do: Enum.map(value, &safe/1)

  defp safe(value) when is_map(value),
    do: Map.take(value, [:method, :transport, :protocol_version, :status, :outcome])

  defp safe(_), do: :opaque

  defp trusted_metadata(metadata)
       when is_map(metadata) and map_size(metadata) <= @max_trusted_entries do
    Enum.reduce(metadata, %{}, fn {key, value}, acc ->
      if valid_trusted_key?(key) and not reserved_metadata_key?(key) and
           valid_trusted_value?(value),
         do: Map.put(acc, key, value),
         else: acc
    end)
  end

  defp trusted_metadata(_metadata), do: %{}

  defp valid_trusted_key?(key) when is_atom(key),
    do: byte_size(Atom.to_string(key)) in 1..@max_trusted_key_bytes

  defp valid_trusted_key?(key) when is_binary(key),
    do: byte_size(key) in 1..@max_trusted_key_bytes and String.valid?(key)

  defp valid_trusted_key?(_key), do: false

  defp reserved_metadata_key?(key) when is_binary(key) do
    Enum.any?(@reserved_metadata, &(Atom.to_string(&1) == key))
  end

  defp reserved_metadata_key?(key), do: MapSet.member?(@reserved_metadata, key)

  defp valid_trusted_value?(value)
       when is_atom(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: true

  defp valid_trusted_value?(value) when is_binary(value),
    do: byte_size(value) <= @max_trusted_value_bytes and String.valid?(value)

  defp valid_trusted_value?(_value), do: false

  defp invoke_reporter(reporter, report) when is_function(reporter, 1), do: reporter.(report)

  defp invoke_reporter({module, function}, report)
       when is_atom(module) and is_atom(function),
       do: apply(module, function, [report])

  defp invoke_reporter({module, function, args}, report)
       when is_atom(module) and is_atom(function) and is_list(args),
       do: apply(module, function, args ++ [report])

  defp invoke_reporter(_reporter, _report), do: :ok
end
