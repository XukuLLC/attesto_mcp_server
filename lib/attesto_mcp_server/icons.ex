defmodule AttestoMCP.Server.Icons do
  @moduledoc false

  # Component definitions keep the field checks they had in 2.3.x so existing
  # registrations remain valid. Implementation identity and presentation
  # output are new surfaces, so they use the complete validator below.

  @max_icons 16
  @max_sizes 16
  @max_src_bytes 65_536
  @max_mime_bytes 255
  @max_total_bytes 131_072
  @icon_keys ["src", "mimeType", "sizes", "theme"]
  @key_aliases %{
    "src" => "src",
    "mimeType" => "mimeType",
    "mime_type" => "mimeType",
    "sizes" => "sizes",
    "theme" => "theme"
  }
  @mime_pattern ~r/^image\/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,126}$/
  @size_pattern ~r/^[1-9][0-9]{0,4}x[1-9][0-9]{0,4}$/
  @data_pattern ~r/^data:(image\/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,126});base64,([A-Za-z0-9+\/]+={0,2})$/

  @doc false
  def max_icons, do: @max_icons

  @doc false
  def max_total_bytes, do: @max_total_bytes

  @doc "Checks the 2.3.x component icon fields used by registered definitions."
  @spec component_list?(term()) :: boolean()
  def component_list?(nil), do: true

  def component_list?(icons) when is_list(icons) do
    Enum.all?(icons, fn icon ->
      is_map(icon) and is_binary(icon["src"]) and icon["src"] != "" and
        (is_nil(icon["mimeType"]) or is_binary(icon["mimeType"])) and
        (is_nil(icon["theme"]) or icon["theme"] in ["light", "dark"]) and
        (is_nil(icon["sizes"]) or
           (is_list(icon["sizes"]) and Enum.all?(icon["sizes"], &is_binary/1)))
    end)
  end

  def component_list?(_icons), do: false

  @doc """
  Validates and canonicalizes a complete icon list.

  Each icon has a `src` that is an absolute `https:` URL or a Base64 `data:`
  URI with an `image/*` media type, plus optional `mimeType`, `sizes`, and
  `theme` fields defined by the MCP `Icon` type. Atom keys and `mime_type` are
  accepted in configuration and returned as wire keys. Icon URLs are never
  fetched or resolved.
  """
  @spec normalize(term()) :: {:ok, [map()]} | {:error, atom()}
  def normalize(icons) when is_list(icons) and icons != [] do
    cond do
      not proper_list?(icons) ->
        {:error, :invalid_icons}

      length(icons) > @max_icons ->
        {:error, :too_many_icons}

      true ->
        with {:ok, normalized} <- normalize_each(icons),
             :ok <- total_budget(normalized) do
          {:ok, normalized}
        end
    end
  end

  def normalize(_icons), do: {:error, :invalid_icons}

  @doc "Returns true when a wire icon list already satisfies `normalize/1`."
  @spec valid_wire_list?(term()) :: boolean()
  def valid_wire_list?(icons) do
    case normalize(icons) do
      {:ok, ^icons} -> true
      _other -> false
    end
  end

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_improper), do: false

  defp normalize_each(icons) do
    Enum.reduce_while(icons, {:ok, []}, fn icon, {:ok, acc} ->
      case normalize_icon(icon) do
        {:ok, icon} -> {:cont, {:ok, [icon | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, icons} -> {:ok, Enum.reverse(icons)}
      error -> error
    end
  end

  defp normalize_icon(icon) when is_map(icon) do
    with {:ok, icon} <- canonical_keys(icon),
         :ok <- valid_src(icon["src"]),
         :ok <- valid_mime(Map.get(icon, "mimeType", :absent)),
         :ok <- valid_sizes(Map.get(icon, "sizes", :absent)),
         :ok <- valid_theme(Map.get(icon, "theme", :absent)) do
      {:ok, icon}
    end
  end

  defp normalize_icon(_icon), do: {:error, :invalid_icon}

  defp canonical_keys(icon) do
    Enum.reduce_while(icon, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      canonical = if is_atom(key) or is_binary(key), do: Map.get(@key_aliases, to_string(key))

      cond do
        is_nil(canonical) -> {:halt, {:error, :unsupported_icon_field}}
        Map.has_key?(acc, canonical) -> {:halt, {:error, :conflicting_icon_field}}
        true -> {:cont, {:ok, Map.put(acc, canonical, value)}}
      end
    end)
    |> case do
      {:ok, icon} ->
        if Map.has_key?(icon, "src") and Enum.all?(Map.keys(icon), &(&1 in @icon_keys)),
          do: {:ok, icon},
          else: {:error, :invalid_icon}

      error ->
        error
    end
  end

  defp valid_src(src) when is_binary(src) and byte_size(src) in 1..@max_src_bytes do
    cond do
      not String.valid?(src) or String.match?(src, ~r/[\x00-\x20\x7F]/u) ->
        {:error, :invalid_icon_src}

      String.starts_with?(src, "data:") ->
        valid_data_uri(src)

      true ->
        valid_https_uri(src)
    end
  end

  defp valid_src(_src), do: {:error, :invalid_icon_src}

  defp valid_https_uri(src) do
    case URI.new(src) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil}}
      when is_binary(host) and host != "" ->
        :ok

      _other ->
        {:error, :invalid_icon_src}
    end
  end

  defp valid_data_uri(src) do
    with [_, _media_type, payload] <- Regex.run(@data_pattern, src),
         true <- rem(byte_size(payload), 4) == 0,
         {:ok, _decoded} <- Base.decode64(payload) do
      :ok
    else
      _other -> {:error, :invalid_icon_src}
    end
  end

  defp valid_mime(:absent), do: :ok

  defp valid_mime(mime) when is_binary(mime) and byte_size(mime) in 1..@max_mime_bytes do
    if Regex.match?(@mime_pattern, mime), do: :ok, else: {:error, :invalid_icon_mime_type}
  end

  defp valid_mime(_mime), do: {:error, :invalid_icon_mime_type}

  defp valid_sizes(:absent), do: :ok

  defp valid_sizes(sizes) when is_list(sizes) and sizes != [] do
    if proper_list?(sizes) and length(sizes) <= @max_sizes and
         Enum.all?(sizes, &valid_size?/1) and Enum.uniq(sizes) == sizes,
       do: :ok,
       else: {:error, :invalid_icon_sizes}
  end

  defp valid_sizes(_sizes), do: {:error, :invalid_icon_sizes}

  defp valid_size?("any"), do: true
  defp valid_size?(size) when is_binary(size), do: Regex.match?(@size_pattern, size)
  defp valid_size?(_size), do: false

  defp valid_theme(:absent), do: :ok
  defp valid_theme(theme) when theme in ["light", "dark"], do: :ok
  defp valid_theme(_theme), do: {:error, :invalid_icon_theme}

  defp total_budget(icons) do
    case Jason.encode(icons) do
      {:ok, encoded} when byte_size(encoded) <= @max_total_bytes -> :ok
      _other -> {:error, :icons_too_large}
    end
  end
end
