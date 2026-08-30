defmodule AttestoMCP.Server.SchemaDefaultsTest do
  use ExUnit.Case, async: true

  alias AttestoMCP.Server.Schema

  test "validation does not materialize JSON Schema defaults" do
    schema = %{
      "type" => "object",
      "properties" => %{"name" => %{"type" => "string", "default" => "Ada"}},
      "required" => ["name"]
    }

    assert {:error, {:required, ["name"]}} = Schema.validate(%{}, schema)
    assert {:ok, %{"name" => "Ada"}} = Schema.apply_property_defaults(%{}, schema)
  end

  test "direct and nested defaults are applied without changing the input" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "mode" => %{"type" => "string", "default" => "safe"},
        "existing" => %{
          "type" => "object",
          "properties" => %{"limit" => %{"type" => "integer", "default" => 10}},
          "required" => ["limit"]
        },
        "injected" => %{
          "type" => "object",
          "default" => %{},
          "properties" => %{"enabled" => %{"type" => "boolean", "default" => true}},
          "required" => ["enabled"]
        }
      },
      "required" => ["mode", "existing", "injected"]
    }

    input = %{"existing" => %{}}

    assert {:ok, completed} = Schema.apply_property_defaults(input, schema)

    assert completed == %{
             "mode" => "safe",
             "existing" => %{"limit" => 10},
             "injected" => %{"enabled" => true}
           }

    assert input == %{"existing" => %{}}
  end

  test "present JSON values are never replaced" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "nil" => %{"default" => "replacement"},
        "false" => %{"default" => true},
        "zero" => %{"default" => 1},
        "empty" => %{"default" => "replacement"}
      }
    }

    input = %{"nil" => nil, "false" => false, "zero" => 0, "empty" => ""}
    assert {:ok, ^input} = Schema.apply_property_defaults(input, schema)
  end

  test "an explicit null default is inserted when the property is absent" do
    schema = %{
      "type" => "object",
      "properties" => %{"nullable" => %{"default" => nil}},
      "required" => ["nullable"]
    }

    assert {:ok, %{"nullable" => nil}} = Schema.apply_property_defaults(%{}, schema)
  end

  test "an absent parent is not synthesized without its own default" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "parent" => %{
          "type" => "object",
          "properties" => %{"child" => %{"default" => "value"}}
        }
      }
    }

    assert {:ok, %{}} = Schema.apply_property_defaults(%{}, schema)
  end

  test "defaults behind references and applicators are not inferred" do
    schema = %{
      "$defs" => %{
        "settings" => %{
          "type" => "object",
          "default" => %{"enabled" => true}
        }
      },
      "type" => "object",
      "properties" => %{"settings" => %{"$ref" => "#/$defs/settings"}},
      "allOf" => [
        %{"properties" => %{"fromAllOf" => %{"type" => "string", "default" => "ignored"}}}
      ]
    }

    assert {:ok, %{}} = Schema.apply_property_defaults(%{}, schema)
  end

  test "an inserted default must make a schema-valid completed instance" do
    schema = %{
      "type" => "object",
      "properties" => %{"count" => %{"type" => "integer", "default" => "invalid"}},
      "required" => ["count"]
    }

    assert {:error, {:type, "integer"}} = Schema.apply_property_defaults(%{}, schema)
  end

  test "default insertion retains normal JSON byte bounds" do
    schema = %{
      "type" => "object",
      "properties" => %{"x" => %{"type" => "string", "default" => "123"}}
    }

    input = %{"payload" => String.duplicate("x", 1_999_990)}
    assert {:error, :not_json} = Schema.apply_property_defaults(input, schema)
  end

  test "schema and input validation run before defaults are applied" do
    assert {:error, :invalid_instance} = Schema.apply_property_defaults([], %{})
    assert {:error, :not_json} = Schema.apply_property_defaults(%{atom_key: true}, %{})

    too_many_properties =
      1..501
      |> Map.new(fn index -> {Integer.to_string(index), %{"default" => index}} end)
      |> then(&%{"type" => "object", "properties" => &1})

    assert {:error, :schema_too_complex} =
             Schema.apply_property_defaults(%{}, too_many_properties)
  end

  test "boolean schemas preserve opt-in behavior" do
    assert {:ok, %{"value" => 1}} =
             Schema.apply_property_defaults(%{"value" => 1}, true)

    assert {:error, :schema_false} = Schema.apply_property_defaults(%{}, false)
  end
end
