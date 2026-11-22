defmodule OzMcp.Structs.TextContentTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.Annotations
  alias OzMcp.Structs.TextContent

  describe "struct defaults" do
    test "has correct defaults for all fields" do
      tc = %TextContent{}

      assert tc.text == ""
      assert tc.annotations == nil
      assert tc._meta == nil
    end
  end

  describe "text/2" do
    test "sets text field" do
      tc = TextContent.text(%TextContent{}, "hello world")

      assert tc.text == "hello world"
    end
  end

  describe "annotations/2" do
    test "sets annotations field" do
      annotations = %Annotations{audience: [:user]}
      tc = TextContent.annotations(%TextContent{}, annotations)

      assert tc.annotations == annotations
    end
  end

  describe "_meta/2" do
    test "sets _meta field" do
      tc = TextContent._meta(%TextContent{}, %{"key" => "value"})

      assert tc._meta == %{"key" => "value"}
    end
  end

  describe "build/1" do
    test "builds with text only" do
      tc = %TextContent{text: "hello"}
      result = TextContent.build(tc)

      assert result == %{type: "text", text: "hello"}
    end

    test "raises when text is empty" do
      tc = %TextContent{text: ""}

      assert_raise ArgumentError, "The 'text' field cannot be an empty string", fn ->
        TextContent.build(tc)
      end
    end

    test "includes annotations when set" do
      tc = %TextContent{
        text: "hello",
        annotations: %Annotations{audience: [:user], priority: 1}
      }

      result = TextContent.build(tc)

      assert result == %{
               type: "text",
               text: "hello",
               annotations: %{audience: [:user], priority: 1}
             }
    end

    test "includes _meta when set" do
      tc = %TextContent{
        text: "hello",
        _meta: %{"progressToken" => 99}
      }

      result = TextContent.build(tc)

      assert result == %{
               type: "text",
               text: "hello",
               _meta: %{"progressToken" => 99}
             }
    end

    test "includes all optional fields" do
      tc = %TextContent{
        text: "hello",
        annotations: %Annotations{priority: 0},
        _meta: %{"key" => "val"}
      }

      result = TextContent.build(tc)

      assert result == %{
               type: "text",
               text: "hello",
               annotations: %{priority: 0},
               _meta: %{"key" => "val"}
             }
    end

    test "does not include nil optional fields" do
      tc = %TextContent{text: "hello", annotations: nil, _meta: nil}
      result = TextContent.build(tc)

      assert result == %{type: "text", text: "hello"}
    end
  end
end
