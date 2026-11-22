defmodule OzMcp.Tasks.ResultTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias OzMcp.Auth.Principal
  alias OzMcp.Context
  alias OzMcp.PostStream
  alias OzMcp.Tasks
  alias OzMcp.Tasks.EtsStore
  alias OzMcp.Tasks.Result
  alias Support.Helpers.Utils
  alias Support.Servers

  # Each test starts its own instance with a unique name, so the tests
  # run in parallel.
  #
  @server_module Servers.TasksTest

  setup do
    instance = Module.concat(@server_module, "T#{System.unique_integer([:positive])}")
    Utils.start_instance(@server_module, name: instance)

    %{instance: instance}
  end

  describe "the wait of a task result" do
    test "a task that ends gives its result", %{instance: instance} do
      principal = alice_principal()
      session = Utils.create_session(instance, initialized: true)
      task = create_slow_task(instance, session, principal)
      finish_after(instance, task.taskId, 100)

      {:ok, stream} = begin_stream(instance, session, 1)

      {outcome, stream} = Result.wait(context(instance, session, task.taskId, principal), stream)

      assert {:ok, %{outcome: :result, value: value}} = outcome
      assert value == %{content: [%{type: "text", text: "slow done"}]}
      refute stream.failed

      PostStream.close(stream)
    end

    test "a task that is cancelled while the wait runs gives its outcome", %{instance: instance} do
      principal = alice_principal()
      session = Utils.create_session(instance, initialized: true)
      task = create_slow_task(instance, session, principal)
      {:ok, stream} = begin_stream(instance, session, 1)

      cancel_after(instance, task.taskId, principal, 100)

      {outcome, stream} = Result.wait(context(instance, session, task.taskId, principal), stream)

      assert {:ok,
              %{outcome: :stored_error, error: %{code: -32800, message: "task was cancelled"}}} =
               outcome

      refute stream.failed
      assert_receive :cancelled
    end
  end

  defp begin_stream(instance, session_id, request_id) do
    Utils.begin_stream(instance, session_id, request_id, conn(:post, "/"), & &1)
  end

  defp context(instance, session_id, task_id, principal) do
    %Context{
      instance: instance,
      server: @server_module,
      session_id: session_id,
      rpc_id: 1,
      rpc_method: "tasks/result",
      rpc_params: %{"taskId" => task_id},
      task_id: task_id,
      principal: principal
    }
  end

  defp alice_principal do
    Principal.new!(
      subject: "alice",
      issuer: "https://issuer.test",
      audiences: "https://mcp.example.com/mcp"
    )
  end

  # A task whose runner blocks until it gets `:finish`. The pid of the
  # runner comes from the record of the instance of this test: the pid
  # under `:any` can belong to the runner of another test that runs at
  # the same time.
  #
  defp create_slow_task(instance, session_id, principal) do
    assert {:ok, task} =
             Tasks.create(instance, %{
               session_id: session_id,
               tool: {Support.Entities.Tools.TaskSlowTest, "task_slow"},
               request: %{"name" => "task_slow", "arguments" => %{}},
               principal: principal
             })

    assert Utils.eventually(fn -> runner_pid(instance, task.taskId) != nil end)

    task
  end

  defp runner_pid(instance, task_id) do
    case EtsStore.get(instance, task_id) do
      {:ok, %{runner_pid: pid}} -> pid
      _ -> nil
    end
  end

  # The runner is finished `delay` after the call, from a timer.
  #
  defp finish_after(instance, task_id, delay) do
    pid = runner_pid(instance, task_id)
    Process.send_after(pid, :finish, delay)
    :ok
  end

  # The cancel runs `delay` after the call, from another process: the
  # wait of the test process is blocked while the cancel runs. The
  # process tells the test when the cancel is done.
  #
  defp cancel_after(instance, task_id, principal, delay) do
    parent = self()
    owner = Tasks.owner_key(%{principal: principal})

    spawn(fn ->
      Process.send_after(self(), :cancel_now, delay)

      receive do
        :cancel_now -> :ok
      end

      {:ok, _task} = Tasks.cancel(instance, owner, task_id)
      send(parent, :cancelled)
    end)

    :ok
  end
end
