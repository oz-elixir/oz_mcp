defmodule OzMcp.Structs.SamplingMessageTest do
  use ExUnit.Case, async: true

  alias OzMcp.Structs.{
    ImageContent,
    SamplingMessage,
    TextContent,
    ToolResultContent,
    ToolUseContent
  }

  test "builds a message with one block" do
    result =
      %SamplingMessage{}
      |> SamplingMessage.role(:assistant)
      |> SamplingMessage.content(%TextContent{} |> TextContent.text("Hi"))
      |> SamplingMessage._meta(%{"k" => "v"})
      |> SamplingMessage.build()

    assert result == %{
             role: "assistant",
             content: %{type: "text", text: "Hi"},
             _meta: %{"k" => "v"}
           }
  end

  test "user/1 and assistant/1 build text messages" do
    assert SamplingMessage.build(SamplingMessage.user("a")) ==
             %{role: "user", content: %{type: "text", text: "a"}}

    assert SamplingMessage.build(SamplingMessage.assistant("b")) ==
             %{role: "assistant", content: %{type: "text", text: "b"}}
  end

  test "builds a message with a list of every kind of block" do
    blocks = [
      %TextContent{} |> TextContent.text("t"),
      %ImageContent{} |> ImageContent.data("aGk=") |> ImageContent.mime_type("image/png"),
      %ToolUseContent{id: "1", name: "n"},
      %ToolResultContent{toolUseId: "1"},
      %{type: "text", text: "raw"}
    ]

    result = %SamplingMessage{content: blocks} |> SamplingMessage.build()

    assert [
             %{type: "text"},
             %{type: "image"},
             %{type: "tool_use"},
             %{type: "tool_result"},
             %{type: "text", text: "raw"}
           ] = result.content
  end

  test "rejects an invalid role, a missing or empty content and a bad block" do
    assert_raise ArgumentError, ~r/'role'/, fn ->
      SamplingMessage.build(%SamplingMessage{role: :system, content: %{}})
    end

    assert_raise ArgumentError, ~r/required/, fn ->
      SamplingMessage.build(%SamplingMessage{})
    end

    assert_raise ArgumentError, ~r/empty list/, fn ->
      SamplingMessage.build(%SamplingMessage{content: []})
    end

    assert_raise ArgumentError, ~r/a content block must be/, fn ->
      SamplingMessage.build(%SamplingMessage{content: "text"})
    end
  end
end
