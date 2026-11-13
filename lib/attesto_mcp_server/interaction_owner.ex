defmodule AttestoMCP.Server.InteractionOwner do
  @moduledoc """
  Identity of the caller that may complete an elicitation or continuation.

  Build with `from_context/1` using trusted authentication, never request params,
  client display metadata, URL parameters, or an approval ID. HTTP contexts use
  verified `attesto_mcp_claims` for issuer, subject and OAuth client. Core/stdio
  integrations may supply `:issuer`, `:subject`, and `:client_id` directly.
  Tenant and the host's stable `:principal_binding` remain independent fields.

  Browser completion handlers must authenticate the browser user and reconstruct
  the same owner, including the initiating client and tenant. This struct does
  not authenticate anyone. Existing custom principal tuples remain intact.
  """

  defstruct [:principal_binding, :issuer, :subject, :client_id, :tenant]

  @type t :: %__MODULE__{
          principal_binding: term(),
          issuer: term(),
          subject: term(),
          client_id: term(),
          tenant: term()
        }

  @spec from_context(map()) :: t()
  def from_context(context) when is_map(context) do
    claims = get(context, :attesto_mcp_claims)

    %__MODULE__{
      principal_binding: get(context, :principal_binding, get(context, :principal, "anonymous")),
      issuer: identity(claims, "iss", context, :issuer),
      subject: identity(claims, "sub", context, :subject),
      client_id: identity(claims, "client_id", context, :client_id),
      tenant: get(context, :tenant, if(is_map(claims), do: claims["tenant"]))
    }
  end

  @doc false
  def from_binding(%__MODULE__{} = owner), do: owner
  def from_binding(binding), do: %__MODULE__{principal_binding: binding}

  defp identity(claims, key, _context, _field) when is_map(claims), do: claims[key]
  defp identity(_claims, _key, context, field), do: get(context, field)

  defp get(context, key, default \\ nil),
    do: Map.get(context, key, Map.get(context, Atom.to_string(key), default))
end
