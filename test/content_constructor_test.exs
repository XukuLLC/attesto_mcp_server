defmodule AttestoMCP.Server.ContentConstructorTest do
  use ExUnit.Case, async: true

  alias AttestoMCP.Server.{Content, Output, Result}

  test "text, image, and audio constructors emit canonical string-key maps" do
    assert Content.text("hello", annotations: %{audience: ["user"]}, meta: %{source: "test"}) ==
             %{
               "type" => "text",
               "text" => "hello",
               "annotations" => %{"audience" => ["user"]},
               "_meta" => %{"source" => "test"}
             }

    assert Content.image("aGk=", "image/png") == %{
             "type" => "image",
             "data" => "aGk=",
             "mimeType" => "image/png"
           }

    assert Content.audio("aGk=", "audio/wav") == %{
             "type" => "audio",
             "data" => "aGk=",
             "mimeType" => "audio/wav"
           }
  end

  test "binary content requires canonical padded Base64 and a non-empty MIME type" do
    for value <- ["aGk", "aGk=\n", "-_==", "%%%"] do
      assert_raise ArgumentError, fn -> Content.image(value, "image/png") end
      assert_raise ArgumentError, fn -> Content.audio(value, "audio/wav") end
      assert_raise ArgumentError, fn -> Content.resource_blob("urn:blob", value) end
    end

    assert_raise ArgumentError, fn -> Content.image("aGk=", "") end
    assert_raise ArgumentError, fn -> Content.audio("aGk=", "") end
  end

  test "resource-link exposes bounded standard options and rejects unsafe values" do
    link =
      Content.resource_link("https://example.test/item", "item",
        title: "Item",
        description: "An item",
        mime_type: "text/plain",
        size: 3,
        icons: [%{src: "https://example.test/icon.png", theme: "dark"}],
        annotations: %{priority: 0.5},
        meta: %{revision: 1}
      )

    assert link == %{
             "type" => "resource_link",
             "uri" => "https://example.test/item",
             "name" => "item",
             "title" => "Item",
             "description" => "An item",
             "mimeType" => "text/plain",
             "size" => 3,
             "icons" => [
               %{"src" => "https://example.test/icon.png", "theme" => "dark"}
             ],
             "annotations" => %{"priority" => 0.5},
             "_meta" => %{"revision" => 1}
           }

    for uri <- [
          "http://localhost/private",
          "https://user@example.test/private",
          "urn:item/../private",
          "urn:item\nother"
        ] do
      assert_raise ArgumentError, fn -> Content.resource_link(uri, "item") end
    end

    assert_raise ArgumentError, fn ->
      Content.resource_link("urn:item", "item", size: -1)
    end

    assert_raise ArgumentError, fn ->
      Content.resource_link("urn:item", "item", icons: [%{src: ""}])
    end
  end

  test "resource text and blob constructors enforce one valid content variant" do
    text =
      Content.resource_text("urn:text", "body",
        mime_type: "text/plain",
        meta: %{etag: "one"}
      )

    blob = Content.resource_blob("urn:blob", "aGk=", mime_type: "application/octet-stream")

    assert text == %{
             "uri" => "urn:text",
             "text" => "body",
             "mimeType" => "text/plain",
             "_meta" => %{"etag" => "one"}
           }

    assert blob == %{
             "uri" => "urn:blob",
             "blob" => "aGk=",
             "mimeType" => "application/octet-stream"
           }

    assert {:error, :invalid_resource_content} =
             Output.normalize_resource_content(%{
               "uri" => "urn:mixed",
               "text" => nil,
               "blob" => "aGk="
             })

    assert {:error, :invalid_resource_content} =
             Output.normalize_resource_content(%{"uri" => "urn:empty"})
  end

  test "embedded resources contain exactly one resource content entry" do
    resource = Content.resource_text("urn:embedded", "body")

    assert Content.embedded_resource(resource, annotations: %{audience: ["assistant"]}) == %{
             "type" => "resource",
             "resource" => %{"uri" => "urn:embedded", "text" => "body"},
             "annotations" => %{"audience" => ["assistant"]}
           }

    assert_raise ArgumentError, fn ->
      Content.embedded_resource(%{"contents" => [resource]})
    end
  end

  test "prompt messages accept only user and assistant roles with valid content" do
    content = Content.text("hello")

    assert Content.prompt_message(:user, content) == %{
             "role" => "user",
             "content" => content
           }

    assert Content.prompt_message("assistant", content) == %{
             "role" => "assistant",
             "content" => content
           }

    assert_raise ArgumentError, fn -> Content.prompt_message(:system, content) end
    assert_raise ArgumentError, fn -> Content.prompt_message(:user, %{"type" => "text"}) end
  end

  test "constructors reject unknown and duplicate options" do
    assert_raise ArgumentError, fn -> Content.text("hello", unknown: true) end

    assert_raise ArgumentError, fn ->
      Content.text("hello", annotations: %{}, annotations: %{})
    end

    assert_raise ArgumentError, fn -> Result.tool([], unknown: true) end
    assert_raise ArgumentError, fn -> Result.resource([], meta: %{}, meta: %{}) end
    assert_raise ArgumentError, fn -> Content.text("hello", [{:meta, %{}} | :improper]) end
  end

  test "tool result validates content, structured JSON, error state, and metadata" do
    content = Content.text("done")

    assert Result.tool(content,
             structured_content: %{count: 1},
             is_error: false,
             meta: %{trace: "safe"}
           ) == %{
             "content" => [content],
             "structuredContent" => %{"count" => 1},
             "isError" => false,
             "_meta" => %{"trace" => "safe"}
           }

    assert Result.tool([], structured_content: nil) == %{
             "content" => [],
             "structuredContent" => nil
           }

    assert_raise ArgumentError, fn -> Result.tool([%{"type" => "text"}]) end
    assert_raise ArgumentError, fn -> Result.tool([], structured_content: self()) end
    assert_raise ArgumentError, fn -> Result.tool([], is_error: nil) end
    assert_raise ArgumentError, fn -> Result.tool([], meta: "not-an-object") end
  end

  test "resource result validates every entry and its complete envelope" do
    content = Content.resource_text("urn:item", "body")

    assert Result.resource(content, meta: %{page: 1}) == %{
             "contents" => [content],
             "_meta" => %{"page" => 1}
           }

    assert Result.resource([]) == %{"contents" => []}
    assert_raise ArgumentError, fn -> Result.resource(%{"uri" => "urn:item"}) end
    assert_raise ArgumentError, fn -> Result.resource([], meta: self()) end

    assert {:error, :not_json} =
             Output.normalize_resource_result(%{"contents" => [], "extension" => self()})

    assert {:error, :not_json} =
             Output.normalize_prompt_result(%{"messages" => [], "extension" => self()})
  end

  test "normalization preserves raw maps and rejects atom/string key collisions" do
    assert {:ok, %{"type" => "text", "text" => "raw", "extension" => true}} =
             Output.normalize_content_item(%{type: "text", text: "raw", extension: true})

    assert {:error, :not_json} =
             Output.normalize_content_item(%{:text => "left", "text" => "right", type: "text"})

    assert {:error, :not_json} =
             Output.normalize_tool_result(%{
               "content" => [Content.text("first") | :improper]
             })
  end

  test "complete results enforce aggregate byte and depth limits" do
    first = Content.text(String.duplicate("a", 1_100_000))
    second = Content.text(String.duplicate("b", 1_100_000))

    assert_raise ArgumentError, fn -> Result.tool([first, second]) end

    deep_meta = Enum.reduce(1..70, %{}, fn index, acc -> %{Integer.to_string(index) => acc} end)
    assert_raise ArgumentError, fn -> Content.text("deep", meta: deep_meta) end
  end

  test "aggregate byte limit counts JSON escaping for values and keys" do
    escaped = String.duplicate("\"\\\n\0", 166_666)
    exact = %{"x" => escaped}

    assert IO.iodata_length(Jason.encode_to_iodata!(exact)) == 2_000_000
    assert {:ok, ^exact} = Output.canonicalize(exact)

    assert {:error, :not_json} = Output.canonicalize(%{"x" => escaped <> "a"})
    assert {:error, :not_json} = Output.canonicalize(%{escaped => nil})
  end
end
