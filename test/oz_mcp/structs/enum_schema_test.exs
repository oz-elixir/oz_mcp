defmodule OzMcp.Structs.EnumSchemaTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.EnumSchema

  test "plain options use enum" do
    result =
      %EnumSchema{}
      |> EnumSchema.title("Level")
      |> EnumSchema.description("Pick one")
      |> EnumSchema.options(["low", "high"])
      |> EnumSchema.default("low")
      |> EnumSchema.build()

    assert result == %{
             type: "string",
             title: "Level",
             description: "Pick one",
             enum: ["low", "high"],
             default: "low"
           }
  end

  test "titled options use oneOf" do
    result =
      %EnumSchema{}
      |> EnumSchema.options([{"r", "Red"}, %{const: "g", title: "Green"}, %{"const" => "b"}])
      |> EnumSchema.build()

    assert result == %{
             type: "string",
             oneOf: [
               %{const: "r", title: "Red"},
               %{const: "g", title: "Green"},
               %{const: "b", title: "b"}
             ]
           }
  end

  test "requires options" do
    assert_raise ArgumentError, ~r/non-empty list/, fn ->
      EnumSchema.build(%EnumSchema{})
    end
  end

  test "rejects an invalid option and a repeated value" do
    assert_raise ArgumentError, ~r/invalid option/, fn ->
      %EnumSchema{} |> EnumSchema.options([1]) |> EnumSchema.build()
    end

    assert_raise ArgumentError, ~r/invalid option/, fn ->
      %EnumSchema{} |> EnumSchema.options([%{const: "a", title: 1}]) |> EnumSchema.build()
    end

    assert_raise ArgumentError, ~r/repeat/, fn ->
      %EnumSchema{} |> EnumSchema.options(["a", "a"]) |> EnumSchema.build()
    end
  end

  test "the default must be one of the options" do
    assert_raise ArgumentError, ~r/'default'/, fn ->
      %EnumSchema{} |> EnumSchema.options(["a"]) |> EnumSchema.default("b") |> EnumSchema.build()
    end
  end
end
