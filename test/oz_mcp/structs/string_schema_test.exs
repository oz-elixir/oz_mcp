defmodule OzMcp.Structs.StringSchemaTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.StringSchema

  test "builds the minimal schema" do
    assert StringSchema.build(%StringSchema{}) == %{type: "string"}
  end

  test "builds every field" do
    result =
      %StringSchema{}
      |> StringSchema.title("Email")
      |> StringSchema.description("Your email")
      |> StringSchema.min_length(3)
      |> StringSchema.max_length(50)
      |> StringSchema.format("email")
      |> StringSchema.default("a@b.c")
      |> StringSchema.build()

    assert result == %{
             type: "string",
             title: "Email",
             description: "Your email",
             minLength: 3,
             maxLength: 50,
             format: "email",
             default: "a@b.c"
           }
  end

  test "accepts the four formats" do
    for format <- ["email", "uri", "date", "date-time"] do
      assert %{format: ^format} =
               %StringSchema{} |> StringSchema.format(format) |> StringSchema.build()
    end
  end

  test "rejects an unknown format" do
    assert_raise ArgumentError, ~r/'format'/, fn ->
      %StringSchema{} |> StringSchema.format("uuid") |> StringSchema.build()
    end
  end

  test "rejects an empty title and a negative length" do
    assert_raise ArgumentError, ~r/'title'/, fn ->
      %StringSchema{} |> StringSchema.title("") |> StringSchema.build()
    end

    assert_raise ArgumentError, ~r/'minLength'/, fn ->
      %StringSchema{} |> StringSchema.min_length(-1) |> StringSchema.build()
    end
  end

  test "rejects minLength greater than maxLength" do
    assert_raise ArgumentError, ~r/cannot be greater/, fn ->
      %StringSchema{}
      |> StringSchema.min_length(5)
      |> StringSchema.max_length(2)
      |> StringSchema.build()
    end
  end

  test "rejects a default that is not a string" do
    assert_raise ArgumentError, ~r/'default'/, fn ->
      %StringSchema{} |> StringSchema.default(1) |> StringSchema.build()
    end
  end
end
