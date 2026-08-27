defmodule AttestoMCP.Server.P15URITemplateTest do
  use ExUnit.Case, async: false

  alias AttestoMCP.Server

  @legacy "2025-11-25"

  defp read(server, id, uri) do
    Server.dispatch(
      server,
      %{kind: :request, id: id, method: "resources/read", params: %{"uri" => uri}},
      %{principal: "uri-template-test"},
      version: @legacy
    )
  end

  defp template_handler(parent) do
    fn %{params: params, uri: uri}, _context ->
      send(parent, {:template_params, params})
      {:ok, %{"contents" => [%{"uri" => uri, "text" => "ok"}]}}
    end
  end

  test "reserved path expansion preserves slash and captures decoded value" do
    {:ok, server} = Server.start_link([])

    assert :ok =
             Server.register_resource_template(server, "https://example.test/{+path}", %{
               handler: template_handler(self())
             })

    assert {1, %{"result" => %{"contents" => _}}} =
             read(server, 1, "https://example.test/a/b")

    assert_receive {:template_params, %{"path" => "a/b"}}
  end

  test "path prefix modifiers reject expansions longer than the declared prefix" do
    {:ok, server} = Server.start_link([])

    assert :ok =
             Server.register_resource_template(server, "https://example.test/items/{id:3}", %{
               handler: template_handler(self())
             })

    assert {1, %{"error" => %{"code" => code}}} =
             read(server, 1, "https://example.test/items/abcd")

    assert code in [-32602, -32002]

    refute_receive {:template_params, _}, 20

    assert {2, %{"result" => %{"contents" => _}}} =
             read(server, 2, "https://example.test/items/abc")

    assert_receive {:template_params, %{"id" => "abc"}}
  end

  test "query expressions accept optional q and limit in either order" do
    {:ok, server} = Server.start_link([])

    assert :ok =
             Server.register_resource_template(server, "https://example.test/items{?q,limit}", %{
               handler: template_handler(self())
             })

    assert {1, %{"result" => _}} = read(server, 1, "https://example.test/items?q=one")
    assert_receive {:template_params, %{"q" => "one"}}

    assert {2, %{"result" => _}} = read(server, 2, "https://example.test/items?limit=10")
    assert_receive {:template_params, %{"limit" => "10"}}

    assert {3, %{"result" => _}} =
             read(server, 3, "https://example.test/items?q=one&limit=10")

    assert_receive {:template_params, %{"q" => "one", "limit" => "10"}}

    assert {4, %{"result" => _}} =
             read(server, 4, "https://example.test/items?limit=10&q=one")

    assert_receive {:template_params, %{"q" => "one", "limit" => "10"}}
  end

  test "query expressions reject unrelated keys and ambiguous duplicates" do
    {:ok, server} = Server.start_link([])

    assert :ok =
             Server.register_resource_template(server, "https://example.test/items{?q,limit}", %{
               handler: template_handler(self())
             })

    for {id, query} <- [
          {1, "q=one&q=two"},
          {2, "other=value"},
          {3, "q=%ZZ"},
          {4, "q=%2E%2E%2Fsecret"}
        ] do
      assert {^id, %{"error" => %{"code" => code}}} =
               read(server, id, "https://example.test/items?" <> query)

      assert code in [-32602, -32002]
    end

    refute_receive {:template_params, _}, 20
  end

  test "exploded query captures repeated lists and associative values" do
    {:ok, server} = Server.start_link([])

    assert :ok =
             Server.register_resource_template(server, "https://example.test/items{?keys*}", %{
               handler: template_handler(self())
             })

    assert {1, %{"result" => _}} =
             read(server, 1, "https://example.test/items?keys=one&keys=two")

    assert_receive {:template_params, %{"keys" => ["one", "two"]}}

    assert {2, %{"result" => _}} =
             read(server, 2, "https://example.test/items?semi=%3B&dot=.&comma=%2C")

    assert_receive {:template_params, %{"keys" => %{"semi" => ";", "dot" => ".", "comma" => ","}}}
  end

  test "exploded query bounds pairs and rejects decoded traversal" do
    {:ok, server} = Server.start_link([])

    assert :ok =
             Server.register_resource_template(server, "https://example.test/items{?keys*}", %{})

    excessive =
      1..33
      |> Enum.map_join("&", fn index -> "k#{index}=value" end)

    assert {1, %{"error" => %{"code" => code}}} =
             read(server, 1, "https://example.test/items?" <> excessive)

    assert code in [-32602, -32002]

    assert {2, %{"error" => %{"code" => code}}} =
             read(server, 2, "https://example.test/items?keys=%2E%2E%2Fsecret")

    assert code in [-32602, -32002]
  end

  test "unsupported reverse-matching layouts fail at registration" do
    {:ok, server} = Server.start_link([])

    for template <- [
          "https://example.test/{#fragment}",
          "https://example.test/{first}/{second}",
          "https://example.test/items{?q}/suffix",
          "https://example.test/items{?q,,limit}"
        ] do
      assert {:error, {:invalid_definition, :uri_template}} =
               Server.register_resource_template(server, template, %{})
    end
  end
end
