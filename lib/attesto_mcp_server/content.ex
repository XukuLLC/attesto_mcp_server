defmodule AttestoMCP.Server.Content do
  @moduledoc """
  Typed constructors for MCP content returned by handlers.

  Constructors emit canonical string-key maps and raise `ArgumentError` for
  invalid programmer input. Image, audio, and blob arguments are already
  Base64-encoded wire values; only canonical padded Base64 is accepted.

  Raw maps remain supported by `AttestoMCP.Server` for hosts that need custom
  extension members.
  """

  alias AttestoMCP.Server.Output

  @type t :: %{required(String.t()) => term()}
  @type resource_content :: %{required(String.t()) => term()}
  @type prompt_message :: %{required(String.t()) => term()}
  @type role :: :user | :assistant | String.t()
  @type common_option :: {:annotations, map()} | {:meta, map()}
  @type resource_link_option ::
          common_option()
          | {:title, String.t()}
          | {:description, String.t()}
          | {:mime_type, String.t()}
          | {:size, non_neg_integer()}
          | {:icons, [map()]}
  @type resource_content_option ::
          {:mime_type, String.t()} | {:meta, map()} | {:annotations, map()} | {:icons, [map()]}

  @doc "Builds a text content block."
  @spec text(String.t(), [common_option()]) :: t()
  def text(text, opts \\ []) do
    opts = options!(opts, [:annotations, :meta])

    %{"type" => "text", "text" => text}
    |> put_options(opts, annotations: "annotations", meta: "_meta")
    |> content!()
  end

  @doc "Builds an image content block from canonical padded Base64 data."
  @spec image(String.t(), String.t(), [common_option()]) :: t()
  def image(data, mime_type, opts \\ []) do
    opts = options!(opts, [:annotations, :meta])

    %{"type" => "image", "data" => data, "mimeType" => mime_type}
    |> put_options(opts, annotations: "annotations", meta: "_meta")
    |> content!()
  end

  @doc "Builds an audio content block from canonical padded Base64 data."
  @spec audio(String.t(), String.t(), [common_option()]) :: t()
  def audio(data, mime_type, opts \\ []) do
    opts = options!(opts, [:annotations, :meta])

    %{"type" => "audio", "data" => data, "mimeType" => mime_type}
    |> put_options(opts, annotations: "annotations", meta: "_meta")
    |> content!()
  end

  @doc "Builds a resource-link content block."
  @spec resource_link(String.t(), String.t(), [resource_link_option()]) :: t()
  def resource_link(uri, name, opts \\ []) do
    opts =
      options!(opts, [
        :title,
        :description,
        :mime_type,
        :size,
        :icons,
        :annotations,
        :meta
      ])

    %{"type" => "resource_link", "uri" => uri, "name" => name}
    |> put_options(
      opts,
      title: "title",
      description: "description",
      mime_type: "mimeType",
      size: "size",
      icons: "icons",
      annotations: "annotations",
      meta: "_meta"
    )
    |> content!()
  end

  @doc "Builds an embedded-resource content block from one resource content entry."
  @spec embedded_resource(resource_content(), [common_option()]) :: t()
  def embedded_resource(resource, opts \\ []) do
    opts = options!(opts, [:annotations, :meta])

    %{"type" => "resource", "resource" => resource}
    |> put_options(opts, annotations: "annotations", meta: "_meta")
    |> content!()
  end

  @doc "Builds a text resource-content entry."
  @spec resource_text(String.t(), String.t(), [resource_content_option()]) :: resource_content()
  def resource_text(uri, text, opts \\ []) do
    opts = options!(opts, [:mime_type, :meta, :annotations, :icons])

    %{"uri" => uri, "text" => text}
    |> put_options(
      opts,
      mime_type: "mimeType",
      meta: "_meta",
      annotations: "annotations",
      icons: "icons"
    )
    |> resource_content!()
  end

  @doc "Builds a blob resource-content entry from canonical padded Base64 data."
  @spec resource_blob(String.t(), String.t(), [resource_content_option()]) :: resource_content()
  def resource_blob(uri, blob, opts \\ []) do
    opts = options!(opts, [:mime_type, :meta, :annotations, :icons])

    %{"uri" => uri, "blob" => blob}
    |> put_options(
      opts,
      mime_type: "mimeType",
      meta: "_meta",
      annotations: "annotations",
      icons: "icons"
    )
    |> resource_content!()
  end

  @doc "Builds one user or assistant prompt message."
  @spec prompt_message(role(), t()) :: prompt_message()
  def prompt_message(role, content) do
    role = normalize_role(role)

    case Output.normalize_prompt_message(%{"role" => role, "content" => content}) do
      {:ok, message} -> message
      {:error, _reason} -> raise ArgumentError, "invalid MCP prompt message"
    end
  end

  defp content!(value) do
    case Output.normalize_content_item(value) do
      {:ok, content} -> content
      {:error, _reason} -> raise ArgumentError, "invalid MCP content"
    end
  end

  defp resource_content!(value) do
    case Output.normalize_resource_content(value) do
      {:ok, content} -> content
      {:error, _reason} -> raise ArgumentError, "invalid MCP resource content"
    end
  end

  defp normalize_role(:user), do: "user"
  defp normalize_role(:assistant), do: "assistant"
  defp normalize_role(role), do: role

  defp options!(opts, allowed) do
    case Output.normalize_options(opts, allowed) do
      {:ok, opts} -> opts
      {:error, :invalid_options} -> raise ArgumentError, "invalid or duplicate MCP content option"
    end
  end

  defp put_options(map, opts, mapping) do
    Enum.reduce(mapping, map, fn {option, key}, acc ->
      case Keyword.fetch(opts, option) do
        {:ok, nil} -> acc
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end
end
