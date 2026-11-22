defmodule OzMcp.Structs.ElicitationSchemaTest do
  use ExUnit.Case, async: true

  alias OzMcp.Structs.{
    BooleanSchema,
    ElicitationSchema,
    EnumSchema,
    MultiSelectEnumSchema,
    NumberSchema,
    StringSchema
  }

  test "builds an object schema from every kind of property" do
    result =
      %ElicitationSchema{}
      |> ElicitationSchema.property("name", %StringSchema{})
      |> ElicitationSchema.property("age", %NumberSchema{} |> NumberSchema.type(:integer))
      |> ElicitationSchema.property("ok", %BooleanSchema{})
      |> ElicitationSchema.property("level", %EnumSchema{} |> EnumSchema.options(["a"]))
      |> ElicitationSchema.property(
        "tags",
        %MultiSelectEnumSchema{} |> MultiSelectEnumSchema.options(["x"])
      )
      |> ElicitationSchema.property("raw", %{type: "string", pattern: "^a"})
      |> ElicitationSchema.required(["name", "age"])
      |> ElicitationSchema.build()

    assert result == %{
             type: "object",
             properties: %{
               "name" => %{type: "string"},
               "age" => %{type: "integer"},
               "ok" => %{type: "boolean"},
               "level" => %{type: "string", enum: ["a"]},
               "tags" => %{type: "array", items: %{type: "string", enum: ["x"]}},
               "raw" => %{type: "string", pattern: "^a"}
             },
             required: ["name", "age"]
           }
  end

  test "properties/2 replaces the properties; no required key when none" do
    result =
      %ElicitationSchema{}
      |> ElicitationSchema.properties(%{"a" => %BooleanSchema{}})
      |> ElicitationSchema.required([])
      |> ElicitationSchema.build()

    assert result == %{type: "object", properties: %{"a" => %{type: "boolean"}}}
  end

  test "requires at least one property" do
    assert_raise ArgumentError, ~r/non-empty map/, fn ->
      ElicitationSchema.build(%ElicitationSchema{})
    end
  end

  test "rejects a property name that is not a string" do
    assert_raise ArgumentError, ~r/property names/, fn ->
      %ElicitationSchema{}
      |> ElicitationSchema.properties(%{a: %BooleanSchema{}})
      |> ElicitationSchema.build()
    end
  end

  test "rejects a required name that is not a property" do
    assert_raise ArgumentError, ~r/required property/, fn ->
      %ElicitationSchema{}
      |> ElicitationSchema.property("a", %BooleanSchema{})
      |> ElicitationSchema.required(["b"])
      |> ElicitationSchema.build()
    end
  end

  test "rejects a property that is not a schema" do
    assert_raise ArgumentError, ~r/a property must be/, fn ->
      %ElicitationSchema{}
      |> ElicitationSchema.property("a", "string")
      |> ElicitationSchema.build()
    end
  end

  test "an invalid property fails the build" do
    assert_raise ArgumentError, fn ->
      %ElicitationSchema{}
      |> ElicitationSchema.property("a", %EnumSchema{})
      |> ElicitationSchema.build()
    end
  end

  describe "a property given as a map is flat" do
    defp build_with(schema) do
      %ElicitationSchema{}
      |> ElicitationSchema.property("a", schema)
      |> ElicitationSchema.build()
    end

    test "accepts primitives, with atom or string keys and a multi-select" do
      for schema <- [
            %{type: "string"},
            %{"type" => "number"},
            %{type: "integer"},
            %{type: "boolean"},
            %{type: "array", items: %{type: "string", enum: ["a"]}},
            %{"type" => "array", "items" => %{"anyOf" => [%{"const" => "a", "title" => "A"}]}}
          ] do
        assert %{properties: %{"a" => ^schema}} = build_with(schema)
      end
    end

    test "rejects a nested object" do
      for schema <- [
            %{type: "object", properties: %{"b" => %{type: "string"}}},
            %{"type" => "object"}
          ] do
        assert_raise ArgumentError, ~r/primitive schema/, fn -> build_with(schema) end
      end
    end

    test "rejects a map without a type" do
      assert_raise ArgumentError, ~r/got type: nil/, fn -> build_with(%{enum: ["a"]}) end
    end

    test "rejects an array of objects or of arrays" do
      for items <- [
            %{type: "object", properties: %{}},
            %{type: "array", items: %{type: "string"}},
            %{properties: %{"b" => %{type: "string"}}}
          ] do
        assert_raise ArgumentError, ~r/string items/, fn ->
          build_with(%{type: "array", items: items})
        end
      end

      assert_raise ArgumentError, ~r/string items/, fn -> build_with(%{type: "array"}) end
    end
  end
end
