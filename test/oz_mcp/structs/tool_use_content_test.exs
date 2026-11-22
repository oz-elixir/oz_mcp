defmodule OzMcp.Structs.ToolUseContentTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.ToolUseContent

  test "builds a tool use" do
    result =
      %ToolUseContent{}
      |> ToolUseContent.id("call_1")
      |> ToolUseContent.name("weather")
      |> ToolUseContent.input(%{"city" => "Paris"})
      |> ToolUseContent._meta(%{"k" => "v"})
      |> ToolUseContent.build()

    assert result == %{
             type: "tool_use",
             id: "call_1",
             name: "weather",
             input: %{"city" => "Paris"},
             _meta: %{"k" => "v"}
           }
  end

  test "an empty input is valid" do
    assert %{input: %{}} = ToolUseContent.build(%ToolUseContent{id: "1", name: "n"})
  end

  test "requires id, name and a map input" do
    assert_raise ArgumentError, ~r/'id'/, fn ->
      ToolUseContent.build(%ToolUseContent{name: "n"})
    end

    assert_raise ArgumentError, ~r/'name'/, fn ->
      ToolUseContent.build(%ToolUseContent{id: "1"})
    end

    assert_raise ArgumentError, ~r/'input'/, fn ->
      ToolUseContent.build(%ToolUseContent{id: "1", name: "n", input: "x"})
    end
  end
end
