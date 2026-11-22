defmodule OzMcp.Tasks.RelatedTaskTest do
  use ExUnit.Case, async: true

  alias OzMcp.Tasks.RelatedTask

  @key "io.modelcontextprotocol/related-task"

  describe "key/0" do
    test "returns the metadata key" do
      assert RelatedTask.key() == @key
    end
  end

  describe "meta/1" do
    test "builds the _meta map of a task" do
      assert RelatedTask.meta("t1") == %{@key => %{"taskId" => "t1"}}
    end

    test "accepts any binary id" do
      assert RelatedTask.meta("") == %{@key => %{"taskId" => ""}}
    end
  end

  describe "put/3" do
    test "adds the metadata to params without _meta" do
      assert RelatedTask.put(%{"a" => 1}, "t1") == %{
               "a" => 1,
               "_meta" => %{@key => %{"taskId" => "t1"}}
             }
    end

    test "keeps the existing _meta entries" do
      assert RelatedTask.put(%{"_meta" => %{"x" => 1}}, "t1") == %{
               "_meta" => %{"x" => 1, @key => %{"taskId" => "t1"}}
             }
    end

    test "moves the entries of the atom key _meta to the string key" do
      assert RelatedTask.put(%{_meta: %{"x" => 1}}, "t1") == %{
               "_meta" => %{"x" => 1, @key => %{"taskId" => "t1"}}
             }
    end

    test "does not keep the atom key _meta after the merge" do
      params = RelatedTask.put(%{_meta: %{"x" => 1}}, "t1")
      refute Map.has_key?(params, :_meta)
    end

    test "keeps the entries of both keys when they differ" do
      assert RelatedTask.put(%{"_meta" => %{"s" => 1}, :_meta => %{"a" => 2}}, "t1") == %{
               "_meta" => %{"s" => 1, "a" => 2, @key => %{"taskId" => "t1"}}
             }
    end

    test "the atom key wins when both keys hold the same entry" do
      assert RelatedTask.put(%{"_meta" => %{"x" => "string"}, :_meta => %{"x" => "atom"}}, "t1") ==
               %{
                 "_meta" => %{"x" => "atom", @key => %{"taskId" => "t1"}}
               }
    end

    test "ignores a _meta value that is not a map" do
      assert RelatedTask.put(%{"_meta" => "bad"}, "t1") == %{
               "_meta" => %{@key => %{"taskId" => "t1"}}
             }

      assert RelatedTask.put(%{_meta: 42}, "t1") == %{
               "_meta" => %{@key => %{"taskId" => "t1"}}
             }
    end

    test "writes under :_meta when asked" do
      assert RelatedTask.put(%{}, "t1", :_meta) == %{
               :_meta => %{@key => %{"taskId" => "t1"}}
             }
    end

    test "keeps the existing :_meta entries under :_meta" do
      assert RelatedTask.put(%{_meta: %{"x" => 1}}, "t1", :_meta) == %{
               :_meta => %{"x" => 1, @key => %{"taskId" => "t1"}}
             }
    end

    test "gives params back when the task id is nil" do
      assert RelatedTask.put(%{"a" => 1}, nil) == %{"a" => 1}
    end

    test "gives nil params back when the task id is nil" do
      assert RelatedTask.put(nil, nil) == nil
    end

    test "treats nil params as an empty map" do
      assert RelatedTask.put(nil, "t1") == %{"_meta" => %{@key => %{"taskId" => "t1"}}}
    end

    test "overwrites a previous related-task entry with the new task id" do
      params = %{"_meta" => %{@key => %{"taskId" => "old"}}}

      assert RelatedTask.put(params, "new") == %{
               "_meta" => %{@key => %{"taskId" => "new"}}
             }
    end
  end
end
