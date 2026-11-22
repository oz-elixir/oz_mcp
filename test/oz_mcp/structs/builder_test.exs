defmodule OzMcp.Structs.BuilderTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.Annotations
  alias OzMcp.Structs.Builder
  alias OzMcp.Structs.TextContent
  alias OzMcp.Structs.Tool

  describe "maybe_put/3" do
    test "returns map unchanged when value is nil" do
      struct = %Annotations{audience: nil}
      result = Builder.maybe_put(%{}, struct, :audience)

      assert result == %{}
    end

    test "puts value into result when value is present" do
      struct = %Annotations{audience: [:user]}
      result = Builder.maybe_put(%{}, struct, :audience)

      assert result == %{audience: [:user]}
    end

    test "puts value when value is false" do
      struct = %{field: false}
      result = Builder.maybe_put(%{}, struct, :field)

      assert result == %{field: false}
    end

    test "puts value when value is 0" do
      struct = %{field: 0}
      result = Builder.maybe_put(%{}, struct, :field)

      assert result == %{field: 0}
    end

    test "preserves existing keys in result map" do
      struct = %{field: "value"}
      result = Builder.maybe_put(%{existing: "key"}, struct, :field)

      assert result == %{existing: "key", field: "value"}
    end

    test "raises when field does not exist in struct" do
      struct = %Annotations{}

      assert_raise KeyError, fn ->
        Builder.maybe_put(%{}, struct, :nonexistent)
      end
    end
  end

  describe "maybe_annotations/2" do
    test "returns map unchanged when annotations is nil" do
      struct = %TextContent{annotations: nil}
      result = Builder.maybe_annotations(%{type: "text"}, struct)

      assert result == %{type: "text"}
    end

    test "builds and puts annotations when present" do
      annotations = %Annotations{audience: [:user], priority: 1}
      struct = %TextContent{annotations: annotations}
      result = Builder.maybe_annotations(%{type: "text"}, struct)

      assert result == %{type: "text", annotations: %{audience: [:user], priority: 1}}
    end

    test "raises when annotations is empty" do
      annotations = %Annotations{}
      struct = %TextContent{annotations: annotations}

      assert_raise ArgumentError, "All fields are 'nil', remove annotations declaration", fn ->
        Builder.maybe_annotations(%{type: "text"}, struct)
      end
    end
  end

  describe "maybe_meta/2" do
    test "returns map unchanged when _meta is nil" do
      struct = %TextContent{_meta: nil}
      result = Builder.maybe_meta(%{type: "text"}, struct)

      assert result == %{type: "text"}
    end

    test "puts _meta when present" do
      struct = %TextContent{_meta: %{"progressToken" => 42}}
      result = Builder.maybe_meta(%{type: "text"}, struct)

      assert result == %{type: "text", _meta: %{"progressToken" => 42}}
    end
  end

  describe "maybe_extras/2" do
    test "returns map unchanged when extras is nil" do
      struct = %{extras: nil}
      result = Builder.maybe_extras(%{content: []}, struct)

      assert result == %{content: []}
    end

    test "merges extras into result" do
      struct = %{extras: %{"customKey" => "customVal"}}
      result = Builder.maybe_extras(%{content: []}, struct)

      assert result == %{"customKey" => "customVal", content: []}
    end

    test "does not override existing result keys" do
      struct = %{extras: %{content: "should not override"}}
      result = Builder.maybe_extras(%{content: []}, struct)

      assert result[:content] == []
    end

    test "merges multiple extra keys" do
      struct = %{extras: %{"foo" => 1, "bar" => 2}}
      result = Builder.maybe_extras(%{}, struct)

      assert result == %{"foo" => 1, "bar" => 2}
    end

    test "drops an extra that has the string form of a result key" do
      struct = %{extras: %{"protocolVersion" => "x"}}
      result = Builder.maybe_extras(%{protocolVersion: "v"}, struct)

      assert result == %{protocolVersion: "v"}
    end

    test "drops an extra that has the name of a struct field with the value nil" do
      struct = %{nextCursor: nil, tools: [], extras: %{"nextCursor" => "2"}}
      result = Builder.maybe_extras(%{}, struct)

      refute Map.has_key?(result, "nextCursor")
      refute Map.has_key?(result, :nextCursor)
    end

    test "drops the second extra with the same string form" do
      struct = %{extras: %{:foo => 1, "foo" => 2}}
      result = Builder.maybe_extras(%{}, struct)

      assert result == %{:foo => 1}
    end

    test "keeps an atom extra that is not a field of the struct" do
      struct = %{tools: [], extras: %{total: 42}}
      result = Builder.maybe_extras(%{tools: []}, struct)

      assert result == %{tools: [], total: 42}
    end
  end

  describe "page/6" do
    test "builds an empty page" do
      assert Builder.page(:tools, Tool, [], nil) == %{tools: []}
    end

    test "builds a struct item and keeps a map item" do
      tool = %Tool{name: "search", inputSchema: %{type: "object"}}
      page = Builder.page(:tools, Tool, [tool, %{"name" => "other"}], nil)

      assert page == %{
               tools: [
                 %{name: "search", inputSchema: %{type: "object"}},
                 %{"name" => "other"}
               ]
             }
    end

    test "sends nextCursor when it is present" do
      assert Builder.page(:tools, Tool, [], "next") == %{tools: [], nextCursor: "next"}
    end

    test "does not send nextCursor when it is nil" do
      refute Map.has_key?(Builder.page(:tools, Tool, [], nil), :nextCursor)
    end

    test "raises on a wrong _meta" do
      assert_raise ArgumentError, "The '_meta' field must be a map or nil", fn ->
        Builder.page(:tools, Tool, [], nil, "bad")
      end
    end

    test "drops an extra with the name of a nil cursor" do
      assert Builder.page(:tools, Tool, [], nil, nil, %{"nextCursor" => "2"}) == %{tools: []}
    end

    test "keeps a free extra" do
      assert Builder.page(:tools, Tool, [], nil, nil, %{total: 42}) == %{tools: [], total: 42}
    end

    test "drops an extra with the name of the item key" do
      assert Builder.page(:tools, Tool, [], nil, nil, %{"tools" => []}) == %{tools: []}
    end

    test "sends _meta when it is present" do
      assert Builder.page(:tools, Tool, [], nil, %{"key" => "value"}) ==
               %{tools: [], _meta: %{"key" => "value"}}
    end
  end
end
