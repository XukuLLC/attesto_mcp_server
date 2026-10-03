defmodule AttestoMCP.Server.Schema.Formats do
  @moduledoc false
  @behaviour JSV.FormatValidator

  @impl true
  def supported_formats, do: ["hostname"]

  @impl true
  def applies_to_type?("hostname", value), do: is_binary(value)

  @impl true
  def validate_cast("hostname", value) do
    # RFC 1034 section 3.1 permits an absolute domain name's final root dot.
    hostname = String.replace_suffix(value, ".", "")

    case JSV.FormatValidator.Default.validate_cast("hostname", hostname) do
      {:ok, _} -> {:ok, value}
      error -> error
    end
  end
end
