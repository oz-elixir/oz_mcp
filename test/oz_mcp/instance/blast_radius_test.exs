#
# The pids and the data that survive the crash of each process of the tree.
#
defmodule OzMcp.Instance.BlastRadiusTest do
  use ExUnit.Case, async: true

  alias OzMcp.Instance
  alias OzMcp.PubSub.PG
  alias OzMcp.Tasks
  alias OzMcp.Tasks.EtsStore
  alias Support.Helpers.PersistentSnapshot
  alias Support.Helpers.TreeProbe
  alias Support.Helpers.Utils
  alias Support.Servers

  @server Servers.TasksTest
  @workers [:calls, :sessions, :tasks_reaper, :tasks]
  @snapshot_workers [:restore_cache, :snapshot_writer]

  describe "the workers" do
    setup do
      start_instance()
    end

    for {child, survives} <- [
          {:tasks_reaper, [:calls, :sessions, :tasks]},
          {:calls, [:sessions, :tasks, :tasks_reaper]},
          {:sessions, [:calls, :tasks, :tasks_reaper]},
          {:tasks, [:calls, :sessions, :tasks_reaper]}
        ] do
      @tag :capture_log
      test "a kill of #{child} restarts that worker only and keeps the records", %{
        instance: instance,
        session_id: session_id
      } do
        task = create_running_task(instance, session_id)
        session = session_pid(instance, session_id)
        before = pids(instance, @workers)
        old = Map.fetch!(before, unquote(child))

        Process.exit(old, :kill)

        wait_new_pid(instance, unquote(child), old)

        for other <- unquote(survives) do
          assert pid_of(instance, other) == Map.fetch!(before, other)
        end

        if unquote(child) == :sessions do
          assert session_pid(instance, session_id) == nil
        else
          assert session_pid(instance, session_id) == session
        end

        assert {:ok, _record} = Tasks.get(instance, task.owner, task.id)
        Support.Entities.Tools.TaskSlowTest.finish()
      end
    end

    @tag :capture_log
    test "a kill of :calls makes the running task failed and keeps its record", %{
      instance: instance,
      session_id: session_id
    } do
      task = create_running_task(instance, session_id)
      old = pid_of(instance, :calls)

      Process.exit(old, :kill)
      wait_new_pid(instance, :calls, old)

      wait_status(instance, task, :failed)
    end

    @tag :capture_log
    test "a kill of :tasks makes the running task failed and keeps its record", %{
      instance: instance,
      session_id: session_id
    } do
      task = create_running_task(instance, session_id)
      old = pid_of(instance, :tasks)

      Process.exit(old, :kill)
      wait_new_pid(instance, :tasks, old)

      wait_status(instance, task, :failed)
      assert task_process(instance, task.id) == nil
    end

    @tag :capture_log
    test "a kill of :sessions keeps the running task of the lost session", %{
      instance: instance,
      session_id: session_id
    } do
      task = create_running_task(instance, session_id)
      old = pid_of(instance, :sessions)

      Process.exit(old, :kill)
      wait_new_pid(instance, :sessions, old)

      assert session_pid(instance, session_id) == nil
      assert task_process(instance, task.id) == task.pid
      wait_status(instance, task, :working)

      Support.Entities.Tools.TaskSlowTest.finish()
      wait_status(instance, task, :completed)
    end

    @tag :capture_log
    test "a kill of the reaper keeps the running task and its final record", %{
      instance: instance,
      session_id: session_id
    } do
      task = create_running_task(instance, session_id)
      old = pid_of(instance, :tasks_reaper)

      Process.exit(old, :kill)
      wait_new_pid(instance, :tasks_reaper, old)

      assert task_process(instance, task.id) == task.pid
      wait_status(instance, task, :working)

      Support.Entities.Tools.TaskSlowTest.finish()
      wait_status(instance, task, :completed)
    end

    @tag :capture_log
    test "a task that starts while the reaper is down is watched by the new reaper", %{
      instance: instance,
      session_id: session_id
    } do
      workers = TreeProbe.workers(instance)
      old = pid_of(instance, :tasks_reaper)

      :ok = :sys.suspend(workers)
      Process.exit(old, :kill)
      wait_until(fn -> Instance.whereis(instance, :tasks_reaper) == :not_running end)

      task = create_running_task(instance, session_id)

      :ok = :sys.resume(workers)
      new = wait_new_pid(instance, :tasks_reaper, old)

      # The call after the sweep makes sure that the new reaper read the
      # active records before the task ends.
      #
      :sys.get_state(new)
      Process.exit(task.pid, :kill)

      wait_status(instance, task, :failed)
    end

    @tag :capture_log
    test "a crash loop of :calls exhausts Workers and keeps the instance", %{
      instance: instance
    } do
      instance_pid = Process.whereis(Module.concat(instance, Instance))
      old_workers = TreeProbe.workers(instance)

      for _ <- 1..4 do
        old = pid_of(instance, :calls)
        Process.exit(old, :kill)
        wait_new_pid(instance, :calls, old)
      end

      assert Utils.eventually(fn ->
               workers = TreeProbe.workers(instance)
               is_pid(workers) and workers != old_workers
             end)

      assert Process.whereis(Module.concat(instance, Instance)) == instance_pid
    end

    @tag :capture_log
    test "a kill of Workers keeps Instance, Core, Tasks.Table and the records", %{
      instance: instance,
      session_id: session_id
    } do
      task = create_running_task(instance, session_id)
      instance_pid = Process.whereis(Module.concat(instance, Instance))
      core = TreeProbe.core(instance)
      table = pid_of(instance, :tasks_table)
      old_workers = TreeProbe.workers(instance)
      slow = start_slow_child(instance)

      Process.exit(old_workers, :kill)

      new_workers = wait_new_supervisor(fn -> TreeProbe.workers(instance) end, old_workers)

      refute new_workers == old_workers
      assert Process.whereis(Module.concat(instance, Instance)) == instance_pid
      assert TreeProbe.core(instance) == core
      assert pid_of(instance, :tasks_table) == table
      assert {:ok, _record} = Tasks.get(instance, task.owner, task.id)

      Process.exit(slow, :kill)
      Support.Entities.Tools.TaskSlowTest.finish()
    end
  end

  describe "the snapshot workers" do
    setup do
      start_instance(session_snapshot: PersistentSnapshot)
    end

    for child <- @snapshot_workers do
      @tag :capture_log
      test "a kill of #{child} restarts that worker only", %{
        instance: instance,
        session_id: session_id
      } do
        task = create_running_task(instance, session_id)
        session = session_pid(instance, session_id)
        before = pids(instance, @workers ++ @snapshot_workers)
        old = Map.fetch!(before, unquote(child))

        Process.exit(old, :kill)

        wait_new_pid(instance, unquote(child), old)

        for other <- @workers ++ @snapshot_workers, other != unquote(child) do
          assert pid_of(instance, other) == Map.fetch!(before, other)
        end

        assert session_pid(instance, session_id) == session
        assert {:ok, _record} = Tasks.get(instance, task.owner, task.id)
        Support.Entities.Tools.TaskSlowTest.finish()
      end
    end
  end

  describe "the core" do
    setup do
      start_instance()
    end

    @tag :capture_log
    test "a kill of Topics restarts Core and Workers and loses the records", %{
      instance: instance,
      session_id: session_id
    } do
      task = create_running_task(instance, session_id)
      core = TreeProbe.core(instance)
      table = pid_of(instance, :tasks_table)
      sessions = pid_of(instance, :sessions)

      Process.exit(Process.whereis(Instance.topics(instance)), :kill)

      new_core = wait_new_supervisor(fn -> TreeProbe.core(instance) end, core)
      new_table = wait_new_pid(instance, :tasks_table, table)
      new_sessions = wait_new_pid(instance, :sessions, sessions)

      refute new_core == core
      refute new_table == table
      refute new_sessions == sessions

      assert session_pid(instance, session_id) == nil
      assert task_process(instance, task.id) == nil
      assert EtsStore.get(instance, task.id) == :not_found
      assert {:ok, _config} = Instance.config(instance)
    end

    @tag :capture_log
    test "a kill of Core restarts Core and Workers and loses the records", %{
      instance: instance,
      session_id: session_id
    } do
      task = create_running_task(instance, session_id)
      core = TreeProbe.core(instance)
      table = pid_of(instance, :tasks_table)
      sessions = pid_of(instance, :sessions)

      Process.exit(core, :kill)

      new_core = wait_new_supervisor(fn -> TreeProbe.core(instance) end, core)
      new_table = wait_new_pid(instance, :tasks_table, table)
      new_sessions = wait_new_pid(instance, :sessions, sessions)

      refute new_core == core
      refute new_table == table
      refute new_sessions == sessions

      assert session_pid(instance, session_id) == nil
      assert task_process(instance, task.id) == nil
      assert EtsStore.get(instance, task.id) == :not_found
      assert {:ok, _config} = Instance.config(instance)
    end
  end

  describe "the pubsub" do
    setup do
      start_instance(pubsub: PG)
    end

    @tag :capture_log
    test "a kill of PubSub restarts PubSub and Workers and keeps the records", %{
      instance: instance,
      session_id: session_id
    } do
      task = create_running_task(instance, session_id)
      core = TreeProbe.core(instance)
      pubsub = TreeProbe.pubsub(instance)
      table = pid_of(instance, :tasks_table)
      sessions = pid_of(instance, :sessions)

      Process.exit(pubsub, :kill)

      new_pubsub = wait_new_supervisor(fn -> TreeProbe.pubsub(instance) end, pubsub)
      new_sessions = wait_new_pid(instance, :sessions, sessions)

      refute new_pubsub == pubsub
      refute new_sessions == sessions
      assert TreeProbe.core(instance) == core
      assert pid_of(instance, :tasks_table) == table
      assert session_pid(instance, session_id) == nil
      assert {:ok, _record} = Tasks.get(instance, task.owner, task.id)
    end

    @tag :capture_log
    test "a kill of the :pg scope restarts PubSub and Workers and keeps the records", %{
      instance: instance,
      session_id: session_id
    } do
      task = create_running_task(instance, session_id)
      core = TreeProbe.core(instance)
      pubsub = TreeProbe.pubsub(instance)
      table = pid_of(instance, :tasks_table)
      sessions = pid_of(instance, :sessions)
      scope = Process.whereis(PG.scope(instance))

      assert is_pid(scope)

      Process.exit(scope, :kill)

      new_pubsub = wait_new_supervisor(fn -> TreeProbe.pubsub(instance) end, pubsub)
      new_sessions = wait_new_pid(instance, :sessions, sessions)

      refute new_pubsub == pubsub
      refute new_sessions == sessions
      assert TreeProbe.core(instance) == core
      assert pid_of(instance, :tasks_table) == table
      wait_until(fn -> session_pid(instance, session_id) == nil end)
      assert {:ok, _record} = Tasks.get(instance, task.owner, task.id)
    end

    @tag :capture_log
    test "a kill of Core restarts Core, PubSub and Workers and keeps Instance", %{
      instance: instance,
      session_id: session_id
    } do
      task = create_running_task(instance, session_id)
      instance_pid = Process.whereis(Module.concat(instance, Instance))
      core = TreeProbe.core(instance)
      pubsub = TreeProbe.pubsub(instance)
      workers = TreeProbe.workers(instance)
      table = pid_of(instance, :tasks_table)

      Process.exit(core, :kill)

      new_core = wait_new_supervisor(fn -> TreeProbe.core(instance) end, core)
      new_pubsub = wait_new_supervisor(fn -> TreeProbe.pubsub(instance) end, pubsub)
      new_workers = wait_new_supervisor(fn -> TreeProbe.workers(instance) end, workers)
      new_table = wait_new_pid(instance, :tasks_table, table)

      refute new_core == core
      refute new_pubsub == pubsub
      refute new_workers == workers
      refute new_table == table
      assert Process.whereis(Module.concat(instance, Instance)) == instance_pid
      assert session_pid(instance, session_id) == nil
      assert task_process(instance, task.id) == nil
    end
  end

  defp start_instance(opts \\ []) do
    instance = Module.concat(@server, "Blast#{System.unique_integer([:positive])}")

    Utils.start_instance(@server, [name: instance] ++ opts)
    Support.Entities.Tools.TaskSlowTest.use_instance(instance)
    Support.Entities.Tools.TaskSlowTest.reset()

    session_id = Utils.create_session(instance, initialized: true)

    %{instance: instance, session_id: session_id}
  end

  defp create_running_task(instance, session_id) do
    Support.Entities.Tools.TaskSlowTest.reset()

    attrs = %{
      session_id: session_id,
      tool: {Support.Entities.Tools.TaskSlowTest, "task_slow"},
      request: %{"name" => "task_slow", "arguments" => %{}},
      ttl: 60_000,
      progress_token: nil
    }

    assert {:ok, task} = Tasks.create(instance, attrs)
    assert {:ok, pid} = Instance.whereis(instance, {:task, task.taskId})

    assert Utils.eventually(fn ->
             Support.Entities.Tools.TaskSlowTest.last_runner_pid() != nil
           end)

    %{id: task.taskId, pid: pid, owner: Utils.owner(session_id)}
  end

  # A child of `:tasks` that traps the exit and stays alive for 200 ms.
  # It keeps the default 5 s shutdown timeout of a supervisor, so the old
  # Workers still stops when the new Workers starts.
  #
  defp start_slow_child(instance) do
    parent = self()

    spec = %{
      id: make_ref(),
      start:
        {Task, :start_link,
         [
           fn ->
             Process.flag(:trap_exit, true)
             send(parent, {:slow_child, self()})

             receive do
               {:EXIT, _parent, _reason} ->
                 receive do
                 after
                   200 -> :ok
                 end
             end
           end
         ]},
      restart: :temporary
    }

    assert {:ok, _pid} = DynamicSupervisor.start_child(Instance.via(instance, :tasks), spec)
    assert_receive {:slow_child, pid}
    pid
  end

  defp pids(instance, keys), do: Map.new(keys, &{&1, pid_of(instance, &1)})

  defp pid_of(instance, key) do
    {:ok, pid} = Instance.whereis(instance, key)
    pid
  end

  defp session_pid(instance, session_id) do
    case Instance.whereis(instance, {:session, session_id}) do
      {:ok, pid} -> pid
      :not_running -> nil
    end
  end

  defp task_process(instance, task_id) do
    case Instance.whereis(instance, {:task, task_id}) do
      {:ok, pid} -> pid
      :not_running -> nil
    end
  end

  defp wait_status(instance, task, status) do
    wait_until(fn ->
      match?({:ok, %{status: ^status}}, Tasks.get(instance, task.owner, task.id))
    end)
  end

  defp wait_new_pid(instance, key, old) do
    wait_until(fn ->
      case Instance.whereis(instance, key) do
        {:ok, pid} -> pid != old and Process.alive?(pid)
        :not_running -> false
      end
    end)

    pid_of(instance, key)
  end

  defp wait_new_supervisor(fun, old) do
    wait_until(fn ->
      case fun.() do
        pid when is_pid(pid) -> pid != old
        nil -> false
      end
    end)

    fun.()
  end

  defp wait_until(fun) do
    if Utils.eventually(fun) do
      :ok
    else
      flunk("the condition was not met in time")
    end
  end
end
