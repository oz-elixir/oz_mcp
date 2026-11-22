defmodule OzMcp.Structs.NumberSchemaTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.NumberSchema

  test "is a number by default" do
    assert NumberSchema.build(%NumberSchema{}) == %{type: "number"}
  end

  test "builds an integer with limits and a default" do
    result =
      %NumberSchema{}
      |> NumberSchema.type(:integer)
      |> NumberSchema.title("Age")
      |> NumberSchema.description("Years")
      |> NumberSchema.minimum(0)
      |> NumberSchema.maximum(150)
      |> NumberSchema.default(30)
      |> NumberSchema.build()

    assert result == %{
             type: "integer",
             title: "Age",
             description: "Years",
             minimum: 0,
             maximum: 150,
             default: 30
           }
  end

  test "accepts string types" do
    assert %{type: "integer"} =
             %NumberSchema{} |> NumberSchema.type("integer") |> NumberSchema.build()
  end

  test "rejects an unknown type" do
    assert_raise ArgumentError, ~r/'type'/, fn ->
      %NumberSchema{} |> NumberSchema.type(:string) |> NumberSchema.build()
    end
  end

  test "rejects values that are not numbers" do
    assert_raise ArgumentError, ~r/'minimum'/, fn ->
      %NumberSchema{} |> NumberSchema.minimum("1") |> NumberSchema.build()
    end

    assert_raise ArgumentError, ~r/'default'/, fn ->
      %NumberSchema{} |> NumberSchema.default(true) |> NumberSchema.build()
    end
  end

  test "rejects minimum greater than maximum" do
    assert_raise ArgumentError, ~r/cannot be greater/, fn ->
      %NumberSchema{}
      |> NumberSchema.minimum(5)
      |> NumberSchema.maximum(1)
      |> NumberSchema.build()
    end
  end
end
