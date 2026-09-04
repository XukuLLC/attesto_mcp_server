defmodule AttestoMCP.Server.UrlElicitation do
  @moduledoc """
  Helpers for staging, resolving, and consuming URL elicitation approval records.

  A link with `mode: "url"` must carry the operation the human is approving by
  its opaque staged-record ID rather than as a bare route. The staged record is
  bound to the calling subject hash, contains the exact fields that the action
  will execute with, is single-use with a short TTL, renders an explicit dead
  end when expired, consumed, or foreign, and is periodically swept.

  The raw principal binding is never persisted in the store; only its
  deterministic SHA-256 digest is stored.
  """

  alias AttestoMCP.Server
  alias AttestoMCP.Server.Schema

  @default_ttl_ms 600_000
  @min_ttl_ms 1_000
  @max_ttl_ms 86_400_000
  @max_action_bytes 256

  @type server :: pid() | atom()
  @type handler_context :: map()
  @type stage_result :: {:ok, %{id: String.t(), expires_at_ms: non_neg_integer()}}
  @type staged_content :: %{
          action: String.t(),
          fields: map(),
          expires_at_ms: non_neg_integer()
        }
  @type resolve_result ::
          {:ok, staged_content()}
          | {:error, :not_found | :foreign | :consumed | :expired | :store_unavailable}
  @type stage_error ::
          {:error,
           :principal_binding_required
           | :invalid_action
           | :invalid_fields
           | :invalid_ttl
           | :store_unavailable}

  @doc """
  Stages a URL elicitation record before returning an interactive `mode: "url"` request.

  The context must contain a non-nil `:principal_binding`. The action must be a
  non-empty string of at most 256 bytes. Fields must be a JSON object within the
  server's `max_json_bytes` budget.
  """
  @spec stage_url_elicitation(server(), handler_context(), String.t(), map(), keyword()) ::
          stage_result() | stage_error()
  def stage_url_elicitation(server, context, action, fields, opts \\ []) do
    safely(fn ->
      with {:ok, principal_binding} <- validate_context(context),
           {:ok, action} <- validate_action(action),
           {:ok, ttl_ms} <- validate_ttl(opts),
           {:ok, config} <- get_server_config(server),
           budget = get_budget(context, config),
           {:ok, fields} <- validate_fields(fields, budget) do
        id = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
        subject_hash = subject_hash(principal_binding)
        now_ms = System.system_time(:millisecond)
        expires_at_ms = now_ms + ttl_ms

        record = %{
          "id" => id,
          "namespace" => config.namespace,
          "subject_hash" => subject_hash,
          "action" => action,
          "fields" => fields,
          "created_at_ms" => now_ms,
          "expires_at_ms" => expires_at_ms,
          "consumed_at_ms" => nil
        }

        case apply(config.module, :put, [config.store, record]) do
          :ok ->
            {:ok, %{id: id, expires_at_ms: expires_at_ms}}

          {:error, _reason} ->
            {:error, :store_unavailable}

          _other ->
            {:error, :store_unavailable}
        end
      else
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Resolves a staged URL elicitation record for display on an approval page.

  Returns `{:error, :foreign}` if the principal binding does not match the
  staged subject hash before revealing any action or field content. Returns
  `{:error, :consumed}` if already consumed, or `{:error, :expired}` if expired.
  Malformed or unknown IDs return `{:error, :not_found}`.
  """
  @spec resolve_url_elicitation(server(), String.t(), term()) :: resolve_result()
  def resolve_url_elicitation(server, id, principal_binding) do
    if valid_id?(id) do
      safely(fn ->
        with {:ok, config} <- get_server_config(server) do
          case apply(config.module, :fetch, [config.store, config.namespace, id]) do
            {:ok, record} ->
              expected_hash = subject_hash(principal_binding)

              cond do
                record["subject_hash"] != expected_hash ->
                  {:error, :foreign}

                not is_nil(record["consumed_at_ms"]) ->
                  {:error, :consumed}

                is_integer(record["expires_at_ms"]) and
                    System.system_time(:millisecond) >= record["expires_at_ms"] ->
                  {:error, :expired}

                true ->
                  {:ok,
                   %{
                     action: record["action"],
                     fields: record["fields"],
                     expires_at_ms: record["expires_at_ms"]
                   }}
              end

            :not_found ->
              {:error, :not_found}

            {:error, _reason} ->
              {:error, :store_unavailable}

            _other ->
              {:error, :store_unavailable}
          end
        else
          {:error, reason} -> {:error, reason}
        end
      end)
    else
      {:error, :not_found}
    end
  end

  @doc """
  Atomically consumes a staged URL elicitation record upon confirmation.

  Can be consumed at most once. Returns `{:error, :foreign}` if the subject
  does not match, `{:error, :consumed}` if already consumed, and `{:error, :expired}`
  if expired. Malformed or unknown IDs return `{:error, :not_found}`.
  """
  @spec consume_url_elicitation(server(), String.t(), term()) :: resolve_result()
  def consume_url_elicitation(server, id, principal_binding) do
    if valid_id?(id) do
      safely(fn ->
        with {:ok, config} <- get_server_config(server) do
          expected_hash = subject_hash(principal_binding)
          now_ms = System.system_time(:millisecond)

          case apply(config.module, :consume, [
                 config.store,
                 config.namespace,
                 id,
                 expected_hash,
                 now_ms
               ]) do
            {:ok, record} ->
              {:ok,
               %{
                 action: record["action"],
                 fields: record["fields"],
                 expires_at_ms: record["expires_at_ms"]
               }}

            :not_found ->
              {:error, :not_found}

            {:error, reason} when reason in [:foreign, :consumed, :expired] ->
              {:error, reason}

            {:error, _reason} ->
              {:error, :store_unavailable}

            _other ->
              {:error, :store_unavailable}
          end
        else
          {:error, reason} -> {:error, reason}
        end
      end)
    else
      {:error, :not_found}
    end
  end

  @doc """
  Computes the deterministic SHA-256 hex digest for a principal binding.

  Only this hash is stored by the URL elicitation store; the raw binding is
  never persisted in the store record.
  """
  @spec subject_hash(term()) :: String.t()
  def subject_hash(principal_binding) do
    :crypto.hash(:sha256, :erlang.term_to_binary(principal_binding, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  @doc false
  @spec valid_id?(term()) :: boolean()
  def valid_id?(id) when is_binary(id) and byte_size(id) == 43 do
    case Base.url_decode64(id, padding: false) do
      {:ok, <<_::binary-size(32)>>} -> true
      _ -> false
    end
  end

  def valid_id?(_id), do: false

  # ----- internal -----

  defp validate_context(%{principal_binding: binding}) when not is_nil(binding),
    do: {:ok, binding}

  defp validate_context(_context), do: {:error, :principal_binding_required}

  defp validate_action(action)
       when is_binary(action) and byte_size(action) in 1..@max_action_bytes do
    if String.valid?(action) and :binary.match(action, <<0>>) == :nomatch,
      do: {:ok, action},
      else: {:error, :invalid_action}
  end

  defp validate_action(_action), do: {:error, :invalid_action}

  defp validate_ttl(opts) when is_list(opts) do
    ttl = Keyword.get(opts, :ttl_ms, @default_ttl_ms)

    if is_integer(ttl) and ttl in @min_ttl_ms..@max_ttl_ms,
      do: {:ok, ttl},
      else: {:error, :invalid_ttl}
  end

  defp validate_ttl(_opts), do: {:error, :invalid_ttl}

  defp get_budget(context, config) do
    case context do
      %{max_json_bytes: budget} when is_integer(budget) and budget > 0 -> budget
      _ -> Map.get(config, :max_json_bytes, Schema.default_instance_bytes())
    end
  end

  defp validate_fields(fields, budget) when is_map(fields) do
    if valid_json_native_map?(fields) do
      case Jason.encode(fields) do
        {:ok, encoded} when byte_size(encoded) <= budget -> {:ok, fields}
        _ -> {:error, :invalid_fields}
      end
    else
      {:error, :invalid_fields}
    end
  rescue
    _ -> {:error, :invalid_fields}
  end

  defp validate_fields(_fields, _budget), do: {:error, :invalid_fields}

  defp valid_json_native_map?(map) when is_map(map) do
    Enum.all?(map, fn {key, value} ->
      is_binary(key) and String.valid?(key) and :binary.match(key, <<0>>) == :nomatch and
        valid_json_native_value?(value)
    end)
  end

  defp valid_json_native_value?(value) when is_nil(value) or is_boolean(value), do: true

  defp valid_json_native_value?(value) when is_binary(value),
    do: String.valid?(value) and :binary.match(value, <<0>>) == :nomatch

  defp valid_json_native_value?(value) when is_integer(value), do: true

  defp valid_json_native_value?(value) when is_float(value) do
    value == value and
      case Jason.encode(value) do
        {:ok, _encoded} -> true
        _ -> false
      end
  end

  defp valid_json_native_value?(value) when is_list(value),
    do: Enum.all?(value, &valid_json_native_value?/1)

  defp valid_json_native_value?(value) when is_map(value),
    do: valid_json_native_map?(value)

  defp valid_json_native_value?(_value), do: false

  defp get_server_config(server) do
    case Server.url_elicitation_store(server) do
      %{module: module, store: _store, namespace: namespace, max_json_bytes: max_json_bytes} =
          config
      when is_atom(module) and is_binary(namespace) and is_integer(max_json_bytes) ->
        {:ok, config}

      _other ->
        {:error, :store_unavailable}
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    _kind, _reason -> {:error, :store_unavailable}
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
