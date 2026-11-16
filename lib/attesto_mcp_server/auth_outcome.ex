defmodule AttestoMCP.Server.AuthOutcome do
  @moduledoc false
  # Bounded outcomes for the HTTP authentication span. The outcome AttestoMCP's
  # plugs record on the connection is preferred; a refusal rendered by an
  # AttestoMCP release that records none is classified from the OAuth error
  # envelope the server's own `:send_error` hook captured in its assigns.

  @outcome_key :attesto_mcp_auth_outcome
  @error_assign :attesto_mcp_oauth_error

  @type t ::
          :ok
          | :missing_credentials
          | :invalid_token
          | :token_expired
          | :token_not_yet_valid
          | :invalid_audience
          | :invalid_issuer
          | :sender_constraint_mismatch
          | :invalid_dpop_proof
          | :dpop_replay
          | :dpop_nonce_required
          | :step_up_required
          | :policy_rejected
          | :insufficient_scope
          | :unauthenticated
          | :verifier_unavailable
          | :principal_unavailable
          | :verifier_failure
          | :principal_binding_failure
          | :other

  @outcomes [
    :ok,
    :missing_credentials,
    :invalid_token,
    :token_expired,
    :token_not_yet_valid,
    :invalid_audience,
    :invalid_issuer,
    :sender_constraint_mismatch,
    :invalid_dpop_proof,
    :dpop_replay,
    :dpop_nonce_required,
    :step_up_required,
    :policy_rejected,
    :insufficient_scope,
    :unauthenticated,
    :verifier_unavailable,
    :principal_unavailable,
    :verifier_failure,
    :principal_binding_failure,
    :other
  ]

  @doc "Stop metadata for the span around `protect_resource/3`."
  @spec metadata({:ok, Plug.Conn.t()} | {:halt, Plug.Conn.t()} | {:error, term()}) :: map()
  def metadata({:ok, conn}), do: %{outcome: :ok, binding: sender_binding(conn)}
  def metadata({:halt, conn}), do: %{outcome: refusal(conn), status: conn.status}
  def metadata({:error, _error}), do: %{outcome: :principal_binding_failure}

  @doc "Records an outcome this boundary decided itself."
  @spec mark(Plug.Conn.t(), t()) :: Plug.Conn.t()
  def mark(conn, outcome) when outcome in @outcomes,
    do: Plug.Conn.put_private(conn, @outcome_key, outcome)

  @doc "The bounded outcome of a halted authentication."
  @spec refusal(Plug.Conn.t()) :: t()
  def refusal(conn) do
    case Map.get(conn.private, @outcome_key) do
      outcome when outcome in @outcomes -> outcome
      _unknown -> classify(conn.status, Map.get(conn.assigns, @error_assign))
    end
  end

  @doc false
  @spec classify(integer() | nil, term()) :: t()
  def classify(status, body) when is_integer(status),
    do: AttestoMCP.Telemetry.refusal_outcome(status, body)

  def classify(_status, _body), do: :other

  defp sender_binding(conn) do
    case Map.get(conn.assigns, :attesto_mcp_sender) do
      %{binding: binding} when binding in [:bearer, :dpop, :mtls] -> binding
      _other -> nil
    end
  end
end
