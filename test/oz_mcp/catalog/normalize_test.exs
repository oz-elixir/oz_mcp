defmodule OzMcp.Catalog.NormalizeTest do
  use ExUnit.Case, async: false

  alias OzMcp.Catalog.Normalize

  alias OzMcp.Structs.{
    Annotations,
    Icon,
    Prompt,
    PromptArgument,
    Resource,
    ResourceTemplate,
    Tool,
    ToolAnnotations,
    ToolExecution
  }

  describe "the three forms give the same struct" do
    test "tools" do
      expected = %Tool{name: "get", inputSchema: %{type: "object"}}

      assert Normalize.entity(:tools, expected) == {:ok, expected}

      assert Normalize.entity(:tools, %{name: "get", inputSchema: %{type: "object"}}) ==
               {:ok, expected}

      assert Normalize.entity(:tools, %{
               "name" => "get",
               "inputSchema" => %{type: "object"}
             }) == {:ok, expected}
    end

    test "prompts" do
      expected = %Prompt{
        name: "weather",
        arguments: [%PromptArgument{name: "city", required: true}],
        icons: [%Icon{src: "https://example.com/icon.png"}]
      }

      assert Normalize.entity(:prompts, expected) == {:ok, expected}

      assert Normalize.entity(:prompts, %{
               name: "weather",
               arguments: [%{name: "city", required: true}],
               icons: [%{src: "https://example.com/icon.png"}]
             }) == {:ok, expected}

      assert Normalize.entity(:prompts, %{
               "name" => "weather",
               "arguments" => [%{"name" => "city", "required" => true}],
               "icons" => [%{"src" => "https://example.com/icon.png"}]
             }) == {:ok, expected}
    end

    test "resources" do
      expected = %Resource{
        uri: "file:///a",
        name: "a",
        annotations: %Annotations{audience: ["assistant"]}
      }

      assert Normalize.entity(:resources, expected) == {:ok, expected}

      assert Normalize.entity(:resources, %{
               uri: "file:///a",
               name: "a",
               annotations: %{audience: ["assistant"]}
             }) == {:ok, expected}

      assert Normalize.entity(:resources, %{
               "uri" => "file:///a",
               "name" => "a",
               "annotations" => %{"audience" => ["assistant"]}
             }) == {:ok, expected}
    end

    test "templates" do
      expected = %ResourceTemplate{
        uriTemplate: "file:///{path}",
        name: "files",
        annotations: %Annotations{priority: 0.5}
      }

      assert Normalize.entity(:templates, expected) == {:ok, expected}

      assert Normalize.entity(:templates, %{
               uriTemplate: "file:///{path}",
               name: "files",
               annotations: %{priority: 0.5}
             }) == {:ok, expected}

      assert Normalize.entity(:templates, %{
               "uriTemplate" => "file:///{path}",
               "name" => "files",
               "annotations" => %{"priority" => 0.5}
             }) == {:ok, expected}
    end
  end

  describe "nested values" do
    test "execution becomes a struct and taskSupport an atom" do
      expected = %Tool{
        name: "get",
        inputSchema: %{},
        execution: %ToolExecution{taskSupport: :optional}
      }

      assert Normalize.entity(:tools, %{
               "name" => "get",
               "inputSchema" => %{},
               "execution" => %{"taskSupport" => "optional"}
             }) == {:ok, expected}

      assert Normalize.entity(:tools, %{
               name: "get",
               inputSchema: %{},
               execution: %{taskSupport: :required}
             }) == {:ok, %{expected | execution: %ToolExecution{taskSupport: :required}}}
    end

    test "annotations of a tool are ToolAnnotations" do
      expected = %Tool{
        name: "get",
        inputSchema: %{},
        annotations: %ToolAnnotations{title: "Get", readOnlyHint: true}
      }

      assert Normalize.entity(:tools, %{
               name: "get",
               inputSchema: %{},
               annotations: %{title: "Get", readOnlyHint: true}
             }) == {:ok, expected}
    end

    test "a struct with nested maps is converted" do
      expected = %Tool{
        name: "get",
        inputSchema: %{},
        icons: [%Icon{src: "https://example.com/icon.png"}]
      }

      assert Normalize.entity(:tools, %Tool{
               name: "get",
               icons: [%{src: "https://example.com/icon.png"}]
             }) == {:ok, expected}
    end

    test "an invalid taskSupport is an error" do
      assert {:error, reason} =
               Normalize.entity(:tools, %{
                 name: "get",
                 inputSchema: %{},
                 execution: %{taskSupport: "sometimes"}
               })

      assert reason =~ "task_support"
    end

    test "an improper list in a list field is an error that names the field" do
      assert {:error, "icons must be a list"} =
               Normalize.entity(:tools, %{name: "get", inputSchema: %{}, icons: [1 | 2]})

      assert {:error, "arguments must be a list"} =
               Normalize.entity(:prompts, %{name: "weather", arguments: [1 | 2]})
    end

    test "a value that is not a list in a list field is an error that names the field" do
      assert {:error, "icons must be a list"} =
               Normalize.entity(:tools, %{name: "get", inputSchema: %{}, icons: 1})

      assert {:error, "arguments must be a list"} =
               Normalize.entity(:prompts, %{name: "weather", arguments: "city"})
    end
  end

  describe "unknown keys" do
    test "a top-level unknown key goes to extras" do
      assert {:ok, tool} =
               Normalize.entity(:tools, %{name: "get", inputSchema: %{}, vendor: 1})

      assert tool.extras == %{vendor: 1}

      assert {:ok, tool} =
               Normalize.entity(:tools, %{"name" => "get", "inputSchema" => %{}, "vendor" => 1})

      assert tool.extras == %{"vendor" => 1}
    end

    test "an explicit extras map is kept and merged with the unknown keys" do
      assert {:ok, tool} =
               Normalize.entity(:tools, %{
                 name: "get",
                 inputSchema: %{},
                 extras: %{"vendor" => 1},
                 other: 2
               })

      assert tool.extras == %{"vendor" => 1, other: 2}
    end

    test "a nested unknown key is an error with its path" do
      assert {:error, reason} =
               Normalize.entity(:tools, %{
                 name: "get",
                 inputSchema: %{},
                 execution: %{taskSupport: "optional", custom: 1}
               })

      assert reason =~ "execution.custom"

      assert {:error, reason} =
               Normalize.entity(:tools, %{
                 name: "get",
                 inputSchema: %{},
                 icons: [%{src: "https://example.com/icon.png", custom: 1}]
               })

      assert reason =~ "icons[0].custom"
    end
  end

  describe "required_scopes" do
    test "a map reads the scopes of both key forms" do
      assert {:ok, tool} =
               Normalize.entity(:tools, %{
                 name: "get",
                 inputSchema: %{},
                 required_scopes: ["tools:write"]
               })

      assert tool.required_scopes == ["tools:write"]

      assert {:ok, tool} =
               Normalize.entity(:tools, %{
                 "name" => "get",
                 "inputSchema" => %{},
                 "required_scopes" => ["tools:write"]
               })

      assert tool.required_scopes == ["tools:write"]
    end

    test "a struct keeps the scopes of its field" do
      assert {:ok, tool} =
               Normalize.entity(:tools, %Tool{
                 name: "get",
                 inputSchema: %{},
                 required_scopes: ["tools:read"]
               })

      assert tool.required_scopes == ["tools:read"]
    end

    test "a bad value is an error" do
      assert {:error, _} =
               Normalize.entity(:tools, %{name: "get", inputSchema: %{}, required_scopes: []})

      assert {:error, _} =
               Normalize.entity(:tools, %{name: "get", inputSchema: %{}, required_scopes: "a"})
    end
  end

  describe "errors" do
    test "a bad field names the field" do
      assert {:error, reason} = Normalize.entity(:tools, %{name: "", inputSchema: %{}})
      assert reason =~ "name"
    end

    test "a struct of the wrong kind is an error" do
      assert {:error, _} = Normalize.entity(:tools, %Prompt{name: "weather"})
    end

    test "a nested struct of the wrong kind is an error" do
      assert {:error, _} =
               Normalize.entity(:resources, %{
                 uri: "file:///a",
                 name: "a",
                 annotations: %ToolAnnotations{title: "a"}
               })
    end

    test "a value that is not a map is an error" do
      assert {:error, _} = Normalize.entity(:tools, "get")
    end

    test "a term that is not JSON is an error with its path" do
      assert {:error, "the entry is not JSON at x: {1, 2} is not a JSON term"} =
               Normalize.entity(:tools, %{name: "get", extras: %{"x" => {1, 2}}})

      assert {:error, "the entry is not JSON at foo: " <> _} =
               Normalize.entity(:resources, %{"foo" => self(), :name => "a", :uri => "file:///a"})

      assert {:error, "the entry is not JSON at _meta.k: struct URI" <> _} =
               Normalize.entity(:prompts, %{name: "p", _meta: %{"k" => URI.parse("x:y")}})

      assert {:error, reason} =
               Normalize.entity(:tools, %{
                 name: "get",
                 inputSchema: %{type: "object", properties: %{x: %{"default" => <<255>>}}}
               })

      assert reason =~ "inputSchema.properties.x.default: a string that is not valid UTF-8"
    end
  end

  describe "entity_and_wire/2" do
    test "gives the struct and the map that its build gave" do
      assert {:ok, struct, wire} =
               Normalize.entity_and_wire(:tools, %{
                 name: "get",
                 inputSchema: %{type: "object"},
                 icons: [%{src: "https://example.com/icon.png"}]
               })

      assert struct == %Tool{
               name: "get",
               inputSchema: %{type: "object"},
               icons: [%Icon{src: "https://example.com/icon.png"}]
             }

      assert wire == Tool.build(struct)
    end

    test "a struct entry gives the same pair as a map entry" do
      expected =
        Normalize.entity_and_wire(:tools, %{name: "get", inputSchema: %{type: "object"}})

      assert Normalize.entity_and_wire(:tools, %Tool{name: "get", inputSchema: %{type: "object"}}) ==
               expected
    end

    test "gives the same error as entity/2" do
      assert {:error, reason} = Normalize.entity_and_wire(:tools, %{name: "", inputSchema: %{}})
      assert {:error, ^reason} = Normalize.entity(:tools, %{name: "", inputSchema: %{}})
    end
  end

  test "a string key never becomes an atom" do
    keys = for index <- 1..200, do: "vendor_#{System.unique_integer([:positive])}_#{index}"

    Normalize.entity(:tools, %{
      "name" => "warmup",
      "inputSchema" => %{},
      "required_scopes" => ["tools:read"]
    })

    before_count = :erlang.system_info(:atom_count)

    for key <- keys do
      assert {:ok, %Tool{extras: extras}} =
               Normalize.entity(:tools, %{"name" => "get", "inputSchema" => %{}, key => 1})

      assert Map.keys(extras) == [key]
    end

    assert :erlang.system_info(:atom_count) == before_count
  end
end
