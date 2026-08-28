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
             Schema.validate("[%", %{"type" => "string", "format" => "uri-reference"})

    assert {:error, :format} =
             Schema.validate("http://[", %{"type" => "string", "format" => "uri"})

    assert {:error, :format} =
             Schema.validate("foo%ZZbar", %{"type" => "string", "format" => "uri-reference"})

    for value <- [
          "../relative",
          "urn:isbn:0451450523",
          "http://[::1]/resource",
          "//user@[::1]:443/resource",
          "foo%20bar"
        ] do
      assert :ok = Schema.validate(value, %{"type" => "string", "format" => "uri-reference"})
    end

    assert :ok = Schema.validate("http://[::1]/resource", %{"format" => "uri"})
    assert {:error, :format} = Schema.validate("path?[::1]", %{"format" => "uri-reference"})
    assert {:error, :format} = Schema.validate("http://[not-ip]/", %{"format" => "uri"})
    assert :ok = Schema.validate("example.com", %{"format" => "hostname"})
    assert :ok = Schema.validate("example.com.", %{"format" => "hostname"})
    assert {:error, :format} = Schema.validate(".bad", %{"format" => "hostname"})
    assert {:error, :format} = Schema.validate("bad..host", %{"format" => "hostname"})
  end

  test "requires a duration component" do
    schema = %{"type" => "string", "format" => "duration"}

    for value <- ["P", "PT", "P1DT"] do
      assert {:error, :format} = Schema.validate(value, schema)
    end

    for value <- ["P0D", "PT0S", "P1Y", "P1DT2H", "PT0.5S"] do
      assert :ok = Schema.validate(value, schema)
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
