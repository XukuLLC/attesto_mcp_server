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

  def uri_template_telemetry(event, measurements, metadata, owner) do
    send(owner, {:uri_template_telemetry, event, measurements, metadata})
  end

  defp aggregate_budget_uri do
    "urn:hostile/" <> String.duplicate("%61/a/", 680) <> "y"
  end

  defp aggregate_budget_templates(count) do
    Enum.map(1..count, fn index ->
      {:template,
       "urn:hostile/{+a_first_#{index}:1}/a/{+a_second_#{index}:1}/a/{a_id_#{index}:1}", %{}}
    end)
  end

  defp aggregate_budget_target(owner) do
    {:template, "urn:hostile/{+z_first}/a/{+z_second}/a/{z_id}",
     %{
       required_scopes: ["target.read"],
       handler: fn %{uri: uri}, _context ->
         send(owner, :aggregate_budget_target_called)
         {:ok, %{"contents" => [%{"uri" => uri, "text" => "ok"}]}}
       end
     }}
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

  test "bounded multi-expression paths capture two and three variables" do
    {:ok, server} = Server.start_link([])

    assert :ok =
             Server.register_resource_template(
               server,
               "https://example.test/records/{record_id}/versions/{version_id}",
               %{handler: template_handler(self())}
             )

    assert {1, %{"result" => _}} =
             read(server, 1, "https://example.test/records/r-7/versions/v-2")

    assert_receive {:template_params, %{"record_id" => "r-7", "version_id" => "v-2"}}

    assert :ok =
             Server.register_resource_template(
               server,
               "https://example.test/records/{record_id}/versions/{version_id}/blobs/{+path}",
               %{handler: template_handler(self())}
             )

    assert {2, %{"result" => _}} =
             read(server, 2, "https://example.test/records/r-7/versions/v-2/blobs/a/b")

    assert_receive {:template_params,
                    %{"record_id" => "r-7", "version_id" => "v-2", "path" => "a/b"}}
  end

  test "multi-expression matching resolves delimiter collisions without guessing" do
    {:ok, server} = Server.start_link([])

    assert :ok =
             Server.register_resource_template(
               server,
               "urn:records/{id}/versions/{version}.json",
               %{handler: template_handler(self())}
             )

    assert {1, %{"result" => _}} =
             read(server, 1, "urn:records/r1/versions/v1.json.bak.json")

    assert_receive {:template_params, %{"id" => "r1", "version" => "v1.json.bak"}}

    assert :ok =
             Server.register_resource_template(
               server,
               "urn:root/{+path}/{id}",
               %{handler: template_handler(self())}
             )

    assert {2, %{"result" => _}} = read(server, 2, "urn:root/a/b/c")
    assert_receive {:template_params, %{"path" => "a/b", "id" => "c"}}
  end

  test "collision-heavy reserved captures honor the 2,048-byte limit" do
    {:ok, server} = Server.start_link([])

    assert :ok =
             Server.register_resource_template(
               server,
               "urn:{+a}x{+b}x{+c}x",
               %{handler: template_handler(self())}
             )

    uri = "urn:" <> String.duplicate("x", 2_100)

    assert byte_size(uri) == 2_104
    assert {1, %{"result" => _}} = read(server, 1, uri)

    assert_receive {:template_params, params}
    assert byte_size(params["a"]) == 2_048
    assert byte_size(params["b"]) == 48
    assert byte_size(params["c"]) == 1
  end

  test "sixteen-expression paths prune prefix-bound captures before matching" do
    {:ok, server} = Server.start_link([])

    template =
      "urn:" <>
        Enum.map_join(1..14, fn index -> "{v#{index}:1}x" end) <>
        "{+a}x{+b}x"

    assert :ok =
             Server.register_resource_template(server, template, %{
               handler: template_handler(self())
             })

    uri = "urn:" <> String.duplicate("x", 2_100)
    assert byte_size(uri) == 2_104
    assert {1, %{"result" => _}} = read(server, 1, uri)

    assert_receive {:template_params, params}
    assert Enum.all?(1..14, &(byte_size(params["v#{&1}"]) == 1))
    assert byte_size(params["a"]) == 2_048
    assert byte_size(params["b"]) == 22
  end

  test "collision-heavy matching stays fail-closed at the URI boundary" do
    {:ok, server} = Server.start_link([])

    assert :ok =
             Server.register_resource_template(
               server,
               "urn:{+a}x{+b}x{+c}x",
               %{handler: template_handler(self())}
             )

    uri = "urn:" <> String.duplicate("x", 4_091) <> "y"

    assert byte_size(uri) == 4_096
    assert {1, %{"error" => %{"code" => code}}} = read(server, 1, uri)
    assert code in [-32602, -32002]
    refute_receive {:template_params, _}, 20
  end

  test "repeated delimiters stay bounded at the URI input limit" do
    {:ok, server} = Server.start_link([])

    assert :ok =
             Server.register_resource_template(
               server,
               "urn:hostile/{+first}/a/{+second}/a/{id}",
               %{handler: template_handler(self())}
             )

    repeated = String.duplicate("a/", 1_900) <> "a/y/z"
    uri = "urn:hostile/" <> repeated

    assert byte_size(uri) < 4_096
    assert {1, %{"error" => %{"code" => code}}} = read(server, 1, uri)
    assert code in [-32602, -32002]
    refute_receive {:template_params, _}, 20
  end

  test "URI template registration enforces expression and captured-value bounds" do
    {:ok, server} = Server.start_link([])

    sixteen = Enum.map_join(1..16, "", fn index -> "/{v#{index}}" end)
    seventeen = sixteen <> "/{v17}"

    assert :ok = Server.register_resource_template(server, "urn:bounded" <> sixteen, %{})

    assert {:error, {:invalid_definition, :uri_template}} =
             Server.register_resource_template(server, "urn:bounded" <> seventeen, %{})

    expression_128 = String.duplicate("a", 128)
    expression_129 = String.duplicate("a", 129)

    assert :ok =
             Server.register_resource_template(
               server,
               "urn:expression/{" <> expression_128 <> "}",
               %{}
             )

    assert {:error, {:invalid_definition, :uri_template}} =
             Server.register_resource_template(
               server,
               "urn:expression/{" <> expression_129 <> "}",
               %{}
             )

    assert :ok =
             Server.register_resource_template(
               server,
               "urn:capture/{id}",
               %{handler: template_handler(self())}
             )

    value = String.duplicate("a", 2_048)

    assert {1, %{"result" => _}} = read(server, 1, "urn:capture/" <> value)
    assert_receive {:template_params, %{"id" => ^value}}

    assert {2, %{"error" => %{"code" => code}}} =
             read(server, 2, "urn:capture/" <> value <> "a")

    assert code in [-32602, -32002]
  end

  test "multi-expression paths decode values and reject encoded separators or traversal" do
    {:ok, server} = Server.start_link([])

    assert :ok =
             Server.register_resource_template(
               server,
               "urn:records/{record_id}/versions/{version_id}/snapshot",
               %{handler: template_handler(self())}
             )

    assert {1, %{"result" => _}} =
             read(server, 1, "urn:records/r%207/versions/v%2D2/snapshot")

    assert_receive {:template_params, %{"record_id" => "r 7", "version_id" => "v-2"}}

    for {id, uri} <- [
          {2, "urn:records/r%2F7/versions/v2/snapshot"},
          {3, "urn:records/r%2E%2E%2Fsecret/versions/v2/snapshot"},
          {4, "urn:records/r7/versions/v2/snapshot/extra"}
        ] do
      assert {^id, %{"error" => %{"code" => code}}} = read(server, id, uri)

      assert code in [-32602, -32002]
    end

    refute_receive {:template_params, _}, 20
  end

  test "multi-expression prefix captures count decoded percent-encoded characters" do
    {:ok, server} = Server.start_link([])

    assert :ok =
             Server.register_resource_template(server, "urn:{a:1}/{b}", %{
               handler: template_handler(self())
             })

    assert {1, %{"result" => _}} = read(server, 1, "urn:%41/x")
    assert_receive {:template_params, %{"a" => "A", "b" => "x"}}

    assert {2, %{"result" => _}} = read(server, 2, "urn:%C3%A9/x")
    assert_receive {:template_params, %{"a" => "é", "b" => "x"}}

    combining = "urn:e%CC%81%CC%81/x"
    assert {3, %{"result" => _}} = read(server, 3, combining)
    assert_receive {:template_params, %{"a" => "é́", "b" => "x"}}

    fully_encoded = "urn:%65%CC%81%CC%81/x"
    assert {4, %{"result" => _}} = read(server, 4, fully_encoded)
    assert_receive {:template_params, %{"a" => "é́", "b" => "x"}}
  end

  test "percent-heavy near-miss matching remains bounded at the URI input limit" do
    {:ok, server} = Server.start_link([])

    assert :ok =
             Server.register_resource_template(
               server,
               "urn:hostile/{+first:1}/a/{+second:1}/a/{id:1}",
               %{handler: template_handler(self())}
             )

    repeated = String.duplicate("%61/a/", 680) <> "y"
    uri = "urn:hostile/" <> repeated

    assert byte_size(uri) < 4_096
    assert {5, %{"error" => %{"code" => code}}} = read(server, 5, uri)
    assert code in [-32602, -32002]
    refute_receive {:template_params, _}, 20
  end

  test "one encoded prefix does not disable pruning for later expressions" do
    {:ok, server} = Server.start_link([])

    template =
      "urn:" <>
        Enum.map_join(1..14, "", &"{v#{&1}:1}x") <>
        "{+a}x{+b}x"

    assert :ok =
             Server.register_resource_template(server, template, %{
               handler: template_handler(self())
             })

    uri =
      "urn:%78x" <>
        String.duplicate("xx", 13) <>
        String.duplicate("x", 2_048) <>
        "x" <>
        String.duplicate("x", 2_012) <>
        "x"

    assert byte_size(uri) == 4_096
    assert {6, %{"result" => _}} = read(server, 6, uri)

    assert_receive {:template_params, params}
    assert params["v1"] == "x"
    assert params["v14"] == "x"
    assert params["a"] == String.duplicate("x", 2_048)
    assert params["b"] == String.duplicate("x", 2_012)
  end

  test "one raw Unicode prefix does not disable pruning for later expressions" do
    {:ok, server} = Server.start_link([])

    template =
      "urn:" <>
        Enum.map_join(1..14, "", &"{v#{&1}:1}x") <>
        "{+a}x{+b}x"

    assert :ok =
             Server.register_resource_template(server, template, %{
               handler: template_handler(self())
             })

    uri =
      "urn:éx" <>
        String.duplicate("xx", 13) <>
        String.duplicate("x", 2_048) <>
        "x" <>
        String.duplicate("x", 2_013) <>
        "x"

    assert byte_size(uri) == 4_096
    assert {7, %{"result" => _}} = read(server, 7, uri)

    assert_receive {:template_params, params}
    assert params["v1"] == "é"
    assert params["v14"] == "x"
    assert params["a"] == String.duplicate("x", 2_048)
    assert params["b"] == String.duplicate("x", 2_013)
  end

  test "encoded grapheme delimiters remain complete within the candidate budget" do
    {:ok, server} = Server.start_link([])
    delimiter = "%CC%81"

    template =
      "urn:" <>
        Enum.map_join(1..16, "", fn index ->
          "{v#{index}:1}" <> delimiter
        end)

    assert :ok =
             Server.register_resource_template(server, template, %{
               handler: template_handler(self())
             })

    value = "%65" <> String.duplicate(delimiter, 10)
    uri = "urn:" <> String.duplicate(value <> delimiter, 16)

    assert byte_size(uri) == 1_108
    assert {8, %{"result" => _}} = read(server, 8, uri)

    assert_receive {:template_params, params}
    expected = "e" <> String.duplicate("́", 10)
    assert map_size(params) == 16
    assert params["v1"] == expected
    assert params["v16"] == expected
    assert Enum.all?(Map.values(params), &(String.length(&1) == 1))
  end

  test "atomic registration and catalog replacement retain multi-expression dispatch" do
    {:ok, server} = Server.start_link([])

    first = "urn:records/{record_id}/versions/{version_id}"

    assert :ok =
             Server.register_all(server, [
               {:template, first, %{handler: template_handler(self())}}
             ])

    assert {1, %{"result" => _}} = read(server, 1, "urn:records/r1/versions/v1")
    assert_receive {:template_params, %{"record_id" => "r1", "version_id" => "v1"}}

    second = "urn:records/{record_id}/versions/{version_id}/blobs/{blob_id}"

    assert :ok =
             Server.replace_catalog(server, [
               {:template, second, %{handler: template_handler(self())}}
             ])

    assert {2, %{"error" => %{"code" => code}}} =
             read(server, 2, "urn:records/r1/versions/v1")

    assert code in [-32602, -32002]

    assert {3, %{"result" => _}} =
             read(server, 3, "urn:records/r1/versions/v1/blobs/b1")

    assert_receive {:template_params,
                    %{"record_id" => "r1", "version_id" => "v1", "blob_id" => "b1"}}
  end

  test "startup registrations retain multi-expression resource dispatch" do
    {:ok, server} =
      Server.start_link(
        registrations: [
          {:template, "urn:startup/{record_id}/versions/{version_id}",
           %{handler: template_handler(self())}}
        ]
      )

    assert {1, %{"result" => _}} =
             read(server, 1, "urn:startup/r1/versions/v1")

    assert_receive {:template_params, %{"record_id" => "r1", "version_id" => "v1"}}
  end

  test "resource notification scope resolution matches multi-expression templates" do
    {:ok, server} = Server.start_link([])

    assert :ok =
             Server.register_resource_template(
               server,
               "urn:notifications/{record_id}/versions/{version_id}",
               %{required_scopes: ["records.read"]}
             )

    assert [AttestoMCP.Scopes.resources_read(), "records.read"] ==
             GenServer.call(
               server,
               {:notification_scopes,
                %{
                  "type" => "resourceUpdated",
                  "uri" => "urn:notifications/r1/versions/v1"
                }}
             )

    assert [AttestoMCP.Scopes.resources_read()] ==
             GenServer.call(
               server,
               {:notification_scopes,
                %{
                  "type" => "resourceUpdated",
                  "uri" => "urn:notifications/r1/versions/v1/extra"
                }}
             )
  end

  test "aggregate template work exhaustion is explicit and never becomes unscoped" do
    {:ok, server} = Server.start_link([])
    uri = aggregate_budget_uri()

    assert :ok =
             Server.register_all(
               server,
               aggregate_budget_templates(3) ++ [aggregate_budget_target(self())]
             )

    assert {1,
            %{
              "error" => %{
                "code" => -32603,
                "data" => %{
                  "reason" => "uri_template_match_budget_exhausted",
                  "type" => "resource_match_limit"
                }
              }
            }} =
             Server.dispatch(
               server,
               %{kind: :request, id: 1, method: "resources/read", params: %{"uri" => uri}},
               %{principal: "aggregate-budget", scopes: ["target.read"]},
               version: @legacy
             )

    notification = %{"type" => "resourceUpdated", "uri" => uri}

    assert {:error, :template_match_budget_exhausted} =
             GenServer.call(server, {:notification_scopes, notification})

    assert {:error, :template_match_budget_exhausted} = Server.publish(server, notification)
    refute_receive :aggregate_budget_target_called
  end

  test "one local publish reuses one successful template scope resolution" do
    {:ok, server} = Server.start_link([])
    uri = aggregate_budget_uri()

    assert :ok =
             Server.register_all(
               server,
               aggregate_budget_templates(2) ++ [aggregate_budget_target(self())]
             )

    event = [:attesto_mcp_server, :uri_template, :scope_resolution]
    handler_id = {:uri_template_scope_resolution, make_ref()}

    assert :ok =
             :telemetry.attach(
               handler_id,
               event,
               &__MODULE__.uri_template_telemetry/4,
               self()
             )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok = Server.publish(server, %{"type" => "resourceUpdated", "uri" => uri})

    assert_receive {:uri_template_telemetry, ^event, %{count: 1},
                    %{source: :resource_notification}}

    refute_receive {:uri_template_telemetry, ^event, _, _}, 20

    assert [AttestoMCP.Scopes.resources_read(), "target.read"] ==
             GenServer.call(
               server,
               {:notification_scopes, %{"type" => "resourceUpdated", "uri" => uri}}
             )
  end

  test "the total catalog is capped across registrations and exact resources bypass template work" do
    {:ok, server} = Server.start_link([])
    uri = "urn:exact/" <> String.duplicate("%61/", 60) <> "item"
    assert byte_size(uri) == 254

    templates =
      Enum.map(1..999, fn index ->
        {:template, "urn:exact/{+a_first_#{index}:1}/{a_id_#{index}:1}", %{}}
      end)

    assert :ok = Server.register_all(server, templates)

    assert :ok =
             Server.register_resource(server, "exact-budget-bypass", %{
               uri: uri,
               required_scopes: ["exact.read"],
               handler: template_handler(self())
             })

    assert {:error, :too_many_registrations} =
             Server.register_resource_template(server, "urn:overflow/{a}/tail/{b}", %{})

    assert 1_000 ==
             server
             |> Server.snapshot()
             |> Map.values()
             |> Enum.reduce(0, fn definitions, count -> count + map_size(definitions) end)

    assert {1, %{"result" => _}} =
             Server.dispatch(
               server,
               %{kind: :request, id: 1, method: "resources/read", params: %{"uri" => uri}},
               %{principal: "exact-budget", scopes: ["exact.read"]},
               version: @legacy
             )

    assert_receive {:template_params, %{}}

    assert [AttestoMCP.Scopes.resources_read(), "exact.read"] ==
             GenServer.call(
               server,
               {:notification_scopes, %{"type" => "resourceUpdated", "uri" => uri}}
             )
  end

  test "unrelated template boundaries preserve the work budget for a late valid candidate" do
    {:ok, server} = Server.start_link([])

    unrelated =
      Enum.map(1..999, fn index ->
        {:template, "urn:a#{String.pad_leading(Integer.to_string(index), 4, "0")}/{x}/tail/{y}",
         %{}}
      end)

    target = "urn:z/{+first}/tail/{+second}"

    assert :ok =
             Server.register_all(
               server,
               unrelated ++ [{:template, target, %{handler: template_handler(self())}}]
             )

    uri =
      "urn:z/" <>
        String.duplicate("a", 2_048) <>
        "/tail/" <>
        String.duplicate("b", 2_036)

    assert byte_size(uri) == 4_096
    assert {1, %{"result" => _}} = read(server, 1, uri)

    assert_receive {:template_params,
                    %{
                      "first" => first,
                      "second" => second
                    }}

    assert byte_size(first) == 2_048
    assert byte_size(second) == 2_036
  end

  test "multi-expression paths reject duplicate names and adjacent expressions" do
    {:ok, server} = Server.start_link([])

    for template <- [
          "urn:records/{id}/versions/{id}",
          "urn:records/{first}{second}"
        ] do
      assert {:error, {:invalid_definition, :uri_template}} =
               Server.register_resource_template(server, template, %{})
    end
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
          "https://example.test/items{?q}/suffix",
          "https://example.test/items{?q,,limit}"
        ] do
      assert {:error, {:invalid_definition, :uri_template}} =
               Server.register_resource_template(server, template, %{})
    end
  end
end
