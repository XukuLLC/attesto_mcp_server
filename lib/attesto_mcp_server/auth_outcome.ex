defmodule AttestoMCP.Server.AuthOutcome do
  @moduledoc false
  # Bounded outcomes for the HTTP authentication span. The outcome AttestoMCP's
  # plugs record on the connection is preferred; a refusal rendered by an
  # AttestoMCP release that records none is classified from the OAuth error
  # envelope the server's own `:send_error` hook captured in its assigns.

  @outcome_key :attesto_mcp_auth_outcome
  @error_assign :attesto_mcp_oauth_error
  @sender_constraint ~w(
    invalid_dpop_jkt invalid_mtls_thumbprint dpop_proof_required dpop_proof_unexpected
    mtls_cert_required mtls_cert_unexpected conflicting_confirmation unsupported_confirmation
  )

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
  def classify(503, _body), do: :verifier_unavailable

  def classify(status, %{"error" => error} = body),
    do: error_outcome(error, Map.get(body, "error_description"), status)

  def classify(status, _body), do: status_outcome(status)

  defp error_outcome("insufficient_scope", _description, _status), do: :insufficient_scope
  defp error_outcome("use_dpop_nonce", _description, _status), do: :dpop_nonce_required
  defp error_outcome("invalid_dpop_proof", "replay", _status), do: :dpop_replay
  defp error_outcome("invalid_dpop_proof", _description, _status), do: :invalid_dpop_proof

  defp error_outcome("insufficient_user_authentication", _description, _status),
    do: :step_up_required

  defp error_outcome("invalid_token", description, _status), do: token_outcome(description)
  defp error_outcome(_error, _description, status), do: status_outcome(status)

  # The core plug reports a verification failure as the verifier's reason atom
  # in `error_description`; these are the reasons worth counting apart.
  defp token_outcome("missing or malformed Authorization header"), do: :missing_credentials
  defp token_outcome("expired"), do: :token_expired
  defp token_outcome("not_yet_valid"), do: :token_not_yet_valid
  defp token_outcome("invalid_audience"), do: :invalid_audience
  defp token_outcome("invalid_issuer"), do: :invalid_issuer
  defp token_outcome("request is not authenticated"), do: :unauthenticated

  defp token_outcome("request was not authenticated by this protected-resource boundary"),
    do: :unauthenticated

  defp token_outcome(reason) when reason in @sender_constraint, do: :sender_constraint_mismatch
  defp token_outcome(_reason), do: :invalid_token

  defp status_outcome(401), do: :invalid_token
  defp status_outcome(403), do: :insufficient_scope
  defp status_outcome(503), do: :verifier_unavailable
  defp status_outcome(_status), do: :other

  defp sender_binding(conn) do
    case Map.get(conn.assigns, :attesto_mcp_sender) do
      %{binding: binding} when binding in [:bearer, :dpop, :mtls] -> binding
      _other -> nil
    end
  end
end
