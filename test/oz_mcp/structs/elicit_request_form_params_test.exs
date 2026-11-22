defmodule OzMcp.Structs.ElicitRequestFormParamsTest do
  use ExUnit.Case, async: true

  alias OzMcp.Structs.{
    BooleanSchema,
    ElicitationSchema,
    ElicitRequestFormParams,
    TaskMetadata
  }

  defp schema, do: %ElicitationSchema{} |> ElicitationSchema.property("ok", %BooleanSchema{})

  defp params do
    %ElicitRequestFormParams{}
    |> ElicitRequestFormParams.message("Sure?")
    |> ElicitRequestFormParams.requested_schema(schema())
  end

  test "builds the params of a form" do
    result =
      %ElicitRequestFormParams{}
      |> ElicitRequestFormParams.message("Sure?")
      |> ElicitRequestFormParams.requested_schema(schema())
      |> ElicitRequestFormParams._meta(%{"k" => "v"})
      |> ElicitRequestFormParams.build()

    assert result == %{
             mode: "form",
             message: "Sure?",
             requestedSchema: %{type: "object", properties: %{"ok" => %{type: "boolean"}}},
             _meta: %{"k" => "v"}
           }
  end

  test "accepts a schema that is already a map" do
    raw = %{"type" => "object", "properties" => %{}}

    result =
      %ElicitRequestFormParams{message: "x"}
      |> ElicitRequestFormParams.requested_schema(raw)
      |> ElicitRequestFormParams.build()

    assert result.requestedSchema == raw
  end

  test "requires a message and a schema" do
    assert_raise ArgumentError, ~r/'message'/, fn ->
      ElicitRequestFormParams.build(%ElicitRequestFormParams{requestedSchema: schema()})
    end

    assert_raise ArgumentError, ~r/'requestedSchema'/, fn ->
      ElicitRequestFormParams.build(%ElicitRequestFormParams{message: "x"})
    end
  end

  test "sends the task metadata" do
    params = params() |> ElicitRequestFormParams.task(%TaskMetadata{ttl: 60_000})
    assert ElicitRequestFormParams.build(params).task == %{ttl: 60_000}
  end

  test "does not send task when it is nil" do
    refute Map.has_key?(ElicitRequestFormParams.build(params()), :task)
  end

  test "raises when task is not a TaskMetadata struct" do
    message = "The 'task' field must be a OzMcp.Structs.TaskMetadata struct or nil"

    assert_raise ArgumentError, message, fn ->
      ElicitRequestFormParams.build(%{params() | task: %{ttl: 1}})
    end
  end
end
