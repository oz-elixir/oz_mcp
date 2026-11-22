defmodule OzMcp.Structs.MultiSelectEnumSchemaTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.MultiSelectEnumSchema

  test "plain options use items.enum" do
    result =
      %MultiSelectEnumSchema{}
      |> MultiSelectEnumSchema.title("Colors")
      |> MultiSelectEnumSchema.description("Pick some")
      |> MultiSelectEnumSchema.options(["a", "b", "c"])
      |> MultiSelectEnumSchema.min_items(1)
      |> MultiSelectEnumSchema.max_items(2)
      |> MultiSelectEnumSchema.default(["a"])
      |> MultiSelectEnumSchema.build()

    assert result == %{
             type: "array",
             title: "Colors",
             description: "Pick some",
             minItems: 1,
             maxItems: 2,
             items: %{type: "string", enum: ["a", "b", "c"]},
             default: ["a"]
           }
  end

  test "titled options use items.anyOf" do
    result =
      %MultiSelectEnumSchema{}
      |> MultiSelectEnumSchema.options([{"a", "Alpha"}, "b"])
      |> MultiSelectEnumSchema.build()

    assert result == %{
             type: "array",
             items: %{anyOf: [%{const: "a", title: "Alpha"}, %{const: "b", title: "b"}]}
           }
  end

  test "requires options" do
    assert_raise ArgumentError, ~r/non-empty list/, fn ->
      MultiSelectEnumSchema.build(%MultiSelectEnumSchema{})
    end
  end

  test "rejects minItems greater than maxItems" do
    assert_raise ArgumentError, ~r/cannot be greater/, fn ->
      %MultiSelectEnumSchema{}
      |> MultiSelectEnumSchema.options(["a"])
      |> MultiSelectEnumSchema.min_items(3)
      |> MultiSelectEnumSchema.max_items(1)
      |> MultiSelectEnumSchema.build()
    end
  end

  test "the default must contain only options" do
    assert_raise ArgumentError, ~r/'default'/, fn ->
      %MultiSelectEnumSchema{}
      |> MultiSelectEnumSchema.options(["a"])
      |> MultiSelectEnumSchema.default(["a", "z"])
      |> MultiSelectEnumSchema.build()
    end

    assert_raise ArgumentError, ~r/'default'/, fn ->
      %MultiSelectEnumSchema{}
      |> MultiSelectEnumSchema.options(["a"])
      |> MultiSelectEnumSchema.default("a")
      |> MultiSelectEnumSchema.build()
    end
  end
end
