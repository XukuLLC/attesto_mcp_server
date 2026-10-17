defmodule AttestoMCP.Server.EctoAdapter do
  @moduledoc false

  @max_key_bytes 256
  @max_schema_prefix_bytes 63
  @query_timeout_ms 1_500
  @lock_timeout_ms 1_000
  @transaction_timeout_ms 3_000

  @doc false
  def checked_store(
        %{repo: repo, namespace: namespace, schema_prefix: prefix} = store,
        required_functions
      )
      when is_atom(repo) and is_binary(namespace) and
             (is_nil(prefix) or is_binary(prefix)) and is_list(required_functions) do
    if valid_repo?(repo, required_functions) and valid_key_part?(namespace) and
         valid_prefix?(prefix),
       do: {:ok, store},
       else: {:error, :invalid_store}
  end

  def checked_store(_store, _required_functions), do: {:error, :invalid_store}

  @doc false
  def valid_options?(opts, option_keys) when is_list(option_keys) do
    Keyword.keyword?(opts) and
      Enum.all?(Keyword.keys(opts), &(&1 in option_keys)) and
      length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts)))
  end

  def valid_options?(_opts, _option_keys), do: false

  @doc false
  def valid_key_part?(value) do
    is_binary(value) and byte_size(value) in 1..@max_key_bytes and String.valid?(value) and
      not contains_nul?(value)
  end

  @doc false
  def contains_nul?(value) when is_binary(value),
    do: :binary.match(value, <<0>>) != :nomatch

  def contains_nul?(value) when is_atom(value),
    do: value |> Atom.to_string() |> contains_nul?()

  def contains_nul?(value) when is_map(value),
    do: Enum.any?(value, fn {key, item} -> contains_nul?(key) or contains_nul?(item) end)

  def contains_nul?([]), do: false
  def contains_nul?([head | tail]), do: contains_nul?(head) or contains_nul?(tail)
  def contains_nul?(value) when is_tuple(value), do: value |> Tuple.to_list() |> contains_nul?()
  def contains_nul?(_value), do: false

  @doc false
  def query_opts(%{schema_prefix: prefix}),
    do: [prefix: prefix, timeout: @query_timeout_ms, log: false, telemetry_event: nil]

  @doc false
  def command_opts,
    do: [timeout: @query_timeout_ms, log: false, telemetry_event: nil]

  @doc false
  def transaction(repo, fun) when is_function(fun, 0) do
    if in_transaction?(repo) do
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

  @doc false
  def in_transaction?(repo),
    do: function_exported?(repo, :in_transaction?, 0) and repo.in_transaction?()

  @doc false
  def safely(fun) when is_function(fun, 0) do
    try do
      fun.()
    rescue
      _exception -> {:error, :store_unavailable}
    catch
      _kind, _reason -> {:error, :store_unavailable}
    end
  end

  @doc false
  def valid_repo?(repo, required_functions) when is_atom(repo) and not is_nil(repo) do
    Code.ensure_loaded?(repo) and
      Enum.all?(required_functions, fn {function, arity} ->
        function_exported?(repo, function, arity)
      end) and
      function_exported?(repo, :__adapter__, 0) and postgres_repo?(repo)
  end

  def valid_repo?(_repo, _required_functions), do: false

  defp postgres_repo?(repo) do
    repo.__adapter__() == Ecto.Adapters.Postgres
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  @doc false
  def valid_prefix?(nil), do: true

  def valid_prefix?(prefix) when is_binary(prefix) do
    byte_size(prefix) in 1..@max_schema_prefix_bytes and
      String.valid?(prefix) and
      prefix != "information_schema" and
      not String.starts_with?(prefix, "pg_") and
      Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, prefix)
  end

  def valid_prefix?(_prefix), do: false
end
