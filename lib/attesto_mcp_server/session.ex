defmodule AttestoMCP.Server.Session do
  @moduledoc "Bounded legacy session records with principal binding and expiry."

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

  defp random_id do
    :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
  end
end
