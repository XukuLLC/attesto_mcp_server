defmodule AttestoMCP.Server.SchemaTest do
  use ExUnit.Case, async: true

  alias AttestoMCP.Server.Schema

  test "validates bounded 2020-12 object and array keywords" do
    schema = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "type" => "object",
      "required" => ["name", "tags"],
      "properties" => %{
        "name" => %{"type" => "string", "minLength" => 2},
        "tags" => %{"type" => "array", "minItems" => 1, "items" => %{"type" => "string"}}
      },
      "additionalProperties" => false
    }

    assert :ok = Schema.validate(%{"name" => "mcp", "tags" => ["one"]}, schema)
    assert {:error, _} = Schema.validate(%{"name" => "x", "tags" => ["one"]}, schema)

    assert {:error, _} =
             Schema.validate(%{"name" => "mcp", "tags" => [], "extra" => true}, schema)
  end

  test "resolves local refs and rejects remote refs" do
    schema = %{
      "$defs" => %{"id" => %{"type" => "integer", "minimum" => 1}},
      "type" => "object",
      "properties" => %{"id" => %{"$ref" => "#/$defs/id"}}
    }

    assert :ok = Schema.validate(%{"id" => 3}, schema)
    assert {:error, _} = Schema.validate(%{"id" => 0}, schema)

    assert {:error, :remote_ref_disabled} =
             Schema.validate(%{"id" => 1}, %{"$ref" => "https://example.invalid/schema.json"})
  end

  test "supports combinators without fetching references" do
    schema = %{
      "oneOf" => [%{"type" => "string"}, %{"type" => "integer"}],
      "not" => %{"const" => "forbidden"}
    }

    assert :ok = Schema.validate("value", schema)
    assert :ok = Schema.validate(5, schema)
    assert {:error, _} = Schema.validate(true, schema)
    assert {:error, _} = Schema.validate("forbidden", schema)
  end

  test "uses JSON numeric and recursive equality for enum and uniqueItems" do
    assert :ok = Schema.validate(1.0, %{"enum" => [1]})

    assert :ok =
             Schema.validate(%{"items" => [%{"value" => 1}]}, %{
               "enum" => [%{"items" => [%{"value" => 1.0}]}]
             })

    assert {:error, :unique_items} =
             Schema.validate([1, 1.0], %{"type" => "array", "uniqueItems" => true})

    assert {:error, :unique_items} =
             Schema.validate(
               [%{"value" => [1]}, %{"value" => [1.0]}],
               %{"type" => "array", "uniqueItems" => true}
             )

    assert :ok = Schema.validate([], %{"type" => "array", "unevaluatedItems" => false})
  end

  test "rejects malformed URI references and hostnames while accepting valid edges" do
    assert {:error, :format} =
             Schema.validate("[%", %{"type" => "string", "format" => "uri-reference"},
               formats: true
             )

    assert {:error, :format} =
             Schema.validate("http://[", %{"type" => "string", "format" => "uri"}, formats: true)

    assert {:error, :format} =
             Schema.validate("foo%ZZbar", %{"type" => "string", "format" => "uri-reference"},
               formats: true
             )

    for value <- [
          "../relative",
          "urn:isbn:0451450523",
          "http://[::1]/resource",
          "//user@[::1]:443/resource",
          "foo%20bar"
        ] do
      assert :ok =
               Schema.validate(value, %{"type" => "string", "format" => "uri-reference"},
                 formats: true
               )
    end

    assert :ok = Schema.validate("http://[::1]/resource", %{"format" => "uri"}, formats: true)

    assert {:error, :format} =
             Schema.validate("path?[::1]", %{"format" => "uri-reference"}, formats: true)

    assert {:error, :format} =
             Schema.validate("http://[not-ip]/", %{"format" => "uri"}, formats: true)

    assert :ok = Schema.validate("example.com", %{"format" => "hostname"}, formats: true)
    assert :ok = Schema.validate("example.com.", %{"format" => "hostname"}, formats: true)
    assert {:error, :format} = Schema.validate(".bad", %{"format" => "hostname"}, formats: true)

    assert {:error, :format} =
             Schema.validate("bad..host", %{"format" => "hostname"}, formats: true)
  end

  test "requires a duration component" do
    schema = %{"type" => "string", "format" => "duration"}

    for value <- ["P", "PT", "P1DT", "PT0.5S"] do
      assert {:error, :format} = Schema.validate(value, schema, formats: true)
    end

    for value <- ["P0D", "PT0S", "P1Y", "P1DT2H"] do
      assert :ok = Schema.validate(value, schema, formats: true)
    end
  end

  test "local pointer array indexes follow JSON Pointer rules" do
    schema = %{
      "x" => [%{"const" => "first"}, %{"const" => "second"}],
      "prefixItems" => [%{"$ref" => "#/x/0"}, %{"$ref" => "#/x/1"}]
    }

    assert :ok = Schema.validate(["first", "second"], schema)

    assert {:error, :unresolved_ref} =
             Schema.validate(["first", "second"], %{"$ref" => "#/x/01", "x" => schema["x"]})
  end

  test "URN resources resolve absolute references and fragments on supported runtimes" do
    urn = "urn:uuid:deadbeef-1234-ffff-ffff-4321feebdaed"
    schema = %{"$id" => urn, "minimum" => 30, "properties" => %{"foo" => %{"$ref" => urn}}}

    assert :ok = Schema.validate_schema(schema)
    assert :ok = Schema.validate(%{"foo" => 37}, schema)
    assert {:error, :minimum} = Schema.validate(%{"foo" => 12}, schema)

    pointer = %{
      "$id" => urn,
      "$defs" => %{"choices" => %{"anyOf" => [false, true]}},
      "$ref" => "#/$defs/choices/anyOf/1"
    }

    assert :ok = Schema.validate(1, pointer)

    assert {:error, :unresolved_ref} =
             Schema.validate_schema(%{pointer | "$ref" => "#/$defs/choices/anyOf/01"})

    nested_urn = "urn:uuid:deadbeef-1234-ffff-ffff-4321feebdaee"

    anchored = %{
      "$id" => urn,
      "$ref" => nested_urn <> "#value",
      "$defs" => %{
        "nested" => %{
          "$id" => nested_urn,
          "$defs" => %{"value" => %{"$anchor" => "value", "type" => "integer"}}
        }
      }
    }

    assert :ok = Schema.validate(1, anchored)
    assert {:error, {:type, "integer"}} = Schema.validate("one", anchored)

    assert {:error, :unresolved_ref} =
             Schema.validate_schema(%{anchored | "$ref" => nested_urn <> "#missing"})
  end

  test "nested pointers use the enclosing resource and reject leading-zero array indexes" do
    schema = %{
      "$defs" => %{"choice" => %{"anyOf" => [false, true]}},
      "properties" => %{"x" => %{"$ref" => "#/$defs/choice/anyOf/01"}}
    }

    assert {:error, :unresolved_ref} = Schema.validate(%{"x" => 1}, schema)

    # The numeric-looking token is a map key in the resource, even though an
    # annotation with the same name is an array beside the nested reference.
    assert :ok =
             Schema.validate(%{"a" => 1}, %{
               "x" => %{"01" => true},
               "properties" => %{"a" => %{"x" => [false, true], "$ref" => "#/x/01"}}
             })

    for index <- ["1", "01"] do
      embedded = %{
        "$id" => "https://example.invalid/embedded",
        "allOf" => [%{"$ref" => "#/choices/" <> index}],
        "choices" => [false, true]
      }

      root = %{"$defs" => %{"embedded" => embedded}, "$ref" => "#/$defs/embedded"}

      if index == "1",
        do: assert(:ok = Schema.validate(1, root)),
        else: assert({:error, :unresolved_ref} = Schema.validate(1, root))
    end

    for reference <- [
          "nested#/$defs/choice/anyOf/01",
          "https://example.invalid/nested#/$defs/choice/anyOf/01"
        ] do
      assert {:error, :unresolved_ref} =
               Schema.validate(1, %{
                 "$id" => "https://example.invalid/root",
                 "$ref" => reference,
                 "$defs" => %{
                   "nested" => %{
                     "$id" => "nested",
                     "$defs" => %{"choice" => %{"anyOf" => [false, true]}}
                   }
                 }
               })
    end
  end

  test "draft-07 does not activate later keywords or anchor annotations" do
    dialect = %{"$schema" => "http://json-schema.org/draft-07/schema#"}
    assert :ok = Schema.validate([1], Map.put(dialect, "prefixItems", [false]))

    assert :ok =
             Schema.validate(%{"a" => 1}, Map.put(dialect, "dependentRequired", %{"a" => ["b"]}))

    assert :ok =
             Schema.validate(%{"a" => 1}, Map.put(dialect, "dependentSchemas", %{"a" => false}))

    assert :ok =
             Schema.validate([1], Map.merge(dialect, %{"contains" => true, "minContains" => 2}))

    assert {:error, :contains} =
             Schema.validate([], Map.merge(dialect, %{"contains" => true, "minContains" => 0}))

    assert :ok =
             Schema.validate_schema(
               Map.put(dialect, "$defs", %{
                 "one" => %{"$anchor" => "same"},
                 "two" => %{"$anchor" => "same"}
               })
             )

    assert {:error, :unresolved_ref} =
             Schema.validate(
               1,
               Map.merge(dialect, %{
                 "$ref" => "#ignored",
                 "annotation" => %{"$anchor" => "ignored", "type" => "integer"}
               })
             )

    assert :ok =
             Schema.validate(
               1,
               Map.merge(dialect, %{
                 "$ref" => "#value",
                 "definitions" => %{"value" => %{"$id" => "#value", "type" => "integer"}}
               })
             )
  end

  test "bounded defaults retain the caller's format-assertion policy" do
    schema = %{"properties" => %{"date" => %{"format" => "date", "default" => "bad"}}}
    assert {:ok, %{"date" => "bad"}} = Schema.apply_property_defaults(%{}, schema, formats: false)
    assert {:error, :format} = Schema.apply_property_defaults(%{}, schema)
    assert {:error, :format} = Schema.apply_property_defaults(%{}, schema, formats: true)
  end

  test "default annotation data is preserved without introducing schema identifiers" do
    default = %{"$id" => 4, "$anchor" => 4, "$dynamicAnchor" => false, "value" => 1}
    schema = %{"properties" => %{"payload" => %{"default" => default, "const" => default}}}
    assert :ok = Schema.validate_schema(schema)
    assert {:ok, %{"payload" => ^default}} = Schema.apply_property_defaults(%{}, schema)

    # A default can also be explicitly referenced as a schema. Its original
    # location must stay addressable in the private compilation copy.
    assert :ok = Schema.validate(1, %{"default" => %{"type" => "integer"}, "$ref" => "#/default"})

    assert {:error, {:type, "integer"}} =
             Schema.validate("1", %{"default" => %{"type" => "integer"}, "$ref" => "#/default"})

    assert {:error, {:invalid_keyword, "title"}} = Schema.validate_schema(%{"title" => 4})
  end

  test "existing public validation failure reasons remain stable" do
    for {value, schema, reason} <- [
          {2, %{"enum" => [1]}, :not_in_enum},
          {2, %{"maximum" => 1}, :maximum},
          {0, %{"minimum" => 1}, :minimum},
          {1, %{"exclusiveMinimum" => 1}, :exclusive_minimum},
          {1, %{"exclusiveMaximum" => 1}, :exclusive_maximum},
          {3, %{"multipleOf" => 2}, :multiple_of},
          {"a", %{"minLength" => 2}, :min_length},
          {"abc", %{"maxLength" => 2}, :max_length},
          {"1", %{"pattern" => "^[a-z]+$"}, :pattern_mismatch},
          {[], %{"minItems" => 1}, :min_items},
          {[1, 2], %{"maxItems" => 1}, :max_items},
          {%{}, %{"minProperties" => 1}, :min_properties},
          {%{"a" => 1}, %{"maxProperties" => 0}, :max_properties},
          {1, %{"anyOf" => [false, false]}, {:any, :mismatch}},
          {1, %{"oneOf" => [true, true]}, {:one, :mismatch}},
          {1, %{"not" => true}, :not_allowed},
          {[1], %{"contains" => false}, :contains},
          {[1], %{"items" => false}, :schema_false},
          {[1, 2],
           %{
             "$schema" => "http://json-schema.org/draft-07/schema#",
             "items" => [true],
             "additionalItems" => false
           }, :additional_items},
          {%{"extra" => true}, %{"anyOf" => [%{"additionalProperties" => false}]},
           {:any, :mismatch}},
          {%{"b" => 2, "c" => 3}, %{"additionalProperties" => false},
           {:additional_properties, ["b", "c"]}},
          {%{"b" => 2}, %{"unevaluatedProperties" => false}, {:unevaluated_properties, ["b"]}}
        ] do
      assert {:error, ^reason} = Schema.validate(value, schema)
    end
  end

  test "applies dialect rules and evaluated annotations only from successful applicators" do
    assert {:error, {:invalid_keyword, "uniqueItems"}} =
             Schema.validate_schema(%{"uniqueItems" => "yes"})

    tuple_schema = %{"items" => [%{"type" => "string"}]}

    assert {:error, {:invalid_keyword, "items"}} = Schema.validate_schema(tuple_schema)

    assert :ok =
             Schema.validate_schema(%{
               "$schema" => "http://json-schema.org/draft-07/schema#",
               "items" => [%{"type" => "string"}]
             })

    assert {:error, {:invalid_keyword, "exclusiveMinimum"}} =
             Schema.validate_schema(%{"exclusiveMinimum" => true})

    assert {:error, {:invalid_keyword, "exclusiveMaximum"}} =
             Schema.validate_schema(%{"exclusiveMaximum" => false})

    assert :ok = Schema.validate(%{"" => 1}, %{"required" => [""]})

    assert :ok =
             Schema.validate(%{"extra" => "ok"}, %{
               "additionalProperties" => %{"type" => "string"},
               "unevaluatedProperties" => false
             })

    assert {:error, _} =
             Schema.validate(%{"a" => "ok", "b" => "bad"}, %{
               "anyOf" => [
                 %{"properties" => %{"a" => %{"type" => "string"}}},
                 %{"properties" => %{"b" => %{"type" => "integer"}}}
               ],
               "unevaluatedProperties" => false
             })

    assert :ok =
             Schema.validate(%{"kind" => "a", "x" => 1}, %{
               "if" => %{"properties" => %{"kind" => %{"const" => "a"}}},
               "then" => %{"properties" => %{"x" => %{"type" => "integer"}}},
               "unevaluatedProperties" => false
             })

    assert :ok =
             Schema.validate(%{"x" => 1}, %{
               "$defs" => %{"props" => %{"properties" => %{"x" => %{"type" => "integer"}}}},
               "$ref" => "#/$defs/props",
               "unevaluatedProperties" => false
             })

    assert :ok =
             Schema.validate(%{"trigger" => true, "dependent" => 1}, %{
               "properties" => %{"trigger" => %{"type" => "boolean"}},
               "dependentSchemas" => %{
                 "trigger" => %{"properties" => %{"dependent" => %{"type" => "integer"}}}
               },
               "unevaluatedProperties" => false
             })

    assert :ok =
             Schema.validate(["head", 2], %{
               "prefixItems" => [%{"type" => "string"}],
               "items" => %{"type" => "integer"},
               "unevaluatedItems" => false
             })

    assert :ok =
             Schema.validate([1], %{
               "$defs" => %{"tuple" => %{"prefixItems" => [%{"type" => "integer"}]}},
               "$ref" => "#/$defs/tuple",
               "unevaluatedItems" => false
             })

    assert :ok =
             Schema.validate([1], %{
               "$defs" => %{"tuple" => %{"prefixItems" => [%{"type" => "integer"}]}},
               "allOf" => [%{"$ref" => "#/$defs/tuple"}],
               "unevaluatedItems" => false
             })

    assert {:error, :unevaluated_items} =
             Schema.validate([1, 2], %{
               "$defs" => %{"tuple" => %{"prefixItems" => [%{"type" => "integer"}]}},
               "allOf" => [%{"$ref" => "#/$defs/tuple"}],
               "unevaluatedItems" => false
             })

    assert :ok =
             Schema.validate(%{"x" => 1}, %{
               "$defs" => %{"props" => %{"properties" => %{"x" => %{"type" => "integer"}}}},
               "allOf" => [%{"$ref" => "#/$defs/props"}],
               "unevaluatedProperties" => false
             })

    assert {:error, _} =
             Schema.validate(["head", 2], %{
               "prefixItems" => [%{"type" => "string"}],
               "unevaluatedItems" => false
             })

    assert {:error, :unresolved_ref} =
             Schema.validate(1, %{"$ref" => "#/x/1x", "x" => [%{"type" => "integer"}]})

    assert :ok =
             Schema.validate_schema(%{
               "$defs" => %{
                 "first" => %{"$anchor" => "first", "type" => "string"},
                 "second" => %{"$anchor" => "second", "type" => "integer"}
               },
               "$ref" => "#second"
             })

    assert {:error, :duplicate_anchor} =
             Schema.validate_schema(%{
               "$defs" => %{
                 "one" => %{"$anchor" => "same"},
                 "two" => %{"$anchor" => "same"}
               }
             })
  end
end
