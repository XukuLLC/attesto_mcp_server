defmodule AttestoMCP.Server.Tasks do
  @moduledoc """
  Disabled task-profile boundary.

  The dated task profiles are intentionally unavailable until a host supplies a
  durable store and the complete profile contract. Keeping this supervised
  no-op process preserves the server's supervision topology while ensuring that
  no in-memory task state can be enabled accidentally.
  """
  use GenServer

  @disabled :tasks_disabled

  @doc "Starts the supervised disabled task boundary."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

  @doc "Returns `{:error, :tasks_disabled}`; no task profile is advertised."
  @spec create(pid(), String.t(), term(), map(), term()) :: {:error, :tasks_disabled}
  def create(_pid, _era, _owner, _data, _tenant \\ nil), do: {:error, @disabled}
  @doc "Returns `{:error, :tasks_disabled}`; task lookup is unavailable."
  @spec get(pid(), term(), term(), term()) :: {:error, :tasks_disabled}
  def get(_pid, _id, _owner, _tenant \\ nil), do: {:error, @disabled}
  @doc "Returns `{:error, :tasks_disabled}`; task updates are unavailable."
  @spec update(pid(), term(), term(), map(), term()) :: {:error, :tasks_disabled}
  def update(_pid, _id, _owner, _attrs, _tenant \\ nil), do: {:error, @disabled}
  @doc "Returns `{:error, :tasks_disabled}`; task cancellation is unavailable."
  @spec cancel(pid(), term(), term(), term()) :: {:error, :tasks_disabled}
  def cancel(_pid, _id, _owner, _tenant \\ nil), do: {:error, @disabled}

  @impl true
  def init(opts), do: {:ok, %{opts: opts}}

  @impl true
  def handle_call(_request, _from, state), do: {:reply, {:error, @disabled}, state}
end
