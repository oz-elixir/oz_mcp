defmodule OzMcp.Structs.TextResourceContentsTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.TextResourceContents

  describe "struct defaults" do
    test "has correct defaults for all fields" do
      rtc = %TextResourceContents{}

      assert rtc.uri == ""
      assert rtc.text == ""
      assert rtc.mimeType == nil
      assert rtc._meta == nil
    end
  end

  describe "uri/2" do
    test "sets uri field" do
      rtc = TextResourceContents.uri(%TextResourceContents{}, "file:///test.md")

      assert rtc.uri == "file:///test.md"
    end
  end

  describe "text/2" do
    test "sets text field" do
      rtc = TextResourceContents.text(%TextResourceContents{}, "hello world")

      assert rtc.text == "hello world"
    end
  end

  describe "mime_type/2" do
    test "sets mimeType field" do
      rtc = TextResourceContents.mime_type(%TextResourceContents{}, "text/markdown")

      assert rtc.mimeType == "text/markdown"
    end
  end

  describe "_meta/2" do
    test "sets _meta field" do
      rtc = TextResourceContents._meta(%TextResourceContents{}, %{"key" => "value"})

      assert rtc._meta == %{"key" => "value"}
    end
  end

  describe "build/1" do
    test "builds with uri and text only" do
      rtc = %TextResourceContents{uri: "file:///doc.md", text: "content"}
      result = TextResourceContents.build(rtc)

      assert result == %{uri: "file:///doc.md", text: "content"}
    end

    test "raises when uri is empty" do
      rtc = %TextResourceContents{uri: "", text: "content"}

      assert_raise ArgumentError, "The 'uri' field cannot be an empty string", fn ->
        TextResourceContents.build(rtc)
      end
    end

    test "raises when uri is not a string" do
      rtc = struct(TextResourceContents, uri: 123, text: "content")

      assert_raise ArgumentError, "The 'uri' field is required and must be a string", fn ->
        TextResourceContents.build(rtc)
      end
    end

    test "raises when text is empty" do
      rtc = %TextResourceContents{uri: "file:///doc.md", text: ""}

      assert_raise ArgumentError, "The 'text' field cannot be an empty string", fn ->
        TextResourceContents.build(rtc)
      end
    end

    test "raises when text is not a string" do
      rtc = struct(TextResourceContents, uri: "file:///doc.md", text: 456)

      assert_raise ArgumentError, "The 'text' field is required and must be a string", fn ->
        TextResourceContents.build(rtc)
      end
    end

    test "raises when text is nil" do
      rtc = struct(TextResourceContents, uri: "file:///doc.md", text: nil)

      assert_raise ArgumentError, "The 'text' field is required and must be a string", fn ->
        TextResourceContents.build(rtc)
      end
    end

    test "raises on an empty mimeType" do
      rtc = %TextResourceContents{uri: "file:///a", text: "x", mimeType: ""}

      assert_raise ArgumentError, "The 'mimeType' field cannot be an empty string", fn ->
        TextResourceContents.build(rtc)
      end
    end

    test "accepts a uri with no scheme" do
      rtc = %TextResourceContents{uri: "a", text: "x"}

      assert TextResourceContents.build(rtc) == %{uri: "a", text: "x"}
    end

    test "includes mimeType when set" do
      rtc = %TextResourceContents{uri: "file:///doc.md", text: "content", mimeType: "text/plain"}
      result = TextResourceContents.build(rtc)

      assert result == %{mimeType: "text/plain", text: "content", uri: "file:///doc.md"}
    end

    test "does not include mimeType when nil" do
      rtc = %TextResourceContents{uri: "file:///doc.md", text: "content", mimeType: nil}
      result = TextResourceContents.build(rtc)

      refute Map.has_key?(result, :mimeType)
    end

    test "includes _meta when set" do
      rtc = %TextResourceContents{
        uri: "file:///doc.md",
        text: "content",
        _meta: %{"progressToken" => 5}
      }

      result = TextResourceContents.build(rtc)

      assert result == %{uri: "file:///doc.md", text: "content", _meta: %{"progressToken" => 5}}
    end

    test "does not include _meta when nil" do
      rtc = %TextResourceContents{uri: "file:///doc.md", text: "content", _meta: nil}
      result = TextResourceContents.build(rtc)

      refute Map.has_key?(result, :_meta)
    end

    test "includes all optional fields" do
      rtc = %TextResourceContents{
        uri: "file:///doc.md",
        text: "content",
        mimeType: "text/markdown",
        _meta: %{"key" => "val"}
      }

      result = TextResourceContents.build(rtc)

      assert result == %{
               mimeType: "text/markdown",
               _meta: %{"key" => "val"},
               text: "content",
               uri: "file:///doc.md"
             }
    end

    test "does not include nil optional fields" do
      rtc = %TextResourceContents{
        uri: "file:///doc.md",
        text: "content",
        mimeType: nil,
        _meta: nil
      }

      result = TextResourceContents.build(rtc)

      assert result == %{uri: "file:///doc.md", text: "content"}
    end
  end
end
