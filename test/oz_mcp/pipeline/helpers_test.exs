defmodule OzMcp.Pipeline.HelpersTest do
  use ExUnit.Case, async: true

  alias OzMcp.Pipeline.Helpers

  describe "completion_ref/1" do
    test "accepts a prompt reference" do
      assert Helpers.completion_ref(%{"ref" => %{"type" => "ref/prompt", "name" => "greet"}}) ==
               {:ok, {:prompt, "greet"}}
    end

    test "accepts a resource reference" do
      assert Helpers.completion_ref(%{
               "ref" => %{"type" => "ref/resource", "uri" => "file:///a.txt"}
             }) == {:ok, {:resource, "file:///a.txt"}}
    end

    test "refuses an empty name" do
      assert Helpers.completion_ref(%{"ref" => %{"type" => "ref/prompt", "name" => ""}}) ==
               {:error, :rpc_invalid_ref}
    end

    test "refuses a reference of another type" do
      assert Helpers.completion_ref(%{"ref" => %{"type" => "ref/other", "name" => "greet"}}) ==
               {:error, :rpc_invalid_ref}
    end

    test "refuses a reference with no name" do
      assert Helpers.completion_ref(%{"ref" => %{"type" => "ref/prompt"}}) ==
               {:error, :rpc_invalid_ref}
    end
  end

  describe "deep/2" do
    test "gives nil for nil" do
      assert Helpers.deep(nil, [:a]) == nil
    end

    test "gives nil for a missing key" do
      assert Helpers.deep(%{a: 1}, [:b]) == nil
      assert Helpers.deep(%{a: %{b: 1}}, [:a, :c, :d]) == nil
    end

    test "gives nil for a value that is not a map" do
      assert Helpers.deep(%{a: "text"}, [:a, :b]) == nil
    end

    test "finds a string key from an atom path" do
      assert Helpers.deep(%{"a" => %{"b" => 2}}, [:a, :b]) == 2
    end

    test "gives the value at an empty path" do
      map = %{a: 1}
      assert Helpers.deep(map, []) == map
    end
  end

  describe "type_name/1" do
    test "names each JSON type" do
      assert Helpers.type_name("text") == "string"
      assert Helpers.type_name(1) == "integer"
      assert Helpers.type_name(1.5) == "float"
      assert Helpers.type_name(true) == "boolean"
      assert Helpers.type_name([1]) == "array"
      assert Helpers.type_name(%{}) == "object"
    end

    test "names another value unknown" do
      assert Helpers.type_name(:atom) == "unknown"
      assert Helpers.type_name(nil) == "unknown"
    end
  end

  describe "tasks_capability_of/1" do
    test "reads the tasks capability from atom keys and from string keys" do
      assert Helpers.tasks_capability_of(%{tasks: %{list: %{}}}) == %{list: %{}}
      assert Helpers.tasks_capability_of(%{"tasks" => %{list: %{}}}) == %{list: %{}}
    end

    test "gives nil when there is no capability" do
      assert Helpers.tasks_capability_of(nil) == nil
      assert Helpers.tasks_capability_of(%{tools: %{}}) == nil
    end
  end

  describe "task_support_of/1" do
    test "reads the execution of a tool struct" do
      assert Helpers.task_support_of(%OzMcp.Structs.Tool{
               name: "t",
               execution: %OzMcp.Structs.ToolExecution{taskSupport: :optional}
             }) == :optional

      assert Helpers.task_support_of(%OzMcp.Structs.Tool{
               name: "t",
               execution: %OzMcp.Structs.ToolExecution{taskSupport: :required}
             }) == :required

      assert Helpers.task_support_of(%OzMcp.Structs.Tool{name: "t"}) == :forbidden

      assert Helpers.task_support_of(%{execution: %{taskSupport: :optional}}) == :optional

      assert Helpers.task_support_of(%{}) == :forbidden
      assert Helpers.task_support_of(nil) == :forbidden
    end

    test "gives forbidden when there is no task support" do
      assert Helpers.task_support_of(%{execution: %{}}) == :forbidden
      assert Helpers.task_support_of(%{execution: nil}) == :forbidden
      assert Helpers.task_support_of(%{execution: %{taskSupport: nil}}) == :forbidden
    end

    test "reads a string-key map tool after normalization" do
      raw = %{
        "name" => "slow",
        "inputSchema" => %{"type" => "object"},
        "execution" => %{"taskSupport" => "optional", "poll_interval" => 100}
      }

      assert {:ok, tool} = OzMcp.Catalog.Normalize.entity(:tools, raw)
      assert Helpers.task_support_of(tool) == :optional
    end
  end

  describe "tools_call_task_capable?/1" do
    test "needs requests.tools.call" do
      refute Helpers.tools_call_task_capable?(nil)
      refute Helpers.tools_call_task_capable?(%{list: %{}, cancel: %{}})
      assert Helpers.tools_call_task_capable?(%{requests: %{tools: %{call: %{}}}})
      assert Helpers.tools_call_task_capable?(%{"requests" => %{"tools" => %{"call" => %{}}}})
    end
  end
end
