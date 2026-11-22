defmodule OzMcp.Structs.ToolTest do
  use ExUnit.Case, async: true

  alias OzMcp.Structs.{Icon, Tool, ToolAnnotations, ToolExecution}

  describe "struct defaults" do
    test "has correct defaults for all fields" do
      tool = %Tool{}

      assert tool.name == ""
      assert tool.title == nil
      assert tool.description == nil
      assert is_map(tool.inputSchema)
      assert map_size(tool.inputSchema) == 0
      assert tool.outputSchema == nil
      assert tool.icons == nil
      assert tool.annotations == nil
      assert tool.execution == nil
      assert tool._meta == nil
      assert tool.extras == nil
    end
  end

  describe "name/2" do
    test "sets name field" do
      tool = Tool.name(%Tool{}, "search")

      assert tool.name == "search"
    end
  end

  describe "title/2" do
    test "sets title field" do
      tool = Tool.title(%Tool{}, "Search")

      assert tool.title == "Search"
    end
  end

  describe "description/2" do
    test "sets description field" do
      tool = Tool.description(%Tool{}, "A search tool")

      assert tool.description == "A search tool"
    end
  end

  describe "input_schema/2" do
    test "sets inputSchema field" do
      schema = %{type: "object", properties: %{"query" => %{type: "string"}}}
      tool = Tool.input_schema(%Tool{}, schema)

      assert tool.inputSchema == schema
    end
  end

  describe "output_schema/2" do
    test "sets outputSchema field" do
      schema = %{type: "object", properties: %{"result" => %{type: "string"}}}
      tool = Tool.output_schema(%Tool{}, schema)

      assert tool.outputSchema == schema
    end
  end

  describe "icons/2" do
    test "sets icons field" do
      icons = [%Icon{src: "https://example.com/icon.png"}]
      tool = Tool.icons(%Tool{}, icons)

      assert tool.icons == icons
    end
  end

  describe "annotations/2" do
    test "sets annotations field" do
      annotations = %ToolAnnotations{title: "My Tool", readOnlyHint: true}
      tool = Tool.annotations(%Tool{}, annotations)

      assert tool.annotations == annotations
    end
  end

  describe "execution/2" do
    test "sets execution field" do
      execution = %ToolExecution{taskSupport: :optional}
      tool = Tool.execution(%Tool{}, execution)

      assert tool.execution == execution
    end
  end

  describe "_meta/2" do
    test "sets _meta field" do
      tool = Tool._meta(%Tool{}, %{"key" => "value"})

      assert tool._meta == %{"key" => "value"}
    end
  end

  describe "extras/2" do
    test "sets extras field" do
      tool = Tool.extras(%Tool{}, %{"vendor" => 1})

      assert tool.extras == %{"vendor" => 1}
    end
  end

  describe "required_scopes/2" do
    test "sets required_scopes field" do
      tool = Tool.required_scopes(%Tool{}, ["files:write"])

      assert tool.required_scopes == ["files:write"]
    end

    test "raises for a scope that is not a scope-token" do
      assert_raise ArgumentError, fn ->
        Tool.required_scopes(%Tool{}, ["a b"])
      end
    end
  end

  describe "build/1" do
    test "builds with name and inputSchema only" do
      tool = %Tool{
        name: "search",
        inputSchema: %{type: "object"}
      }

      result = Tool.build(tool)

      assert result == %{name: "search", inputSchema: %{type: "object"}}
    end

    test "raises when name is empty" do
      tool = %Tool{name: "", inputSchema: %{type: "object"}}

      assert_raise ArgumentError, "The 'name' field cannot be an empty string", fn ->
        Tool.build(tool)
      end
    end

    test "raises when name is not a string" do
      tool = struct(Tool, name: 123, inputSchema: %{type: "object"})

      assert_raise ArgumentError, "The 'name' field is required and must be a string", fn ->
        Tool.build(tool)
      end
    end

    test "raises for inputSchema nil" do
      tool = struct(Tool, name: "search", inputSchema: nil)

      assert_raise ArgumentError, "The 'inputSchema' field must be a map, got: nil", fn ->
        Tool.build(tool)
      end
    end

    test "raises for an inputSchema string" do
      tool = struct(Tool, name: "search", inputSchema: "x")

      assert_raise ArgumentError, ~s(The 'inputSchema' field must be a map, got: "x"), fn ->
        Tool.build(tool)
      end
    end

    test "keeps the default schema for %{}" do
      tool = %Tool{name: "search"}
      result = Tool.build(tool)

      assert result.inputSchema == %{type: "object", properties: %{}}
    end

    test "raises when the inputSchema root type is not object" do
      tool = struct(Tool, name: "search", inputSchema: %{type: "string"})

      assert_raise ArgumentError,
                   ~s(The 'inputSchema' field the root must have type: "object", got: "string"),
                   fn ->
                     Tool.build(tool)
                   end
    end

    test "raises when outputSchema has no type object" do
      tool = struct(Tool, name: "search", inputSchema: %{type: "object"}, outputSchema: %{a: 1})

      assert_raise ArgumentError,
                   ~s(The 'outputSchema' field the root must have type: "object", got: nil),
                   fn ->
                     Tool.build(tool)
                   end
    end

    test "includes title when set" do
      tool = %Tool{name: "search", title: "Search", inputSchema: %{type: "object"}}
      result = Tool.build(tool)

      assert result == %{name: "search", title: "Search", inputSchema: %{type: "object"}}
    end

    test "includes description when set" do
      tool = %Tool{
        name: "search",
        description: "A search tool",
        inputSchema: %{type: "object"}
      }

      result = Tool.build(tool)

      assert result == %{
               name: "search",
               description: "A search tool",
               inputSchema: %{type: "object"}
             }
    end

    test "includes inputSchema with all fields" do
      tool = %Tool{
        name: "search",
        inputSchema: %{
          :type => "object",
          :"$schema" => "https://json-schema.org/draft/2020-12/schema",
          :properties => %{"query" => %{type: "string"}},
          :required => ["query"]
        }
      }

      result = Tool.build(tool)

      assert result == %{
               name: "search",
               inputSchema: %{
                 :"$schema" => "https://json-schema.org/draft/2020-12/schema",
                 type: "object",
                 properties: %{"query" => %{type: "string"}},
                 required: ["query"]
               }
             }
    end

    test "includes outputSchema when set" do
      tool = %Tool{
        name: "search",
        inputSchema: %{type: "object"},
        outputSchema: %{type: "object", properties: %{"result" => %{type: "string"}}}
      }

      result = Tool.build(tool)

      assert result == %{
               name: "search",
               inputSchema: %{type: "object"},
               outputSchema: %{type: "object", properties: %{"result" => %{type: "string"}}}
             }
    end

    test "does not include outputSchema when nil" do
      tool = %Tool{name: "search", inputSchema: %{type: "object"}, outputSchema: nil}
      result = Tool.build(tool)

      refute Map.has_key?(result, :outputSchema)
    end

    test "includes icons when set" do
      icons = [%Icon{src: "https://example.com/icon.png"}]
      tool = %Tool{name: "search", inputSchema: %{type: "object"}, icons: icons}
      result = Tool.build(tool)

      assert result == %{
               name: "search",
               inputSchema: %{type: "object"},
               icons: [%{src: "https://example.com/icon.png"}]
             }
    end

    test "includes annotations when set" do
      annotations = %ToolAnnotations{title: "Search Tool", readOnlyHint: true}

      tool = %Tool{
        name: "search",
        inputSchema: %{type: "object"},
        annotations: annotations
      }

      result = Tool.build(tool)

      assert result == %{
               name: "search",
               inputSchema: %{type: "object"},
               annotations: %{title: "Search Tool", readOnlyHint: true}
             }
    end

    test "includes execution when set" do
      tool = %Tool{
        name: "search",
        inputSchema: %{type: "object"},
        execution: %ToolExecution{taskSupport: :optional}
      }

      result = Tool.build(tool)

      assert result == %{
               name: "search",
               inputSchema: %{type: "object"},
               execution: %{taskSupport: :optional}
             }
    end

    test "includes _meta when set" do
      tool = %Tool{
        name: "search",
        inputSchema: %{type: "object"},
        _meta: %{"progressToken" => 5}
      }

      result = Tool.build(tool)

      assert result == %{
               name: "search",
               inputSchema: %{type: "object"},
               _meta: %{"progressToken" => 5}
             }
    end

    test "does not include _meta when nil" do
      tool = %Tool{name: "search", inputSchema: %{type: "object"}, _meta: nil}
      result = Tool.build(tool)

      refute Map.has_key?(result, :_meta)
    end

    test "does not include required_scopes" do
      tool = Tool.required_scopes(%Tool{name: "search", inputSchema: %{type: "object"}}, ["a"])
      result = Tool.build(tool)

      refute Map.has_key?(result, :required_scopes)
    end

    test "merges extras into result" do
      tool = %Tool{name: "search", inputSchema: %{type: "object"}, extras: %{"vendor" => 1}}
      result = Tool.build(tool)

      assert result["vendor"] == 1
    end

    test "does not include extras when nil" do
      tool = %Tool{name: "search", inputSchema: %{type: "object"}, extras: nil}
      result = Tool.build(tool)

      refute Map.has_key?(result, "vendor")
    end

    test "extras do not override existing result keys" do
      tool = %Tool{
        name: "search",
        inputSchema: %{type: "object"},
        extras: %{name: "should not override"}
      }

      result = Tool.build(tool)

      assert result[:name] == "search"
    end

    test "includes all fields when all are set" do
      tool = %Tool{
        name: "search",
        title: "Search",
        description: "A search tool",
        inputSchema: %{
          :type => "object",
          :"$schema" => "https://json-schema.org/draft/2020-12/schema",
          :properties => %{"query" => %{type: "string"}},
          :required => ["query"]
        },
        outputSchema: %{type: "object"},
        icons: [%Icon{src: "https://example.com/icon.png"}],
        annotations: %ToolAnnotations{title: "Search Tool", readOnlyHint: true},
        execution: %ToolExecution{taskSupport: :required},
        _meta: %{"key" => "val"}
      }

      result = Tool.build(tool)

      assert result == %{
               name: "search",
               title: "Search",
               description: "A search tool",
               inputSchema: %{
                 :"$schema" => "https://json-schema.org/draft/2020-12/schema",
                 type: "object",
                 properties: %{"query" => %{type: "string"}},
                 required: ["query"]
               },
               outputSchema: %{type: "object"},
               icons: [%{src: "https://example.com/icon.png"}],
               annotations: %{title: "Search Tool", readOnlyHint: true},
               execution: %{taskSupport: :required},
               _meta: %{"key" => "val"}
             }
    end

    test "does not include nil optional fields" do
      tool = %Tool{
        name: "search",
        title: nil,
        description: nil,
        inputSchema: %{type: "object"},
        outputSchema: nil,
        icons: nil,
        annotations: nil,
        execution: nil,
        _meta: nil
      }

      result = Tool.build(tool)

      assert result == %{name: "search", inputSchema: %{type: "object"}}
    end
  end
end
