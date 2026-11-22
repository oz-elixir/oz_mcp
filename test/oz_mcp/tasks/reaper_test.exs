defmodule OzMcp.Tasks.ReaperTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias OzMcp.Tasks.EtsStore
  alias OzMcp.Tasks.Index
  alias OzMcp.Tasks.Reaper
  alias OzMcp.Tasks.Records
  alias Support.Helpers.TaskScan
  alias Support.Helpers.TelemetryCapture
  alias Support.Helpers.Utils
  alias Support.Servers

  @server Module.concat(Servers.TasksTest, __MODULE__)
  @failing Module.concat(Servers.TasksTest, ReaperFailing)
  @behaviour_only Module.concat(Servers.TasksTest, ReaperBehaviourOnly)

  setup do
    Utils.start_instance(Servers.TasksTest, name: @server)
    session_id = Utils.create_session(@server, initialized: true, streams: [self()])
    %{session_id: session_id}
  end

  defp put_record(session_id, attrs), do: put_record_on(@server, session_id, attrs)

  defp put_record_on(instance, session_id, attrs) do
    now = DateTime.utc_now()

    record =
      struct!(
        %EtsStore{
          task_id: OzMcp.Utils.Generator.task_id(),
          session_id: session_id,
          owner_key: {:session, session_id},
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

  defp wait_until(fun, retries \\ 1_500) do
    if Utils.eventually(fun, retries * 10) do
      :ok
    else
      flunk("condition not met")
    end
  end

  test "deletes the expired records and keeps the others", %{session_id: session_id} do
    now = System.system_time(:millisecond)
    a = put_record(session_id, status: :completed, expires_at_ms: now - 20)
    b = put_record(session_id, status: :completed, expires_at_ms: now - 10)
    keep = put_record(session_id, status: :completed, expires_at_ms: now + 60_000)

    Reaper.rearm(@server)

    # `Records.delete/3` removes the record first, then the entries of
    # the index: wait for the last one, so the checks below do not read
    # between the deletes.
    #
    wait_until(fn ->
      EtsStore.get(@server, a.task_id) == :not_found and
        EtsStore.get(@server, b.task_id) == :not_found and
        Records.next_expiry(EtsStore, @server) == keep.expires_at_ms
    end)

    assert {:ok, _} = EtsStore.get(@server, keep.task_id)
    assert :ets.tab2list(Index.index_table(@server)) |> length() == 1
  end

  test "deletes a record when its time comes", %{session_id: session_id} do
    record =
      put_record(session_id,
        status: :completed,
        expires_at_ms: System.system_time(:millisecond) + 50
      )

    Reaper.rearm(@server)

    # The expiry entry goes after the record (see `Records.delete/3`):
    # wait for it, do not read between the two deletes.
    #
    wait_until(fn ->
      EtsStore.get(@server, record.task_id) == :not_found and
        Records.next_expiry(EtsStore, @server) == nil
    end)
  end

  test "an abnormal exit of a watched process marks the record failed", %{
    session_id: session_id
  } do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    record = put_record(session_id, pid: pid)

    Reaper.watch(@server, pid, record.task_id)
    Process.exit(pid, :kill)

    wait_until(fn ->
      match?({:ok, %{status: :failed}}, EtsStore.get(@server, record.task_id))
    end)

    assert {:ok, failed} = EtsStore.get(@server, record.task_id)
    assert failed.status_message == "The task process crashed."
    assert failed.pid == nil
    assert {:error, %{message: "The task process crashed."}} = failed.result

    assert_receive {:oz_mcp_stream, _, {:event, _, json}}, 5_000

    assert %{"method" => "notifications/tasks/status", "params" => %{"status" => "failed"}} =
             JSON.decode!(json)
  end

  test "after a lost task the reaper holds a live timer when the expiry index is not empty", %{
    session_id: session_id
  } do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    record = put_record(session_id, pid: pid, runner_pid: self(), ttl: 60_000)

    Reaper.watch(@server, pid, record.task_id)
    {:ok, reaper} = OzMcp.Instance.whereis(@server, :tasks_reaper)
    :sys.get_state(reaper)
    Process.exit(pid, :kill)

    wait_until(fn ->
      match?({:ok, %{status: :failed}}, EtsStore.get(@server, record.task_id))
    end)

    assert {:ok, failed} = EtsStore.get(@server, record.task_id)
    assert failed.pid == nil
    assert failed.runner_pid == nil
    assert failed.expires_at_ms != nil

    wait_until(fn ->
      %{timer: timer} = :sys.get_state(reaper)
      is_reference(timer) and Process.read_timer(timer) != false
    end)
  end

  test "a normal exit leaves the record alone", %{session_id: session_id} do
    parent = self()

    pid =
      spawn(fn ->
        receive do
          :stop -> send(parent, :stopped)
        end
      end)

    record = put_record(session_id, pid: pid)

    Reaper.watch(@server, pid, record.task_id)
    {:ok, reaper} = OzMcp.Instance.whereis(@server, :tasks_reaper)
    :sys.get_state(reaper)
    send(pid, :stop)
    assert_receive :stopped
    #
    # The call is a sync point: the reaper has handled the :DOWN of the pid.
    #
    :sys.get_state(reaper)

    assert {:ok, %{status: :working}} = EtsStore.get(@server, record.task_id)
  end

  test "an exit of a task that is terminal changes nothing", %{session_id: session_id} do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    record = put_record(session_id, status: :completed, pid: pid)

    Reaper.watch(@server, pid, record.task_id)
    Process.exit(pid, :kill)
    #
    # The call is a sync point: the reaper has handled the :DOWN of the pid.
    #
    :sys.get_state(reaper_pid_on(@server))

    assert {:ok, %{status: :completed}} = EtsStore.get(@server, record.task_id)
  end

  describe "the sweep at start" do
    test "marks the records with a dead process failed", %{session_id: session_id} do
      dead = spawn(fn -> :ok end)
      Process.monitor(dead)
      assert_receive {:DOWN, _, :process, ^dead, _reason}, 5_000

      record = put_record(session_id, pid: dead)

      old = reaper_pid_on(@server)
      capture_log(fn -> Process.exit(old, :kill) end)
      assert wait_new_reaper(@server, old) != old

      wait_until(fn ->
        match?({:ok, %{status: :failed}}, EtsStore.get(@server, record.task_id))
      end)

      assert {:ok, failed} = EtsStore.get(@server, record.task_id)
      assert failed.status_message == "The server stopped the task."
      assert failed.pid == nil

      assert {:error, %{code: -32_603, message: "The server stopped the task."}} =
               failed.result

      wait_until(fn ->
        Records.count_active(EtsStore, @server, {:owner, record.owner_key}) ==
          TaskScan.active(@server, {:owner, record.owner_key})
      end)
    end

    test "monitors the live processes again", %{session_id: session_id} do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      record = put_record(session_id, pid: pid)

      old = reaper_pid_on(@server)
      capture_log(fn -> Process.exit(old, :kill) end)
      new = wait_new_reaper(@server, old)
      assert new != old

      # The sweep saw a live process outside the tree of the instance: it
      # monitors it and leaves the record alone.
      #
      wait_until(fn ->
        %{watched: watched} = :sys.get_state(new)
        is_map_key(watched, record.task_id)
      end)

      assert {:ok, %{status: :working}} = EtsStore.get(@server, record.task_id)

      # The new reaper follows the process: a kill still marks the record.
      #
      Process.exit(pid, :kill)

      wait_until(fn ->
        match?({:ok, %{status: :failed}}, EtsStore.get(@server, record.task_id))
      end)
    end

    test "does not touch the records of another node", %{session_id: session_id} do
      record = put_record(session_id, pid: remote_pid())

      put_record(session_id,
        status: :completed,
        expires_at_ms: System.system_time(:millisecond) - 20
      )

      old = reaper_pid_on(@server)
      capture_log(fn -> Process.exit(old, :kill) end)
      new = wait_new_reaper(@server, old)

      # The end of the start of the reaper: the expired record of the
      # index went away.
      #
      wait_until(fn -> Records.next_expiry(EtsStore, @server) == nil end)

      assert {:ok, %{status: :working}} = EtsStore.get(@server, record.task_id)
      assert %{watched: watched, monitors: monitors} = :sys.get_state(new)
      assert watched == %{}
      assert monitors == %{}
    end

    test "a shutdown exit marks the record failed with the stopped message", %{
      session_id: session_id
    } do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      record = put_record(session_id, pid: pid)

      old = reaper_pid_on(@server)
      capture_log(fn -> Process.exit(old, :kill) end)
      new = wait_new_reaper(@server, old)

      # The call returns after the sweep at start, so the monitor of the
      # watched process exists before the exit.
      #
      assert %{monitors: monitors} = :sys.get_state(new)
      assert record.task_id in Map.values(monitors)

      Process.exit(pid, :shutdown)

      wait_until(fn ->
        match?({:ok, %{status: :failed}}, EtsStore.get(@server, record.task_id))
      end)

      assert {:ok, failed} = EtsStore.get(@server, record.task_id)
      assert failed.status_message == "The server stopped the task."
    end

    test "reconcile/2 marks the record of a dead process failed before it answers", %{
      session_id: session_id
    } do
      dead = spawn(fn -> :ok end)
      Process.monitor(dead)
      assert_receive {:DOWN, _, :process, ^dead, _reason}, 5_000

      lost = put_record(session_id, pid: dead)
      live = put_record(session_id, pid: self())

      assert :ok = Reaper.reconcile(@server, lost.task_id)

      assert {:ok, %{status: :failed, status_message: "The server stopped the task."}} =
               EtsStore.get(@server, lost.task_id)

      # A record whose process is live stays alone.
      #
      assert :ok = Reaper.reconcile(@server, live.task_id)
      assert {:ok, %{status: :working}} = EtsStore.get(@server, live.task_id)
    end
  end

  # A `:DOWN` that waits in the mailbox of the reaper while a sweep or a
  # reconcile looks at its record: the record gets the message of the
  # real end reason and a killed task gets its telemetry `:stop` event
  # from the reaper.
  #
  describe "a DOWN that waits in the mailbox" do
    test "the retry of the sweep leaves a watched record alone and its DOWN keeps the reason", %{
      session_id: session_id
    } do
      tel = TelemetryCapture.attach()
      dead = dead_pid()
      record = put_record(session_id, pid: dead)
      reaper = reaper_pid_on(@server)
      down_ref = fake_watch(reaper, record.task_id)

      send(reaper, :retry_sweep)
      :sys.get_state(reaper)
      assert {:ok, %{status: :working}} = EtsStore.get(@server, record.task_id)

      send(reaper, {:DOWN, down_ref, :process, dead, :killed})

      wait_until(fn ->
        match?({:ok, %{status: :failed}}, EtsStore.get(@server, record.task_id))
      end)

      assert {:ok, failed} = EtsStore.get(@server, record.task_id)
      assert failed.status_message == "The task process crashed."

      wait_until(fn ->
        stops = task_stops(TelemetryCapture.drain(tel, @server))
        length(stops) == 1 and elem(hd(stops), 2).status == :failed
      end)
    end

    test "reconcile takes the DOWN of a watched process and keeps the reason", %{
      session_id: session_id
    } do
      tel = TelemetryCapture.attach()
      dead = dead_pid()
      record = put_record(session_id, pid: dead)
      reaper = reaper_pid_on(@server)
      down_ref = fake_watch(reaper, record.task_id)

      caller = Task.async(fn -> Reaper.reconcile(@server, record.task_id) end)

      wait_until(fn ->
        Process.info(reaper, :current_function) ==
          {:current_function, {OzMcp.Tasks.Reaper, :reconcile_dead, 2}}
      end)

      send(reaper, {:DOWN, down_ref, :process, dead, :killed})

      assert {:ok, :ok} = Task.yield(caller, 5_000)

      wait_until(fn ->
        match?({:ok, %{status: :failed}}, EtsStore.get(@server, record.task_id))
      end)

      assert {:ok, failed} = EtsStore.get(@server, record.task_id)
      assert failed.status_message == "The task process crashed."

      wait_until(fn ->
        stops = task_stops(TelemetryCapture.drain(tel, @server))
        length(stops) == 1 and elem(hd(stops), 2).status == :failed
      end)
    end

    test "reconcile with no DOWN writes the lost record and answers in the time limit", %{
      session_id: session_id
    } do
      dead = dead_pid()
      record = put_record(session_id, pid: dead)
      reaper = reaper_pid_on(@server)
      fake_watch(reaper, record.task_id)

      started = System.monotonic_time(:millisecond)
      assert :ok = Reaper.reconcile(@server, record.task_id)
      elapsed = System.monotonic_time(:millisecond) - started

      # The wait for the `:DOWN` is shorter than the time limit of the
      # call, so the caller gets its answer either way.
      #
      assert elapsed < 1_000

      assert {:ok, %{status: :failed, status_message: "The server stopped the task."}} =
               EtsStore.get(@server, record.task_id)
    end
  end

  describe "with a store that fails" do
    setup do
      Utils.start_instance(Servers.TasksTest,
        name: @failing,
        task_store: Support.TasksStores.Failing
      )

      on_exit(fn -> Support.TasksStores.Failing.clear_instance(@failing) end)
      session_id = Utils.create_session(@failing, initialized: true)
      %{session_id: session_id}
    end

    test "a raise in expired/3 keeps the reaper alive and retries", %{session_id: session_id} do
      record =
        put_record_on(@failing, session_id,
          status: :completed,
          expires_at_ms: System.system_time(:millisecond) - 20
        )

      reaper = reaper_pid()
      Support.TasksStores.Failing.arm(@failing, :expired)

      capture_log(fn ->
        Reaper.rearm(@failing)
        wait_until(fn -> failed_once?(reaper) end)
      end)

      assert {:ok, _record} = EtsStore.get(@failing, record.task_id)
      assert reaper_pid() == reaper

      Support.TasksStores.Failing.clear(@failing, :expired)

      wait_until(fn -> EtsStore.get(@failing, record.task_id) == :not_found end)
      assert reaper_pid() == reaper
    end

    test "a raise in next_expiry/1 keeps the reaper alive and retries", %{
      session_id: session_id
    } do
      record =
        put_record_on(@failing, session_id,
          status: :completed,
          expires_at_ms: System.system_time(:millisecond) + 60_000
        )

      reaper = reaper_pid()
      Support.TasksStores.Failing.arm(@failing, :next_expiry)

      capture_log(fn ->
        Reaper.rearm(@failing)
        :sys.get_state(reaper)
        wait_until(fn -> failed_once?(reaper) end)
      end)

      assert reaper_pid() == reaper

      Support.TasksStores.Failing.clear(@failing, :next_expiry)
      Reaper.rearm(@failing)

      wait_until(fn ->
        %{timer: timer} = :sys.get_state(reaper)
        is_reference(timer) and Process.read_timer(timer) != false
      end)

      assert {:ok, _record} = EtsStore.get(@failing, record.task_id)
    end

    test "a raise in put/2 during fail_lost keeps the reaper alive and retries", %{
      session_id: session_id
    } do
      {record, reaper} = lost_task(session_id, :put, :raise)

      assert {:ok, %{status: :working}} = EtsStore.get(@failing, record.task_id)
      assert reaper_pid() == reaper

      Support.TasksStores.Failing.clear(@failing, :put)

      wait_until(fn ->
        match?({:ok, %{status: :failed}}, EtsStore.get(@failing, record.task_id))
      end)

      assert reaper_pid() == reaper
    end

    test "an error answer from put/2 during fail_lost gives the same retry", %{
      session_id: session_id
    } do
      {record, reaper} = lost_task(session_id, :put, :error)

      assert {:ok, %{status: :working}} = EtsStore.get(@failing, record.task_id)
      assert reaper_pid() == reaper

      Support.TasksStores.Failing.clear(@failing, :put)

      wait_until(fn ->
        match?({:ok, %{status: :failed}}, EtsStore.get(@failing, record.task_id))
      end)

      assert reaper_pid() == reaper
    end

    test "an exit in get/2 during fail_lost keeps the reaper alive and retries", %{
      session_id: session_id
    } do
      {record, reaper} = lost_task(session_id, :get, :exit)

      assert {:ok, %{status: :working}} = EtsStore.get(@failing, record.task_id)
      assert reaper_pid() == reaper

      Support.TasksStores.Failing.clear(@failing, :get)

      wait_until(fn ->
        match?({:ok, %{status: :failed}}, EtsStore.get(@failing, record.task_id))
      end)

      assert reaper_pid() == reaper
    end

    test "an error answer from get/2 during fail_lost keeps the reaper alive and retries", %{
      session_id: session_id
    } do
      {record, reaper} = lost_task(session_id, :get, :error)

      assert {:ok, %{status: :working}} = EtsStore.get(@failing, record.task_id)
      assert reaper_pid() == reaper

      Support.TasksStores.Failing.clear(@failing, :get)

      wait_until(fn ->
        match?({:ok, %{status: :failed}}, EtsStore.get(@failing, record.task_id))
      end)

      assert {:ok, failed} = EtsStore.get(@failing, record.task_id)
      assert failed.status_message == "The task process crashed."
      assert reaper_pid() == reaper
    end

    test "an error answer from get/2 during reconcile answers :ok and logs a warning", %{
      session_id: session_id
    } do
      record = put_record_on(@failing, session_id, pid: self())
      reaper = reaper_pid()

      Support.TasksStores.Failing.arm(@failing, :get, :error)

      log =
        capture_log(fn ->
          assert :ok = Reaper.reconcile(@failing, record.task_id)
        end)

      assert log =~ "store failure in {:reconcile, "
      assert reaper_pid() == reaper

      # The caller reads the record again: with a working store the
      # record of a live process stays alone.
      #
      Support.TasksStores.Failing.clear(@failing, :get)

      assert :ok = Reaper.reconcile(@failing, record.task_id)
      assert {:ok, %{status: :working}} = EtsStore.get(@failing, record.task_id)
    end

    test "a raise in active/1 keeps the reaper alive and the sweep retries", %{
      session_id: session_id
    } do
      dead = spawn(fn -> :ok end)
      Process.monitor(dead)
      assert_receive {:DOWN, _, :process, ^dead, _reason}, 5_000

      record = put_record_on(@failing, session_id, pid: dead)

      old = reaper_pid()
      Support.TasksStores.Failing.arm(@failing, :active)

      capture_log(fn -> Process.exit(old, :kill) end)
      new = wait_new_reaper(@failing, old)
      assert new != old

      capture_log(fn -> wait_until(fn -> failed_once?(new) end) end)
      assert {:ok, %{status: :working}} = EtsStore.get(@failing, record.task_id)

      Support.TasksStores.Failing.clear(@failing, :active)

      wait_until(fn ->
        match?({:ok, %{status: :failed}}, EtsStore.get(@failing, record.task_id))
      end)

      assert {:ok, failed} = EtsStore.get(@failing, record.task_id)
      assert failed.status_message == "The server stopped the task."
      assert reaper_pid() == new
    end

    test "a successful retry of the sweep resets the backoff", %{session_id: session_id} do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      record = put_record_on(@failing, session_id, pid: pid)

      old = reaper_pid()
      Support.TasksStores.Failing.arm(@failing, :active)

      capture_log(fn -> Process.exit(old, :kill) end)
      new = wait_new_reaper(@failing, old)
      assert new != old

      capture_log(fn -> wait_until(fn -> failed_once?(new) end) end)
      assert {:ok, %{status: :working}} = EtsStore.get(@failing, record.task_id)

      Support.TasksStores.Failing.clear(@failing, :active)

      # The retry of the sweep finds no lost task: it monitors the live
      # process again and the backoff of the failed sweep goes away.
      #
      wait_until(fn ->
        %{watched: watched, backoff: backoff} = :sys.get_state(new)
        is_map_key(watched, record.task_id) and backoff == nil
      end)

      assert {:ok, %{status: :working}} = EtsStore.get(@failing, record.task_id)
      assert reaper_pid() == new
    end

    test "the log of a store failure keeps the message of the exception out", %{
      session_id: session_id
    } do
      put_record_on(@failing, session_id,
        status: :completed,
        expires_at_ms: System.system_time(:millisecond) - 20
      )

      reaper = reaper_pid()
      Support.TasksStores.Failing.arm(@failing, :expired)

      log =
        capture_log(fn ->
          Reaper.rearm(@failing)
          wait_until(fn -> failed_once?(reaper) end)
        end)

      assert log =~ "store failure in :reap"
      refute log =~ "secret-client-payload"
    end
  end

  test "a store that has no active/1 starts and runs and the reaper logs one info line" do
    {_, log} =
      with_log(fn ->
        Utils.start_instance(Servers.TasksTest,
          name: @behaviour_only,
          task_store: Support.TasksStores.BehaviourOnly
        )

        reaper_pid_on(@behaviour_only)

        record =
          put_record_on(@behaviour_only, "session-behaviour-only",
            status: :completed,
            expires_at_ms: System.system_time(:millisecond) - 20
          )

        Reaper.rearm(@behaviour_only)

        wait_until(fn -> EtsStore.get(@behaviour_only, record.task_id) == :not_found end)
      end)

    assert log =~ "no active/1"
    assert Records.next_expiry(EtsStore, @behaviour_only) == nil
  end

  # A lost task whose store fails on the way to the `failed` record.
  #
  defp lost_task(session_id, function, mode) do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    record = put_record_on(@failing, session_id, pid: pid)
    reaper = reaper_pid()

    Reaper.watch(@failing, pid, record.task_id)
    :sys.get_state(reaper)

    Support.TasksStores.Failing.arm(@failing, function, mode)

    capture_log(fn ->
      Process.exit(pid, :kill)
      wait_until(fn -> failed_once?(reaper) end)
    end)

    {record, reaper}
  end

  defp reaper_pid, do: reaper_pid_on(@failing)

  defp reaper_pid_on(instance) do
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

    reaper_pid_on(instance)
  end

  # A pid of another node: the bytes of a live pid of this node in the
  # external term format, with the name of another node. A spawn of this
  # node cannot make one.
  #
  defp remote_pid do
    case :erlang.term_to_binary(self()) do
      <<131, 88, 119, len, _name::binary-size(len), rest::binary>> ->
        :erlang.binary_to_term(<<131, 88, 119, len, "otherx@nohost", rest::binary>>)
    end
  end

  # True once the reaper gave up on one store call: its backoff is set.
  #
  defp failed_once?(reaper) do
    %{backoff: backoff} = :sys.get_state(reaper)
    backoff != nil
  end

  # The pid of a process that is gone: the `:DOWN` of the test monitor
  # proves it before the test goes on.
  #
  defp dead_pid do
    pid = spawn(fn -> :ok end)
    Process.monitor(pid)
    assert_receive {:DOWN, _, :process, ^pid, _reason}, 5_000
    pid
  end

  # A watch of the test: the ref of the test stands in `monitors` and
  # `watched` for the monitor of the reaper, so the test sends the
  # `:DOWN` of that ref itself.
  #
  defp fake_watch(reaper, task_id) do
    ref = make_ref()

    :sys.replace_state(reaper, fn state ->
      %{
        state
        | monitors: Map.put(state.monitors, ref, task_id),
          watched: Map.put(state.watched, task_id, ref)
      }
    end)

    ref
  end

  # The events of the `task` span that ended, in the drained list.
  #
  defp task_stops(events),
    do: Enum.filter(events, fn {name, _, _} -> name == [:oz_mcp, :task, :stop] end)
end
