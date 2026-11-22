defmodule OzMcp.Structs.CreateTaskResultTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.{CreateTaskResult, Task}

  defp build_task do
    %Task{
      taskId: "task-1",
      status: :working,
      createdAt: "2024-01-01T00:00:00Z",
      lastUpdatedAt: "2024-01-02T00:00:00Z"
    }
  end

  describe "struct defaults" do
    test "has correct defaults for all fields" do
      result = %CreateTaskResult{}

      assert result.task == %Task{}
      assert result._meta == nil
      assert result.extras == nil
    end
  end

  describe "task/2" do
    test "sets task field" do
      task = build_task()
      result = CreateTaskResult.task(%CreateTaskResult{}, task)

      assert result.task == task
    end
  end

  describe "_meta/2" do
    test "sets _meta field" do
      result = CreateTaskResult._meta(%CreateTaskResult{}, %{"token" => 1})

      assert result._meta == %{"token" => 1}
    end

    test "accepts nil for _meta field" do
      result = CreateTaskResult._meta(%CreateTaskResult{}, nil)

      assert result._meta == nil
    end
  end

  describe "extras/2" do
    test "sets extras field" do
      result = CreateTaskResult.extras(%CreateTaskResult{}, %{"custom" => "field"})

      assert result.extras == %{"custom" => "field"}
    end

    test "accepts nil for extras field" do
      result = CreateTaskResult.extras(%CreateTaskResult{}, nil)

      assert result.extras == nil
    end
  end

  describe "build/1" do
    test "builds with a task" do
      result = CreateTaskResult.build(%CreateTaskResult{task: build_task()})

      assert result == %{
               task: %{
                 taskId: "task-1",
                 status: "working",
                 createdAt: "2024-01-01T00:00:00Z",
                 lastUpdatedAt: "2024-01-02T00:00:00Z",
                 ttl: nil
               }
             }
    end

    test "raises when task is nil" do
      assert_raise ArgumentError, "The 'task' field is required", fn ->
        CreateTaskResult.build(%CreateTaskResult{task: nil})
      end
    end

    test "raises when task is not a Task struct" do
      assert_raise ArgumentError,
                   ~s(The 'task' field must be a OzMcp.Structs.Task struct, got: "bad"),
                   fn ->
                     CreateTaskResult.build(%CreateTaskResult{task: "bad"})
                   end
    end

    test "includes _meta when set" do
      result =
        CreateTaskResult.build(%CreateTaskResult{
          task: build_task(),
          _meta: %{"progressToken" => 5}
        })

      assert result[:_meta] == %{"progressToken" => 5}
    end

    test "does not include _meta when nil" do
      result = CreateTaskResult.build(%CreateTaskResult{task: build_task(), _meta: nil})

      refute Map.has_key?(result, :_meta)
    end

    test "merges extras into result" do
      result =
        CreateTaskResult.build(%CreateTaskResult{
          task: build_task(),
          extras: %{"customKey" => "customVal"}
        })

      assert result["customKey"] == "customVal"
    end

    test "does not include extras when nil" do
      result = CreateTaskResult.build(%CreateTaskResult{task: build_task(), extras: nil})

      refute Map.has_key?(result, "customKey")
    end

    test "extras do not override existing result keys" do
      result =
        CreateTaskResult.build(%CreateTaskResult{
          task: build_task(),
          extras: %{task: "should not override"}
        })

      refute result[:task] == "should not override"
    end

    test "builds with all fields" do
      result =
        CreateTaskResult.build(%CreateTaskResult{
          task: build_task(),
          _meta: %{"progressToken" => 1},
          extras: %{"customField" => "value"}
        })

      assert result.task == %{
               taskId: "task-1",
               status: "working",
               createdAt: "2024-01-01T00:00:00Z",
               lastUpdatedAt: "2024-01-02T00:00:00Z",
               ttl: nil
             }

      assert result[:_meta] == %{"progressToken" => 1}
      assert result["customField"] == "value"
    end
  end
end
