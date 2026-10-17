defmodule AttestoMCP.Server.Stores do
  @moduledoc false

  @session_pg_scope AttestoMCP.Server.SessionCluster

  @session_callbacks [
    save: 3,
    load: 2,
    delete: 2,
    list_active: 1,
    update_ttl: 3,
    update: 3,
    cleanup_expired: 1
  ]

  @url_callbacks [put: 2, fetch: 3, consume: 5, cleanup_expired: 2]

  @doc false
  def setup_session(opts) do
    namespace = Keyword.get(opts, :session_namespace) || default_namespace(opts)

    {module, store, external?} =
      case Keyword.get(opts, :session_store) do
        nil ->
          {:ok, store} = AttestoMCP.Server.SessionStore.ETS.start_link([])
          {AttestoMCP.Server.SessionStore.ETS, store, false}

        {module, store} when is_atom(module) ->
          validate_session_adapter!(module)
          {module, store, true}
      end

    monitor = if external? and is_pid(store), do: Process.monitor(store)

    group =
      if opts[:session_clustered] == true do
        ensure_pg_started!()
        group = {:attesto_mcp_server_sessions, namespace}
        :ok = :pg.join(@session_pg_scope, group, self())
        group
      end

    {module, store, external?, monitor, namespace, group}
  end

  @doc false
  def setup_url_elicitation(opts) do
    case Keyword.get(opts, :url_elicitation_store) do
      nil ->
        {:ok, store} =
          AttestoMCP.Server.UrlElicitationStore.ETS.start_link(
            max_entries: opts[:url_elicitation_max_entries],
            max_bytes: opts[:url_elicitation_max_bytes]
          )

        {AttestoMCP.Server.UrlElicitationStore.ETS, store, false, nil}

      {module, store} when is_atom(module) ->
        validate_url_adapter!(module)
        monitor = if is_pid(store), do: Process.monitor(store)
        {module, store, true, monitor}
    end
  end

  @doc false
  def validate_options!(opts) do
    case Keyword.get(opts, :session_store) do
      nil -> :ok
      {module, _store} when is_atom(module) -> validate_session_adapter!(module)
      _ -> raise ArgumentError, ":session_store must be a {module, store} adapter tuple"
    end

    validate_session_namespace!(opts)

    case Keyword.get(opts, :url_elicitation_store) do
      nil -> :ok
      {module, _store} when is_atom(module) -> validate_url_adapter!(module)
      _ -> raise ArgumentError, ":url_elicitation_store must be a {module, store} adapter tuple"
    end

    validate_url_namespace!(opts)
    :ok
  end

  @doc false
  def default_namespace(opts) do
    case Keyword.get(opts, :name) || Keyword.get(opts, :server_name) do
      nil -> "default"
      value when is_atom(value) -> Atom.to_string(value)
      value when is_binary(value) and value != "" -> value
      _ -> "default"
    end
  end

  defp validate_session_adapter!(module),
    do:
      validate_adapter!(
        module,
        @session_callbacks,
        ":session_store module must implement AttestoMCP.Server.SessionStore"
      )

  defp validate_url_adapter!(module),
    do:
      validate_adapter!(
        module,
        @url_callbacks,
        ":url_elicitation_store module must implement AttestoMCP.Server.UrlElicitationStore"
      )

  defp validate_adapter!(module, callbacks, message) do
    unless Code.ensure_loaded?(module) and
             Enum.all?(callbacks, fn {function, arity} ->
               function_exported?(module, function, arity)
             end) do
      raise ArgumentError, message
    end
  end

  defp validate_session_namespace!(opts) do
    case Keyword.get(opts, :session_store) do
      {module, store} when module == AttestoMCP.Server.SessionStore.Ecto ->
        validate_namespace!(
          module,
          store,
          Keyword.get(opts, :session_namespace) || default_namespace(opts),
          ":session_store"
        )

      _other ->
        :ok
    end
  end

  defp validate_url_namespace!(opts) do
    case Keyword.get(opts, :url_elicitation_store) do
      {module, store}
      when module in [
             AttestoMCP.Server.UrlElicitationStore.Ecto,
             :"Elixir.AttestoMCP.Server.UrlElicitationStore.Ecto"
           ] ->
        validate_namespace!(
          module,
          store,
          Keyword.get(opts, :session_namespace) || default_namespace(opts),
          ":url_elicitation_store"
        )

      _other ->
        :ok
    end
  end

  defp validate_namespace!(module, store, namespace, option) do
    unless Code.ensure_loaded?(module) and function_exported?(module, :namespace_matches?, 2) and
             apply(module, :namespace_matches?, [store, namespace]) do
      raise ArgumentError,
            "#{option} must be a valid Ecto handle whose namespace matches :session_namespace"
    end
  end

  defp ensure_pg_started! do
    case :pg.start_link(@session_pg_scope) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
      other -> raise "cannot start cluster session registry: #{inspect(other)}"
    end
  end
end
