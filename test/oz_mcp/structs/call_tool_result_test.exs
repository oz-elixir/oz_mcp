defmodule OzMcp.Structs.CallToolResultTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.{Annotations, CallToolResult, ImageContent, TextContent}

  describe "struct defaults" do
    test "has correct defaults for all fields" do
      tr = %CallToolResult{}

      assert tr.content == []
      assert tr.structuredContent == nil
      assert tr._meta == nil
      assert tr.extras == nil
      assert tr.isError == nil
    end
  end

  describe "content/2" do
    test "sets content field" do
      tr = CallToolResult.content(%CallToolResult{}, ["item"])

      assert tr.content == ["item"]
    end
  end

  describe "structured_content/2" do
    test "sets structuredContent field" do
      tr = CallToolResult.structured_content(%CallToolResult{}, %{"key" => "val"})

      assert tr.structuredContent == %{"key" => "val"}
    end
  end

  describe "_meta/2" do
    test "sets _meta field" do
      tr = CallToolResult._meta(%CallToolResult{}, %{"token" => 1})

      assert tr._meta == %{"token" => 1}
    end
  end

  describe "extras/2" do
    test "sets extras field" do
      tr = CallToolResult.extras(%CallToolResult{}, %{"custom" => "field"})

      assert tr.extras == %{"custom" => "field"}
    end
  end

  describe "is_error/2" do
    test "sets isError field to true" do
      tr = CallToolResult.is_error(%CallToolResult{}, true)

      assert tr.isError == true
    end

    test "sets isError field to false" do
      tr = CallToolResult.is_error(%CallToolResult{isError: true}, false)

      assert tr.isError == false
    end
  end

  describe "build/1" do
    test "builds with default empty content and no error" do
      result = CallToolResult.build(%CallToolResult{})

      assert result == %{content: []}
      refute Map.has_key?(result, :isError)
    end

    test "raises when content is not a list" do
      tr = struct(%CallToolResult{}, content: "not a list")

      assert_raise ArgumentError, "The 'content' field must be a list", fn ->
        CallToolResult.build(tr)
      end
    end

    test "raises when isError is not a boolean or nil" do
      tr = %CallToolResult{isError: "true"}

      assert_raise ArgumentError, "The 'isError' field must be a boolean or nil", fn ->
        CallToolResult.build(tr)
      end
    end

    test "builds with isError when isError is true" do
      tr = %CallToolResult{isError: true}
      result = CallToolResult.build(tr)

      assert result[:isError] == true
    end

    test "does not include isError when isError is nil" do
      tr = %CallToolResult{isError: nil}
      result = CallToolResult.build(tr)

      refute Map.has_key?(result, :isError)
    end

    test "builds TextContent items in content" do
      tc = %TextContent{text: "hello"}
      tr = %CallToolResult{content: [tc]}
      result = CallToolResult.build(tr)

      assert result.content == [%{type: "text", text: "hello"}]
    end

    test "builds ImageContent items in content" do
      ic = %ImageContent{data: "abc123", mimeType: "image/png"}
      tr = %CallToolResult{content: [ic]}
      result = CallToolResult.build(tr)

      assert result.content == [%{type: "image", data: "abc123", mimeType: "image/png"}]
    end

    test "passes through raw maps in content without transformation" do
      raw = %{"type" => "resource", "resource" => %{"uri" => "file:///test", "text" => "raw"}}
      tr = %CallToolResult{content: [raw]}
      result = CallToolResult.build(tr)

      assert result.content == [
               %{"type" => "resource", "resource" => %{"uri" => "file:///test", "text" => "raw"}}
             ]
    end

    test "accepts a content map with an atom type" do
      raw = %{type: :text, text: "x"}
      tr = %CallToolResult{content: [raw]}
      result = CallToolResult.build(tr)

      assert result.content == [%{type: :text, text: "x"}]
    end

    test "raises when a content map has no type" do
      tr = %CallToolResult{content: [%{"text" => "x"}]}

      assert_raise ArgumentError, ~r/a content block map needs a 'type'/, fn ->
        CallToolResult.build(tr)
      end
    end

    test "raises when a content map has an empty or nil type" do
      for block <- [%{type: ""}, %{type: nil}, %{"type" => ""}, %{type: true}] do
        tr = %CallToolResult{content: [block]}

        assert_raise ArgumentError, ~r/a content block map needs a 'type'/, fn ->
          CallToolResult.build(tr)
        end
      end
    end

    test "raises when a content item is not a map or a struct" do
      tr = %CallToolResult{content: ["text"]}

      assert_raise ArgumentError, ~r/The 'content' field is required and must be one of/, fn ->
        CallToolResult.build(tr)
      end
    end

    test "builds mixed content types" do
      tc = %TextContent{text: "desc"}
      ic = %ImageContent{data: "xyz", mimeType: "image/jpeg"}
      raw = %{"type" => "other"}
      tr = %CallToolResult{content: [tc, ic, raw]}
      result = CallToolResult.build(tr)

      assert result.content == [
               %{type: "text", text: "desc"},
               %{type: "image", data: "xyz", mimeType: "image/jpeg"},
               %{"type" => "other"}
             ]
    end

    test "preserves content order" do
      tc1 = %TextContent{text: "first"}
      tc2 = %TextContent{text: "second"}
      tr = %CallToolResult{content: [tc1, tc2]}
      result = CallToolResult.build(tr)

      assert result.content == [
               %{type: "text", text: "first"},
               %{type: "text", text: "second"}
             ]
    end

    test "keeps the order of a long list of contents" do
      contents = for i <- 1..50, do: %TextContent{text: "item #{i}"}
      tr = %CallToolResult{content: contents}
      result = CallToolResult.build(tr)

      assert result.content ==
               for(i <- 1..50, do: %{type: "text", text: "item #{i}"})
    end

    test "includes structuredContent when set" do
      tr = %CallToolResult{structuredContent: %{"result" => 42}}
      result = CallToolResult.build(tr)

      assert result[:structuredContent] == %{"result" => 42}
    end

    test "does not include structuredContent when nil" do
      tr = %CallToolResult{structuredContent: nil}
      result = CallToolResult.build(tr)

      refute Map.has_key?(result, "structuredContent")
    end

    test "includes _meta when set" do
      tr = %CallToolResult{_meta: %{"progressToken" => 5}}
      result = CallToolResult.build(tr)

      assert result[:_meta] == %{"progressToken" => 5}
    end

    test "does not include _meta when nil" do
      tr = %CallToolResult{_meta: nil}
      result = CallToolResult.build(tr)

      refute Map.has_key?(result, :_meta)
    end

    test "merges extras into result" do
      tr = %CallToolResult{extras: %{"customKey" => "customVal"}}
      result = CallToolResult.build(tr)

      assert result["customKey"] == "customVal"
    end

    test "does not include extras when nil" do
      tr = %CallToolResult{extras: nil}
      result = CallToolResult.build(tr)

      refute Map.has_key?(result, "customKey")
    end

    test "extras do not override existing result keys" do
      tr = %CallToolResult{
        content: [],
        extras: %{content: "should not override"}
      }

      result = CallToolResult.build(tr)

      assert result[:content] == []
    end

    test "builds full CallToolResult with all fields" do
      tc = %TextContent{text: "done"}
      annotations = %Annotations{audience: [:user]}
      tc_with_annotations = %TextContent{text: "annotated", annotations: annotations}

      tr = %CallToolResult{
        content: [tc, tc_with_annotations],
        structuredContent: %{"count" => 2},
        _meta: %{"progressToken" => 1},
        extras: %{"customField" => "value"},
        isError: nil
      }

      result = CallToolResult.build(tr)

      assert result.content == [
               %{type: "text", text: "done"},
               %{type: "text", text: "annotated", annotations: %{audience: [:user]}}
             ]

      assert result[:structuredContent] == %{"count" => 2}
      assert result[:_meta] == %{"progressToken" => 1}
      assert result["customField"] == "value"
      refute Map.has_key?(result, :isError)
    end
  end
end
