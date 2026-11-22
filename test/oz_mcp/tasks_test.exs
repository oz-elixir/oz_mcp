defmodule OzMcp.TasksTest do
  use ExUnit.Case, async: true

  alias OzMcp.Structs.Task
  alias OzMcp.Tasks
  alias OzMcp.Tasks.EtsStore
  alias OzMcp.Tasks.Records
  alias Support.Helpers.SessionProbe
  alias Support.Helpers.TaskScan
  alias Support.Helpers.Utils
  alias Support.Servers

  @server Servers.TasksTest
  @stopped Module.concat(@server, TasksStopped)

  # Each test starts its own instance with a unique name, so the tests
  # run in parallel: no test holds the reaper of another test back.
  #
  setup do
    instance = Module.concat(@server, "T#{System.unique_integer([:positive])}")
    Utils.start_instance(@server, name: instance)
    Support.Entities.Tools.TaskSlowTest.use_instance(instance)

    session_id = Utils.create_session(instance, initialized: true, streams: [self()])

    %{instance: instance, session_id: session_id}
  end

  describe "with an instance that runs" do
    test "create/2, get/3 and list/4", %{instance: instance, session_id: session_id} do
      assert {:ok, %Task{} = task} = Tasks.create(instance, attrs(session_id))
      assert task.status == :working

      assert {:ok, {:ok, _}} = Tasks.await(instance, Utils.owner(session_id), task.taskId)

      assert {:ok, %Task{status: :completed} = stored} =
               Tasks.get(instance, Utils.owner(session_id), task.taskId)

      assert stored.taskId == task.taskId

      assert {:ok, [%Task{} = listed], nil} =
               Tasks.list(instance, Utils.owner(session_id), nil, 10)

      assert listed.taskId == task.taskId
    end

    test "get/3, cancel/3 and await/3 of an unknown or foreign task", %{
      instance: instance,
      session_id: session_id
    } do
      {task, runner} = create_slow_task(instance, session_id)

      assert {:error, :no_task} = Tasks.get(instance, Utils.owner(session_id), "unknown")
      assert {:error, :no_task} = Tasks.get(instance, Utils.owner("stranger"), task.taskId)

      assert {:error, :no_task} =
               Tasks.cancel(instance, Utils.owner("stranger"), task.taskId)

      assert {:error, :no_task} = Tasks.await(instance, Utils.owner("stranger"), task.taskId)
      assert {:ok, [], nil} = Tasks.list(instance, Utils.owner("stranger"), nil, 10)

      send(runner, :finish)
      assert {:ok, {:ok, _}} = Tasks.await(instance, Utils.owner(session_id), task.taskId)
    end

    test "list/4 paginates with the cursor and refuses a broken cursor", %{
      instance: instance,
      session_id: session_id
    } do
      first = create_task(instance, session_id)
      second = create_task(instance, session_id)

      assert {:ok, [%Task{} = page1], cursor} =
               Tasks.list(instance, Utils.owner(session_id), nil, 1)

      assert page1.taskId == first.taskId
      assert is_binary(cursor)

      assert {:ok, [%Task{} = page2], nil} =
               Tasks.list(instance, Utils.owner(session_id), cursor, 1)

      assert page2.taskId == second.taskId

      assert {:error, :invalid_cursor} =
               Tasks.list(instance, Utils.owner(session_id), "not-a-cursor", 10)
    end

    test "await/3 returns the outcome of a completed task", %{
      instance: instance,
      session_id: session_id
    } do
      task = create_task(instance, session_id)

      assert {:ok, {:ok, result}} =
               Tasks.await(instance, Utils.owner(session_id), task.taskId)

      assert result == %{content: [%{type: "text", text: "done"}]}

      assert {:ok, %Task{status: :completed}} =
               Tasks.get(instance, Utils.owner(session_id), task.taskId)
    end

    test "await/3 returns the error outcome of a failed task", %{
      instance: instance,
      session_id: session_id
    } do
      task =
        create_task(instance, session_id,
          tool: {Support.Entities.Tools.TaskErrorTest, "task_error"},
          request: %{"name" => "task_error", "arguments" => %{"shape" => "plain_map"}}
        )

      assert {:ok, {:error, err}} =
               Tasks.await(instance, Utils.owner(session_id), task.taskId)

      assert err == %{code: -32000, message: "boom", data: %{"detail" => "extra"}}

      assert {:ok, %Task{status: :failed, statusMessage: "boom"}} =
               Tasks.get(instance, Utils.owner(session_id), task.taskId)
    end

    test "the stored record of a task holds no copy of the request", %{
      instance: instance,
      session_id: session_id
    } do
      owner = Utils.owner(session_id)

      {slow, _runner} = create_slow_task(instance, session_id)
      assert {:ok, working} = EtsStore.get(instance, slow.taskId)
      refute Map.has_key?(working, :request)

      completed = create_task(instance, session_id)

      assert {:ok, {:ok, _}} = Tasks.await(instance, owner, completed.taskId)
      assert {:ok, done} = EtsStore.get(instance, completed.taskId)
      refute Map.has_key?(done, :request)

      failed =
        create_task(instance, session_id,
          tool: {Support.Entities.Tools.TaskErrorTest, "task_error"},
          request: %{"name" => "task_error", "arguments" => %{"shape" => "plain_map"}}
        )

      assert {:ok, {:error, _}} = Tasks.await(instance, owner, failed.taskId)
      assert {:ok, stored_failed} = EtsStore.get(instance, failed.taskId)
      refute Map.has_key?(stored_failed, :request)

      {cancelled, _runner} = create_slow_task(instance, session_id)
      assert {:ok, %Task{status: :cancelled}} = Tasks.cancel(instance, owner, cancelled.taskId)
      assert {:ok, stored_cancelled} = EtsStore.get(instance, cancelled.taskId)
      refute Map.has_key?(stored_cancelled, :request)
    end

    test "cancel/3 cancels a working task and refuses a terminal task", %{
      instance: instance,
      session_id: session_id
    } do
      {task, _runner} = create_slow_task(instance, session_id)

      assert {:ok, %Task{status: :cancelled} = cancelled} =
               Tasks.cancel(instance, Utils.owner(session_id), task.taskId)

      assert cancelled.taskId == task.taskId

      assert {:error, {:terminal, :cancelled}} =
               Tasks.cancel(instance, Utils.owner(session_id), task.taskId)

      assert {:ok, {:error, %{message: "task was cancelled"}}} =
               Tasks.await(instance, Utils.owner(session_id), task.taskId)
    end

    test "status_message/3 sets the message of a working task", %{
      instance: instance,
      session_id: session_id
    } do
      {task, runner} = create_slow_task(instance, session_id)

      assert :ok = Tasks.status_message(instance, task.taskId, "halfway there")
      Utils.sync_task(instance, task.taskId)

      assert {:ok, %Task{status: :working, statusMessage: "halfway there"}} =
               Tasks.get(instance, Utils.owner(session_id), task.taskId)

      send(runner, :finish)
    end

    test "status_message/3 refuses a message that JSON cannot encode and keeps the old message",
         %{
           instance: instance,
           session_id: session_id
         } do
      {task, runner} = create_slow_task(instance, session_id)

      assert :ok = Tasks.status_message(instance, task.taskId, "halfway there")
      Utils.sync_task(instance, task.taskId)

      assert {:error, :not_encodable} = Tasks.status_message(instance, task.taskId, <<0xFF>>)
      assert {:error, :not_encodable} = Tasks.status_message(instance, task.taskId, {1, 2})

      Utils.sync_task(instance, task.taskId)

      assert {:ok, %Task{status: :working, statusMessage: "halfway there"}} =
               Tasks.get(instance, Utils.owner(session_id), task.taskId)

      send(runner, :finish)
    end

    test "status_message/3 accepts nil and clears the message", %{
      instance: instance,
      session_id: session_id
    } do
      {task, runner} = create_slow_task(instance, session_id)

      assert :ok = Tasks.status_message(instance, task.taskId, "halfway there")
      Utils.sync_task(instance, task.taskId)

      assert :ok = Tasks.status_message(instance, task.taskId, nil)
      Utils.sync_task(instance, task.taskId)

      assert {:ok, %Task{status: :working, statusMessage: nil}} =
               Tasks.get(instance, Utils.owner(session_id), task.taskId)

      send(runner, :finish)
    end

    test "progress/5 forwards the notification of a task with a progress token", %{
      instance: instance,
      session_id: session_id
    } do
      {task, runner} = create_slow_task(instance, session_id, %{progress_token: "pt-1"})

      assert :ok = Tasks.progress(instance, task.taskId, 1, 2, "step 1")

      {_, notification} = Utils.receive_event(5_000)
      assert notification["method"] == "notifications/progress"

      assert notification["params"] == %{
               "progress" => 1,
               "progressToken" => "pt-1",
               "total" => 2,
               "message" => "step 1",
               "_meta" => %{"io.modelcontextprotocol/related-task" => %{"taskId" => task.taskId}}
             }

      send(runner, :finish)
    end

    test "progress/5 refuses values that JSON cannot encode and sends nothing", %{
      instance: instance,
      session_id: session_id
    } do
      {task, runner} = create_slow_task(instance, session_id, %{progress_token: "pt-1"})

      assert {:error, :not_encodable} = Tasks.progress(instance, task.taskId, 1, 2, self())
      assert {:error, :not_encodable} = Tasks.progress(instance, task.taskId, 1, {1, 2}, nil)

      # The wait is part of the check: no event of the stream arrives.
      #
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 150

      assert {:ok, %Task{status: :working}} =
               Tasks.get(instance, Utils.owner(session_id), task.taskId)

      send(runner, :finish)
    end

    test "the casts of an unknown task answer :ok and change nothing", %{
      instance: instance,
      session_id: session_id
    } do
      assert :ok = Tasks.progress(instance, "unknown", 1, 2, nil)
      assert :ok = Tasks.status_message(instance, "unknown", "msg")

      assert {:ok, [], nil} = Tasks.list(instance, Utils.owner(session_id), nil, 10)
    end

    test "the end of a session ends the tasks of the session", %{
      instance: instance,
      session_id: session_id
    } do
      {task, _runner} = create_slow_task(instance, session_id)

      assert :ok = SessionProbe.terminate_tasks(instance, session_id)
      assert {:error, :no_task} = Tasks.get(instance, Utils.owner(session_id), task.taskId)
      assert {:ok, [], nil} = Tasks.list(instance, Utils.owner(session_id), nil, 10)
      assert :ok = SessionProbe.terminate_tasks(instance, "stranger")
    end

    test "create/2 gives the limit of the active tasks of a session" do
      name = Module.concat(@server, TasksLimit)
      Utils.start_instance(@server, name: name, max_tasks_per_session: 1)
      Support.Entities.Tools.TaskSlowTest.use_instance(name)

      session_id = Utils.create_session(name, initialized: true)
      {first, runner} = create_slow_task(name, session_id)

      assert {:error, {:too_many_tasks, :max_tasks_per_session}} =
               Tasks.create(
                 name,
                 attrs(session_id, tool: {Support.Entities.Tools.TaskSlowTest, "task_slow"})
               )

      send(runner, :finish)
      assert {:ok, {:ok, _}} = Tasks.await(name, Utils.owner(session_id), first.taskId)

      assert {:ok, %Task{}} =
               Tasks.create(
                 name,
                 attrs(session_id, tool: {Support.Entities.Tools.TaskSlowTest, "task_slow"})
               )
    end
  end

  describe "with an instance that does not run" do
    test "each function gives :unavailable" do
      results = [
        Tasks.create(@stopped, %{}),
        Tasks.get(@stopped, Utils.owner("session"), "task"),
        Tasks.list(@stopped, Utils.owner("session"), nil, 10),
        Tasks.await(@stopped, Utils.owner("session"), "task"),
        Tasks.cancel(@stopped, Utils.owner("session"), "task"),
        Tasks.progress(@stopped, "task", 1, 2, nil),
        Tasks.status_message(@stopped, "task", "msg"),
        SessionProbe.terminate_tasks(@stopped, "session")
      ]

      assert Enum.all?(results, &(&1 == {:error, :unavailable}))
    end
  end

  describe "the helpers of a lost task" do
    test "failed_record/2 builds a failed record with no process" do
      now = DateTime.utc_now()

      record = %OzMcp.Tasks.EtsStore{
        task_id: "task-lost-1",
        session_id: "session-1",
        seq: 1,
        status: :working,
        created_at: now,
        last_updated_at: now,
        ttl: 5_000,
        pid: self(),
        runner_pid: self()
      }

      failed = Tasks.failed_record(record, "any message")

      assert failed.status == :failed
      assert failed.status_message == "any message"
      assert failed.pid == nil
      assert failed.runner_pid == nil
      assert failed.result == {:error, %{code: -32_603, message: "any message", data: nil}}
      assert DateTime.compare(failed.last_updated_at, now) != :lt
      assert failed.expires_at_ms == Tasks.expires_at_ms(record)
    end

    test "failed_record/2 keeps the expiry of a record without ttl nil" do
      now = DateTime.utc_now()

      record = %OzMcp.Tasks.EtsStore{
        task_id: "task-lost-2",
        session_id: "session-1",
        seq: 2,
        status: :input_required,
        created_at: now,
        last_updated_at: now
      }

      failed = Tasks.failed_record(record, "any message")

      assert failed.status == :failed
      assert failed.expires_at_ms == nil
    end

    test "lost_message/1 gives one message for each kind of end reason" do
      assert Tasks.lost_message(:shutdown) == "The server stopped the task."
      assert Tasks.lost_message({:shutdown, :x}) == "The server stopped the task."
      assert Tasks.lost_message(:lost) == "The server stopped the task."
      assert Tasks.lost_message(:killed) == "The task process crashed."
      assert Tasks.lost_message(:boom) == "The task process crashed."
    end

    test "pid_state/1 sorts the states of a pid and never raises" do
      dead = spawn(fn -> :ok end)
      Process.monitor(dead)
      assert_receive {:DOWN, _, :process, ^dead, _reason}, 5_000

      assert Tasks.pid_state(nil) == :dead
      assert Tasks.pid_state(self()) == :alive
      assert Tasks.pid_state(dead) == :dead

      # A pid of another node: the bytes of a live pid of this node in
      # the external term format, with the name of another node.
      #
      <<131, 88, 119, len, _name::binary-size(len), rest::binary>> =
        :erlang.term_to_binary(self())

      remote = :erlang.binary_to_term(<<131, 88, 119, len, "otherx@nohost", rest::binary>>)
      assert node(remote) != node()
      assert Tasks.pid_state(remote) == :remote
    end
  end

  describe "with a record whose process is gone" do
    test "cancel/3 gives the failed terminal status of the lost task", %{
      instance: instance,
      session_id: session_id
    } do
      record = lost_record(instance, session_id)

      assert {:error, {:terminal, :failed}} =
               Tasks.cancel(instance, Utils.owner(session_id), record.task_id)

      assert {:ok, %Task{status: :failed, statusMessage: "The server stopped the task."}} =
               Tasks.get(instance, Utils.owner(session_id), record.task_id)

      assert Records.count_active(EtsStore, instance, {:session, session_id}) ==
               TaskScan.active(instance, {:session, session_id})
    end

    test "cancel/3 asks the reaper for a record with no pid", %{
      instance: instance,
      session_id: session_id
    } do
      record = put_record(instance, session_id, pid: nil)

      assert {:error, {:terminal, :failed}} =
               Tasks.cancel(instance, Utils.owner(session_id), record.task_id)

      assert {:ok, %Task{status: :failed, statusMessage: "The server stopped the task."}} =
               Tasks.get(instance, Utils.owner(session_id), record.task_id)

      assert Records.count_active(EtsStore, instance, {:session, session_id}) ==
               TaskScan.active(instance, {:session, session_id})
    end

    test "cancel/3 with a reaper that cannot answer gives :unavailable", %{
      instance: instance,
      session_id: session_id
    } do
      record = lost_record(instance, session_id)
      {:ok, reaper} = OzMcp.Instance.whereis(instance, :tasks_reaper)
      :sys.get_state(reaper)
      :sys.suspend(reaper)

      on_exit(fn ->
        if Process.alive?(reaper), do: :sys.resume(reaper)
      end)

      assert {:error, :unavailable} =
               Tasks.cancel(instance, Utils.owner(session_id), record.task_id)

      # No answer named an active task terminal: the record is as it was.
      #
      assert {:ok, %{status: :working}} = EtsStore.get(instance, record.task_id)
    end

    test "await/4 gives the result of the failed record", %{
      instance: instance,
      session_id: session_id
    } do
      record = lost_record(instance, session_id)

      assert {:ok, {:error, %{code: -32_603, message: "The server stopped the task."}}} =
               Tasks.await(instance, Utils.owner(session_id), record.task_id, 5_000)

      assert {:ok, %{status: :failed}} = EtsStore.get(instance, record.task_id)
    end

    test "attach/5 gives the outcome of the failed record", %{
      instance: instance,
      session_id: session_id
    } do
      record = lost_record(instance, session_id)

      assert {:done, {:ok, {:error, %{code: -32_603, message: "The server stopped the task."}}}} =
               Tasks.attach(instance, Utils.owner(session_id), record.task_id, "s", %{
                 session_id: session_id,
                 client_capabilities: %{}
               })
    end
  end

  describe "a task process that stops while a caller follows the task" do
    test "await/4 and attach/5 give the failed result of a killed task", %{
      instance: instance,
      session_id: session_id
    } do
      owner = Utils.owner(session_id)
      {task, _runner} = create_slow_task(instance, session_id)
      {:ok, pid} = OzMcp.Instance.whereis(instance, {:task, task.taskId})

      Process.exit(pid, :kill)

      before = System.monotonic_time(:millisecond)

      assert {:ok, {:error, %{code: -32_603, message: "The task process crashed."}}} =
               Tasks.await(instance, owner, task.taskId, 5_000)

      assert System.monotonic_time(:millisecond) - before < 5_000

      before = System.monotonic_time(:millisecond)

      assert {:done, {:ok, {:error, %{code: -32_603, message: "The task process crashed."}}}} =
               Tasks.attach(instance, owner, task.taskId, "s", %{
                 session_id: session_id,
                 client_capabilities: %{}
               })

      assert System.monotonic_time(:millisecond) - before < 5_000

      assert {:ok, %Task{status: :failed, statusMessage: "The task process crashed."}} =
               Tasks.get(instance, owner, task.taskId)

      assert Records.count_active(EtsStore, instance, {:session, session_id}) ==
               TaskScan.active(instance, {:session, session_id})
    end
  end

  describe "a task whose ttl elapsed" do
    test "a record whose process is dead goes at once", %{
      instance: instance,
      session_id: session_id
    } do
      dead = spawn(fn -> :ok end)
      Process.monitor(dead)
      assert_receive {:DOWN, _, :process, ^dead, _reason}, 5_000

      record = expired_record(instance, session_id, pid: dead)

      assert {:error, :expired} =
               Tasks.get(instance, Utils.owner(session_id), record.task_id)

      assert EtsStore.get(instance, record.task_id) == :not_found
      assert Records.count_active(EtsStore, instance, {:session, session_id}) == 0
      assert TaskScan.active(instance, {:session, session_id}) == 0
    end

    test "a task whose process runs still gets the order to expire", %{
      instance: instance,
      session_id: session_id
    } do
      parent = self()

      pid =
        spawn(fn ->
          receive do
            {:"$gen_cast", :expire} -> send(parent, :got_expire)
          end
        end)

      record = expired_record(instance, session_id, pid: pid)

      assert {:error, :expired} =
               Tasks.get(instance, Utils.owner(session_id), record.task_id)

      assert_receive :got_expire, 5_000
    end

    test "await/4 answers the expiry of a lost task, as cancel/3 does", %{
      instance: instance,
      session_id: session_id
    } do
      owner = Utils.owner(session_id)
      {:ok, reaper} = OzMcp.Instance.whereis(instance, :tasks_reaper)
      :sys.get_state(reaper)
      :sys.suspend(reaper)

      on_exit(fn ->
        if Process.alive?(reaper), do: :sys.resume(reaper)
      end)

      # The suspend comes before the record: the rearm of the record
      # waits in the mailbox of the suspended reaper, so on the resume
      # the sweep of the expiry goes behind the ask of the wait, never
      # in front of it. The ttl is long, so the first read of the wait
      # always sees an active record, however late the waiter starts.
      #
      record = lost_record(instance, session_id, ttl: 60_000)
      waiter = Elixir.Task.async(fn -> Tasks.await(instance, owner, record.task_id, 5_000) end)

      # The wait sits in the ask of the suspended reaper, after the calls
      # of the dead process. The event is the arrival of the ask in the
      # mailbox, not a lapse of time.
      #
      assert Utils.eventually(fn -> reconcile_asked?(reaper, record.task_id) end)

      # Only now the record expires. The ask must stay short of its
      # 1 s limit, so the resume follows at once.
      #
      assert EtsStore.expired?(expire_record(instance, record))
      assert Elixir.Task.yield(waiter, 0) == nil

      # The ask writes the failed record and that write arms the sweep
      # of the expired record at once. A debug hook of the reaper holds
      # the sweep until the waiter has its answer: a sweep before the
      # second read of the waiter gives `:no_task`, not the expiry.
      #
      hold = make_ref()
      :sys.install(reaper, {&hold_reap/3, hold})
      on_exit(fn -> send(reaper, {hold, :go}) end)

      :sys.resume(reaper)

      # The ask wrote the failed record and the second read deleted it:
      # the answer is the expiry of the record.
      #
      assert {:error, :expired} = Elixir.Task.await(waiter, 5_000)
      assert EtsStore.get(instance, record.task_id) == :not_found

      send(reaper, {hold, :go})
      :sys.get_state(reaper)

      # The same case answers the same to a cancel: the expiry of the
      # record comes before any status. Here the record is expired
      # before the cancel reads it, so the first read already sees the
      # expiry: no timing decides the answer. The suspended reaper holds the
      # sweep back: the rearm of the twin and the ask of the cancel sit
      # in the mailbox in front of the sweep.
      #
      :sys.suspend(reaper)
      :sys.get_state(reaper)

      twin = lost_record(instance, session_id, ttl: 1)
      wait_until(fn -> EtsStore.expired?(twin) end)
      twin_waiter = Elixir.Task.async(fn -> Tasks.cancel(instance, owner, twin.task_id) end)

      :sys.resume(reaper)

      assert {:error, :expired} = Elixir.Task.await(twin_waiter, 5_000)
      assert EtsStore.get(instance, twin.task_id) == :not_found

      assert Records.count_active(EtsStore, instance, {:session, session_id}) ==
               TaskScan.active(instance, {:session, session_id})
    end
  end

  # An active record whose process is gone: the state a record can keep
  # when the end of a task stayed unseen.
  #
  defp lost_record(instance, session_id, attrs \\ []) do
    dead = dead_pid()
    put_record(instance, session_id, Keyword.merge([pid: dead], attrs))
  end

  # A debug function of `:sys.install/2`: the reaper waits for `{hold,
  # :go}` before it takes its next sweep. A `:go` that comes first ends
  # the hook.
  #
  defp hold_reap(hold, {:in, :reap}, _state) do
    receive do
      {^hold, :go} -> :done
    end
  end

  defp hold_reap(hold, {:in, {hold, :go}}, _state), do: :done
  defp hold_reap(hold, _event, _state), do: hold

  defp reconcile_asked?(reaper, task_id) do
    {:messages, messages} = Process.info(reaper, :messages)

    Enum.any?(messages, fn
      {:"$gen_call", _from, {:reconcile, ^task_id}} -> true
      _ -> false
    end)
  end

  # Puts the record again with a creation time in the past.
  #
  defp expire_record(instance, record) do
    expired = %{record | created_at: DateTime.add(DateTime.utc_now(), -120_000, :millisecond)}
    :ok = Records.put(EtsStore, instance, expired)
    expired
  end

  defp dead_pid do
    dead = spawn(fn -> :ok end)
    Process.monitor(dead)
    assert_receive {:DOWN, _, :process, ^dead, _reason}, 5_000
    dead
  end

  defp expired_record(instance, session_id, attrs) do
    record =
      put_record(
        instance,
        session_id,
        Keyword.merge(attrs,
          created_at: DateTime.add(DateTime.utc_now(), -5_000, :millisecond),
          ttl: 1_000
        )
      )

    assert EtsStore.expired?(record)
    record
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

  defp attrs(session_id, extra \\ %{}) do
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

  defp create_task(instance, session_id, extra \\ %{}) do
    assert {:ok, %Task{} = task} = Tasks.create(instance, attrs(session_id, extra))
    task
  end

  defp create_slow_task(instance, session_id, extra \\ %{}) do
    Support.Entities.Tools.TaskSlowTest.reset()

    task =
      create_task(
        instance,
        session_id,
        Map.merge(%{tool: {Support.Entities.Tools.TaskSlowTest, "task_slow"}}, extra)
      )

    {task, wait_for_runner()}
  end

  defp wait_for_runner do
    assert Utils.eventually(fn ->
             Support.Entities.Tools.TaskSlowTest.last_runner_pid() != nil
           end)

    Support.Entities.Tools.TaskSlowTest.last_runner_pid()
  end

  defp wait_until(fun, retries \\ 1_500) do
    if Utils.eventually(fun, retries * 10) do
      :ok
    else
      flunk("condition was not met in time")
    end
  end
end
