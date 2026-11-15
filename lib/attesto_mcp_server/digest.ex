defmodule AttestoMCP.Server.Digest do
  @moduledoc false

  @doc false
  @spec raw(term()) :: binary()
  def raw(value),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))

  @doc false
  @spec base64url(term()) :: String.t()
  def base64url(value), do: value |> raw() |> Base.url_encode64(padding: false)

  @doc false
  @spec hex(term()) :: String.t()
  def hex(value), do: value |> raw() |> Base.encode16(case: :lower)
end
