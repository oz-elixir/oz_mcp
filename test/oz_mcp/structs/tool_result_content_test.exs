defmodule OzMcp.Structs.ToolResultContentTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.{TextContent, ToolResultContent}

  test "builds a tool result" do
    result =
      %ToolResultContent{}
      |> ToolResultContent.tool_use_id("call_1")
      |> ToolResultContent.content([%TextContent{} |> TextContent.text("18 C")])
      |> ToolResultContent.structured_content(%{"t" => 18})
      |> ToolResultContent.is_error(false)
      |> ToolResultContent._meta(%{"k" => "v"})
      |> ToolResultContent.build()

    assert result == %{
             type: "tool_result",
             toolUseId: "call_1",
             content: [%{type: "text", text: "18 C"}],
             structuredContent: %{"t" => 18},
             isError: false,
             _meta: %{"k" => "v"}
           }
  end

  test "the content may be empty and may hold maps" do
    assert %{content: []} = ToolResultContent.build(%ToolResultContent{toolUseId: "1"})

    assert %{content: [%{type: "text", text: "x"}]} =
             ToolResultContent.build(%ToolResultContent{
               toolUseId: "1",
               content: [%{type: "text", text: "x"}]
             })
  end

  test "requires the id of the tool use and valid fields" do
    assert_raise ArgumentError, ~r/'toolUseId'/, fn ->
      ToolResultContent.build(%ToolResultContent{})
    end

    assert_raise ArgumentError, ~r/'content'/, fn ->
      ToolResultContent.build(%ToolResultContent{toolUseId: "1", content: "x"})
    end

    assert_raise ArgumentError, ~r/'isError'/, fn ->
      ToolResultContent.build(%ToolResultContent{toolUseId: "1", isError: "no"})
    end

    assert_raise ArgumentError, ~r/content/, fn ->
      ToolResultContent.build(%ToolResultContent{toolUseId: "1", content: ["x"]})
    end
  end

  test "checks the content items before the other fields" do
    assert_raise ArgumentError, ~r/'content' field is required/, fn ->
      ToolResultContent.build(%ToolResultContent{
        toolUseId: "1",
        content: ["x"],
        isError: "no"
      })
    end
  end
end
