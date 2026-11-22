defmodule OzMcp.Structs.BooleanSchemaTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.BooleanSchema

  test "builds the minimal schema" do
    assert BooleanSchema.build(%BooleanSchema{}) == %{type: "boolean"}
  end

  test "builds every field, including a false default" do
    result =
      %BooleanSchema{}
      |> BooleanSchema.title("Subscribe")
      |> BooleanSchema.description("Newsletter")
      |> BooleanSchema.default(false)
      |> BooleanSchema.build()

    assert result == %{
             type: "boolean",
             title: "Subscribe",
             description: "Newsletter",
             default: false
           }
  end

  test "rejects a default that is not a boolean" do
    assert_raise ArgumentError, ~r/'default'/, fn ->
      %BooleanSchema{} |> BooleanSchema.default("yes") |> BooleanSchema.build()
    end
  end

  test "rejects an empty description" do
    assert_raise ArgumentError, ~r/'description'/, fn ->
      %BooleanSchema{} |> BooleanSchema.description("") |> BooleanSchema.build()
    end
  end
end
