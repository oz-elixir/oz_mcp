#
# A snapshot module whose table outlives the instances of the test: a
# session survives a restart of the instance. The state of the store is
# keyed by the name of the instance and each test of the file runs its
# instance under a name of its own.
#
defmodule OzMcp.Session.PersistentSnapshotTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Conn, only: [put_req_header: 3]
  import Plug.Test, only: [conn: 3]

  alias OzMcp.Session.RestoreCache
  alias OzMcp.Session.Snapshot.Writer
  alias OzMcp.Sessions
  alias Support.Helpers.PersistentSnapshot
  alias Support.Helpers.SessionProbe
  alias Support.Helpers.TelemetryCapture
  alias Support.Helpers.TreeProbe
  alias Support.Helpers.Utils
  alias Support.Servers

  @server_module Servers.Default

  setup do
    Process.put(
      :snapshot_instance,
      Module.concat(@server_module, "PS#{System.unique_integer([:positive])}")
    )

    start_instance()
    :ok
  end

  # The name of the instance of the test: the setup gives it a name of its
  # own, so the tests of the file (and of the other files) run apart.
  #
  defp server, do: Process.get(:snapshot_instance)

  defp start_instance do
    Utils.start_instance(@server_module,
      name: server(),
      session_snapshot: PersistentSnapshot
    )
  end

  defp restart_instance do
    Utils.stop_instance(server())
    start_instance()
  end

  defp initialized_session do
    session_id = Utils.create_session(server(), initialized: true)
    :ok = Sessions.set_log_level(server(), session_id, :warning)
    :ok = Sessions.subscribe(server(), session_id, "file:///a.md")

    # The writes run outside of the session process: the test waits for
    # the store to hold what the session holds.
    #
    wait_saved(server(), session_id, %{log_level: :warning, subscriptions: ["file:///a.md"]})

    session_id
  end

  describe "fetch_snapshot" do
    test "gives :disabled when the instance has no snapshot module" do
      no_snapshot = Module.concat(server(), "NoSnapshot")
      Utils.start_instance(Servers.Default, name: no_snapshot)

      assert Sessions.fetch_snapshot(no_snapshot, "any-id") == :disabled
    end

    test "gives the snapshot that the module holds" do
      PersistentSnapshot.put(server(), "stored-id", restored_snapshot())

      assert {:ok, snapshot} = Sessions.fetch_snapshot(server(), "stored-id")
      assert snapshot == restored_snapshot()
    end

    test "gives :not_found for an id that the module does not hold" do
      assert Sessions.fetch_snapshot(server(), "unknown") == :not_found
      assert PersistentSnapshot.calls(server(), :load) == 1
    end

    test "gives :not_found for a marked id, with no call of the module" do
      ref = TelemetryCapture.attach()
      :ok = RestoreCache.put_deleted(server(), "ended-id")

      assert Sessions.fetch_snapshot(server(), "ended-id") == :not_found
      assert PersistentSnapshot.calls(server(), :load) == 0

      assert [event] = restore_events(ref)
      assert elem(event, 2).outcome == :deleted
    end

    test "gives {:error, :failed} when the module fails" do
      PersistentSnapshot.fail(server(), :load, :raise)

      log =
        Utils.capture_log([level: :error], fn ->
          assert Sessions.fetch_snapshot(server(), "stored-id") == {:error, :failed}
        end)

      assert log =~ "session snapshot load failed"
    end

    test "gives {:error, :invalid} for an answer that is not a snapshot" do
      PersistentSnapshot.put(server(), "bad-id", "text-instead-of-a-snapshot")

      log =
        Utils.capture_log([level: :warning], fn ->
          assert Sessions.fetch_snapshot(server(), "bad-id") == {:error, :invalid}
        end)

      assert log =~ "session snapshot load: invalid answer"
      refute log =~ "text-instead-of-a-snapshot"
    end

    test "gives {:error, :unavailable} when the instance does not run" do
      absent = Module.concat(server(), "Absent")

      assert Sessions.fetch_snapshot(absent, "any-id") == {:error, :unavailable}
    end
  end

  describe "start_restored" do
    test "does not start a session that runs already" do
      session_id = Utils.create_session(server(), initialized: true)
      {:ok, pid} = OzMcp.Instance.whereis(server(), {:session, session_id})

      assert {:ok, view} = Sessions.start_restored(server(), session_id, restored_snapshot())
      assert view.initialized

      {:ok, same_pid} = OzMcp.Instance.whereis(server(), {:session, session_id})
      assert same_pid == pid
      assert Utils.session_count(server()) == 1
    end

    test "counts in the limit of the principal" do
      limited = Module.concat(server(), "PrincipalLimitFull")

      Utils.start_instance(Servers.Default,
        name: limited,
        session_snapshot: PersistentSnapshot,
        max_sessions_per_principal: 1
      )

      key = {"https://issuer.test", "alice"}
      Utils.create_session(limited, initialized: true, principal_key: key, streams: [self()])
      PersistentSnapshot.put(limited, "stored-id", %{restored_snapshot() | principal_key: key})

      assert Sessions.start_restored(limited, "stored-id", %{
               restored_snapshot()
               | principal_key: key
             }) == {:error, :too_many_sessions}

      # The refusal keeps the snapshot: the caller can end its old
      # session and the next restore starts again.
      #
      assert PersistentSnapshot.get(limited, "stored-id") != nil
      assert Registry.lookup(OzMcp.Instance.names(limited), {:session, "stored-id"}) == []
    end

    test "does not count the session that runs already" do
      limited = Module.concat(server(), "PrincipalLimitSame")

      Utils.start_instance(Servers.Default,
        name: limited,
        session_snapshot: PersistentSnapshot,
        max_sessions_per_principal: 1
      )

      key = {"https://issuer.test", "alice"}
      session_id = Utils.create_session(limited, initialized: true, principal_key: key)

      assert {:ok, view} =
               Sessions.start_restored(limited, session_id, %{
                 restored_snapshot()
                 | principal_key: key
               })

      assert view.initialized
      assert Utils.session_count(limited) == 1
    end

    test "concurrent restores of one id pass at the limit and start one session" do
      limited = Module.concat(server(), "PrincipalLimitConcurrent")

      Utils.start_instance(Servers.Default,
        name: limited,
        session_snapshot: PersistentSnapshot,
        max_sessions_per_principal: 1
      )

      key = {"https://issuer.test", "alice"}
      snapshot = %{restored_snapshot() | principal_key: key}
      PersistentSnapshot.put(limited, "shared-id", snapshot)

      results =
        1..20
        |> Enum.map(fn _ ->
          Task.async(fn -> Sessions.start_restored(limited, "shared-id", snapshot) end)
        end)
        |> Task.await_many()

      assert Enum.all?(results, &match?({:ok, %{initialized: true}}, &1))
      assert Utils.session_count(limited) == 1
    end
  end

  describe "a lookup of an unknown id" do
    test "does not call the snapshot module and starts no session" do
      PersistentSnapshot.put(server(), "stored-id", restored_snapshot())

      assert {:error, :no_session} = Sessions.lookup(server(), "stored-id")
      assert PersistentSnapshot.calls(server(), :load) == 0
      assert Registry.lookup(OzMcp.Instance.names(server()), {:session, "stored-id"}) == []
    end
  end

  describe "a reader of a session that is only in the snapshot store" do
    test "gives no session and calls load zero times" do
      PersistentSnapshot.put(server(), "stored-id", restored_snapshot())

      assert Sessions.state(server(), "stored-id") == {:error, :no_session}
      assert Sessions.delivery(server(), "stored-id") == {:error, :no_session}
      assert Sessions.client_capabilities(server(), "stored-id") == {:error, :no_session}
      assert SessionProbe.initialized?(server(), "stored-id") == {:error, :no_session}
      assert Sessions.touch(server(), "stored-id") == {:error, :no_session}

      assert PersistentSnapshot.calls(server(), :load) == 0
      assert Utils.session_count(server()) == 0
    end

    test "gives no session to a message of the server and calls load zero times" do
      PersistentSnapshot.put(server(), "stored-id", restored_snapshot())

      assert OzMcp.Notify.log_session(server(), "stored-id", :warning, "hello") ==
               {:error, :no_session}

      assert PersistentSnapshot.calls(server(), :load) == 0
      assert Utils.session_count(server()) == 0
    end

    test "a request of the router starts the session again" do
      PersistentSnapshot.put(server(), "stored-id", restored_snapshot())

      assert restore_ping("stored-id").status == 200

      assert {:ok, %{initialized: true}} = Sessions.state(server(), "stored-id")
      assert Utils.session_count(server()) == 1
    end
  end

  describe "a snapshot with a wrong shape" do
    test "gives 404 and one warning that holds the reason only" do
      for bad <- [
            %{restored_snapshot() | log_level: "warning"},
            %{restored_snapshot() | client_capabilities: nil},
            %{restored_snapshot() | subscriptions: ["file:///a.md" | "file:///b.md"]},
            Map.delete(restored_snapshot(), :client_info)
          ] do
        PersistentSnapshot.put(server(), "stored-id", bad)

        log =
          Utils.capture_log([level: :warning], fn ->
            conn = restore_ping("stored-id")
            assert conn.status == 404
            assert decode_resp(conn) == json_rpc_error(1, -32001, "invalid session")
          end)

        warnings = log |> String.split("\n") |> Enum.count(&String.contains?(&1, "[warning]"))
        assert warnings == 1, "bad snapshot: #{inspect(bad)}"
        refute log =~ "stored-id"
      end
    end

    test "an extra key is removed and the session starts" do
      PersistentSnapshot.put(server(), "stored-id", Map.put(restored_snapshot(), :extra, true))

      assert restore_ping("stored-id").status == 200

      assert {:ok, view} = Sessions.lookup(server(), "stored-id")
      assert view.initialized
      assert view.log_level == :warning
    end

    test "a failure of load gives 404 through the pipeline" do
      PersistentSnapshot.fail(server(), :load, :raise)

      log =
        Utils.capture_log([level: :error], fn ->
          conn = restore_ping("stored-id")
          assert conn.status == 404
          assert decode_resp(conn) == json_rpc_error(1, -32001, "invalid session")
        end)

      assert log =~ "session snapshot load failed"
      assert Utils.session_count(server()) == 0
    end
  end

  describe "save" do
    test "an initialized session saves its persistent part after each change" do
      session_id = initialized_session()

      assert %{
               log_level: :warning,
               subscriptions: ["file:///a.md"],
               client_capabilities: %{},
               principal_key: nil
             } = PersistentSnapshot.get(server(), session_id)

      :ok = Sessions.unsubscribe(server(), session_id, "file:///a.md")
      wait_saved(server(), session_id, %{log_level: :warning, subscriptions: []})
    end

    test "a session that is not initialized saves nothing" do
      {:ok, session_id} = Sessions.start(server())
      :ok = Sessions.set_log_level(server(), session_id, :warning)

      assert PersistentSnapshot.get(server(), session_id) == nil
      assert PersistentSnapshot.calls(server(), :save) == 0
    end

    test "a failure of save writes a log and the session goes on" do
      for kind <- [:raise, :throw, :exit, :error] do
        PersistentSnapshot.fail(server(), :save, kind)
        session_id = Utils.create_session(server(), initialized: true)

        log =
          capture_log(fn ->
            assert :ok = Sessions.set_log_level(server(), session_id, :debug)
            wait_save_done(server(), session_id, 2)
          end)

        assert log =~ "session snapshot save failed"
        assert {:ok, %{log_level: :debug}} = Sessions.lookup(server(), session_id)
      end
    end

    test "a change that gives the same persistent part saves nothing" do
      session_id = initialized_session()
      saves_before = PersistentSnapshot.calls(server(), :save)

      :ok = Sessions.set_log_level(server(), session_id, :warning)
      :ok = Sessions.subscribe(server(), session_id, "file:///a.md")

      assert PersistentSnapshot.calls(server(), :save) == saves_before
    end

    test "a subscribe of the same uri twice saves once" do
      session_id = Utils.create_session(server(), initialized: true)
      wait_saved(server(), session_id, %{log_level: nil, subscriptions: []})
      saves_before = PersistentSnapshot.calls(server(), :save)

      :ok = Sessions.subscribe(server(), session_id, "file:///b.md")
      wait_save_done(server(), session_id, saves_before + 1)

      :ok = Sessions.subscribe(server(), session_id, "file:///b.md")
      assert PersistentSnapshot.calls(server(), :save) == saves_before + 1
      assert %{subscriptions: ["file:///b.md"]} = PersistentSnapshot.get(server(), session_id)
    end

    test "a failed save is tried again at the next change" do
      session_id = initialized_session()
      saves_before = PersistentSnapshot.calls(server(), :save)
      PersistentSnapshot.fail(server(), :save, :raise)

      log =
        capture_log(fn ->
          assert :ok = Sessions.set_log_level(server(), session_id, :debug)
          wait_save_done(server(), session_id, saves_before + 1)
        end)

      assert log =~ "session snapshot save failed"
      assert %{log_level: :warning} = PersistentSnapshot.get(server(), session_id)

      PersistentSnapshot.heal(server(), :save)
      :ok = Sessions.unsubscribe(server(), session_id, "file:///a.md")

      wait_saved(server(), session_id, %{log_level: :debug, subscriptions: []})
    end

    test "a restored session saves nothing at its start" do
      session_id = initialized_session()
      restart_instance()
      saves_before = PersistentSnapshot.calls(server(), :save)

      assert restore_ping(session_id).status == 200
      assert PersistentSnapshot.calls(server(), :save) == saves_before
    end

    test "a restored session with the subscriptions in another order saves nothing at a change that gives the same snapshot" do
      PersistentSnapshot.put(server(), "stored-id", %{
        restored_snapshot()
        | subscriptions: ["file:///b.md", "file:///a.md"]
      })

      assert restore_ping("stored-id").status == 200
      saves_before = PersistentSnapshot.calls(server(), :save)

      :ok = Sessions.set_log_level(server(), "stored-id", :warning)
      :ok = Sessions.subscribe(server(), "stored-id", "file:///a.md")

      assert PersistentSnapshot.calls(server(), :save) == saves_before
    end

    test "with no snapshot module the session holds no saved snapshot" do
      no_snapshot = Module.concat(server(), "NoSnapshotSaved")
      Utils.start_instance(Servers.Default, name: no_snapshot)

      session_id = Utils.create_session(no_snapshot, initialized: true)
      data = Utils.session_data(no_snapshot, session_id)
      assert data.saved == nil

      :ok = Sessions.set_log_level(no_snapshot, session_id, :debug)
      :ok = Sessions.subscribe(no_snapshot, session_id, "file:///a.md")

      data = Utils.session_data(no_snapshot, session_id)
      assert data.saved == nil
      assert data.view.log_level == :debug
      assert data.subscriptions == MapSet.new(["file:///a.md"])
    end

    test "a slow save does not block a call to the same session" do
      session_id = initialized_session()
      PersistentSnapshot.slow(server(), :save, 500)

      {duration, :ok} =
        :timer.tc(fn -> Sessions.set_log_level(server(), session_id, :debug) end)

      assert duration < 100_000

      wait_saved(server(), session_id, %{log_level: :debug, subscriptions: ["file:///a.md"]})
    end
  end

  describe "the writer of the saves" do
    test "an instance with no snapshot module starts no writer" do
      no_snapshot = Module.concat(server(), "NoSnapshotWriter")
      Utils.start_instance(Servers.Default, name: no_snapshot)

      assert OzMcp.Instance.whereis(no_snapshot, :snapshot_writer) == :not_running
    end

    test "a burst of changes writes at most two snapshots and the last one holds the last value" do
      session_id = initialized_session()
      saves_before = PersistentSnapshot.calls(server(), :save)
      PersistentSnapshot.slow(server(), :save, 200)

      for level <- [
            :debug,
            :error,
            :debug,
            :error,
            :debug,
            :error,
            :debug,
            :error,
            :debug,
            :error
          ] do
        :ok = Sessions.set_log_level(server(), session_id, level)
      end

      wait_saved(server(), session_id, %{log_level: :error, subscriptions: ["file:///a.md"]})

      assert PersistentSnapshot.calls(server(), :save) <= saves_before + 2
      assert PersistentSnapshot.calls(server(), :save) > saves_before
    end

    test "a delete after a change leaves no snapshot" do
      PersistentSnapshot.slow(server(), :save, 5)

      for _ <- 1..50 do
        session_id = initialized_session()
        :ok = Sessions.set_log_level(server(), session_id, :debug)

        assert delete_session(session_id).status == 200

        # The writer deletes the snapshot after the answer of the request.
        #
        wait_until(fn -> PersistentSnapshot.get(server(), session_id) == nil end, 200)
        assert {:error, :no_session} = Sessions.lookup(server(), session_id)
      end
    end

    test "a delete stops a save that does not end in time" do
      session_id = initialized_session()
      {:ok, writer} = OzMcp.Instance.whereis(server(), :snapshot_writer)
      PersistentSnapshot.slow(server(), :save, 10_000)

      :ok = Sessions.set_log_level(server(), session_id, :debug)
      wait_until(fn -> writer_running?(writer, session_id) end, 200)

      log =
        capture_log(fn ->
          #
          # The request does not wait for the stop of the save: the end
          # of the session hands the delete to the writer and answers.
          #
          {duration, status} = :timer.tc(fn -> delete_session(session_id).status end)
          assert status == 200
          assert duration < 5_000_000

          # The stop of the save (at the time limit) and the delete
          # behind it come after the answer: the wait keeps the capture
          # open until the log of the stop ran.
          #
          wait_until(fn -> writer_idle?(server(), session_id) end, 600)
        end)

      assert log =~ "session snapshot save stopped"

      assert PersistentSnapshot.get(server(), session_id) == nil
      assert {:error, :no_session} = Sessions.lookup(server(), session_id)
    end

    test "a crash of a worker does not stop the writer" do
      session_id = initialized_session()
      {:ok, writer} = OzMcp.Instance.whereis(server(), :snapshot_writer)
      PersistentSnapshot.slow(server(), :save, 200)

      :ok = Sessions.set_log_level(server(), session_id, :debug)
      wait_until(fn -> writer_running?(writer, session_id) end, 200)

      %{workers: %{^session_id => worker}} = :sys.get_state(writer)
      worker_pid = worker.pid
      ref = Process.monitor(worker_pid)
      Process.exit(worker_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^worker_pid, :killed}

      wait_until(fn -> writer_idle?(server(), session_id) end, 200)

      # The writer is the same process and it takes the next save.
      #
      PersistentSnapshot.clear_slow(server(), :save)
      :ok = Sessions.set_log_level(server(), session_id, :error)
      wait_saved(server(), session_id, %{log_level: :error, subscriptions: ["file:///a.md"]})
      assert OzMcp.Instance.whereis(server(), :snapshot_writer) == {:ok, writer}
    end

    test "a pending delete waits for a restart of the calls supervisor" do
      session_id = initialized_session()
      {:ok, writer} = OzMcp.Instance.whereis(server(), :snapshot_writer)
      workers = TreeProbe.workers(server())
      :ok = Supervisor.terminate_child(workers, calls_child_id())

      :ok = RestoreCache.put_deleted(server(), session_id)
      assert :ok = Writer.delete(server(), session_id)

      wait_until(fn -> OzMcp.Instance.whereis(server(), :calls) == :not_running end, 200)
      wait_until(fn -> writer_has_job?(writer, session_id) end, 200)

      assert {:ok, _pid} = Supervisor.restart_child(workers, calls_child_id())

      wait_until(fn -> PersistentSnapshot.calls(server(), :delete) == 1 end, 200)
      wait_until(fn -> writer_idle?(server(), session_id) end, 200)

      assert PersistentSnapshot.get(server(), session_id) == nil
      assert RestoreCache.deleted?(server(), session_id) == false
      assert OzMcp.Instance.whereis(server(), :snapshot_writer) == {:ok, writer}
    end

    test "a pending save waits for a restart of the calls supervisor" do
      session_id = initialized_session()
      {:ok, writer} = OzMcp.Instance.whereis(server(), :snapshot_writer)
      workers = TreeProbe.workers(server())
      :ok = Supervisor.terminate_child(workers, calls_child_id())

      :ok = Sessions.set_log_level(server(), session_id, :debug)

      wait_until(fn -> OzMcp.Instance.whereis(server(), :calls) == :not_running end, 200)
      wait_until(fn -> writer_has_job?(writer, session_id) end, 200)

      assert {:ok, _pid} = Supervisor.restart_child(workers, calls_child_id())

      wait_saved(server(), session_id, %{log_level: :debug, subscriptions: ["file:///a.md"]})
      assert OzMcp.Instance.whereis(server(), :snapshot_writer) == {:ok, writer}
    end

    test "a kill of the writer stops its worker: the delete writes no snapshot again" do
      session_id = initialized_session()
      {:ok, writer} = OzMcp.Instance.whereis(server(), :snapshot_writer)
      PersistentSnapshot.slow(server(), :save, 1_000)

      :ok = Sessions.set_log_level(server(), session_id, :debug)
      wait_until(fn -> writer_running?(writer, session_id) end, 200)

      %{workers: %{^session_id => worker}} = :sys.get_state(writer)
      worker_pid = worker.pid
      worker_ref = Process.monitor(worker_pid)
      writer_ref = Process.monitor(writer)

      Process.exit(writer, :kill)
      assert_receive {:DOWN, ^writer_ref, :process, ^writer, :killed}

      # The life of a worker ends with the life of the writer.
      #
      assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, :killed}, 1_000

      wait_new_writer(writer)

      # The delete cannot race a save of the old writer: the new writer
      # holds no save of the id and the worker of the old writer is gone.
      #
      assert delete_session(session_id).status == 200

      wait_until(fn -> PersistentSnapshot.calls(server(), :delete) == 1 end, 200)

      # The stopped save would have ended one second after its start: no
      # snapshot may appear in the store while the wait runs.
      #
      refute Utils.eventually(
               fn -> PersistentSnapshot.get(server(), session_id) != nil end,
               1_500
             )

      assert {:error, :no_session} = Sessions.lookup(server(), session_id)
    end

    test "a kill of the writer stops its save: the next change holds the last value" do
      session_id = initialized_session()
      {:ok, writer} = OzMcp.Instance.whereis(server(), :snapshot_writer)
      PersistentSnapshot.slow(server(), :save, 500)

      :ok = Sessions.set_log_level(server(), session_id, :debug)
      wait_until(fn -> writer_running?(writer, session_id) end, 200)

      writer_ref = Process.monitor(writer)
      Process.exit(writer, :kill)
      assert_receive {:DOWN, ^writer_ref, :process, ^writer, :killed}
      wait_new_writer(writer)

      # The new writer takes the next change: the save that the writer
      # stopped cannot write the old value over the new one.
      #
      PersistentSnapshot.clear_slow(server(), :save)
      :ok = Sessions.set_log_level(server(), session_id, :error)
      wait_saved(server(), session_id, %{log_level: :error, subscriptions: ["file:///a.md"]})

      # The stopped save would have ended 500 ms after its start: the
      # value it holds must not change while the wait runs.
      #
      refute Utils.eventually(
               fn ->
                 case PersistentSnapshot.get(server(), session_id) do
                   %{log_level: :error} -> false
                   _other -> true
                 end
               end,
               600
             )

      assert %{log_level: :error} = PersistentSnapshot.get(server(), session_id)
    end

    @tag :capture_log
    test "a crash of the writer ends no session and removes no task record" do
      session_id = Utils.create_session(server(), initialized: true)
      task_id = insert_task_record(session_id)

      {:ok, old_writer} = OzMcp.Instance.whereis(server(), :snapshot_writer)
      ref = Process.monitor(old_writer)
      Process.exit(old_writer, :kill)
      assert_receive {:DOWN, ^ref, :process, ^old_writer, :killed}

      wait_new_writer(old_writer)

      assert {:ok, %{initialized: true}} = Sessions.state(server(), session_id)

      assert {:ok, _record} =
               OzMcp.Tasks.get(server(), Utils.owner(session_id), task_id)

      # The writer of the restart takes the next save.
      #
      :ok = Sessions.set_log_level(server(), session_id, :debug)
      wait_saved(server(), session_id, %{log_level: :debug, subscriptions: []})
    end
  end

  describe "the delete of the writer" do
    test "a delete replaces a pending save: only the delete runs" do
      session_id = initialized_session()
      wait_until(fn -> writer_idle?(server(), session_id) end, 200)
      saves_idle = PersistentSnapshot.calls(server(), :save)
      PersistentSnapshot.slow(server(), :save, 2_000)

      # The writer holds the worker before the worker calls the store: the
      # test waits for the count of the store, so the slow save runs.
      #
      :ok = Sessions.set_log_level(server(), session_id, :debug)
      wait_until(fn -> PersistentSnapshot.calls(server(), :save) == saves_idle + 1 end, 200)

      # A second save waits in the writer while the first one runs.
      #
      :ok = Sessions.set_log_level(server(), session_id, :error)
      saves_before = saves_idle + 1

      :ok = RestoreCache.put_deleted(server(), session_id)
      assert :ok = Writer.delete(server(), session_id)

      wait_until(fn -> PersistentSnapshot.calls(server(), :delete) == 1 end, 1_200)
      wait_until(fn -> writer_idle?(server(), session_id) end, 200)

      # The pending save is dropped: the store holds no snapshot again.
      #
      assert PersistentSnapshot.calls(server(), :save) == saves_before
      assert PersistentSnapshot.get(server(), session_id) == nil
      assert RestoreCache.deleted?(server(), session_id) == false
    end

    test "an idle id is deleted once, the event holds the outcome and the tombstone is cleared" do
      ref = TelemetryCapture.attach()
      PersistentSnapshot.put(server(), "ended-id", restored_snapshot())
      :ok = RestoreCache.put_deleted(server(), "ended-id")
      assert RestoreCache.deleted?(server(), "ended-id")

      assert :ok = Writer.delete(server(), "ended-id")

      wait_until(fn -> PersistentSnapshot.calls(server(), :delete) == 1 end, 200)
      wait_until(fn -> writer_idle?(server(), "ended-id") end, 200)

      assert PersistentSnapshot.get(server(), "ended-id") == nil
      assert RestoreCache.deleted?(server(), "ended-id") == false

      assert [%{action: :delete, result: :ok}] = delete_events(ref)
    end

    test "a delete behind a running save runs after the save" do
      session_id = initialized_session()
      ref = TelemetryCapture.attach()
      PersistentSnapshot.slow(server(), :save, 300)

      :ok = Sessions.set_log_level(server(), session_id, :debug)
      {:ok, writer} = OzMcp.Instance.whereis(server(), :snapshot_writer)
      wait_until(fn -> writer_running?(writer, session_id) end, 200)

      :ok = RestoreCache.put_deleted(server(), session_id)
      assert :ok = Writer.delete(server(), session_id)

      wait_until(fn -> PersistentSnapshot.calls(server(), :delete) == 1 end, 200)
      wait_until(fn -> writer_idle?(server(), session_id) end, 200)

      assert PersistentSnapshot.get(server(), session_id) == nil
      assert RestoreCache.deleted?(server(), session_id) == false

      assert [%{action: :save, result: :ok}, %{action: :delete, result: :ok}] =
               write_events(ref)
    end

    test "a delete stops a save that blocks it after three seconds" do
      session_id = initialized_session()
      {:ok, writer} = OzMcp.Instance.whereis(server(), :snapshot_writer)
      PersistentSnapshot.slow(server(), :save, 10_000)

      :ok = Sessions.set_log_level(server(), session_id, :debug)
      wait_until(fn -> writer_running?(writer, session_id) end, 200)

      :ok = RestoreCache.put_deleted(server(), session_id)

      {duration, log} =
        :timer.tc(fn ->
          capture_log(fn ->
            assert :ok = Writer.delete(server(), session_id)
            wait_until(fn -> PersistentSnapshot.calls(server(), :delete) == 1 end, 1_200)
            wait_until(fn -> writer_idle?(server(), session_id) end, 200)
          end)
        end)

      assert log =~ "session snapshot save stopped"
      #
      # The delete starts when the stopped save is over, at about 3 s.
      #
      assert duration > 2_500_000 and duration < 8_000_000
      assert PersistentSnapshot.get(server(), session_id) == nil
      assert RestoreCache.deleted?(server(), session_id) == false
    end

    test "a delete that the store does not answer is stopped and the tombstone stays" do
      ref = TelemetryCapture.attach()
      session_id = initialized_session()
      PersistentSnapshot.slow(server(), :delete, 10_000)
      :ok = RestoreCache.put_deleted(server(), session_id)

      log =
        capture_log(fn ->
          assert :ok = Writer.delete(server(), session_id)
          wait_until(fn -> writer_idle?(server(), session_id) end, 1_200)
        end)

      assert log =~ "session snapshot delete stopped"
      assert PersistentSnapshot.calls(server(), :delete) == 1
      assert RestoreCache.deleted?(server(), session_id) == true

      assert [%{action: :delete, result: :stopped}] = delete_events(ref)
    end

    test "a save that arrives while the delete of the id runs is ignored" do
      session_id = initialized_session()
      saves_before = PersistentSnapshot.calls(server(), :save)
      PersistentSnapshot.slow(server(), :delete, 500)

      :ok = RestoreCache.put_deleted(server(), session_id)
      assert :ok = Writer.delete(server(), session_id)

      # A save of the ended session arrives while the delete runs.
      #
      :ok = Writer.save(server(), session_id, %{log_level: :debug})

      wait_until(fn -> PersistentSnapshot.calls(server(), :delete) == 1 end, 200)
      wait_until(fn -> writer_idle?(server(), session_id) end, 200)

      assert PersistentSnapshot.calls(server(), :save) == saves_before
      assert PersistentSnapshot.get(server(), session_id) == nil
      assert RestoreCache.deleted?(server(), session_id) == false
    end

    test "a delete that the store refused keeps the tombstone and gives the outcome error" do
      ref = TelemetryCapture.attach()
      session_id = initialized_session()

      for kind <- [:error, :raise] do
        PersistentSnapshot.fail(server(), :delete, kind)
        :ok = RestoreCache.put_deleted(server(), session_id)

        log =
          capture_log(fn ->
            assert :ok = Writer.delete(server(), session_id)
            wait_until(fn -> writer_idle?(server(), session_id) end, 200)
          end)

        assert log =~ "session snapshot delete failed"
        assert RestoreCache.deleted?(server(), session_id) == true
        assert PersistentSnapshot.get(server(), session_id) != nil
      end

      assert [%{action: :delete, result: :error}, %{action: :delete, result: :error}] =
               delete_events(ref)
    end

    test "a kill of a delete worker does not stop the writer" do
      session_id = initialized_session()
      {:ok, writer} = OzMcp.Instance.whereis(server(), :snapshot_writer)
      PersistentSnapshot.slow(server(), :delete, 2_000)
      :ok = RestoreCache.put_deleted(server(), session_id)

      assert :ok = Writer.delete(server(), session_id)
      wait_until(fn -> writer_running?(writer, session_id) end, 200)

      %{workers: %{^session_id => worker}} = :sys.get_state(writer)
      worker_pid = worker.pid
      ref = Process.monitor(worker_pid)
      Process.exit(worker_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^worker_pid, :killed}

      wait_until(fn -> writer_idle?(server(), session_id) end, 200)
      assert OzMcp.Instance.whereis(server(), :snapshot_writer) == {:ok, writer}

      # The same writer takes the next delete.
      #
      PersistentSnapshot.clear_slow(server(), :delete)
      :ok = RestoreCache.put_deleted(server(), session_id)
      assert :ok = Writer.delete(server(), session_id)

      # The count of the deletes holds the delete that ran: the kill of
      # the first worker can land before its call of the store started
      # (the count stays 0 until the next delete) or after it (the count
      # holds both deletes for a moment). The store holds no snapshot and
      # the tombstone is gone after the wait: the deletes of the check
      # below carry the assertion.
      #
      wait_until(fn -> PersistentSnapshot.calls(server(), :delete) >= 1 end, 200)
      wait_until(fn -> writer_idle?(server(), session_id) end, 200)

      assert PersistentSnapshot.get(server(), session_id) == nil
      assert RestoreCache.deleted?(server(), session_id) == false
    end

    test "a writer that does not run hands the delete to a task of the instance" do
      ref = TelemetryCapture.attach()
      supervisor = Support.Helpers.TreeProbe.workers(server())
      PersistentSnapshot.put(server(), "ended-id", restored_snapshot())
      :ok = RestoreCache.put_deleted(server(), "ended-id")

      :ok = Supervisor.terminate_child(supervisor, Writer)

      wait_until(
        fn -> OzMcp.Instance.whereis(server(), :snapshot_writer) == :not_running end,
        200
      )

      instance = server()
      assert :ok = Writer.delete(instance, "ended-id")

      # The task of the fallback deletes from the store, then removes the
      # tombstone, then emits the event. The event is its last step, so the
      # test waits for it before it reads the store and the tombstone.
      #
      assert_receive {[:oz_mcp, :snapshot, :write], ^ref, _,
                      %{instance: ^instance, action: :delete, result: :ok}},
                     2_000

      assert PersistentSnapshot.get(instance, "ended-id") == nil
      assert RestoreCache.deleted?(instance, "ended-id") == false
      assert delete_events(ref) == []
    end

    test "a delete call that times out keeps the tombstone until the ordered delete ends" do
      ref = TelemetryCapture.attach()
      instance = server()
      session_id = initialized_session()
      {:ok, writer} = OzMcp.Instance.whereis(server(), :snapshot_writer)
      PersistentSnapshot.slow(server(), :save, 3_000)

      # A save runs in the writer while the session hands its delete over.
      #
      :ok = Sessions.set_log_level(server(), session_id, :debug)
      wait_until(fn -> writer_running?(writer, session_id) end, 200)

      # The writer cannot answer: the call passes its time limit and
      # the delete goes to a task of the instance.
      #
      :sys.suspend(writer)

      on_exit(fn ->
        try do
          :sys.resume(writer)
        catch
          :exit, _ -> :ok
        end
      end)

      :ok = RestoreCache.put_deleted(server(), session_id)

      {duration, :ok} = :timer.tc(fn -> Writer.delete(server(), session_id) end)
      assert duration > 900_000 and duration < 5_000_000

      # The event of the fallback comes after its decision about the
      # tombstone: this wait holds the checks below until that
      # decision ran. The handler is global, so the pattern names the
      # instance: an event of a test of another file must not match.
      #
      assert_receive {[:oz_mcp, :snapshot, :write], ^ref, _measurements,
                      %{instance: ^instance, action: :delete, result: :ok}},
                     2_000

      # The writer may still run the save of the id: the fallback
      # delete leaves the tombstone.
      #
      assert RestoreCache.deleted?(server(), session_id) == true
      assert PersistentSnapshot.calls(server(), :delete) == 1

      # The writer resumes: the ordered delete runs after the running
      # save ends and it removes the tombstone.
      #
      :sys.resume(writer)

      wait_until(
        fn ->
          PersistentSnapshot.get(server(), session_id) == nil and
            not RestoreCache.deleted?(server(), session_id)
        end,
        600
      )

      assert PersistentSnapshot.calls(server(), :delete) == 2
    end
  end

  describe "a restart of the instance" do
    @tag :capture_log
    test "keeps the session: the next request starts it again, initialized" do
      session_id = initialized_session()
      {:ok, old_pid} = OzMcp.Instance.whereis(server(), {:session, session_id})

      restart_instance()
      assert Utils.session_count(server()) == 0

      assert restore_ping(session_id).status == 200

      assert {:ok, view} = Sessions.lookup(server(), session_id)
      assert view.initialized
      assert view.log_level == :warning

      {:ok, new_pid} = OzMcp.Instance.whereis(server(), {:session, session_id})
      refute new_pid == old_pid
      assert Utils.subscriptions(server(), session_id) == ["file:///a.md"]
      assert Utils.session_data(server(), session_id).view.initialized
    end

    @tag :capture_log
    test "keeps the scopes of the subscriptions: the restored session is checked at the touch" do
      session_id = Utils.create_session(server(), initialized: true)

      :ok = Sessions.subscribe(server(), session_id, "file:///secret.md", ["files:write"])

      wait_saved(server(), session_id, %{
        subscriptions: ["file:///secret.md"],
        subscription_scopes: %{"file:///secret.md" => ["files:write"]}
      })

      restart_instance()
      assert restore_ping(session_id).status == 200

      assert Utils.session_data(server(), session_id).subscription_scopes == %{
               "file:///secret.md" => ["files:write"]
             }

      # The restored subscription is checked at the next touch.
      #
      :ok = Sessions.touch(server(), session_id, ["files:read"])

      assert Utils.eventually(
               fn -> Utils.subscriptions(server(), session_id) == [] end,
               2_000
             )
    end

    test "a store that loads a nil for the scopes gives a session that survives the touch" do
      PersistentSnapshot.put(
        server(),
        "stored-id",
        Map.put(restored_snapshot(), :subscription_scopes, nil)
      )

      assert restore_ping("stored-id").status == 200

      # A touch with a list of scopes: the session must not crash on
      # the nil of the store.
      #
      :ok = Sessions.touch(server(), "stored-id", ["files:read"])
      assert {:ok, %{initialized: true}} = Sessions.lookup(server(), "stored-id")

      # A repeat subscribe of a uri of the snapshot writes the entry of
      # its scopes and the save holds no nil again.
      #
      :ok = Sessions.subscribe(server(), "stored-id", "file:///a.md", ["files:write"])

      assert Utils.session_data(server(), "stored-id").subscription_scopes == %{
               "file:///a.md" => ["files:write"]
             }

      wait_saved(server(), "stored-id", %{
        subscriptions: ["file:///a.md"],
        subscription_scopes: %{"file:///a.md" => ["files:write"]}
      })
    end

    test "gives the same session to 20 requests at the same time" do
      session_id = initialized_session()
      restart_instance()

      # The requests run in tasks: a task does not inherit the process
      # dictionary of the test, so the instance name goes into the closure.
      #
      inst = server()

      results =
        1..20
        |> Enum.map(fn _ -> Task.async(fn -> restore_ping(inst, session_id).status end) end)
        |> Task.await_many()

      assert Enum.all?(results, &(&1 == 200))
      assert Utils.session_count(server()) == 1
    end

    test "a read of a live session does not call load" do
      session_id = initialized_session()

      assert {:ok, _view} = Sessions.lookup(server(), session_id)
      assert {:ok, _state} = Sessions.state(server(), session_id)
      assert PersistentSnapshot.calls(server(), :load) == 0
    end

    test "gives no session for an id that has no snapshot" do
      assert {:error, :no_session} = Sessions.lookup(server(), "unknown")
    end

    test "a session that started again is ready: it takes the requests of a session" do
      session_id = initialized_session()
      restart_instance()

      assert restore_ping(session_id).status == 200
      assert :ok = Sessions.set_log_level(server(), session_id, :error)
      wait_saved(server(), session_id, %{log_level: :error, subscriptions: ["file:///a.md"]})
    end
  end

  describe "delete" do
    test "a request at once after the kill of the session is restored" do
      session_id = initialized_session()
      {:ok, pid} = OzMcp.Instance.whereis(server(), {:session, session_id})

      # A first request warms the code of the pipeline: a cold request is
      # slower than the exit handling of the Registry and hides the race.
      #
      assert restore_ping(session_id).status == 200

      # No wait for the exit: the Registry still holds the entry.
      #
      Process.exit(pid, :kill)
      assert restore_ping(session_id).status == 200

      assert {:ok, new_pid} = OzMcp.Instance.whereis(server(), {:session, session_id})
      assert new_pid != pid
    end

    test "a crash of the session keeps the snapshot" do
      session_id = initialized_session()
      {:ok, pid} = OzMcp.Instance.whereis(server(), {:session, session_id})

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert PersistentSnapshot.get(server(), session_id) != nil
      assert restore_ping(session_id).status == 200
    end

    test "an evicted session leaves a tombstone and deletes its snapshot" do
      session_id = initialized_session()
      assert PersistentSnapshot.get(server(), session_id) != nil

      PersistentSnapshot.slow(server(), :delete, 200)

      assert :ok = OzMcp.Session.evict(server(), session_id)
      assert RestoreCache.deleted?(server(), session_id)

      wait_until(fn -> PersistentSnapshot.get(server(), session_id) == nil end, 100)
    end

    test "a slow delete does not hold the DELETE request" do
      session_id = initialized_session()
      PersistentSnapshot.slow(server(), :delete, 10_000)

      {duration, conn} = :timer.tc(fn -> delete_session(session_id) end)

      assert conn.status == 200
      assert duration < 1_000_000
      assert {:error, :no_session} = Sessions.lookup(server(), session_id)
    end

    test "a request with the id of a session whose delete runs gets 404, not a restore" do
      session_id = initialized_session()
      PersistentSnapshot.slow(server(), :delete, 10_000)
      assert delete_session(session_id).status == 200
      load_calls_before = PersistentSnapshot.calls(server(), :load)

      # The store still holds the snapshot (the delete sleeps).
      #
      assert PersistentSnapshot.get(server(), session_id) != nil

      conn = restore_ping(session_id)
      assert conn.status == 404
      assert decode_resp(conn) == json_rpc_error(1, -32001, "invalid session")
      assert PersistentSnapshot.calls(server(), :load) == load_calls_before
    end

    test "the restore works again for a new session only; the old id stays 404" do
      session_id = initialized_session()
      PersistentSnapshot.slow(server(), :delete, 2_000)
      assert delete_session(session_id).status == 200

      # The store still holds the snapshot while the delete runs.
      #
      assert PersistentSnapshot.get(server(), session_id) != nil

      # The mark of the ended id hides that id only: the snapshot of a
      # session that the store holds starts again.
      #
      PersistentSnapshot.put(server(), "stored-id", restored_snapshot())
      assert restore_ping("stored-id").status == 200
      assert Utils.session_count(server()) == 1

      conn = restore_ping(session_id)
      assert conn.status == 404
      assert decode_resp(conn) == json_rpc_error(1, -32001, "invalid session")

      # The delete of the store ended: the mark is gone and the store
      # holds nothing, so the old id stays 404.
      #
      wait_until(fn -> PersistentSnapshot.get(server(), session_id) == nil end, 300)
      assert {:error, :no_session} = Sessions.lookup(server(), session_id)

      conn = restore_ping(session_id)
      assert conn.status == 404
      assert decode_resp(conn) == json_rpc_error(1, -32001, "invalid session")
    end

    test "a hung delete is stopped and the log says so" do
      session_id = initialized_session()
      PersistentSnapshot.slow(server(), :delete, 10_000)

      log =
        capture_log(fn ->
          #
          # The request does not wait for the hung store: the end of the
          # session hands the delete to the writer and answers.
          #
          {duration, status} = :timer.tc(fn -> delete_session(session_id).status end)
          assert status == 200
          assert duration < 1_000_000

          # The stop of the delete comes at its time limit, after the
          # answer of the request: the wait keeps the capture open until
          # the log of the stop ran.
          #
          wait_until(fn -> writer_idle?(server(), session_id) end, 1_200)
        end)

      assert log =~ "session snapshot delete stopped"

      # The store kept the snapshot: the restore of the id stays 404.
      #
      assert PersistentSnapshot.get(server(), session_id) != nil

      conn = restore_ping(session_id)
      assert conn.status == 404
      assert decode_resp(conn) == json_rpc_error(1, -32001, "invalid session")
    end

    test "the end of a session deletes its snapshot and no lookup starts it again" do
      session_id = initialized_session()

      assert :ok = Sessions.terminate(server(), session_id)

      # The delete runs in the writer, after the end of the session.
      #
      wait_until(fn -> PersistentSnapshot.get(server(), session_id) == nil end, 200)
      assert {:error, :no_session} = Sessions.lookup(server(), session_id)
    end

    @tag :capture_log
    test "a failure inside the session process keeps the snapshot" do
      session_id = initialized_session()
      {:ok, pid} = OzMcp.Instance.whereis(server(), {:session, session_id})

      ref = Process.monitor(pid)
      catch_exit(:gen_statem.call(pid, {:update_view, :not_a_keyword_list}))
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      assert PersistentSnapshot.calls(server(), :delete) == 0
      assert PersistentSnapshot.get(server(), session_id) != nil
    end

    test "a failure of delete writes a log and the session ends" do
      session_id = initialized_session()
      PersistentSnapshot.fail(server(), :delete, :raise)

      log =
        capture_log(fn ->
          assert :ok = Sessions.terminate(server(), session_id)

          # The delete runs in the writer, after the end of the session:
          # the wait keeps the capture open until the log of the failure
          # ran.
          #
          wait_until(fn -> writer_idle?(server(), session_id) end, 200)
        end)

      assert log =~ "session snapshot delete failed"
      assert :not_running = OzMcp.Instance.whereis(server(), {:session, session_id})
    end

    test "the idle timer deletes the snapshot" do
      Utils.stop_instance(server())

      Utils.start_instance(@server_module,
        name: server(),
        session_snapshot: PersistentSnapshot,
        session_timeout_ms: 1_000
      )

      session_id = initialized_session()

      wait_until(
        fn -> OzMcp.Instance.whereis(server(), {:session, session_id}) == :not_running end,
        400
      )

      # The delete runs in the writer, after the end of the session.
      #
      wait_until(fn -> PersistentSnapshot.get(server(), session_id) == nil end, 200)
      assert {:error, :no_session} = Sessions.lookup(server(), session_id)
    end
  end

  describe "load" do
    test "a failure of load is an unknown session and writes a log" do
      session_id = initialized_session()
      restart_instance()

      for kind <- [:raise, :throw, :exit, :error] do
        PersistentSnapshot.fail(server(), :load, kind)

        log =
          capture_log(fn ->
            assert Sessions.fetch_snapshot(server(), session_id) == {:error, :failed}
          end)

        assert log =~ "session snapshot load failed"
      end

      PersistentSnapshot.heal(server(), :load)
      assert {:ok, snapshot} = Sessions.fetch_snapshot(server(), session_id)
      assert is_map(snapshot)

      # The failure stayed out of the cache of the instance: a request
      # starts the session again.
      #
      assert restore_ping(session_id).status == 200
    end
  end

  defp wait_until(fun, retries) do
    if Utils.eventually(fun, retries * 10) do
      :ok
    else
      flunk("condition was not met in time")
    end
  end

  # Waits until the store holds the fields of `expected`. The writes run
  # outside of the session process, so the test waits for the store.
  #
  defp wait_saved(instance, session_id, expected) do
    wait_until(
      fn ->
        snapshot = PersistentSnapshot.get(instance, session_id)
        snapshot != nil and Map.take(snapshot, Map.keys(expected)) == expected
      end,
      400
    )
  end

  # Waits until the store counted `calls` saves and the writer holds no
  # worker for the session: the save is over (its log, if any, is out).
  #
  defp wait_save_done(instance, session_id, calls) do
    wait_until(fn -> PersistentSnapshot.calls(instance, :save) >= calls end, 200)
    wait_until(fn -> writer_idle?(instance, session_id) end, 200)
    :ok
  end

  defp writer_running?(writer, session_id) do
    %{workers: workers} = :sys.get_state(writer)
    Map.has_key?(workers, session_id)
  end

  # True when the writer holds the job of the id, pending or running.
  #
  defp writer_has_job?(writer, session_id) do
    %{pending: pending, workers: workers} = :sys.get_state(writer)
    Map.has_key?(pending, session_id) or Map.has_key?(workers, session_id)
  end

  defp calls_child_id, do: {OzMcp.Instance.names(server()), :calls}

  defp writer_idle?(instance, session_id) do
    case OzMcp.Instance.whereis(instance, :snapshot_writer) do
      {:ok, writer} -> not writer_running?(writer, session_id)
      :not_running -> true
    end
  end

  defp insert_task_record(session_id) do
    now = DateTime.utc_now()
    task_id = OzMcp.Utils.Generator.task_id()

    :ok =
      OzMcp.Tasks.Records.put(OzMcp.Tasks.EtsStore, server(), %OzMcp.Tasks.EtsStore{
        task_id: task_id,
        session_id: session_id,
        owner_key: Utils.owner(session_id),
        seq: System.unique_integer([:positive]),
        status: :completed,
        created_at: now,
        last_updated_at: now,
        ttl: 60_000,
        result: {:ok, %{}}
      })

    task_id
  end

  defp wait_new_writer(old_pid) do
    wait_until(
      fn ->
        case OzMcp.Instance.whereis(server(), :snapshot_writer) do
          {:ok, pid} -> pid != old_pid and Process.alive?(pid)
          :not_running -> false
        end
      end,
      200
    )
  end

  # A request that the router runs for a session id: the way a request
  # reads a session after the restore moved into the pipeline.
  #
  defp restore_ping(session_id), do: restore_ping(server(), session_id)

  defp restore_ping(instance, session_id) do
    body =
      :json.encode(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}) |> IO.iodata_to_binary()

    conn(:post, "/", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("mcp-session-id", session_id)
    |> OzMcp.Router.call(OzMcp.Router.init(server: instance, allowed_origins: []))
  end

  defp delete_session(session_id) do
    conn(:delete, "/", "")
    |> put_req_header("mcp-session-id", session_id)
    |> OzMcp.Router.call(OzMcp.Router.init(server: server(), allowed_origins: []))
  end

  # The events of the restore in the drained list of the capture.
  #
  defp restore_events(ref) do
    ref
    |> TelemetryCapture.drain(server())
    |> Enum.filter(fn {name, _, _} -> name == [:oz_mcp, :session, :restore] end)
  end

  # The events of the writes of the snapshot in the drained list.
  #
  defp write_events(ref) do
    ref
    |> TelemetryCapture.drain(server())
    |> Enum.filter(fn {name, _, _} -> name == [:oz_mcp, :snapshot, :write] end)
    |> Enum.map(&elem(&1, 2))
  end

  # The events of the deletes of the snapshot in the drained list.
  #
  defp delete_events(ref) do
    Enum.filter(write_events(ref), &(&1.action == :delete))
  end

  defp decode_resp(conn), do: :json.decode(conn.resp_body)

  defp json_rpc_error(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end

  defp restored_snapshot do
    %{
      principal_key: nil,
      protocol_version: nil,
      client_info: %{"name" => "restore-test", "version" => "1"},
      client_capabilities: %{},
      log_level: :warning,
      subscriptions: ["file:///a.md"]
    }
  end
end
