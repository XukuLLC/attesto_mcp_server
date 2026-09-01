defmodule AttestoMCP.Server.SessionStore.Ecto.CompileSentinel do
  @moduledoc false

  @ecto_available Code.ensure_loaded?(Ecto.Schema) and Code.ensure_loaded?(Ecto.Query) and
                    Code.ensure_loaded?(Ecto.Changeset)

  # Optional dependencies can be added after this package has already been
  # compiled in a consumer. Tell Mix to revisit this source when Ecto's
  # availability changes so the schema and adapter appear (or disappear)
  # during an ordinary incremental compile, without a forced rebuild.
  @doc false
  def __mix_recompile__? do
    @ecto_available !=
      (Code.ensure_loaded?(Ecto.Schema) and Code.ensure_loaded?(Ecto.Query) and
         Code.ensure_loaded?(Ecto.Changeset))
  end
end

if Code.ensure_loaded?(Ecto.Schema) and Code.ensure_loaded?(Ecto.Query) and
     Code.ensure_loaded?(Ecto.Changeset) do
  defmodule AttestoMCP.Server.SessionStore.Ecto.Session do
    @moduledoc """
    Ecto schema for durable MCP session records.

    The session namespace is part of the primary key. This lets multiple
    named MCP servers share one table without allowing a session id issued by
    one server to be loaded by another. The complete versioned record is kept
    in `:record`; the integer expiry columns are a denormalized index used for
    bounded SQL-side filtering and cleanup.
    """

    use Ecto.Schema

    import Ecto.Changeset

    @max_session_timeout_ms AttestoMCP.Server.Session.max_timeout_ms()

    @type t :: %__MODULE__{}

    @primary_key false
    schema "attesto_mcp_sessions" do
      field(:namespace, :string, primary_key: true)
      field(:session_id, :string, primary_key: true)
      field(:record, :map)
      field(:created_at_ms, :integer)
      field(:last_seen_ms, :integer)
      field(:absolute_timeout_ms, :integer)
      field(:idle_timeout_ms, :integer)
      field(:expires_at_ms, :integer)

      timestamps(type: :utc_datetime_usec)
    end

    @fields ~w(namespace session_id record created_at_ms last_seen_ms absolute_timeout_ms idle_timeout_ms expires_at_ms)a

    @doc false
    @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
    def changeset(session, attrs) do
      session
      |> cast(attrs, @fields)
      |> validate_required(@fields)
      |> validate_length(:namespace, min: 1, max: 256)
      |> validate_length(:session_id, min: 1, max: 256)
      |> validate_number(:created_at_ms, greater_than_or_equal_to: 0)
      |> validate_number(:last_seen_ms, greater_than_or_equal_to: 0)
      |> validate_number(:absolute_timeout_ms,
        greater_than: 0,
        less_than_or_equal_to: @max_session_timeout_ms
      )
      |> validate_number(:idle_timeout_ms,
        greater_than: 0,
        less_than_or_equal_to: @max_session_timeout_ms
      )
      |> validate_number(:expires_at_ms, greater_than_or_equal_to: 0)
      |> unique_constraint([:namespace, :session_id], name: :attesto_mcp_sessions_pkey)
    end
  end

  defmodule AttestoMCP.Server.SessionStore.Ecto do
    @moduledoc """
    Optional Ecto-backed implementation of `AttestoMCP.Server.SessionStore`.

    The adapter is stateless: its store handle contains the host repository,
    namespace, and optional PostgreSQL schema prefix. The host application remains
    responsible for supervising the repository and applying the migration
    that creates `attesto_mcp_sessions`.

    A row is keyed by `{namespace, session_id}`.  The namespace is deliberately
    persisted as part of the key so separate named MCP servers can safely use
    one table.  The complete versioned record is stored in JSON, while its
    expiry fields are duplicated in integer columns for indexed, bounded list
    and cleanup queries. Records accept only JSON-native values with binary
    object keys, so every accepted unknown field survives the JSONB round trip
    without atom conversion or key collisions.

    Ecto is an optional dependency of this package.  Consumers that do not
    include Ecto do not compile this module; ETS remains the built-in store.

    This adapter targets PostgreSQL (`Ecto.Adapters.Postgres`).  It relies on
    PostgreSQL row locks for atomic read-modify-write operations and JSONB
    encoding for the record column; other Ecto adapters are rejected at
    construction time. Lock waits are limited to one second, individual query
    calls to 1.5 seconds, and transactions to three seconds so the adapter
    returns a neutral outage before the server's call budget is exhausted.
    Operations that need an adapter-owned row-locking transaction are
    unsupported inside a caller-owned `repo.transaction`. This includes
    updates, record listings, expiry cleanup, and corrupt-row cleanup reached
    by a load. The adapter detects that context before opening its own
    transaction or changing transaction-local settings and returns
    `{:error, :nested_transaction_unsupported}`; call those operations outside
    the host transaction instead.

    Malformed or unrepresentable external keys are treated as absent by
    `load/2`, `update/3`, and `update_ttl/3`, and as an idempotent success by
    `delete/2`. A valid key bound to another namespace still returns
    `{:error, :namespace_mismatch}`.

    The table contains authenticated principal and tenant bindings and is part
    of the authorization trust boundary. Give the application role access only
    to its intended schema/table, keep direct writers out, and provision enough
    Repo connections for normal application traffic plus concurrent MCP calls.
    A structurally corrupt row is removed under a row lock during direct load
    or record listing instead of blocking every later call. A row with a future
    `format_version`, or a valid atom-bearing binding that this node cannot
    decode without creating an atom, is preserved. Future-version rows are also
    excluded from expiry maintenance. The adapter emits a bounded
    `[:attesto_mcp_server, :session_store, :failure]` event with outcome
    `:corrupt_discarded` and no row content or identifier.

    ## Configuration

        {:ok, store} =
          AttestoMCP.Server.SessionStore.Ecto.new(
            repo: MyApp.Repo,
            namespace: "primary-mcp",
            schema_prefix: "mcp"
          )

        AttestoMCP.Server.start_link(
          session_store: {AttestoMCP.Server.SessionStore.Ecto, store},
          session_namespace: "primary-mcp"
        )

    `:repo` and `:namespace` are required. The namespace must be a non-empty
    UTF-8 string up to 256 bytes and is bound to the store handle: every key
    operation and every list/cleanup query is restricted to that namespace.
    When this handle is configured on `AttestoMCP.Server`, its namespace must
    exactly match the server's `:session_namespace` option; mismatches are
    rejected during startup.

    `:schema_prefix` defaults to `nil` (the repository's default schema);
    arbitrary table names are intentionally not accepted, keeping migrations
    and runtime queries aligned.

    Record-bearing listings return the first eight active rows ordered by
    expiry and session ID; they are bounded snapshots, not a pagination API.
    Counting uses a separate SQL aggregate. Cleanup trusts the indexed expiry
    column, selects only keys, and claims at most 1,000 rows. The server repeats
    cleanup periodically, so a large expired backlog is drained in bounded
    batches without loading record payloads. Corruption is detected and
    reported only when a direct load or record-bearing listing validates the
    complete record against its indexed expiry mirrors.
    """

    @behaviour AttestoMCP.Server.SessionStore

    import Ecto.Query, only: [from: 2]

    alias AttestoMCP.Server.SessionStore.Ecto.Session
    alias AttestoMCP.Server.Telemetry

    @max_key_bytes 256
    @max_record_bytes 1_000_000
    @max_db_integer 9_223_372_036_854_775_807
    @max_session_timeout_ms AttestoMCP.Server.Session.max_timeout_ms()
    @max_schema_prefix_bytes 63
    @max_list 8
    @max_cleanup 1_000
    @query_timeout_ms 1_500
    @lock_timeout_ms 1_000
    @transaction_timeout_ms 3_000
    @option_keys [:repo, :schema_prefix, :namespace]

    @type store :: %{
            repo: module(),
            namespace: String.t(),
            schema_prefix: String.t() | nil
          }

    @doc "Builds a stateless store handle for a host repository."
    @spec new(keyword()) :: {:ok, store()} | {:error, term()}
    def new(opts \\ [])

    def new(opts) when is_list(opts) do
      if valid_options?(opts) do
        repo = Keyword.get(opts, :repo)
        namespace = Keyword.get(opts, :namespace)
        prefix = Keyword.get(opts, :schema_prefix)

        cond do
          not valid_repo?(repo) -> {:error, :invalid_repo}
          not valid_key_part?(namespace) -> {:error, :invalid_namespace}
          not valid_prefix?(prefix) -> {:error, :invalid_schema_prefix}
          true -> {:ok, %{repo: repo, namespace: namespace, schema_prefix: prefix}}
        end
      else
        {:error, :invalid_options}
      end
    end

    def new(_opts), do: {:error, :invalid_options}

    @doc false
    @spec namespace_matches?(store(), String.t()) :: boolean()
    def namespace_matches?(store, namespace) when is_binary(namespace) do
      case checked_store(store) do
        {:ok, %{namespace: ^namespace}} -> true
        _other -> false
      end
    end

    def namespace_matches?(_store, _namespace), do: false

    @impl true
    @spec save(store(), AttestoMCP.Server.SessionStore.key(), map()) :: :ok | {:error, term()}
    def save(store, key, record) when is_map(record) do
      with {:ok, %{repo: repo, namespace: namespace} = config} <- checked_store(store),
           {:ok, attrs} <- record_attrs(key, record, namespace) do
        safely(fn ->
          changeset = Session.changeset(%Session{}, attrs)

          insert_opts =
            [
              on_conflict:
                {:replace,
                 [
                   :record,
                   :created_at_ms,
                   :last_seen_ms,
                   :absolute_timeout_ms,
                   :idle_timeout_ms,
                   :expires_at_ms,
                   :updated_at
                 ]},
              conflict_target: [:namespace, :session_id]
            ] ++ query_opts(config)

          case repo.insert(changeset, insert_opts) do
            {:ok, _row} -> :ok
            {:error, _changeset} -> {:error, :write_failed}
          end
        end)
      end
    end

    def save(_store, _key, _record), do: {:error, :invalid_record}

    @impl true
    @spec load(store(), AttestoMCP.Server.SessionStore.key()) ::
            {:ok, map()} | :not_found | {:error, term()}
    def load(store, key) do
      with {:ok, %{repo: repo, namespace: expected_namespace} = config} <- checked_store(store),
           {:ok, {namespace, session_id}} <- lookup_key(key),
           :ok <- ensure_namespace(expected_namespace, namespace) do
        safely(fn ->
          now = System.system_time(:millisecond)

          case repo.one(key_query(namespace, session_id), query_opts(config)) do
            nil ->
              :not_found

            %Session{} = row ->
              if unknown_record_version?(row.record) do
                # A rolling deployment may read a record written by a newer
                # package version. Return it to the server for a neutral
                # unsupported result; never expire or discard it here.
                {:ok, row.record}
              else
                with {:ok, record} <- validated_row_record(row, expected_namespace),
                     false <- expired?(record, now) do
                  {:ok, record}
                else
                  true ->
                    :not_found

                  {:error, :store_corrupt} ->
                    discard_corrupt_row(repo, config, namespace, session_id, now)
                end
              end
          end
        end)
      end
    end

    @impl true
    @spec delete(store(), AttestoMCP.Server.SessionStore.key()) :: :ok | {:error, term()}
    def delete(store, key) do
      with {:ok, %{repo: repo, namespace: expected_namespace} = config} <- checked_store(store),
           {:ok, {namespace, session_id}} <- lookup_key(key),
           :ok <- ensure_namespace(expected_namespace, namespace) do
        safely(fn ->
          repo.delete_all(key_query(namespace, session_id), query_opts(config))
          :ok
        end)
      else
        :not_found -> :ok
        other -> other
      end
    end

    @impl true
    @spec list_active(store()) ::
            {:ok, [{AttestoMCP.Server.SessionStore.key(), map()}]} | {:error, term()}
    def list_active(store) do
      with {:ok, %{repo: repo, namespace: namespace} = config} <- checked_store(store) do
        safely(fn ->
          now = System.system_time(:millisecond)

          case transaction(repo, fn ->
                 query =
                   from(s in Session,
                     where: s.namespace == ^namespace and s.expires_at_ms >= ^now,
                     order_by: [asc: s.expires_at_ms, asc: s.session_id],
                     limit: ^@max_list,
                     lock: "FOR UPDATE SKIP LOCKED",
                     select: s
                   )

                 rows = repo.all(query, query_opts(config))
                 {valid, corrupt} = partition_rows(rows, namespace)
                 :ok = delete_rows(repo, config, namespace, corrupt)

                 {:listed,
                  Enum.map(valid, fn {row, record} ->
                    {{row.namespace, row.session_id}, record}
                  end), length(corrupt)}
               end) do
            {:listed, values, corrupt_count} ->
              report_corrupt_rows(:list_active, corrupt_count)
              {:ok, values}

            {:error, reason} ->
              {:error, reason}
          end
        end)
      end
    end

    @impl true
    @spec count_active(store()) :: {:ok, non_neg_integer()} | {:error, term()}
    def count_active(store) do
      with {:ok, %{repo: repo, namespace: namespace} = config} <- checked_store(store) do
        safely(fn ->
          now = System.system_time(:millisecond)

          query =
            from(s in Session,
              where: s.namespace == ^namespace and s.expires_at_ms >= ^now,
              select: count(s.session_id)
            )

          case repo.one(query, query_opts(config)) do
            count when is_integer(count) and count >= 0 -> {:ok, count}
            _other -> {:error, :store_unavailable}
          end
        end)
      end
    end

    @impl true
    @spec update_ttl(store(), AttestoMCP.Server.SessionStore.key(), non_neg_integer()) ::
            {:ok, map()} | :not_found | {:error, term()}
    def update_ttl(store, key, now) when is_integer(now) and now >= 0 do
      with {:ok, %{repo: repo, namespace: expected_namespace} = config} <- checked_store(store),
           {:ok, {namespace, session_id}} <- lookup_key(key),
           :ok <- ensure_namespace(expected_namespace, namespace) do
        safely(fn ->
          transaction(repo, fn ->
            case repo.one(locked_key_query(namespace, session_id), query_opts(config)) do
              nil ->
                :not_found

              %Session{} = row ->
                cond do
                  unknown_record_version?(row.record) ->
                    # Preserve an opaque record written by a newer node and
                    # return it so callers can distinguish preservation from
                    # an absent row.
                    {:ok, row.record}

                  AttestoMCP.Server.Session.record_version_status(row.record) == :invalid ->
                    delete_row(repo, config, namespace, session_id)
                    :not_found

                  true ->
                    with {:ok, record} <- validated_row_record(row, expected_namespace),
                         false <-
                           expired?(
                             record,
                             max(now, System.system_time(:millisecond))
                           ) do
                      # The row lock serializes refreshes across processes/nodes.
                      # Keep the newest activity timestamp when calls arrive out
                      # of order; an older waiter must not rewind the session.
                      updated = Map.put(record, "last_seen_ms", max(record["last_seen_ms"], now))

                      case update_row(repo, config, row, updated) do
                        {:ok, _row} -> {:ok, updated}
                        {:error, reason} -> repo.rollback({:error, reason})
                      end
                    else
                      true ->
                        delete_row(repo, config, namespace, session_id)
                        :not_found

                      {:error, reason} ->
                        repo.rollback({:error, reason})
                    end
                end
            end
          end)
        end)
      end
    end

    def update_ttl(_store, _key, _now), do: {:error, :invalid_timestamp}

    @impl true
    @spec update(
            store(),
            AttestoMCP.Server.SessionStore.key(),
            AttestoMCP.Server.SessionStore.update_fun()
          ) ::
            {:ok, map()} | :not_found | {:error, term()}
    def update(store, key, fun) when is_function(fun, 1) do
      with {:ok, %{repo: repo, namespace: expected_namespace} = config} <- checked_store(store),
           {:ok, {namespace, session_id}} <- lookup_key(key),
           :ok <- ensure_namespace(expected_namespace, namespace) do
        safely(fn ->
          transaction(repo, fn ->
            case repo.one(locked_key_query(namespace, session_id), query_opts(config)) do
              nil ->
                :not_found

              %Session{} = row ->
                cond do
                  unknown_record_version?(row.record) ->
                    # Preserve an opaque record written by a newer node and
                    # return it so callers can distinguish preservation from
                    # an absent row.
                    {:ok, row.record}

                  AttestoMCP.Server.Session.record_version_status(row.record) == :invalid ->
                    delete_row(repo, config, namespace, session_id)
                    :not_found

                  true ->
                    with {:ok, record} <- validated_row_record(row, expected_namespace),
                         false <- expired?(record, System.system_time(:millisecond)) do
                      apply_update(repo, config, row, record, fun)
                    else
                      true ->
                        delete_row(repo, config, namespace, session_id)
                        :not_found

                      {:error, reason} ->
                        repo.rollback({:error, reason})
                    end
                end
            end
          end)
        end)
      end
    end

    def update(_store, _key, _fun), do: {:error, :invalid_update}

    @impl true
    @spec cleanup_expired(store()) ::
            {:ok, [AttestoMCP.Server.SessionStore.key()]} | {:error, term()}
    def cleanup_expired(store) do
      with {:ok, %{repo: repo, namespace: namespace} = config} <- checked_store(store) do
        safely(fn ->
          now = System.system_time(:millisecond)

          case transaction(repo, fn ->
                 query =
                   from(s in Session,
                     where: s.namespace == ^namespace and s.expires_at_ms < ^now,
                     where:
                       fragment(
                         "NOT (COALESCE(jsonb_typeof(? -> 'format_version'), '') = 'number' AND COALESCE(? ->> 'format_version', '') ~ '^[1-9][0-9]*$' AND ? ->> 'format_version' <> '1')",
                         s.record,
                         s.record,
                         s.record
                       ),
                     order_by: [asc: s.expires_at_ms, asc: s.session_id],
                     limit: ^@max_cleanup,
                     lock: "FOR UPDATE SKIP LOCKED",
                     select: {s.namespace, s.session_id}
                   )

                 keys = repo.all(query, query_opts(config))
                 :ok = delete_session_ids(repo, config, namespace, Enum.map(keys, &elem(&1, 1)))
                 {:cleaned, keys}
               end) do
            {:cleaned, keys} ->
              {:ok, keys}

            {:error, reason} ->
              {:error, reason}
          end
        end)
      end
    end

    # ----- internal -----

    defp checked_store(%{repo: repo, namespace: namespace, schema_prefix: prefix} = store)
         when is_atom(repo) and is_binary(namespace) and (is_nil(prefix) or is_binary(prefix)),
         do:
           if(valid_repo?(repo) and valid_key_part?(namespace) and valid_prefix?(prefix),
             do: {:ok, store},
             else: {:error, :invalid_store}
           )

    defp checked_store(_store), do: {:error, :invalid_store}

    defp valid_options?(opts) do
      Keyword.keyword?(opts) and
        Enum.all?(Keyword.keys(opts), &(&1 in @option_keys)) and
        length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts)))
    end

    defp valid_repo?(repo) when is_atom(repo) and not is_nil(repo) do
      Code.ensure_loaded?(repo) and function_exported?(repo, :transaction, 2) and
        function_exported?(repo, :one, 2) and function_exported?(repo, :all, 2) and
        function_exported?(repo, :insert, 2) and function_exported?(repo, :update, 2) and
        function_exported?(repo, :delete_all, 2) and function_exported?(repo, :rollback, 1) and
        function_exported?(repo, :query, 3) and function_exported?(repo, :in_transaction?, 0) and
        function_exported?(repo, :__adapter__, 0) and postgres_repo?(repo)
    end

    defp valid_repo?(_repo), do: false

    defp postgres_repo?(repo) do
      repo.__adapter__() == Ecto.Adapters.Postgres
    rescue
      _exception -> false
    catch
      _kind, _reason -> false
    end

    defp valid_prefix?(nil), do: true

    defp valid_prefix?(prefix) when is_binary(prefix) do
      byte_size(prefix) in 1..@max_schema_prefix_bytes and
        String.valid?(prefix) and
        prefix != "information_schema" and
        not String.starts_with?(prefix, "pg_") and
        Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, prefix)
    end

    defp valid_prefix?(_prefix), do: false

    defp valid_key({namespace, session_id}) do
      if valid_key_part?(namespace) and valid_key_part?(session_id),
        do: {:ok, {namespace, session_id}},
        else: {:error, :invalid_key}
    end

    defp valid_key(_key), do: {:error, :invalid_key}

    # A malformed external session identifier is indistinguishable from an
    # absent one for read/update operations. Keep that distinction out of the
    # server's outage path while preserving namespace/store configuration
    # errors for callers.
    defp lookup_key(key) do
      case valid_key(key) do
        {:ok, valid} -> {:ok, valid}
        {:error, :invalid_key} -> :not_found
      end
    end

    defp valid_key_part?(value) do
      is_binary(value) and byte_size(value) in 1..@max_key_bytes and String.valid?(value) and
        not contains_nul?(value)
    end

    defp ensure_namespace(namespace, namespace), do: :ok
    defp ensure_namespace(_expected, _actual), do: {:error, :namespace_mismatch}

    defp record_attrs(key, record, expected_namespace) do
      with {:ok, {namespace, session_id}} <- valid_key(key),
           :ok <- ensure_namespace(expected_namespace, namespace),
           :ok <- valid_json_record(record),
           {:ok, fields} <- expiry_fields(record) do
        {:ok,
         Map.merge(fields, %{
           namespace: namespace,
           session_id: session_id,
           record: record
         })}
      end
    end

    defp valid_json_record(record) do
      with true <- valid_json_native?(record),
           {:ok, encoded} <- Jason.encode(record),
           true <- byte_size(encoded) <= @max_record_bytes do
        :ok
      else
        _ -> {:error, :invalid_record}
      end
    rescue
      _ -> {:error, :invalid_record}
    end

    defp expiry_fields(record) do
      fields = %{
        created_at_ms: record["created_at_ms"],
        last_seen_ms: record["last_seen_ms"],
        absolute_timeout_ms: record["absolute_timeout_ms"],
        idle_timeout_ms: record["idle_timeout_ms"]
      }

      with true <- valid_expiry_fields?(fields),
           {:ok, expires_at_ms} <- expires_at_ms(fields) do
        {:ok, Map.put(fields, :expires_at_ms, expires_at_ms)}
      else
        _ -> {:error, :invalid_record}
      end
    end

    defp valid_expiry_fields?(%{
           created_at_ms: created,
           last_seen_ms: seen,
           absolute_timeout_ms: absolute,
           idle_timeout_ms: idle
         }) do
      is_integer(created) and created >= 0 and created <= @max_db_integer and
        is_integer(seen) and seen >= 0 and seen <= @max_db_integer and
        is_integer(absolute) and absolute in 1..@max_session_timeout_ms and
        is_integer(idle) and idle in 1..@max_session_timeout_ms
    end

    defp expires_at_ms(%{
           created_at_ms: created,
           last_seen_ms: seen,
           absolute_timeout_ms: absolute,
           idle_timeout_ms: idle
         }) do
      with true <- created <= @max_db_integer - absolute,
           true <- seen <= @max_db_integer - idle do
        {:ok, min(created + absolute, seen + idle)}
      else
        _ -> {:error, :invalid_record}
      end
    end

    defp expired?(record, now) do
      case expiry_fields(record) do
        {:ok, %{expires_at_ms: expires_at}} ->
          now > expires_at

        {:error, _reason} ->
          true
      end
    end

    defp unknown_record_version?(record),
      do: AttestoMCP.Server.Session.record_version_status(record) == :future

    defp validated_row_record(%Session{} = row, expected_namespace) do
      with :current <- AttestoMCP.Server.Session.record_version_status(row.record),
           true <- row.namespace == expected_namespace,
           true <- valid_key_part?(row.session_id),
           :ok <- valid_json_record(row.record),
           {:ok, fields} <- expiry_fields(row.record),
           true <- denormalized_fields_match?(row, fields) do
        {:ok, row.record}
      else
        _ -> {:error, :store_corrupt}
      end
    end

    defp partition_rows(rows, namespace) do
      Enum.reduce(rows, {[], []}, fn row, {valid, corrupt} ->
        if unknown_record_version?(row.record) do
          {[{row, row.record} | valid], corrupt}
        else
          case validated_row_record(row, namespace) do
            {:ok, record} -> {[{row, record} | valid], corrupt}
            {:error, :store_corrupt} -> {valid, [row | corrupt]}
          end
        end
      end)
      |> then(fn {valid, corrupt} -> {Enum.reverse(valid), Enum.reverse(corrupt)} end)
    end

    defp discard_corrupt_row(repo, config, namespace, session_id, now) do
      case transaction(repo, fn ->
             case repo.one(locked_key_query(namespace, session_id), query_opts(config)) do
               nil ->
                 :not_found

               %Session{} = row ->
                 if unknown_record_version?(row.record) do
                   # The row may have been replaced by a newer node after
                   # the initial read classified it as corrupt. Re-check the
                   # format before any cleanup so the newer row wins.
                   {:ok, row.record}
                 else
                   with {:ok, record} <- validated_row_record(row, namespace),
                        false <- expired?(record, now) do
                     {:ok, record}
                   else
                     true ->
                       :not_found

                     {:error, :store_corrupt} ->
                       :ok = delete_rows(repo, config, namespace, [row])
                       :corrupt_discarded
                   end
                 end
             end
           end) do
        :corrupt_discarded ->
          report_corrupt_rows(:load, 1)
          :not_found

        result ->
          result
      end
    end

    defp denormalized_fields_match?(row, fields) do
      Enum.all?([:created_at_ms, :last_seen_ms, :absolute_timeout_ms, :idle_timeout_ms], fn key ->
        Map.get(row, key) == Map.fetch!(fields, key)
      end) and row.expires_at_ms == fields.expires_at_ms
    end

    defp valid_json_native?(value) when is_nil(value) or is_boolean(value), do: true

    defp valid_json_native?(value) when is_binary(value),
      do: String.valid?(value) and not contains_nul?(value)

    defp valid_json_native?(value) when is_integer(value), do: true

    defp valid_json_native?(value) when is_float(value) do
      value == value and
        case Jason.encode(value) do
          {:ok, _encoded} -> true
          _ -> false
        end
    end

    defp valid_json_native?(value) when is_list(value),
      do: Enum.all?(value, &valid_json_native?/1)

    defp valid_json_native?(value) when is_map(value) do
      Enum.all?(value, fn {key, item} ->
        is_binary(key) and valid_json_native?(key) and valid_json_native?(item)
      end)
    end

    defp valid_json_native?(_value), do: false

    defp contains_nul?(value) when is_binary(value),
      do: :binary.match(value, <<0>>) != :nomatch

    defp contains_nul?(value) when is_atom(value),
      do: value |> Atom.to_string() |> contains_nul?()

    defp contains_nul?(value) when is_map(value),
      do: Enum.any?(value, fn {key, item} -> contains_nul?(key) or contains_nul?(item) end)

    defp contains_nul?([]), do: false
    defp contains_nul?([head | tail]), do: contains_nul?(head) or contains_nul?(tail)

    defp contains_nul?(value) when is_tuple(value),
      do: value |> Tuple.to_list() |> contains_nul?()

    defp contains_nul?(_value), do: false

    defp key_query(namespace, session_id) do
      from(s in Session,
        where: s.namespace == ^namespace and s.session_id == ^session_id
      )
    end

    defp locked_key_query(namespace, session_id) do
      from(s in Session,
        where: s.namespace == ^namespace and s.session_id == ^session_id,
        lock: "FOR UPDATE"
      )
    end

    defp delete_row(repo, config, namespace, session_id) do
      case repo.delete_all(key_query(namespace, session_id), query_opts(config)) do
        {_count, _rows} -> :ok
      end
    end

    defp delete_rows(_repo, _config, _namespace, []), do: :ok

    defp delete_rows(repo, config, namespace, rows) do
      delete_session_ids(repo, config, namespace, Enum.map(rows, & &1.session_id))
    end

    defp delete_session_ids(_repo, _config, _namespace, []), do: :ok

    defp delete_session_ids(repo, config, namespace, session_ids) do
      query =
        from(s in Session,
          where: s.namespace == ^namespace and s.session_id in ^session_ids
        )

      case repo.delete_all(query, query_opts(config)) do
        {count, _rows} when count == length(session_ids) -> :ok
        {_count, _rows} -> repo.rollback({:error, :write_failed})
      end
    end

    defp update_row(repo, config, row, record) do
      with {:ok, attrs} <- record_attrs({row.namespace, row.session_id}, record, config.namespace) do
        case repo.update(Session.changeset(row, attrs), query_opts(config)) do
          {:ok, updated} -> {:ok, updated}
          {:error, _changeset} -> {:error, :write_failed}
        end
      end
    end

    defp apply_update(repo, config, row, record, fun) do
      result =
        try do
          fun.(record)
        rescue
          _ -> {:error, :update_failed}
        catch
          _kind, _reason -> {:error, :update_failed}
        end

      case result do
        {:ok, updated} when is_map(updated) ->
          case update_row(repo, config, row, updated) do
            {:ok, _row} -> {:ok, updated}
            {:error, reason} -> repo.rollback({:error, reason})
          end

        :delete ->
          delete_row(repo, config, row.namespace, row.session_id)
          :not_found

        {:error, reason} ->
          {:error, reason}

        _other ->
          {:error, :invalid_update}
      end
    end

    defp query_opts(%{schema_prefix: prefix}),
      do: [prefix: prefix, timeout: @query_timeout_ms, log: false, telemetry_event: nil]

    defp transaction(repo, fun) do
      if function_exported?(repo, :in_transaction?, 0) and repo.in_transaction?() do
        {:error, :nested_transaction_unsupported}
      else
        wrapped = fn ->
          case repo.query(
                 "SET LOCAL lock_timeout = '#{@lock_timeout_ms}ms'",
                 [],
                 command_opts()
               ) do
            {:ok, _result} -> fun.()
            {:error, _reason} -> repo.rollback({:error, :store_unavailable})
          end
        end

        case repo.transaction(wrapped,
               timeout: @transaction_timeout_ms,
               log: false,
               telemetry_event: nil
             ) do
          {:ok, result} -> result
          {:error, {:error, reason}} -> {:error, reason}
          {:error, reason} -> {:error, reason}
        end
      end
    end

    defp command_opts,
      do: [timeout: @query_timeout_ms, log: false, telemetry_event: nil]

    defp report_corrupt_rows(_source, 0), do: :ok

    defp report_corrupt_rows(source, count) when count > 0 do
      Telemetry.execute(
        [:session_store, :failure],
        %{count: count},
        %{source: source, outcome: :corrupt_discarded}
      )
    end

    defp safely(fun) do
      try do
        fun.()
      rescue
        _exception -> {:error, :store_unavailable}
      catch
        _kind, _reason -> {:error, :store_unavailable}
      end
    end
  end
end
