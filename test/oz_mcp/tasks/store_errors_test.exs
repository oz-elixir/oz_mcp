#
# The end-to-end cases where a task record could stay `working` with a
# dead process: a store that fails during the stop of a task, a store
# that fails again and again, a stop of the child of the task
# supervisor, a kill of the process of a task after a restart of the
# reaper, a store that keeps its records over a stop and a start of the
# instance and the quota of the tasks after a loss. A kill of the
# reaper keeps the running task and the new reaper watches it again.
# Each case ends with no active record whose process is dead and with
# counters that agree with the records.
#
defmodule OzMcp.Tasks.StoreErrorsTest do
  use ExUnit.Case, async: true

  alias OzMcp.Structs.Task
  alias OzMcp.Tasks
  alias OzMcp.Tasks.EtsStore
  alias OzMcp.Tasks.Reaper
  alias OzMcp.Tasks.Records
  alias Support.Helpers.TaskScan
  alias Support.Helpers.Utils
  alias Support.Servers

  @server_module Servers.TasksTest
  @server Module.concat(@server_module, __MODULE__)
  @failing Module.concat(@server_module, StoreErrorsFailing)
  @persistent Module.concat(@server_module, StoreErrorsPersistent)
  @limit Module.concat(@server_module, StoreErrorsLimit)
  @slow {Support.Entities.Tools.TaskSlowTest, "task_slow"}
  @stopped_message "The server stopped the task."
  @crash_message "The task process crashed."

  describe "with the default store" do
    setup do
      Utils.start_instance(@server_module, name: @server)
      session_id = Utils.create_session(@server, initialized: true)
      %{session_id: session_id}
    end

    test "a kill of the reaper keeps the running task and the new reaper watches it",
         %{session_id: session_id} do
      owner = Utils.owner(session_id)
      {task, _runner} = create_slow_task(@server, session_id)
      {:ok, task_pid} = OzMcp.Instance.whereis(@server, {:task, task.taskId})

      old = reaper_pid(@server)
      Process.exit(old, :kill)
      new = wait_new_reaper(@server, old)
      assert new != old

      # The new reaper monitors the running task again.
      #
      wait_until(fn ->
        %{watched: watched} = :sys.get_state(new)
        is_map_key(watched, task.taskId)
      end)

      assert OzMcp.Instance.whereis(@server, {:task, task.taskId}) == {:ok, task_pid}
      assert {:ok, %{status: :working}} = EtsStore.get(@server, task.taskId)

      Support.Entities.Tools.TaskSlowTest.finish()

      wait_until(fn ->
        match?({:ok, %{status: :completed}}, EtsStore.get(@server, task.taskId))
      end)

      assert {:error, {:terminal, :completed}} = Tasks.cancel(@server, owner, task.taskId)

      assert_consistent(@server)
    end

    test "a stop of the child of the supervisor of the tasks gives a failed record", %{
      session_id: session_id
    } do
      {task, runner} = create_slow_task(@server, session_id)
      {:ok, pid} = OzMcp.Instance.whereis(@server, {:task, task.taskId})

      assert :ok = DynamicSupervisor.terminate_child(OzMcp.Instance.via(@server, :tasks), pid)

      wait_until(fn ->
        match?({:ok, %{status: :failed}}, EtsStore.get(@server, task.taskId))
      end)

      assert {:ok, failed} = EtsStore.get(@server, task.taskId)
      assert failed.status_message == @stopped_message

      wait_until(fn -> not Process.alive?(runner) end)

      assert_consistent(@server)
    end

    test "a kill of the task process after a restart of the reaper gives a failed record", %{
      session_id: session_id
    } do
      old = reaper_pid(@server)
      Process.exit(old, :kill)
      new = wait_new_reaper(@server, old)
      assert new != old

      {task, _runner} = create_slow_task(@server, session_id)

      # The new reaper watches the new task before the kill.
      #
      wait_until(fn ->
        %{watched: watched} = :sys.get_state(new)
        is_map_key(watched, task.taskId)
      end)

      {:ok, pid} = OzMcp.Instance.whereis(@server, {:task, task.taskId})
      Process.exit(pid, :kill)

      wait_until(fn ->
        match?({:ok, %{status: :failed}}, EtsStore.get(@server, task.taskId))
      end)

      assert {:ok, failed} = EtsStore.get(@server, task.taskId)
      assert failed.status_message == @crash_message

      assert_consistent(@server)
    end
  end

  describe "with a store that fails" do
    setup do
      Utils.start_instance(@server_module,
        name: @failing,
        task_store: Support.TasksStores.Failing
      )

      on_exit(fn -> Support.TasksStores.Failing.clear_instance(@failing) end)
      session_id = Utils.create_session(@failing, initialized: true)
      %{session_id: session_id}
    end

    test "a raise of the store during the stop of a task is repaired by the retry of the sweep",
         %{
           session_id: session_id
         } do
      {task, _runner} = create_slow_task(@failing, session_id)

      Support.TasksStores.Failing.arm(@failing, :put)

      reaper = reaper_pid(@failing)
      {:ok, task_pid} = OzMcp.Instance.whereis(@failing, {:task, task.taskId})

      assert :ok =
               DynamicSupervisor.terminate_child(OzMcp.Instance.via(@failing, :tasks), task_pid)

      # The task could not write its failed record during the stop and
      # the reaper could not write it either.
      #
      assert {:ok, %{status: :working}} = EtsStore.get(@failing, task.taskId)

      Support.TasksStores.Failing.clear(@failing, :put)

      wait_until(fn ->
        match?({:ok, %{status: :failed}}, EtsStore.get(@failing, task.taskId))
      end)

      assert {:ok, failed} = EtsStore.get(@failing, task.taskId)
      assert failed.status_message == @stopped_message
      assert reaper_pid(@failing) == reaper

      assert_consistent(@failing)
    end

    test "the reaper keeps its pid while the store fails in expired/3 and in put/2", %{
      session_id: session_id
    } do
      lost = lost_record(@failing, session_id)

      expired =
        put_record(@failing, session_id,
          status: :completed,
          expires_at_ms: System.system_time(:millisecond) - 20
        )

      reaper = reaper_pid(@failing)

      Support.TasksStores.Failing.arm(@failing, :expired)

      Reaper.rearm(@failing)
      wait_until(fn -> failed_once?(reaper) end)
      assert reaper_pid(@failing) == reaper

      Support.TasksStores.Failing.clear(@failing, :expired)
      Support.TasksStores.Failing.arm(@failing, :put)

      assert :ok = Reaper.reconcile(@failing, lost.task_id)
      assert {:ok, %{status: :working}} = EtsStore.get(@failing, lost.task_id)
      assert reaper_pid(@failing) == reaper

      Support.TasksStores.Failing.clear(@failing, :put)

      wait_until(fn ->
        match?({:ok, %{status: :failed}}, EtsStore.get(@failing, lost.task_id))
      end)

      assert {:ok, failed} = EtsStore.get(@failing, lost.task_id)
      assert failed.status_message == @stopped_message
      assert EtsStore.get(@failing, expired.task_id) == :not_found
      assert reaper_pid(@failing) == reaper

      assert_consistent(@failing)
    end
  end

  describe "with a store that keeps its records" do
    test "the next start of the instance repairs the records that stayed active" do
      instance = @persistent
      :ok = Records.init(EtsStore, instance)

      Utils.start_instance(@server_module,
        name: instance,
        task_store: Support.TasksStores.Persistent
      )

      session_id = Utils.create_session(instance, initialized: true)
      {task, _runner} = create_slow_task(instance, session_id)

      Utils.stop_instance(instance)

      # The stop of the instance wrote the failed record in the tables
      # of the test process.
      #
      assert {:ok, %{status: :failed, status_message: @stopped_message}} =
               EtsStore.get(instance, task.taskId)

      # A record that no process of the instance wrote while it was
      # stopped: an active record with a dead process.
      #
      lost = lost_record(instance, "store-errors-persistent")

      Utils.start_instance(@server_module,
        name: instance,
        task_store: Support.TasksStores.Persistent
      )

      wait_until(fn ->
        match?({:ok, %{status: :failed}}, EtsStore.get(instance, lost.task_id))
      end)

      assert {:ok, failed} = EtsStore.get(instance, lost.task_id)
      assert failed.status_message == @stopped_message

      assert_consistent(instance)
    end
  end

  describe "at the limit of the tasks of a session" do
    setup do
      Utils.start_instance(@server_module, name: @limit, max_tasks_per_session: 1)
      :ok
    end

    test "the quota is free again after the task is lost" do
      session_id = Utils.create_session(@limit, initialized: true)
      {task, _runner} = create_slow_task(@limit, session_id)

      assert {:error, {:too_many_tasks, :max_tasks_per_session}} =
               Tasks.create(@limit, attrs(session_id, %{tool: @slow}))

      {:ok, task_pid} = OzMcp.Instance.whereis(@limit, {:task, task.taskId})
      Process.exit(task_pid, :kill)

      wait_until(fn ->
        match?({:ok, %{status: :failed}}, EtsStore.get(@limit, task.taskId))
      end)

      assert {:ok, %Task{status: :working}} =
               Tasks.create(@limit, attrs(session_id, %{tool: @slow}))

      assert_consistent(@limit)
    end
  end

  # Every active record has a live process and the counters of the
  # store agree with the records, for the session and for the owner.
  #
  defp assert_consistent(instance) do
    for record <- TaskScan.all(instance), record.status in [:working, :input_required] do
      assert Tasks.pid_state(record.pid) == :alive
    end

    for record <- TaskScan.all(instance) do
      assert Records.count_active(EtsStore, instance, {:session, record.session_id}) ==
               TaskScan.active(instance, {:session, record.session_id})

      assert Records.count_active(EtsStore, instance, {:owner, record.owner_key}) ==
               TaskScan.active(instance, {:owner, record.owner_key})
    end
  end

  defp attrs(session_id, extra) do
    Map.merge(
      %{
        session_id: session_id,
        tool: {Support.Entities.Tools.TaskImmediateTest, "task_immediate"},
        request: %{"name" => "task_immediate", "arguments" => %{}},
        ttl: nil,
        progress_token: nil
      },
      Map.new(extra)
    )
  end

  defp create_task(instance, session_id, extra) do
    assert {:ok, %Task{} = task} = Tasks.create(instance, attrs(session_id, extra))
    task
  end

  defp create_slow_task(instance, session_id) do
    Support.Entities.Tools.TaskSlowTest.use_instance(instance)
    Support.Entities.Tools.TaskSlowTest.reset()

    task =
      create_task(instance, session_id, %{tool: @slow, request: %{"name" => "task_slow"}})

    {task, wait_for_runner()}
  end

  defp wait_for_runner do
    assert Utils.eventually(fn ->
             Support.Entities.Tools.TaskSlowTest.last_runner_pid() != nil
           end)

    Support.Entities.Tools.TaskSlowTest.last_runner_pid()
  end

  # An active record whose process is gone: the state a record keeps
  # when the end of a task stayed unseen.
  #
  defp lost_record(instance, session_id) do
    dead = spawn(fn -> :ok end)
    Process.monitor(dead)
    assert_receive {:DOWN, _, :process, ^dead, _reason}, 5_000

    put_record(instance, session_id, pid: dead)
  end

  defp put_record(instance, session_id, attrs) do
    now = DateTime.utc_now()

    record =
      struct!(
        %EtsStore{
          task_id: OzMcp.Utils.Generator.task_id(),
          session_id: session_id,
          owner_key: Utils.owner(session_id),
          seq: System.unique_integer([:positive]),
          status: :working,
          created_at: now,
          last_updated_at: now
        },
        attrs
      )

    :ok = Records.put(EtsStore, instance, record)
    record
  end

  defp reaper_pid(instance) do
    {:ok, pid} = OzMcp.Instance.whereis(instance, :tasks_reaper)
    pid
  end

  defp wait_new_reaper(instance, old_pid) do
    wait_until(fn ->
      case OzMcp.Instance.whereis(instance, :tasks_reaper) do
        {:ok, pid} -> pid != old_pid and Process.alive?(pid)
        :not_running -> false
      end
    end)

    reaper_pid(instance)
  end

  # True once the reaper gave up on one store call: its backoff is set.
  #
  defp failed_once?(reaper) do
    %{backoff: backoff} = :sys.get_state(reaper)
    backoff != nil
  end

  defp wait_until(fun, retries \\ 1_500) do
    if Utils.eventually(fun, retries * 10) do
      :ok
    else
      flunk("condition was not met in time")
    end
  end
end
