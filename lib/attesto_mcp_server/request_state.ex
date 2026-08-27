defmodule AttestoMCP.Server.RequestState do
  @moduledoc "Integrity-protected, expiring, single-use modern retry state."

  def issue(principal, tenant, version, method, params, opts \\ []) do
    now = System.system_time(:millisecond)

    payload = %{
      "p" => digest(principal),
      "t" => digest(tenant),
      "v" => version,
      "m" => method,
      "d" => digest(params),
      "e" => now + (Keyword.get(opts, :ttl) || 60_000),
      "n" => Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    }

    payload =
      payload
      |> maybe_claim("i", Keyword.get(opts, :request_id), &digest/1)
      |> maybe_claim("o", Keyword.get(opts, :operation_identity), &digest/1)
      |> maybe_claim("k", Keyword.get(opts, :input_keys), &normalize_keys/1)
      |> maybe_claim("q", Keyword.get(opts, :input_types), &normalize_types/1)
      |> maybe_claim("r", Keyword.get(opts, :round), & &1)

    encoded = payload |> Jason.encode!() |> Base.url_encode64(padding: false)

    signature =
      :crypto.mac(:hmac, :sha256, signing_secret(opts), encoded)
      |> Base.url_encode64(padding: false)

    encoded <> "." <> signature
  end

  def verify(state, principal, tenant, version, method, params, opts \\ [])

  def verify(state, principal, tenant, version, method, params, opts) when is_binary(state) do
    case verify_payload(state, principal, tenant, version, method, params, opts) do
      {:ok, payload} -> {:ok, payload["n"]}
      error -> error
    end
  end

  @doc "Verifies state and returns its claims for the modern retry protocol."
  def ensure_table, do: state_table()

  def verify_payload(state, principal, tenant, version, method, params, opts \\ [])

  def verify_payload(state, principal, tenant, version, method, params, opts)
      when is_binary(state) do
    with [encoded, provided] <- String.split(state, ".", parts: 2),
         secret <- signing_secret(opts),
         expected <-
           :crypto.mac(:hmac, :sha256, secret, encoded) |> Base.url_encode64(padding: false),
         true <- Plug.Crypto.secure_compare(expected, provided),
         {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, payload} <- Jason.decode(json),
         true <- payload["p"] == digest(principal),
         true <- payload["t"] == digest(tenant),
         true <- payload["v"] == version,
         true <- payload["m"] == method,
         true <- payload["d"] == digest(params),
         true <- request_id_valid?(payload, opts),
         true <- operation_valid?(payload, opts),
         true <- responses_valid?(payload, Keyword.get(opts, :responses)),
         true <- is_integer(payload["e"]) and payload["e"] >= System.system_time(:millisecond),
         true <- consume?(payload, opts) do
      {:ok, payload}
    else
      _ -> {:error, :invalid_request_state}
    end
  end

  def verify_payload(_, _, _, _, _, _, _), do: {:error, :invalid_request_state}

  def consume_payload(payload, opts \\ [])
  def consume_payload(%{"n" => nonce}, opts), do: consume(nonce, Keyword.get(opts, :store))
  def consume_payload(_, _opts), do: false

  defp consume?(payload, opts),
    do:
      Keyword.get(opts, :consume, true) == false or
        consume(payload["n"], Keyword.get(opts, :store))

  defp maybe_claim(payload, _key, nil, _fun), do: payload
  defp maybe_claim(payload, key, value, fun), do: Map.put(payload, key, fun.(value))

  defp normalize_keys(keys) when is_list(keys), do: Enum.map(keys, &to_string/1) |> Enum.uniq()
  defp normalize_keys(_), do: []

  defp normalize_types(types) when is_map(types) do
    Map.new(types, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_types(_), do: %{}

  defp request_id_valid?(%{"i" => original}, opts) do
    case Keyword.fetch(opts, :request_id) do
      {:ok, request_id} -> original != digest(request_id)
      :error -> true
    end
  end

  defp request_id_valid?(_payload, _opts), do: true

  defp operation_valid?(%{"o" => expected}, opts) do
    case Keyword.fetch(opts, :operation_identity) do
      {:ok, operation} -> expected == digest(operation)
      :error -> true
    end
  end

  defp operation_valid?(_payload, _opts), do: true

  defp responses_valid?(%{"k" => expected}, responses) when is_map(responses) do
    Enum.all?(expected, &Map.has_key?(responses, &1))
  end

  defp responses_valid?(%{"k" => expected}, nil), do: expected == []
  defp responses_valid?(_payload, _responses), do: true

  defp digest(value),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.url_encode64(padding: false)

  defp secret do
    case Application.get_env(:attesto_mcp_server, :request_state_secret) do
      value when is_binary(value) ->
        value

      _ ->
        # persistent_term has no insert-if-absent operation.  Serialize the
        # one-time fallback initialization so concurrent first use cannot
        # overwrite a secret between issuing and verifying a state token.
        :global.trans({{__MODULE__, :secret}, self()}, fn ->
          case :persistent_term.get({__MODULE__, :secret}, nil) do
            value when is_binary(value) -> value
            _ -> persist(:crypto.strong_rand_bytes(32))
          end
        end)
    end
  end

  defp persist(value) do
    :persistent_term.put({__MODULE__, :secret}, value)
    value
  end

  defp consume(nonce, store) when is_pid(store), do: __MODULE__.Store.consume(store, nonce)

  defp consume(nonce, _store) do
    table = state_table()
    now = System.monotonic_time(:millisecond)

    :ets.foldl(
      fn {old_nonce, timestamp}, :ok ->
        if timestamp < now - 120_000, do: :ets.delete(table, old_nonce)
        :ok
      end,
      :ok,
      table
    )

    :ets.insert_new(table, {nonce, now})
  end

  defp signing_secret(opts) do
    secret = Keyword.get(opts, :secret) || secret()

    case Keyword.get(opts, :instance) do
      instance when is_binary(instance) -> :crypto.hash(:sha256, secret <> instance)
      _ -> secret
    end
  end

  defp state_table do
    case :ets.whereis(:attesto_mcp_server_request_states) do
      :undefined ->
        try do
          :ets.new(:attesto_mcp_server_request_states, [:set, :public, :named_table])
        catch
          :error, :badarg -> :ets.whereis(:attesto_mcp_server_request_states)
        end

      table ->
        table
    end
  end
end

defmodule AttestoMCP.Server.RequestState.Store do
  @moduledoc "Stable per-server owner for consumed modern request-state nonces."
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @spec consume(pid(), binary()) :: boolean()
  def consume(pid, nonce), do: GenServer.call(pid, {:consume, nonce})

  @impl true
  def init(opts) do
    table = :ets.new(:attesto_mcp_request_state_store, [:set, :private])
    {:ok, %{table: table, max_age_ms: Keyword.get(opts, :max_age_ms, 120_000)}}
  end

  @impl true
  def handle_call({:consume, nonce}, _from, state) when is_binary(nonce) do
    now = System.monotonic_time(:millisecond)

    :ets.foldl(
      fn {old_nonce, timestamp}, :ok ->
        if timestamp < now - state.max_age_ms, do: :ets.delete(state.table, old_nonce)
        :ok
      end,
      :ok,
      state.table
    )

    {:reply, :ets.insert_new(state.table, {nonce, now}), state}
  end

  def handle_call(_, _from, state), do: {:reply, false, state}
end
