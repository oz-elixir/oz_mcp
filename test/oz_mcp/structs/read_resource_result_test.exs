defmodule OzMcp.Structs.ReadResourceResultTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.{BlobResourceContents, ReadResourceResult, TextResourceContents}

  describe "struct defaults" do
    test "has correct defaults for all fields" do
      rrr = %ReadResourceResult{}

      assert rrr.contents == []
      assert rrr._meta == nil
      assert rrr.extras == nil
    end
  end

  describe "_meta/2" do
    test "sets _meta field" do
      rrr = ReadResourceResult._meta(%ReadResourceResult{}, %{"key" => "value"})

      assert rrr._meta == %{"key" => "value"}
    end
  end

  describe "contents/2" do
    test "sets contents field" do
      rrr = ReadResourceResult.contents(%ReadResourceResult{}, ["item"])

      assert rrr.contents == ["item"]
    end
  end

  describe "extras/2" do
    test "sets extras field" do
      rrr = ReadResourceResult.extras(%ReadResourceResult{}, %{"custom" => "field"})

      assert rrr.extras == %{"custom" => "field"}
    end
  end

  describe "build/1" do
    test "builds with default empty contents" do
      result = ReadResourceResult.build(%ReadResourceResult{})

      assert result == %{contents: []}
    end

    test "raises when contents is not a list" do
      rrr = struct(%ReadResourceResult{}, contents: "not a list")

      assert_raise ArgumentError, "The 'contents' field must be a list", fn ->
        ReadResourceResult.build(rrr)
      end
    end

    test "builds TextResourceContents items in contents" do
      rtc = %TextResourceContents{uri: "file:///doc.md", text: "hello"}
      rrr = %ReadResourceResult{contents: [rtc]}
      result = ReadResourceResult.build(rrr)

      assert result.contents == [%{uri: "file:///doc.md", text: "hello"}]
    end

    test "builds BlobResourceContents items in contents" do
      rbc = %BlobResourceContents{uri: "file:///img.png", blob: "base64data"}
      rrr = %ReadResourceResult{contents: [rbc]}
      result = ReadResourceResult.build(rrr)

      assert result.contents == [%{uri: "file:///img.png", blob: "base64data"}]
    end

    test "passes through raw maps in contents without transformation" do
      raw = %{"uri" => "file:///test", "text" => "raw"}
      rrr = %ReadResourceResult{contents: [raw]}
      result = ReadResourceResult.build(rrr)

      assert result.contents == [%{"uri" => "file:///test", "text" => "raw"}]
    end

    test "builds mixed content types" do
      rtc = %TextResourceContents{uri: "file:///a.md", text: "text"}
      rbc = %BlobResourceContents{uri: "file:///b.png", blob: "data"}
      raw = %{"uri" => "file:///c.md", "text" => "other"}
      rrr = %ReadResourceResult{contents: [rtc, rbc, raw]}
      result = ReadResourceResult.build(rrr)

      assert result.contents == [
               %{uri: "file:///a.md", text: "text"},
               %{uri: "file:///b.png", blob: "data"},
               %{"uri" => "file:///c.md", "text" => "other"}
             ]
    end

    test "raises when a content map has no text and no blob" do
      for raw <- [%{uri: "file:///a"}, %{"uri" => ""}, %{uri: nil}] do
        rrr = %ReadResourceResult{contents: [raw]}

        assert_raise ArgumentError, "contents[0] needs a 'text' or a 'blob'", fn ->
          ReadResourceResult.build(rrr)
        end
      end
    end

    test "raises when a content map with a text has no uri or an empty uri" do
      for raw <- [%{"text" => "x"}, %{text: "x", uri: ""}] do
        rrr = %ReadResourceResult{contents: [raw]}

        assert_raise ArgumentError, "The 'uri' field cannot be an empty string", fn ->
          ReadResourceResult.build(rrr)
        end
      end
    end

    test "the message of a bad item names the index of the item" do
      rrr = %ReadResourceResult{contents: [%{uri: "file:///a", text: "x"}, %{uri: "file:///b"}]}

      assert_raise ArgumentError, "contents[1] needs a 'text' or a 'blob'", fn ->
        ReadResourceResult.build(rrr)
      end
    end

    test "a content map with a blob is checked as blob contents" do
      rrr = %ReadResourceResult{contents: [%{uri: "file:///a", blob: 1}]}

      assert_raise ArgumentError, "The 'blob' field is required and must be a string", fn ->
        ReadResourceResult.build(rrr)
      end
    end

    test "raises when a content item is not a struct or a map" do
      rrr = %ReadResourceResult{contents: ["text"]}

      assert_raise ArgumentError, ~r/each content item must be/, fn ->
        ReadResourceResult.build(rrr)
      end
    end

    test "preserves contents order" do
      rtc1 = %TextResourceContents{uri: "file:///1.md", text: "first"}
      rtc2 = %TextResourceContents{uri: "file:///2.md", text: "second"}
      rrr = %ReadResourceResult{contents: [rtc1, rtc2]}
      result = ReadResourceResult.build(rrr)

      assert result.contents == [
               %{uri: "file:///1.md", text: "first"},
               %{uri: "file:///2.md", text: "second"}
             ]
    end

    test "keeps the order of a long list of contents" do
      contents =
        for i <- 1..50, do: %TextResourceContents{uri: "file:///#{i}.md", text: "item #{i}"}

      rrr = %ReadResourceResult{contents: contents}
      result = ReadResourceResult.build(rrr)

      assert result.contents ==
               for(i <- 1..50, do: %{uri: "file:///#{i}.md", text: "item #{i}"})
    end

    test "includes _meta when set" do
      rrr = %ReadResourceResult{_meta: %{"progressToken" => 5}}
      result = ReadResourceResult.build(rrr)

      assert result[:_meta] == %{"progressToken" => 5}
    end

    test "does not include _meta when nil" do
      rrr = %ReadResourceResult{_meta: nil}
      result = ReadResourceResult.build(rrr)

      refute Map.has_key?(result, :_meta)
    end

    test "merges extras into result" do
      rrr = %ReadResourceResult{extras: %{"customKey" => "customVal"}}
      result = ReadResourceResult.build(rrr)

      assert result["customKey"] == "customVal"
    end

    test "does not include extras when nil" do
      rrr = %ReadResourceResult{extras: nil}
      result = ReadResourceResult.build(rrr)

      refute Map.has_key?(result, "customKey")
    end

    test "extras do not override existing result keys" do
      rrr = %ReadResourceResult{
        contents: [],
        extras: %{contents: "should not override"}
      }

      result = ReadResourceResult.build(rrr)

      assert result[:contents] == []
    end

    test "builds full ReadResourceResult with all fields" do
      rtc = %TextResourceContents{
        uri: "file:///doc.md",
        text: "content",
        mimeType: "text/markdown"
      }

      rrr = %ReadResourceResult{
        contents: [rtc],
        _meta: %{"progressToken" => 1},
        extras: %{"customField" => "value"}
      }

      result = ReadResourceResult.build(rrr)

      assert result.contents == [
               %{
                 mimeType: "text/markdown",
                 text: "content",
                 uri: "file:///doc.md"
               }
             ]

      assert result[:_meta] == %{"progressToken" => 1}
      assert result["customField"] == "value"
    end
  end
end
