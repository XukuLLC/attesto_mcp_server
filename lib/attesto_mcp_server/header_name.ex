defmodule AttestoMCP.Server.HeaderName do
  @moduledoc false

  @max_name_bytes 256
  @max_suffix_bytes 128
  @reserved ~w(authorization cookie host content-length transfer-encoding connection upgrade)

  @doc false
  @spec valid?(term()) :: boolean()
  def valid?(name)
      when is_binary(name) and byte_size(name) in 1..@max_name_bytes do
    String.valid?(name) and
      token?(name) and
      String.downcase(name) not in @reserved
  end

  def valid?(_name), do: false

  @doc false
  @spec valid_suffix?(term()) :: boolean()
  def valid_suffix?(suffix)
      when is_binary(suffix) and byte_size(suffix) in 1..@max_suffix_bytes do
    String.valid?(suffix) and token?(suffix) and
      not String.starts_with?(String.downcase(suffix), "mcp-param-")
  end

  def valid_suffix?(_suffix), do: false

  defp token?(name) do
    name
    |> String.to_charlist()
    |> Enum.all?(fn code ->
      code in ?a..?z or code in ?A..?Z or code in ?0..?9 or
        code in [?!, ?#, ?$, ?%, ?&, ?', ?*, ?+, ?-, ?., ?^, ?_, ?`, ?|, ?~]
    end)
  end
end
