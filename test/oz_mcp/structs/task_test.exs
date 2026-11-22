defmodule OzMcp.Structs.TaskTest do
  use ExUnit.Case, async: true
  alias OzMcp.Structs.Task

  describe "struct defaults" do
    test "has correct defaults for all fields" do
      task = %Task{}

      assert task.taskId == ""
      assert task.status == :working
      assert task.statusMessage == nil
      assert task.createdAt == ""
      assert task.lastUpdatedAt == ""
      assert task.ttl == nil
      assert task.pollInterval == nil
    end
  end

  describe "task_id/2" do
    test "sets taskId field" do
      task = Task.task_id(%Task{}, "task-1")

      assert task.taskId == "task-1"
    end
  end

  describe "status/2" do
    test "sets status field to working" do
      task = Task.status(%Task{}, :working)

      assert task.status == :working
    end

    test "sets status field to input_required" do
      task = Task.status(%Task{}, :input_required)

      assert task.status == :input_required
    end

    test "sets status field to completed" do
      task = Task.status(%Task{}, :completed)

      assert task.status == :completed
    end

    test "sets status field to failed" do
      task = Task.status(%Task{}, :failed)

      assert task.status == :failed
    end

    test "sets status field to cancelled" do
      task = Task.status(%Task{}, :cancelled)

      assert task.status == :cancelled
    end
  end

  describe "status_message/2" do
    test "sets statusMessage field" do
      task = Task.status_message(%Task{}, "in progress")

      assert task.statusMessage == "in progress"
    end

    test "accepts nil for statusMessage field" do
      task = Task.status_message(%Task{statusMessage: "x"}, nil)

      assert task.statusMessage == nil
    end
  end

  describe "created_at/2" do
    test "sets createdAt field" do
      task = Task.created_at(%Task{}, "2024-01-01T00:00:00Z")

      assert task.createdAt == "2024-01-01T00:00:00Z"
    end
  end

  describe "last_updated_at/2" do
    test "sets lastUpdatedAt field" do
      task = Task.last_updated_at(%Task{}, "2024-01-02T00:00:00Z")

      assert task.lastUpdatedAt == "2024-01-02T00:00:00Z"
    end
  end

  describe "ttl/2" do
    test "sets ttl field to a non-negative integer" do
      task = Task.ttl(%Task{}, 5000)

      assert task.ttl == 5000
    end

    test "sets ttl field to zero" do
      task = Task.ttl(%Task{}, 0)

      assert task.ttl == 0
    end

    test "accepts nil for ttl field" do
      task = Task.ttl(%Task{ttl: 5000}, nil)

      assert task.ttl == nil
    end
  end

  describe "poll_interval/2" do
    test "sets pollInterval field to a non-negative integer" do
      task = Task.poll_interval(%Task{}, 1000)

      assert task.pollInterval == 1000
    end

    test "accepts nil for pollInterval field" do
      task = Task.poll_interval(%Task{pollInterval: 1000}, nil)

      assert task.pollInterval == nil
    end
  end

  describe "build/1" do
    test "builds a task with all required fields" do
      task = %Task{
        taskId: "task-1",
        status: :working,
        createdAt: "2024-01-01T00:00:00Z",
        lastUpdatedAt: "2024-01-02T00:00:00Z"
      }

      result = Task.build(task)

      assert result == %{
               taskId: "task-1",
               status: "working",
               createdAt: "2024-01-01T00:00:00Z",
               lastUpdatedAt: "2024-01-02T00:00:00Z",
               ttl: nil
             }
    end

    test "always includes ttl even when nil" do
      task = %Task{
        taskId: "task-1",
        createdAt: "2024-01-01T00:00:00Z",
        lastUpdatedAt: "2024-01-02T00:00:00Z"
      }

      result = Task.build(task)

      assert result[:ttl] == nil
    end

    test "includes ttl when set to a value" do
      task = %Task{
        taskId: "task-1",
        createdAt: "2024-01-01T00:00:00Z",
        lastUpdatedAt: "2024-01-02T00:00:00Z",
        ttl: 30000
      }

      result = Task.build(task)

      assert result[:ttl] == 30000
    end

    test "includes statusMessage when set" do
      task = %Task{
        taskId: "task-1",
        statusMessage: "waiting for input",
        createdAt: "2024-01-01T00:00:00Z",
        lastUpdatedAt: "2024-01-02T00:00:00Z"
      }

      result = Task.build(task)

      assert result[:statusMessage] == "waiting for input"
    end

    test "does not include statusMessage when nil" do
      task = %Task{
        taskId: "task-1",
        statusMessage: nil,
        createdAt: "2024-01-01T00:00:00Z",
        lastUpdatedAt: "2024-01-02T00:00:00Z"
      }

      result = Task.build(task)

      refute Map.has_key?(result, :statusMessage)
    end

    test "includes pollInterval when set" do
      task = %Task{
        taskId: "task-1",
        pollInterval: 2000,
        createdAt: "2024-01-01T00:00:00Z",
        lastUpdatedAt: "2024-01-02T00:00:00Z"
      }

      result = Task.build(task)

      assert result[:pollInterval] == 2000
    end

    test "does not include pollInterval when nil" do
      task = %Task{
        taskId: "task-1",
        pollInterval: nil,
        createdAt: "2024-01-01T00:00:00Z",
        lastUpdatedAt: "2024-01-02T00:00:00Z"
      }

      result = Task.build(task)

      refute Map.has_key?(result, :pollInterval)
    end

    test "converts each status to its string representation" do
      base = %Task{
        taskId: "task-1",
        createdAt: "2024-01-01T00:00:00Z",
        lastUpdatedAt: "2024-01-02T00:00:00Z"
      }

      assert Task.build(%{base | status: :working}).status == "working"
      assert Task.build(%{base | status: :input_required}).status == "input_required"
      assert Task.build(%{base | status: :completed}).status == "completed"
      assert Task.build(%{base | status: :failed}).status == "failed"
      assert Task.build(%{base | status: :cancelled}).status == "cancelled"
    end

    test "raises when status is invalid" do
      task = struct!(%Task{}, taskId: "task-1", status: :bogus)

      allowed = "[:working, :input_required, :completed, :failed, :cancelled]"

      assert_raise ArgumentError, "The 'status' field must be one of #{allowed}", fn ->
        Task.build(task)
      end
    end

    test "raises when taskId is empty" do
      task = %Task{
        taskId: "",
        createdAt: "2024-01-01T00:00:00Z",
        lastUpdatedAt: "2024-01-02T00:00:00Z"
      }

      assert_raise ArgumentError, "The 'taskId' field cannot be an empty string", fn ->
        Task.build(task)
      end
    end

    test "raises when taskId is not a string" do
      task = struct!(%Task{}, taskId: 123)

      assert_raise ArgumentError, "The 'taskId' field is required and must be a string", fn ->
        Task.build(task)
      end
    end

    test "raises when statusMessage is not a string or nil" do
      task = struct!(%Task{}, taskId: "task-1", statusMessage: 1)

      assert_raise ArgumentError, "The 'statusMessage' field must be a string or nil", fn ->
        Task.build(task)
      end
    end

    test "raises when createdAt is empty" do
      task = %Task{
        taskId: "task-1",
        createdAt: "",
        lastUpdatedAt: "2024-01-02T00:00:00Z"
      }

      assert_raise ArgumentError, "The 'createdAt' field cannot be an empty string", fn ->
        Task.build(task)
      end
    end

    test "raises when lastUpdatedAt is empty" do
      task = %Task{
        taskId: "task-1",
        createdAt: "2024-01-01T00:00:00Z",
        lastUpdatedAt: ""
      }

      assert_raise ArgumentError, "The 'lastUpdatedAt' field cannot be an empty string", fn ->
        Task.build(task)
      end
    end

    test "raises when lastUpdatedAt is not a string" do
      task =
        struct!(%Task{},
          taskId: "task-1",
          createdAt: "2024-01-01T00:00:00Z",
          lastUpdatedAt: :nope
        )

      assert_raise ArgumentError,
                   "The 'lastUpdatedAt' field is required and must be a string",
                   fn ->
                     Task.build(task)
                   end
    end

    test "raises when ttl is a negative integer" do
      task = %Task{
        taskId: "task-1",
        createdAt: "2024-01-01T00:00:00Z",
        lastUpdatedAt: "2024-01-02T00:00:00Z",
        ttl: -1
      }

      assert_raise ArgumentError, "The 'ttl' field must be a non-negative integer or nil", fn ->
        Task.build(task)
      end
    end

    test "raises when pollInterval is not a non-negative integer or nil" do
      task = %Task{
        taskId: "task-1",
        createdAt: "2024-01-01T00:00:00Z",
        lastUpdatedAt: "2024-01-02T00:00:00Z",
        pollInterval: "soon"
      }

      assert_raise ArgumentError,
                   "The 'pollInterval' field must be a non-negative integer or nil",
                   fn ->
                     Task.build(task)
                   end
    end

    test "builds a full task with all fields set" do
      task = %Task{
        taskId: "task-1",
        status: :input_required,
        statusMessage: "need more info",
        createdAt: "2024-01-01T00:00:00Z",
        lastUpdatedAt: "2024-01-02T00:00:00Z",
        ttl: 60000,
        pollInterval: 1500
      }

      result = Task.build(task)

      assert result == %{
               taskId: "task-1",
               status: "input_required",
               statusMessage: "need more info",
               createdAt: "2024-01-01T00:00:00Z",
               lastUpdatedAt: "2024-01-02T00:00:00Z",
               ttl: 60000,
               pollInterval: 1500
             }
    end
  end
end
