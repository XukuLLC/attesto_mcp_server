defmodule AttestoMCP.Server.UrlElicitationStore.Ecto.CompileSentinel do
  @moduledoc false

  @ecto_available Code.ensure_loaded?(Ecto.Schema) and Code.ensure_loaded?(Ecto.Query) and
                    Code.ensure_loaded?(Ecto.Changeset)

  @doc false
  def __mix_recompile__? do
    @ecto_available !=
      (Code.ensure_loaded?(Ecto.Schema) and Code.ensure_loaded?(Ecto.Query) and
         Code.ensure_loaded?(Ecto.Changeset))
  end
end

if Code.ensure_loaded?(Ecto.Schema) and Code.ensure_loaded?(Ecto.Query) and
     Code.ensure_loaded?(Ecto.Changeset) do
  defmodule AttestoMCP.Server.UrlElicitationStore.Ecto.UrlElicitation do
    @moduledoc """
    Ecto schema for durable URL elicitation records.

    The namespace is part of the primary key so multiple MCP servers can share
    the table safely. The integer columns provide bounded indexed cleanup.
    """

    use Ecto.Schema

    import Ecto.Changeset

    @type t :: %__MODULE__{}

    @primary_key false
    schema "attesto_mcp_url_elicitations" do
      field(:namespace, :string, primary_key: true)
      field(:id, :string, primary_key: true)
      field(:subject_hash, :string)
      field(:action, :string)
      field(:fields, :map)
      field(:created_at_ms, :integer)
      field(:expires_at_ms, :integer)
      field(:consumed_at_ms, :integer)

      timestamps(type: :utc_datetime_usec)
    end

    @fields ~w(namespace id subject_hash action fields created_at_ms expires_at_ms consumed_at_ms)a
    @required_fields ~w(namespace id subject_hash action fields created_at_ms expires_at_ms)a

    @doc false
    @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
    def changeset(elicitation, attrs) do
      elicitation
      |> cast(attrs, @fields)
      |> validate_required(@required_fields)
      |> validate_length(:namespace, min: 1, max: 256)
      |> validate_length(:id, min: 1, max: 256)
      |> validate_length(:action, min: 1, max: 256)
      |> validate_number(:created_at_ms, greater_than_or_equal_to: 0)
      |> validate_number(:expires_at_ms, greater_than_or_equal_to: 0)
      |> validate_number(:consumed_at_ms, greater_than_or_equal_to: 0)
      |> unique_constraint([:namespace, :id], name: :attesto_mcp_url_elicitations_pkey)
    end
  end

  defmodule AttestoMCP.Server.UrlElicitationStore.Ecto do
    @moduledoc """
    Optional Ecto-backed implementation of `AttestoMCP.Server.UrlElicitationStore`.

    The adapter is stateless and wraps a repository, namespace, and optional schema prefix.
    It targets PostgreSQL (`Ecto.Adapters.Postgres`).
    """

    @behaviour AttestoMCP.Server.UrlElicitationStore

    import Ecto.Query, only: [from: 2]

    alias AttestoMCP.Server.UrlElicitationStore.Ecto.UrlElicitation

    @max_key_bytes 256
    @max_schema_prefix_bytes 63
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
    def put(store, record) when is_map(record) do
      with {:ok, %{repo: repo, namespace: expected_namespace} = config} <- checked_store(store),
           {:ok, attrs} <- record_attrs(record, expected_namespace) do
        if in_transaction?(repo) do
          {:error, :nested_transaction_unsupported}
        else
          safely(fn ->
            changeset = UrlElicitation.changeset(%UrlElicitation{}, attrs)

            # Identifiers are 256-bit random values, so a conflict means a
            # caller reused an id. Never replace the existing row: that could
            # resurrect a consumed approval.
            case repo.insert(changeset, query_opts(config)) do
              {:ok, _row} -> :ok
              {:error, _changeset} -> {:error, :write_failed}
            end
          end)
        end
      end
    end

    def put(_store, _record), do: {:error, :invalid_record}

    @impl true
    def fetch(store, namespace, id) do
      with {:ok, %{repo: repo, namespace: expected_namespace} = config} <- checked_store(store),
           :ok <- ensure_namespace(expected_namespace, namespace),
           {:ok, valid_id} <- lookup_id(id) do
        safely(fn ->
          query =
            from(u in UrlElicitation,
              where: u.namespace == ^namespace and u.id == ^valid_id
            )

          case repo.one(query, query_opts(config)) do
            nil -> :not_found
            %UrlElicitation{} = row -> {:ok, to_record(row)}
          end
        end)
      else
        :not_found -> :not_found
        {:error, reason} -> {:error, reason}
      end
    end

    @impl true
    def consume(store, namespace, id, subject_hash, now_ms)
        when is_integer(now_ms) and now_ms >= 0 do
      with {:ok, %{repo: repo, namespace: expected_namespace} = config} <- checked_store(store),
           :ok <- ensure_namespace(expected_namespace, namespace),
           {:ok, valid_id} <- lookup_id(id) do
        if in_transaction?(repo) do
          {:error, :nested_transaction_unsupported}
        else
          safely(fn ->
            transaction(repo, fn ->
              sql = """
              UPDATE #{table_name(config)}
              SET consumed_at_ms = $1, updated_at = NOW()
              WHERE namespace = $2
                AND id = $3
                AND subject_hash = $4
                AND consumed_at_ms IS NULL
                AND expires_at_ms > $1
              RETURNING id, namespace, subject_hash, action, fields, created_at_ms, expires_at_ms, consumed_at_ms
              """

              case repo.query(sql, [now_ms, namespace, valid_id, subject_hash], command_opts()) do
                {:ok, %{rows: [[r_id, r_ns, r_hash, r_act, r_fields, r_created, r_exp, r_cons]]}} ->
                  {:ok,
                   %{
                     "id" => r_id,
                     "namespace" => r_ns,
                     "subject_hash" => r_hash,
                     "action" => r_act,
                     "fields" => decode_fields(r_fields),
                     "created_at_ms" => r_created,
                     "expires_at_ms" => r_exp,
                     "consumed_at_ms" => r_cons
                   }}

                {:ok, %{rows: []}} ->
                  classify_missing_consume(
                    repo,
                    config,
                    namespace,
                    valid_id,
                    subject_hash,
                    now_ms
                  )

                {:error, _reason} ->
                  repo.rollback({:error, :store_unavailable})
              end
            end)
          end)
        end
      else
        :not_found -> :not_found
        {:error, reason} -> {:error, reason}
      end
    end

    def consume(_store, _namespace, _id, _subject_hash, _now_ms), do: {:error, :invalid_timestamp}

    @impl true
    def cleanup_expired(store, now_ms) when is_integer(now_ms) and now_ms >= 0 do
      with {:ok, %{repo: repo, namespace: namespace} = config} <- checked_store(store) do
        if in_transaction?(repo) do
          {:error, :nested_transaction_unsupported}
        else
          safely(fn ->
            transaction(repo, fn ->
              query =
                from(u in UrlElicitation,
                  where: u.namespace == ^namespace and u.expires_at_ms <= ^now_ms,
                  order_by: [asc: u.expires_at_ms, asc: u.id],
                  limit: ^@max_cleanup,
                  lock: "FOR UPDATE SKIP LOCKED",
                  select: u.id
                )

              ids = repo.all(query, query_opts(config))

              if ids == [] do
                {:cleaned, []}
              else
                delete_query =
                  from(u in UrlElicitation,
                    where: u.namespace == ^namespace and u.id in ^ids
                  )

                case repo.delete_all(delete_query, query_opts(config)) do
                  {count, _rows} when count == length(ids) -> {:cleaned, ids}
                  {_count, _rows} -> repo.rollback({:error, :write_failed})
                end
              end
            end)
            |> case do
              {:cleaned, ids} -> {:ok, ids}
              {:error, reason} -> {:error, reason}
            end
          end)
        end
      end
    end

    def cleanup_expired(_store, _now_ms), do: {:error, :invalid_timestamp}

    # ----- internal -----

    defp classify_missing_consume(repo, config, namespace, id, subject_hash, now_ms) do
      read_query =
        from(u in UrlElicitation,
          where: u.namespace == ^namespace and u.id == ^id,
          select: u
        )

      case repo.one(read_query, query_opts(config)) do
        nil ->
          :not_found

        %UrlElicitation{} = row ->
          cond do
            row.subject_hash != subject_hash -> {:error, :foreign}
            not is_nil(row.consumed_at_ms) -> {:error, :consumed}
            row.expires_at_ms <= now_ms -> {:error, :expired}
            true -> {:error, :consumed}
          end
      end
    end

    defp to_record(%UrlElicitation{} = row) do
      %{
        "id" => row.id,
        "namespace" => row.namespace,
        "subject_hash" => row.subject_hash,
        "action" => row.action,
        "fields" => decode_fields(row.fields),
        "created_at_ms" => row.created_at_ms,
        "expires_at_ms" => row.expires_at_ms,
        "consumed_at_ms" => row.consumed_at_ms
      }
    end

    defp decode_fields(fields) when is_map(fields), do: fields
    defp decode_fields(fields) when is_binary(fields), do: Jason.decode!(fields)

    defp checked_store(%{repo: repo, namespace: namespace, schema_prefix: prefix} = store)
         when is_atom(repo) and is_binary(namespace) and (is_nil(prefix) or is_binary(prefix)) do
      cond do
        not valid_repo?(repo) -> {:error, :invalid_store}
        not valid_key_part?(namespace) -> {:error, :invalid_store}
        not valid_prefix?(prefix) -> {:error, :invalid_store}
        true -> {:ok, store}
      end
    end

    defp checked_store(_store), do: {:error, :invalid_store}

    defp valid_options?(opts) do
      Keyword.keyword?(opts) and
        Enum.all?(Keyword.keys(opts), &(&1 in @option_keys)) and
        length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts)))
    end

    defp valid_repo?(repo) when is_atom(repo) and not is_nil(repo) do
      Code.ensure_loaded?(repo) and function_exported?(repo, :transaction, 2) and
        function_exported?(repo, :one, 2) and function_exported?(repo, :all, 2) and
        function_exported?(repo, :insert, 2) and function_exported?(repo, :delete_all, 2) and
        function_exported?(repo, :rollback, 1) and function_exported?(repo, :query, 3) and
        function_exported?(repo, :in_transaction?, 0) and
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

    defp valid_key_part?(value) do
      is_binary(value) and byte_size(value) in 1..@max_key_bytes and String.valid?(value) and
        not contains_nul?(value)
    end

    defp contains_nul?(value) when is_binary(value),
      do: :binary.match(value, <<0>>) != :nomatch

    defp lookup_id(id) do
      if valid_key_part?(id), do: {:ok, id}, else: :not_found
    end

    defp ensure_namespace(namespace, namespace), do: :ok
    defp ensure_namespace(_expected, _actual), do: {:error, :namespace_mismatch}

    defp record_attrs(record, expected_namespace) do
      id = record["id"]
      namespace = record["namespace"]
      subject_hash = record["subject_hash"]
      action = record["action"]
      fields = record["fields"]
      created = record["created_at_ms"]
      expires = record["expires_at_ms"]
      consumed = record["consumed_at_ms"]

      cond do
        not valid_key_part?(id) ->
          {:error, :invalid_record}

        not valid_key_part?(namespace) or namespace != expected_namespace ->
          {:error, :invalid_record}

        not is_binary(subject_hash) or byte_size(subject_hash) != 64 ->
          {:error, :invalid_record}

        not valid_key_part?(action) ->
          {:error, :invalid_record}

        not is_map(fields) ->
          {:error, :invalid_record}

        not is_integer(created) or created < 0 ->
          {:error, :invalid_record}

        not is_integer(expires) or expires < 0 ->
          {:error, :invalid_record}

        not (is_nil(consumed) or (is_integer(consumed) and consumed >= 0)) ->
          {:error, :invalid_record}

        true ->
          case Jason.encode(fields) do
            {:ok, _encoded} ->
              {:ok,
               %{
                 namespace: namespace,
                 id: id,
                 subject_hash: subject_hash,
                 action: action,
                 fields: fields,
                 created_at_ms: created,
                 expires_at_ms: expires,
                 consumed_at_ms: consumed
               }}

            _ ->
              {:error, :invalid_record}
          end
      end
    rescue
      _ -> {:error, :invalid_record}
    end

    defp query_opts(%{schema_prefix: prefix}),
      do: [prefix: prefix, timeout: @query_timeout_ms, log: false, telemetry_event: nil]

    defp command_opts,
      do: [timeout: @query_timeout_ms, log: false, telemetry_event: nil]

    defp table_name(%{schema_prefix: nil}), do: "\"attesto_mcp_url_elicitations\""

    defp table_name(%{schema_prefix: prefix}) when is_binary(prefix),
      do: "\"#{prefix}\".\"attesto_mcp_url_elicitations\""

    defp in_transaction?(repo),
      do: function_exported?(repo, :in_transaction?, 0) and repo.in_transaction?()

    defp transaction(repo, fun) do
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
