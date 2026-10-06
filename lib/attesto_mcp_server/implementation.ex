defmodule AttestoMCP.Server.Implementation do
  @moduledoc false

  # Builds and checks the server `Implementation` value used by modern
  # discovery, modern result metadata, and legacy initialization. The value is
  # display metadata only; nothing in the server routes, authorizes, or
  # partitions caches by it.

  alias AttestoMCP.Server.Icons

  @legacy_2025_06_18 "2025-06-18"
  @max_text_bytes 1_024
  @max_description_bytes 4_096
  @max_url_bytes 2_048
  @fields ["name", "version", "title", "description", "websiteUrl", "icons"]

  @doc "Builds the configured implementation value from normalized startup options."
  @spec build(keyword()) :: map()
  def build(opts) do
    %{
      "name" => opts[:server_name] || "attesto_mcp_server",
      "version" => opts[:server_version] || application_version()
    }
    |> maybe_put("icons", opts[:server_icons])
  end

  @doc "Removes fields that a negotiated revision does not define."
  @spec for_revision(map(), String.t() | nil) :: map()
  def for_revision(info, @legacy_2025_06_18), do: Map.take(info, ["name", "version", "title"])
  def for_revision(info, _version), do: info

  @doc """
  Returns handler-authored implementation information when every field is a
  valid MCP `Implementation` field; otherwise returns the configured value.
  """
  @spec resolve_authored(term(), map()) :: map()
  def resolve_authored(authored, configured) do
    if valid?(authored), do: authored, else: configured
  end

  @doc "Checks a complete wire `Implementation` value."
  @spec valid?(term()) :: boolean()
  def valid?(%{"name" => name, "version" => version} = info) do
    Enum.all?(Map.keys(info), &(&1 in @fields)) and
      text?(name, @max_text_bytes) and text?(version, @max_text_bytes) and
      optional?(info, "title", &optional_text?(&1, @max_text_bytes)) and
      optional?(info, "description", &optional_text?(&1, @max_description_bytes)) and
      optional?(info, "websiteUrl", &website_url?/1) and
      optional?(info, "icons", &Icons.valid_wire_list?/1)
  end

  def valid?(_info), do: false

  defp optional?(info, key, check) do
    case Map.fetch(info, key) do
      :error -> true
      {:ok, value} -> check.(value)
    end
  end

  defp text?(value, max_bytes) when is_binary(value),
    do: byte_size(value) in 1..max_bytes and String.valid?(value)

  defp text?(_value, _max_bytes), do: false

  defp optional_text?(value, max_bytes) when is_binary(value),
    do: byte_size(value) <= max_bytes and String.valid?(value)

  defp optional_text?(_value, _max_bytes), do: false

  defp website_url?(value) when is_binary(value) and byte_size(value) in 1..@max_url_bytes do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil}}
      when scheme in ["https", "http"] and is_binary(host) and host != "" ->
        true

      _other ->
        false
    end
  end

  defp website_url?(_value), do: false

  defp application_version do
    _ = Application.load(:attesto_mcp_server)

    case Application.spec(:attesto_mcp_server, :vsn) do
      nil -> "0.0.0"
      version -> to_string(version)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
