defmodule OzMcp.Structs.ValidateTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.{Task, Validate}

  describe "non_empty_string/2" do
    test "returns :ok for a non-empty string" do
      assert Validate.non_empty_string(:taskId, "abc") == :ok
    end

    test "raises ArgumentError when value is not a string" do
      assert_raise ArgumentError, "The 'taskId' field is required and must be a string", fn ->
        Validate.non_empty_string(:taskId, 123)
      end
    end

    test "raises ArgumentError when value is nil" do
      assert_raise ArgumentError, "The 'taskId' field is required and must be a string", fn ->
        Validate.non_empty_string(:taskId, nil)
      end
    end

    test "raises ArgumentError when value is an empty string" do
      assert_raise ArgumentError, "The 'taskId' field cannot be an empty string", fn ->
        Validate.non_empty_string(:taskId, "")
      end
    end

    test "uses the provided field name in the message" do
      assert_raise ArgumentError, "The 'name' field cannot be an empty string", fn ->
        Validate.non_empty_string(:name, "")
      end
    end
  end

  describe "non_empty_string_or_nil/2" do
    test "returns :ok for a non-empty string" do
      assert Validate.non_empty_string_or_nil(:statusMessage, "msg") == :ok
    end

    test "returns :ok for nil" do
      assert Validate.non_empty_string_or_nil(:statusMessage, nil) == :ok
    end

    test "raises ArgumentError for an empty string" do
      assert_raise ArgumentError, "The 'statusMessage' field cannot be an empty string", fn ->
        Validate.non_empty_string_or_nil(:statusMessage, "")
      end
    end

    test "raises ArgumentError when value is not a string or nil" do
      assert_raise ArgumentError, "The 'statusMessage' field must be a string or nil", fn ->
        Validate.non_empty_string_or_nil(:statusMessage, 42)
      end
    end

    test "raises ArgumentError for a list value" do
      assert_raise ArgumentError, "The 'statusMessage' field must be a string or nil", fn ->
        Validate.non_empty_string_or_nil(:statusMessage, ["a"])
      end
    end
  end

  describe "string_or_nil/2" do
    test "returns :ok for a string" do
      assert Validate.string_or_nil(:default, "abc") == :ok
      assert Validate.string_or_nil(:default, "") == :ok
    end

    test "returns :ok for nil" do
      assert Validate.string_or_nil(:default, nil) == :ok
    end

    test "raises ArgumentError when value is not a string or nil" do
      assert_raise ArgumentError, "The 'default' field must be a string or nil", fn ->
        Validate.string_or_nil(:default, 42)
      end
    end
  end

  describe "one_of/3" do
    test "returns :ok when value is in allowed list" do
      assert Validate.one_of(:status, :working, [:working, :completed]) == :ok
    end

    test "raises ArgumentError when value is not in allowed list" do
      assert_raise ArgumentError,
                   "The 'status' field must be one of [:working, :completed]",
                   fn ->
                     Validate.one_of(:status, :unknown, [:working, :completed])
                   end
    end

    test "raises ArgumentError for nil value" do
      assert_raise ArgumentError, "The 'status' field must be one of [:a, :b]", fn ->
        Validate.one_of(:status, nil, [:a, :b])
      end
    end
  end

  describe "non_neg_integer_or_nil/2" do
    test "returns :ok for a non-negative integer" do
      assert Validate.non_neg_integer_or_nil(:ttl, 0) == :ok
      assert Validate.non_neg_integer_or_nil(:ttl, 100) == :ok
    end

    test "returns :ok for nil" do
      assert Validate.non_neg_integer_or_nil(:ttl, nil) == :ok
    end

    test "raises ArgumentError for a negative integer" do
      assert_raise ArgumentError, "The 'ttl' field must be a non-negative integer or nil", fn ->
        Validate.non_neg_integer_or_nil(:ttl, -1)
      end
    end

    test "raises ArgumentError for a non-integer value" do
      assert_raise ArgumentError, "The 'ttl' field must be a non-negative integer or nil", fn ->
        Validate.non_neg_integer_or_nil(:ttl, "100")
      end
    end

    test "raises ArgumentError for a float value" do
      assert_raise ArgumentError, "The 'ttl' field must be a non-negative integer or nil", fn ->
        Validate.non_neg_integer_or_nil(:ttl, 1.5)
      end
    end
  end

  describe "boolean_or_nil/2" do
    test "returns :ok for true" do
      assert Validate.boolean_or_nil(:isError, true) == :ok
    end

    test "returns :ok for false" do
      assert Validate.boolean_or_nil(:isError, false) == :ok
    end

    test "returns :ok for nil" do
      assert Validate.boolean_or_nil(:isError, nil) == :ok
    end

    test "raises ArgumentError for an integer" do
      assert_raise ArgumentError, "The 'isError' field must be a boolean or nil", fn ->
        Validate.boolean_or_nil(:isError, 1)
      end
    end

    test "raises ArgumentError for a string" do
      assert_raise ArgumentError, "The 'isError' field must be a boolean or nil", fn ->
        Validate.boolean_or_nil(:isError, "true")
      end
    end
  end

  describe "map_or_nil/2" do
    test "returns :ok for a map" do
      assert Validate.map_or_nil(:_meta, %{"key" => "value"}) == :ok
      assert Validate.map_or_nil(:_meta, %{}) == :ok
    end

    test "returns :ok for nil" do
      assert Validate.map_or_nil(:_meta, nil) == :ok
    end

    test "raises ArgumentError for a list" do
      assert_raise ArgumentError, "The '_meta' field must be a map or nil", fn ->
        Validate.map_or_nil(:_meta, [1, 2])
      end
    end

    test "raises ArgumentError for an integer" do
      assert_raise ArgumentError, "The '_meta' field must be a map or nil", fn ->
        Validate.map_or_nil(:_meta, 42)
      end
    end
  end

  describe "map/2" do
    test "returns :ok for a map" do
      assert Validate.map(:input, %{"key" => "value"}) == :ok
      assert Validate.map(:input, %{}) == :ok
    end

    test "raises ArgumentError for nil" do
      assert_raise ArgumentError, "The 'input' field is required and must be a map", fn ->
        Validate.map(:input, nil)
      end
    end

    test "raises ArgumentError for a list" do
      assert_raise ArgumentError, "The 'input' field is required and must be a map", fn ->
        Validate.map(:input, [1, 2])
      end
    end
  end

  describe "list/2" do
    test "returns :ok for a list" do
      assert Validate.list(:tasks, []) == :ok
      assert Validate.list(:tasks, [:a, :b]) == :ok
    end

    test "raises ArgumentError for a non-list value" do
      assert_raise ArgumentError, "The 'tasks' field must be a list", fn ->
        Validate.list(:tasks, "not a list")
      end
    end

    test "raises ArgumentError for a map value" do
      assert_raise ArgumentError, "The 'tasks' field must be a list", fn ->
        Validate.list(:tasks, %{})
      end
    end

    test "raises ArgumentError for nil" do
      assert_raise ArgumentError, "The 'tasks' field must be a list", fn ->
        Validate.list(:tasks, nil)
      end
    end
  end

  describe "list_or_nil/2" do
    test "returns :ok for a list" do
      assert Validate.list_or_nil(:icons, []) == :ok
      assert Validate.list_or_nil(:icons, [:a, :b]) == :ok
    end

    test "returns :ok for nil" do
      assert Validate.list_or_nil(:icons, nil) == :ok
    end

    test "raises ArgumentError for a non-list value" do
      assert_raise ArgumentError, "The 'icons' field must be a list or nil", fn ->
        Validate.list_or_nil(:icons, "not a list")
      end
    end

    test "raises ArgumentError for a map value" do
      assert_raise ArgumentError, "The 'icons' field must be a list or nil", fn ->
        Validate.list_or_nil(:icons, %{})
      end
    end
  end

  describe "struct/3" do
    test "returns :ok for the correct struct" do
      assert Validate.struct(:task, Task, %Task{}) == :ok
    end

    test "raises ArgumentError for nil" do
      assert_raise ArgumentError,
                   "The 'task' field is required and must be a OzMcp.Structs.Task struct",
                   fn ->
                     Validate.struct(:task, Task, nil)
                   end
    end

    test "raises ArgumentError for the wrong struct" do
      assert_raise ArgumentError,
                   "The 'task' field is required and must be a OzMcp.Structs.Task struct",
                   fn ->
                     alias OzMcp.Structs.Annotations
                     Validate.struct(:task, Task, %Annotations{})
                   end
    end

    test "raises ArgumentError for a plain map" do
      assert_raise ArgumentError,
                   "The 'task' field is required and must be a OzMcp.Structs.Task struct",
                   fn ->
                     Validate.struct(:task, Task, %{foo: "bar"})
                   end
    end

    test "raises ArgumentError for an integer" do
      assert_raise ArgumentError,
                   "The 'task' field is required and must be a OzMcp.Structs.Task struct",
                   fn ->
                     Validate.struct(:task, Task, 42)
                   end
    end
  end

  describe "struct_or_nil/3" do
    test "returns :ok for the correct struct" do
      assert Validate.struct_or_nil(:task, Task, %Task{}) == :ok
    end

    test "returns :ok for nil" do
      assert Validate.struct_or_nil(:task, Task, nil) == :ok
    end

    test "raises ArgumentError for the wrong struct" do
      assert_raise ArgumentError,
                   "The 'task' field must be a OzMcp.Structs.Task struct or nil",
                   fn ->
                     alias OzMcp.Structs.Annotations
                     Validate.struct_or_nil(:task, Task, %Annotations{})
                   end
    end

    test "raises ArgumentError for a plain map" do
      assert_raise ArgumentError,
                   "The 'task' field must be a OzMcp.Structs.Task struct or nil",
                   fn ->
                     Validate.struct_or_nil(:task, Task, %{foo: "bar"})
                   end
    end

    test "raises ArgumentError for an integer" do
      assert_raise ArgumentError,
                   "The 'task' field must be a OzMcp.Structs.Task struct or nil",
                   fn ->
                     Validate.struct_or_nil(:task, Task, 42)
                   end
    end
  end

  describe "task/1" do
    test "returns :ok for a Task struct" do
      assert Validate.task(%Task{}) == :ok
    end

    test "raises ArgumentError for nil" do
      assert_raise ArgumentError, "The 'task' field is required", fn ->
        Validate.task(nil)
      end
    end

    test "raises ArgumentError for a non-Task value" do
      assert_raise ArgumentError,
                   ~s(The 'task' field must be a OzMcp.Structs.Task struct, got: "nope"),
                   fn ->
                     Validate.task("nope")
                   end
    end

    test "raises ArgumentError for a map value" do
      assert_raise ArgumentError,
                   ~s(The 'task' field must be a OzMcp.Structs.Task struct, got: %{foo: "bar"}),
                   fn ->
                     Validate.task(%{foo: "bar"})
                   end
    end
  end

  describe "number_or_nil/2" do
    test "accepts numbers and nil" do
      assert :ok = Validate.number_or_nil(:f, 1)
      assert :ok = Validate.number_or_nil(:f, 1.5)
      assert :ok = Validate.number_or_nil(:f, nil)
    end

    test "rejects anything else" do
      assert_raise ArgumentError, ~r/'f' field must be a number or nil/, fn ->
        Validate.number_or_nil(:f, "1")
      end
    end
  end

  describe "number_between_or_nil/4" do
    test "accepts nil and numbers inside the limits, limits included" do
      assert :ok = Validate.number_between_or_nil(:f, nil, 0, 1)
      assert :ok = Validate.number_between_or_nil(:f, 0, 0, 1)
      assert :ok = Validate.number_between_or_nil(:f, 0.5, 0, 1)
      assert :ok = Validate.number_between_or_nil(:f, 1, 0, 1)
    end

    test "rejects numbers outside the limits and non numbers" do
      for value <- [-0.1, 1.1, "0.5", :half] do
        assert_raise ArgumentError, ~r/between 0 and 1/, fn ->
          Validate.number_between_or_nil(:f, value, 0, 1)
        end
      end
    end
  end

  describe "one_of_or_nil/3" do
    test "accepts nil and an allowed value" do
      assert :ok = Validate.one_of_or_nil(:f, nil, [:a])
      assert :ok = Validate.one_of_or_nil(:f, :a, [:a])
    end

    test "rejects another value" do
      assert_raise ArgumentError, ~r/'f' field must be one of/, fn ->
        Validate.one_of_or_nil(:f, :b, [:a])
      end
    end
  end

  describe "input_schema/1" do
    test "accepts the empty map" do
      assert Validate.input_schema(%{}) == :ok
    end

    test "accepts a schema with the object type" do
      assert Validate.input_schema(%{type: :object}) == :ok
      assert Validate.input_schema(%{type: "object"}) == :ok
      assert Validate.input_schema(%{"type" => "object"}) == :ok
    end

    test "raises ArgumentError for nil" do
      assert_raise ArgumentError, "The 'inputSchema' field must be a map, got: nil", fn ->
        Validate.input_schema(nil)
      end
    end

    test "raises ArgumentError for a string" do
      assert_raise ArgumentError, ~s(The 'inputSchema' field must be a map, got: "x"), fn ->
        Validate.input_schema("x")
      end
    end

    test "raises ArgumentError when the root type is not object" do
      assert_raise ArgumentError,
                   ~s(The 'inputSchema' field the root must have type: "object", got: "string"),
                   fn ->
                     Validate.input_schema(%{type: "string"})
                   end
    end
  end

  describe "output_schema_or_nil/1" do
    test "accepts nil" do
      assert Validate.output_schema_or_nil(nil) == :ok
    end

    test "accepts a schema with the object type" do
      assert Validate.output_schema_or_nil(%{"type" => "object"}) == :ok
    end

    test "raises ArgumentError when the root type is not object" do
      assert_raise ArgumentError,
                   ~s(The 'outputSchema' field the root must have type: "object", got: nil),
                   fn ->
                     Validate.output_schema_or_nil(%{})
                   end
    end

    test "raises ArgumentError for a value that is not a map" do
      assert_raise ArgumentError, "The 'outputSchema' field must be a map, got: 42", fn ->
        Validate.output_schema_or_nil(42)
      end
    end
  end

  describe "iso8601_or_nil/2" do
    test "accepts nil" do
      assert Validate.iso8601_or_nil(:lastModified, nil) == :ok
    end

    test "accepts a date and time with an offset" do
      assert Validate.iso8601_or_nil(:lastModified, "2025-01-12T15:00:58Z") == :ok
    end

    test "raises ArgumentError for a date with no time" do
      assert_raise ArgumentError,
                   ~r/The 'lastModified' field must be an ISO 8601 date and time/,
                   fn ->
                     Validate.iso8601_or_nil(:lastModified, "2025-01-12")
                   end
    end

    test "raises ArgumentError for a value that is not a string" do
      assert_raise ArgumentError,
                   ~r/The 'lastModified' field must be an ISO 8601 date and time/,
                   fn ->
                     Validate.iso8601_or_nil(:lastModified, 42)
                   end
    end
  end

  describe "absolute_uri/2" do
    test "accepts an absolute URI" do
      assert Validate.absolute_uri(:uri, "file:///logs/app.log") == :ok
    end

    test "raises ArgumentError for a value with no scheme" do
      assert_raise ArgumentError,
                   ~s(The 'uri' field must be an absolute URI with a scheme, got: "notes/1"),
                   fn ->
                     Validate.absolute_uri(:uri, "notes/1")
                   end
    end
  end

  describe "icon_src/2" do
    test "accepts an https URL" do
      assert Validate.icon_src(:src, "https://a.com/a.png") == :ok
    end

    test "raises ArgumentError for a public http host" do
      assert_raise ArgumentError,
                   ~s(The 'src' field must be an https: URL, an http: URL of a loopback host, or a data: URI, got: "http://example.com/a.png"),
                   fn ->
                     Validate.icon_src(:src, "http://example.com/a.png")
                   end
    end
  end

  describe "icon_sizes_or_nil/2" do
    test "accepts nil" do
      assert Validate.icon_sizes_or_nil(:sizes, nil) == :ok
    end

    test "accepts valid sizes" do
      assert Validate.icon_sizes_or_nil(:sizes, ["48x48", "any"]) == :ok
    end

    test "raises ArgumentError for a bad entry" do
      assert_raise ArgumentError,
                   ~s(The 'sizes' field must be "any" or a "WxH" string such as "48x48", got: "48"),
                   fn ->
                     Validate.icon_sizes_or_nil(:sizes, ["48x48", "48"])
                   end
    end

    test "raises ArgumentError for an entry that is not a string" do
      assert_raise ArgumentError,
                   ~s(The 'sizes' field must be "any" or a "WxH" string such as "48x48", got: 48),
                   fn ->
                     Validate.icon_sizes_or_nil(:sizes, [48])
                   end
    end
  end

  describe "content/1" do
    test "accepts a map with a non-empty string type" do
      assert Validate.content(%{"type" => "text", "text" => "x"}) == :ok
      assert Validate.content(%{type: "text", text: "x"}) == :ok
    end

    test "accepts a map with an atom type that is not nil, true or false" do
      assert Validate.content(%{type: :custom}) == :ok
    end

    test "a block whose type names a content struct is checked with its build" do
      for block <- [
            %{type: "text"},
            %{type: :text},
            %{type: "text", text: 1},
            %{"type" => "image"},
            %{type: "audio", data: "x"},
            %{type: "resource_link", uri: "file:///a"},
            %{type: "resource", resource: %{uri: "file:///a"}}
          ] do
        assert_raise ArgumentError, fn -> Validate.content(block) end
      end
    end

    test "a block with a known type and an unknown key still passes" do
      assert Validate.content(%{type: "text", text: "x", vendor: 1}) == :ok
      assert Validate.content(%{"type" => "text", "text" => "x", "vendor" => 1}) == :ok
    end

    test "raises for a map with no type, an empty type, or a boolean type" do
      for block <- [
            %{},
            %{"text" => "x"},
            %{type: ""},
            %{type: nil},
            %{type: true},
            %{type: false}
          ] do
        assert_raise ArgumentError, ~r/a content block map needs a 'type'/, fn ->
          Validate.content(block)
        end
      end
    end

    test "raises for a value that is not a struct or a map" do
      assert_raise ArgumentError, ~r/The 'content' field is required and must be one of/, fn ->
        Validate.content("text")
      end
    end
  end

  describe "resource_contents/2" do
    test "checks a map with a text as text contents" do
      assert Validate.resource_contents(%{uri: "file:///a", text: "x"}, "contents[0]") == :ok

      assert_raise ArgumentError, "The 'uri' field cannot be an empty string", fn ->
        Validate.resource_contents(%{text: "x"}, "contents[0]")
      end
    end

    test "checks a map with a blob as blob contents" do
      assert Validate.resource_contents(%{uri: "file:///a", blob: "x"}, "contents[0]") == :ok

      assert_raise ArgumentError, "The 'blob' field is required and must be a string", fn ->
        Validate.resource_contents(%{uri: "file:///a", blob: 1}, "contents[0]")
      end
    end

    test "raises for a map with neither a text nor a blob" do
      assert_raise ArgumentError, "contents[2] needs a 'text' or a 'blob'", fn ->
        Validate.resource_contents(%{uri: "file:///a"}, "contents[2]")
      end
    end
  end

  describe "meta/2" do
    test "returns :ok for a map with valid keys" do
      assert Validate.meta(:_meta, %{"key" => "value"}) == :ok
      assert Validate.meta(:_meta, %{}) == :ok
    end

    test "returns :ok for nil" do
      assert Validate.meta(:_meta, nil) == :ok
    end

    test "raises ArgumentError for a list" do
      assert_raise ArgumentError, "The '_meta' field must be a map or nil", fn ->
        Validate.meta(:_meta, [1, 2])
      end
    end

    test "raises ArgumentError for a bad key" do
      assert_raise ArgumentError, "The '_meta' field bad _meta key \"a b\": bad name", fn ->
        Validate.meta(:_meta, %{"a b" => 1})
      end
    end

    test "raises ArgumentError for a reserved prefix" do
      assert_raise ArgumentError,
                   "The '_meta' field the _meta prefix of \"dev.mcp/x\" is reserved",
                   fn ->
                     Validate.meta(:_meta, %{"dev.mcp/x" => 1})
                   end
    end

    test "accepts the key that the framework writes" do
      assert Validate.meta(:_meta, %{"io.modelcontextprotocol/related-task" => "t"}) == :ok
    end
  end
end
