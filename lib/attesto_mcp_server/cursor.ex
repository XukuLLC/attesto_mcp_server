defmodule AttestoMCP.Server.Cursor do
  @moduledoc "Opaque, signed, expiring authorization-bound pagination cursors."

  @doc false
  @spec catalog_digest([map()]) :: String.t()
  def catalog_digest(catalog) when is_list(catalog) do
    catalog
    |> Enum.map(&(&1 |> digestible_definition() |> raw_digest()))
    |> digest()
  end

  @spec issue(term(), String.t(), String.t(), keyword()) :: String.t()
  def issue(position, principal, version, opts \\ []) do
    ttl = positive_ttl(Keyword.get(opts, :ttl), 300_000)
    secret = Keyword.get(opts, :secret) || secret()
    page_size = positive_integer(Keyword.get(opts, :page_size), 100)

    payload = %{
      "p" => position,
      "s" => digest(principal),
      "v" => version,
      "t" => digest(Keyword.get(opts, :tenant)),
      "c" => context_digest(opts),
      "d" => Keyword.get(opts, :catalog_digest),
      "z" => page_size,
      "e" => System.system_time(:millisecond) + ttl
    }

    encoded = payload |> Jason.encode!() |> Base.url_encode64(padding: false)
    signature = :crypto.mac(:hmac, :sha256, secret, encoded) |> Base.url_encode64(padding: false)
    encoded <> "." <> signature
  end

  @spec verify(String.t(), term(), String.t(), keyword()) :: {:ok, term()} | {:error, atom()}
  def verify(cursor, principal, version, opts \\ [])

  def verify(cursor, principal, version, opts) when is_binary(cursor) do
    with [payload, provided] <- String.split(cursor, ".", parts: 2),
         secret <- Keyword.get(opts, :secret) || secret(),
         expected <-
           :crypto.mac(:hmac, :sha256, secret, payload) |> Base.url_encode64(padding: false),
         true <- Plug.Crypto.secure_compare(expected, provided),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, data} <- Jason.decode(json),
         true <- data["s"] == digest(principal),
         true <- data["v"] == version,
         true <- data["t"] == digest(Keyword.get(opts, :tenant)),
         true <- data["c"] == context_digest(opts),
         true <- data["d"] == Keyword.get(opts, :catalog_digest),
         true <- data["z"] == positive_integer(Keyword.get(opts, :page_size), 100),
         true <- is_integer(data["e"]) and data["e"] >= System.system_time(:millisecond) do
      {:ok, data["p"]}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  def verify(_, _, _, _), do: {:error, :invalid_cursor}

  defp context_digest(opts) do
    context = %{
      "catalog" => Keyword.get(opts, :catalog),
      "catalog_digest" => Keyword.get(opts, :catalog_digest),
      "scopes" => opts |> Keyword.get(:scopes, []) |> List.wrap() |> Enum.sort(),
      "visibility" => Keyword.get(opts, :visibility, Keyword.get(opts, :visibility_digest)),
      "page_size" => positive_integer(Keyword.get(opts, :page_size), 100)
    }

    digest(context)
  end

  defp positive_ttl(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive_ttl(_, fallback), do: fallback

  defp positive_integer(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive_integer(_, fallback), do: fallback

  defp digestible_definition(definition) when is_map(definition),
    do: Map.drop(definition, [:handler, :authorize, "handler", "authorize"])

  defp digest(nil), do: "anonymous"

  defp digest(value),
    do: value |> raw_digest() |> Base.url_encode64(padding: false)

  defp raw_digest(value),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))

  defp secret do
    case Application.get_env(:attesto_mcp_server, :cursor_secret) do
      value when is_binary(value) ->
        value

      _ ->
        persisted_secret()
    end
  end

  defp persisted_secret do
    case :persistent_term.get({__MODULE__, :secret}, nil) do
      value when is_binary(value) ->
        value

      _ ->
        :global.trans({{__MODULE__, :secret}, self()}, fn ->
          case :persistent_term.get({__MODULE__, :secret}, nil) do
            value when is_binary(value) ->
              value

            _ ->
              value = :crypto.strong_rand_bytes(32)
              :persistent_term.put({__MODULE__, :secret}, value)
              value
          end
        end)
    end
  end
end
