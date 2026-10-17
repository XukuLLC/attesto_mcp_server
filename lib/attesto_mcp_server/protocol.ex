defmodule AttestoMCP.Server.Protocol do
  @moduledoc false

  @modern "2026-07-28"
  @legacy "2025-11-25"
  @legacy_versions [@legacy, "2025-06-18"]
  @versions [@modern | @legacy_versions]

  @doc false
  def modern, do: @modern

  @doc false
  def legacy, do: @legacy

  @doc false
  def legacy_versions, do: @legacy_versions

  @doc false
  def versions, do: @versions

  @doc false
  def era(request, opts \\ []) when is_map(request) and is_list(opts) do
    case Keyword.fetch(opts, :version) do
      {:ok, version} -> normalize_era(version)
      :error -> inferred_era(request, opts)
    end
  end

  @doc false
  def version(request, opts \\ []) when is_map(request) and is_list(opts) do
    default = Keyword.get(opts, :default, @legacy)
    params = Map.get(request, :params, %{})
    metadata_version = metadata_value(params, "io.modelcontextprotocol/protocolVersion")

    case Map.get(request, :method) do
      "initialize" ->
        requested = if is_map(params), do: params["protocolVersion"], else: nil

        cond do
          is_binary(metadata_version) -> @modern
          requested in @legacy_versions -> requested
          true -> default
        end

      "notifications/initialized" ->
        @legacy

      _ ->
        if is_binary(metadata_version), do: metadata_version, else: default
    end
  end

  @doc false
  def metadata_value(params, key) when is_map(params) and is_binary(key) do
    case Map.get(params, "_meta") do
      metadata when is_map(metadata) -> Map.get(metadata, key)
      _ -> nil
    end
  end

  def metadata_value(_params, _key), do: nil

  defp inferred_era(request, opts) do
    headers = Keyword.get(opts, :headers)

    if is_list(headers) do
      http_era(request, headers, Keyword.get(opts, :session?, false))
    else
      request
      |> version(default: Keyword.get(opts, :default, @modern))
      |> normalize_era()
    end
  end

  defp http_era(%{method: "initialize"} = request, headers, _session?) do
    body_version = request |> Map.get(:params, %{}) |> metadata_version()

    cond do
      @modern in headers or body_version == @modern -> @modern
      Enum.any?(@legacy_versions, &(&1 in headers or body_version == &1)) -> @legacy
      true -> @legacy
    end
  end

  defp http_era(%{method: method} = request, headers, _session?)
       when method in ["ping", "notifications/initialized"] do
    if @modern in headers or modern_body?(request), do: @modern, else: @legacy
  end

  defp http_era(request, headers, session?) do
    cond do
      @modern in headers or modern_body?(request) -> @modern
      match?([version] when version in @legacy_versions, headers) -> @legacy
      session? -> @legacy
      true -> @modern
    end
  end

  defp modern_body?(request), do: metadata_version(Map.get(request, :params, %{})) == @modern

  defp metadata_version(params),
    do: metadata_value(params, "io.modelcontextprotocol/protocolVersion")

  defp normalize_era(version) when version in @legacy_versions, do: @legacy
  defp normalize_era(version), do: version
end
