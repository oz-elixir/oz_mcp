#
# Tests for the OzMcp.Tasks.Context helper module.
# See: lib/oz_mcp/tasks/context.ex
#
defmodule OzMcp.Tasks.ContextTest do
  use ExUnit.Case, async: true
  alias OzMcp.Tasks
  alias OzMcp.Tasks.Context
  alias Support.Helpers.Utils
  alias Support.Servers

  @server_module Servers.TasksTest

  @server Module.concat(@server_module, __MODULE__)
  setup do
    Utils.start_instance(@server_module, name: @server)
    Support.Entities.Tools.TaskSlowTest.use_instance(@server)

    session_id = Utils.create_session(@server, initialized: true, streams: [self()])

    %{session_id: session_id}
  end

  describe "progress/4" do
    test "forwards notifications/progress with the task's progress token and the related-task _meta",
         %{session_id: session_id} do
      {task, runner} = create_slow_task(session_id, %{progress_token: "tok-ctx"})

      assert :ok = Context.progress(task_ctx(session_id, task.taskId), 3, 10, "step 3")

      {_, notification} = Utils.receive_event(5_000)
      assert notification["method"] == "notifications/progress"

      assert notification["params"] == %{
               "progress" => 3,
               "progressToken" => "tok-ctx",
               "total" => 10,
               "message" => "step 3",
               "_meta" => %{"io.modelcontextprotocol/related-task" => %{"taskId" => task.taskId}}
             }

      send(runner, :finish)
    end

    test "omits total and message when nil", %{session_id: session_id} do
      {task, runner} = create_slow_task(session_id, %{progress_token: "tok-ctx"})

      assert :ok = Context.progress(task_ctx(session_id, task.taskId), 1, nil, nil)

      {_, notification} = Utils.receive_event(5_000)

      assert notification["params"] == %{
               "progress" => 1,
               "progressToken" => "tok-ctx",
               "_meta" => %{"io.modelcontextprotocol/related-task" => %{"taskId" => task.taskId}}
             }

      send(runner, :finish)
    end

    test "returns {:error, :not_a_task} for a synchronous ctx and sends nothing (OQ2)" do
      assert Context.progress(sync_ctx(), 1, 2, "step 1") == {:error, :not_a_task}

      # The wait is part of the check: no event of the stream arrives.
      #
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 150
    end

    test "both entry points send the same notification", %{session_id: session_id} do
      {task_a, runner_a} = create_slow_task(session_id, %{progress_token: "tok-same"})
      {task_b, runner_b} = create_slow_task(session_id, %{progress_token: "tok-same"})

      assert :ok = Context.progress(task_ctx(session_id, task_a.taskId), 3, 10, "step 3")
      {_, from_context} = Utils.receive_event(5_000)

      ctx = %{task_ctx(session_id, task_b.taskId) | progress_token: "tok-same"}
      assert :ok = OzMcp.Notify.progress(ctx, 3, total: 10, message: "step 3")
      {_, from_notify} = Utils.receive_event(5_000)

      assert from_context["method"] == "notifications/progress"

      assert from_context["params"] == %{
               "progress" => 3,
               "progressToken" => "tok-same",
               "total" => 10,
               "message" => "step 3",
               "_meta" => %{
                 "io.modelcontextprotocol/related-task" => %{"taskId" => task_a.taskId}
               }
             }

      assert from_notify["params"] ==
               %{
                 "progress" => 3,
                 "progressToken" => "tok-same",
                 "total" => 10,
                 "message" => "step 3",
                 "_meta" => %{
                   "io.modelcontextprotocol/related-task" => %{"taskId" => task_b.taskId}
                 }
               }

      send(runner_a, :finish)
      send(runner_b, :finish)
    end

    test "returns {:error, :not_encodable} for a value that JSON cannot encode and sends nothing",
         %{session_id: session_id} do
      {task, runner} = create_slow_task(session_id, %{progress_token: "tok-ctx"})
      ctx = task_ctx(session_id, task.taskId)

      assert {:error, :not_encodable} = Context.progress(ctx, 1, 2, self())
      assert {:error, :not_encodable} = Context.progress(ctx, 1, {1, 2}, nil)

      # The wait is part of the check: no event of the stream arrives.
      #
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 150

      assert {:ok, stored} = Tasks.get(@server, Utils.owner(session_id), task.taskId)
      assert stored.status == :working

      send(runner, :finish)
    end

    test "a ctx with no progress token sends nothing on both entry points", %{
      session_id: session_id
    } do
      {task, runner} = create_slow_task(session_id)

      assert :ok =
               OzMcp.Notify.progress(
                 %{task_ctx(session_id, task.taskId) | progress_token: nil},
                 1
               )

      assert :ok = Context.progress(task_ctx(session_id, task.taskId), 1, 2, "step 1")

      # The wait is part of the check: no event of the stream arrives.
      #
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 150

      send(runner, :finish)
    end
  end

  describe "status_message/2" do
    test "updates statusMessage without changing the status", %{session_id: session_id} do
      {task, runner} = create_slow_task(session_id)

      assert :ok = Context.status_message(task_ctx(session_id, task.taskId), "halfway there")
      Utils.sync_task(@server, task.taskId)

      assert {:ok, stored} = Tasks.get(@server, Utils.owner(session_id), task.taskId)
      assert stored.status == :working
      assert stored.statusMessage == "halfway there"

      # The wait is part of the check: no status notification arrives.
      #
      refute_receive {:oz_mcp_stream, _, {:event, _, %{method: "notifications/tasks/status"}}},
                     150

      send(runner, :finish)
    end

    test "returns {:error, :not_a_task} for a synchronous ctx and sends nothing (OQ2)" do
      assert Context.status_message(sync_ctx(), "halfway there") == {:error, :not_a_task}

      # The wait is part of the check: no event of the stream arrives.
      #
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 150
    end

    test "returns {:error, :not_encodable} for a message that JSON cannot encode and keeps the old message",
         %{session_id: session_id} do
      {task, runner} = create_slow_task(session_id)
      ctx = task_ctx(session_id, task.taskId)

      assert :ok = Context.status_message(ctx, "halfway there")
      Utils.sync_task(@server, task.taskId)

      assert {:error, :not_encodable} = Context.status_message(ctx, <<0xFF>>)

      Utils.sync_task(@server, task.taskId)

      assert {:ok, stored} = Tasks.get(@server, Utils.owner(session_id), task.taskId)
      assert stored.status == :working
      assert stored.statusMessage == "halfway there"

      # The wait is part of the check: no event of the stream arrives.
      #
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 150

      send(runner, :finish)
    end
  end

  describe "behaviour regression" do
    test "the tool behaviour still has exactly the 041 callbacks (no task callback)" do
      callbacks = OzMcp.Config.Tool.behaviour_info(:callbacks)

      assert MapSet.new(callbacks) ==
               MapSet.new([
                 {:list, 0},
                 {:call, 2}
               ])

      assert OzMcp.Config.Tool.behaviour_info(:optional_callbacks) == []
    end

    test "the manual helpers of the input_required status are gone" do
      refute function_exported?(Context, :input_required, 2)
      refute function_exported?(Tasks, :input_required, 3)
      refute function_exported?(Tasks, :input_resumed, 3)
    end
  end

  defp sync_ctx do
    %{
      instance: @server,
      server: @server,
      session_id: "sync-session",
      request_id: 1,
      progress_token: "tok-sync",
      task_id: nil
    }
  end

  defp task_ctx(session_id, task_id) do
    %{
      instance: @server,
      server: @server,
      session_id: session_id,
      request_id: nil,
      progress_token: "tok-ctx",
      task_id: task_id
    }
  end

  defp create_slow_task(session_id, extra_attrs \\ %{}) do
    Support.Entities.Tools.TaskSlowTest.reset()

    attrs =
      Map.merge(
        %{
          session_id: session_id,
          tool: {Support.Entities.Tools.TaskSlowTest, "task_slow"},
          request: %{"name" => "task_slow", "arguments" => %{}},
          ttl: nil,
          progress_token: nil
        },
        Map.new(extra_attrs)
      )

    assert {:ok, task} = Tasks.create(@server, attrs)
    {task, wait_for_runner()}
  end

  defp wait_for_runner do
    assert Utils.eventually(fn ->
             Support.Entities.Tools.TaskSlowTest.last_runner_pid() != nil
           end)

    Support.Entities.Tools.TaskSlowTest.last_runner_pid()
  end
end
