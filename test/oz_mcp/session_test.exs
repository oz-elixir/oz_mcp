defmodule OzMcp.SessionTest do
  #
  # Every test starts its own instance with a unique name, so the tests
  # run in parallel.
  #
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  import Plug.Test

  alias OzMcp.Instance
  alias OzMcp.PostStream
  alias OzMcp.Session
  alias OzMcp.Session.View
  alias OzMcp.Sessions
  alias Support.Helpers.SessionLeak
  alias Support.Helpers.SessionProbe
  alias Support.Helpers.TelemetryCapture
  alias Support.Helpers.Utils
  alias Support.Servers

  @server Servers.RuntimeTest

  defp start_instance(extra \\ []) do
    name = :"session_test_#{System.unique_integer([:positive])}"
    opts = Keyword.merge([server: @server, name: name, allowed_origins: []], extra)
    start_supervised!({OzMcp, opts})
    name
  end

  defp start_session(instance, id \\ "sid-1") do
    attrs = %{
      session_id: id,
      principal_key: "p1",
      protocol_version: "2025-11-25",
      client_info: %{"name" => "c"},
      client_capabilities: %{"roots" => %{}}
    }

    {:ok, pid} = Session.start(instance, attrs)
    {pid, id}
  end

  defp down?(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} -> {:down, reason}
    after
      2_500 -> :alive
    end
  end

  describe "start and view" do
    test "registers the public view with the pid" do
      instance = start_instance()
      {pid, id} = start_session(instance)

      assert {:ok, %View{} = view} = SessionProbe.view(instance, id)
      assert view.pid == pid
      assert view.principal_key == "p1"
      assert view.protocol_version == "2025-11-25"
      assert view.client_info == %{"name" => "c"}
      assert view.client_capabilities == %{"roots" => %{}}
      assert view.initialized == false
      assert view.log_level == nil
      assert {:ok, ^pid} = Instance.whereis(instance, {:session, id})
    end

    test "view/2 gives :error for an unknown session or instance" do
      instance = start_instance()
      assert SessionProbe.view(instance, "none") == :error
      assert SessionProbe.view(:no_such_instance, "none") == :error
    end

    test "the sessions are temporary children of the session supervisor" do
      instance = start_instance()
      {pid, _id} = start_session(instance)

      assert [{_, ^pid, _, _}] =
               DynamicSupervisor.which_children(Instance.via(instance, :sessions))
    end

    test "max_sessions limits the sessions" do
      instance = start_instance(max_sessions: 1)
      start_session(instance, "a")

      assert {:error, :max_children} =
               Session.start(instance, %{session_id: "b", principal_key: nil})
    end
  end

  describe "states" do
    test "initialized moves the session to :ready and sets the view" do
      instance = start_instance()
      {pid, id} = start_session(instance)

      assert {:initializing, _} = :sys.get_state(pid)
      assert :ok = Session.initialized(instance, id)
      assert {:ready, _} = :sys.get_state(pid)
      assert {:ok, %View{initialized: true}} = SessionProbe.view(instance, id)
    end

    test "initialized is idempotent" do
      instance = start_instance()
      {pid, id} = start_session(instance)

      assert :ok = Session.initialized(instance, id)
      assert :ok = Session.initialized(instance, id)
      assert {:ready, _} = :sys.get_state(pid)
    end

    test "close stops the session and removes its entry" do
      instance = start_instance()
      {pid, id} = start_session(instance)
      :ok = Session.initialized(instance, id)

      ref = Process.monitor(pid)
      assert :ok = Session.close(instance, id)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :terminated}}
      assert Utils.eventually(fn -> SessionProbe.view(instance, id) == :error end)
    end

    test "close works in the :initializing state" do
      instance = start_instance()
      {pid, id} = start_session(instance)

      ref = Process.monitor(pid)
      assert :ok = Session.close(instance, id, :deleted)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :deleted}}
    end

    test "calls to a session that does not exist give {:error, :no_session}" do
      instance = start_instance()
      assert Session.initialized(instance, "none") == {:error, :no_session}
      assert Session.close(instance, "none") == {:error, :no_session}
    end

    test "calls to an instance that does not run give {:error, :unavailable}" do
      assert Session.initialized(:session_test_not_running, "none") == {:error, :unavailable}
      assert Session.close(:session_test_not_running, "none") == {:error, :unavailable}
    end

    test "a lookup after close finds no session, before the process is down" do
      instance = start_instance()
      {_pid, id} = start_session(instance)

      assert :ok = Session.close(instance, id)
      assert SessionProbe.view(instance, id) == :error
      assert {:error, :no_session} = Sessions.lookup(instance, id)
    end

    test "a call that no clause takes answers {:error, :badarg} at once" do
      instance = start_instance()
      {pid, _id} = start_session(instance)

      {micros, answer} = :timer.tc(fn -> :gen_statem.call(pid, :nonsense) end)
      assert answer == {:error, :badarg}
      assert micros < 100_000
    end

    test "a call in the state :closing answers {:error, :no_session}" do
      instance = start_instance()
      {pid, id} = start_session(instance)
      :ok = Session.initialized(instance, id)

      # The state :closing is transient: no external call reaches it. The
      # replace puts the process there to exercise the defense clause.
      #
      :sys.replace_state(pid, fn {_state, data} -> {:closing, data} end)

      assert :gen_statem.call(pid, {:nonsense, "x"}) == {:error, :no_session}
    end

    test "in the state :closing, a request to the client answers {:error, :session_terminated}" do
      instance = start_instance()
      {pid, id} = start_session(instance)
      :ok = Session.initialized(instance, id)

      :sys.replace_state(pid, fn {_state, data} -> {:closing, data} end)

      assert Session.request_client(instance, id, {:request, nil}, self(), "ping", nil) ==
               {:error, :session_terminated}
    end

    test "an unknown call in the state :closing gives no warning" do
      instance = start_instance()
      {pid, id} = start_session(instance)
      :ok = Session.initialized(instance, id)

      :sys.replace_state(pid, fn {_state, data} -> {:closing, data} end)

      log =
        capture_log([level: :debug], fn ->
          assert :gen_statem.call(pid, {:nonsense, "x"}) == {:error, :no_session}
        end)

      refute log =~ "has no clause"
    end

    test "the warning of a call that no clause takes holds the tag only" do
      instance = start_instance()
      {pid, _id} = start_session(instance)

      log =
        capture_log(fn ->
          assert :gen_statem.call(pid, {:nonsense, "secret-text"}) == {:error, :badarg}
        end)

      assert log =~ "session call :nonsense"
      refute log =~ "secret-text"
    end
  end

  describe "evict" do
    test "an idle session ends and its entry goes" do
      instance = start_instance()
      {pid, id} = start_session(instance)
      :ok = Session.initialized(instance, id)

      ref = Process.monitor(pid)
      assert :ok = Session.evict(instance, id)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :evicted}}
      assert Utils.eventually(fn -> SessionProbe.view(instance, id) == :error end)
    end

    test "a session that never got notifications/initialized ends" do
      instance = start_instance()
      {pid, id} = start_session(instance)

      assert {:initializing, _} = :sys.get_state(pid)

      ref = Process.monitor(pid)
      assert :ok = Session.evict(instance, id)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :evicted}}
    end

    test "a session with a request in flight gives busy and stays" do
      instance = start_instance()
      {pid, id} = start_session(instance)
      :ok = Session.initialized(instance, id)

      owner = spawn(fn -> Process.sleep(:infinity) end)
      assert :ok = Utils.open_request(instance, id, 7, owner)

      assert {:error, :busy} = Session.evict(instance, id)
      assert Process.alive?(pid)
      assert {:ok, _view} = SessionProbe.view(instance, id)

      Process.exit(owner, :kill)
    end

    test "an unknown id gives no_session" do
      instance = start_instance()
      assert Session.evict(instance, "none") == {:error, :no_session}
    end

    test "an instance that does not run gives unavailable" do
      assert Session.evict(:session_test_not_running, "none") == {:error, :unavailable}
    end
  end

  describe "timers" do
    test "a session that is not initialized stops after session_init_timeout_ms" do
      instance = start_instance(session_init_timeout_ms: 50)
      {pid, _id} = start_session(instance)

      assert {:down, {:shutdown, :init_timeout}} = down?(pid)
    end

    test "initialized cancels the init timer" do
      instance = start_instance(session_init_timeout_ms: 500)
      {pid, id} = start_session(instance)
      :ok = Session.initialized(instance, id)

      # Nothing happens within the span of the cancelled timer: the DOWN of
      # the session must not arrive.
      #
      ref = Process.monitor(pid)
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 800
    end

    test "a ready session stops after session_timeout_ms" do
      instance = start_instance(session_timeout_ms: 1_000)
      {pid, id} = start_session(instance)
      :ok = Session.initialized(instance, id)

      assert {:down, {:shutdown, :idle}} = down?(pid)
    end

    test "touch starts the idle timer again" do
      instance = start_instance(session_timeout_ms: 1_000)
      {pid, id} = start_session(instance)
      :ok = Session.initialized(instance, id)

      # Without a touch the session stops 1000 ms after the last one. Five
      # touches 300 ms apart keep it alive for 1500 ms. A gap needs an
      # overshoot of 700 ms to fail, so a loaded machine does not break it.
      # Each wait is the check that the DOWN did not arrive before the touch.
      #
      ref = Process.monitor(pid)

      for _ <- 1..5 do
        refute_receive {:DOWN, ^ref, :process, ^pid, _}, 300
        Session.touch(instance, id)
      end

      assert {:down, {:shutdown, :idle}} = down?(pid)
    end

    test "an open GET stream stops the idle timer" do
      instance = start_instance(session_timeout_ms: 1_000)
      {pid, id} = start_session(instance)
      :ok = Session.initialized(instance, id)

      stream = spawn(fn -> Process.sleep(:infinity) end)
      assert {:ok, %{mode: :get}} = Session.open_stream(instance, id, :get, stream, nil)

      # The open stream holds the idle timer off: no DOWN within the span
      # of the timeout.
      #
      ref = Process.monitor(pid)
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 1_300

      Process.exit(stream, :kill)
      assert {:down, {:shutdown, :idle}} = down?(pid)
    end

    test "a request in flight stops the idle timer" do
      instance = start_instance(session_timeout_ms: 1_000)
      {pid, id} = start_session(instance)
      :ok = Session.initialized(instance, id)

      owner = spawn(fn -> Process.sleep(:infinity) end)
      assert :ok = Utils.open_request(instance, id, 7, owner)

      # The request in flight holds the idle timer off: no DOWN within the
      # span of the timeout.
      #
      ref = Process.monitor(pid)
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 1_300

      assert :ok = Session.end_request(instance, id, 7)
      assert {:down, {:shutdown, :idle}} = down?(pid)
      Process.exit(owner, :kill)
    end

    test "a touch while a request is in flight does not arm the idle timer" do
      instance = start_instance(session_timeout_ms: 1_000)
      {pid, id} = start_session(instance)
      :ok = Session.initialized(instance, id)

      owner = spawn(fn -> Process.sleep(:infinity) end)
      assert :ok = Utils.open_request(instance, id, 7, owner)

      # Without a touch the session stops 1000 ms after the last one. Five
      # touches 300 ms apart keep it alive for 1500 ms: a touch during a
      # request must not start a timer of its own. Each wait is the check
      # that the DOWN did not arrive before the touch.
      #
      ref = Process.monitor(pid)

      for _ <- 1..5 do
        refute_receive {:DOWN, ^ref, :process, ^pid, _}, 300
        Session.touch(instance, id)
      end

      assert :ok = Session.end_request(instance, id, 7)
      assert {:down, {:shutdown, :idle}} = down?(pid)
      Process.exit(owner, :kill)
    end

    test "the death of the owner of the last request starts the idle timer again" do
      instance = start_instance(session_timeout_ms: 1_000)
      {pid, id} = start_session(instance)
      :ok = Session.initialized(instance, id)

      owner = spawn(fn -> Process.sleep(:infinity) end)
      assert :ok = Utils.open_request(instance, id, 7, owner)

      # The request in flight holds the idle timer off: no DOWN within the
      # span of the timeout.
      #
      ref = Process.monitor(pid)
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 1_300

      Process.exit(owner, :kill)
      assert {:down, {:shutdown, :idle}} = down?(pid)
    end

    test "an open GET stream and a request: the timer stays off while the request lives" do
      instance = start_instance(session_timeout_ms: 1_000)
      {pid, id} = start_session(instance)
      :ok = Session.initialized(instance, id)

      stream = spawn(fn -> Process.sleep(:infinity) end)
      assert {:ok, %{mode: :get}} = Session.open_stream(instance, id, :get, stream, nil)

      owner = spawn(fn -> Process.sleep(:infinity) end)
      assert :ok = Utils.open_request(instance, id, 7, owner)

      # The stream ends: the request in flight still holds the timer off.
      #
      Process.exit(stream, :kill)
      ref = Process.monitor(pid)
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 1_300

      assert :ok = Session.end_request(instance, id, 7)
      assert {:down, {:shutdown, :idle}} = down?(pid)
      Process.exit(owner, :kill)
    end
  end

  describe "the view after each change" do
    test "update_view changes the fields in the Registry" do
      instance = start_instance()
      {_pid, id} = start_session(instance)

      assert :ok =
               Session.update_view(instance, id,
                 log_level: :warning,
                 client_capabilities: %{"sampling" => %{}}
               )

      assert {:ok, view} = SessionProbe.view(instance, id)
      assert view.log_level == :warning
      assert view.client_capabilities == %{"sampling" => %{}}
    end

    test "update_view ignores the fields that are not public" do
      instance = start_instance()
      {pid, id} = start_session(instance)

      assert :ok = Session.update_view(instance, id, pid: self(), initialized: true)
      assert {:ok, %View{pid: ^pid, initialized: false}} = SessionProbe.view(instance, id)
    end
  end

  describe "event log" do
    test "keeps the events and honors the limits of the instance" do
      instance = start_instance(sse_event_log_size: 2)
      {_pid, id} = start_session(instance)

      for n <- 1..3, do: SessionProbe.append_event(instance, id, "st", {"#{n}", "x"})

      assert {:ok, [{"2", "x"}, {"3", "x"}]} = Utils.events_after(instance, id, "st", nil)
      assert {:ok, [{"3", "x"}]} = Utils.events_after(instance, id, "st", "2")
      assert Utils.events_after(instance, id, "st", "1") == :gap
    end

    test "honors sse_event_log_bytes" do
      instance = start_instance(sse_event_log_bytes: 4)
      {_pid, id} = start_session(instance)

      for n <- 1..3, do: SessionProbe.append_event(instance, id, "st", {"#{n}", "abc"})

      assert {:ok, [{"3", "abc"}]} = Utils.events_after(instance, id, "st", nil)
    end

    test "all_events orders the events of every stream by the order of the writes" do
      instance = start_instance()
      {_pid, id} = start_session(instance)

      :ok = SessionProbe.append_event(instance, id, "a", {"a:1", "x"})
      :ok = SessionProbe.append_event(instance, id, "b", {"b:1", "x"})
      :ok = SessionProbe.append_event(instance, id, "a", {"a:2", "x"})

      assert {:ok, [{"a:1", "x"}, {"b:1", "x"}, {"a:2", "x"}]} =
               SessionProbe.events_after(instance, id, nil)
    end
  end

  describe "event log retention" do
    defp retention_session(extra) do
      instance = start_instance(extra)
      {_pid, id} = start_session(instance)
      :ok = Session.initialized(instance, id)
      {instance, id}
    end

    # The entry of the stream of a request, with the owner `owner`.
    #
    defp post_stream(instance, id, request_id, stream_id, owner \\ self()) do
      :ok = Utils.open_request(instance, id, request_id, owner, {stream_id, :sse})
    end

    test "the ring of an ended stream is dropped after the resume window" do
      {instance, id} = retention_session(sse_resume_window_ms: 50)

      post_stream(instance, id, 1, "st")
      :ok = Session.emit(instance, id, {:request, 1}, "x")

      assert {:sse, "st:2"} =
               Utils.close_request(instance, id, 1, "st", {:response, "y", false})

      assert {:ok, [_, _]} = Utils.events_after(instance, id, "st", nil)

      # The window is over: the session drops the ring.
      #
      assert Utils.eventually(fn ->
               Utils.events_after(instance, id, "st", nil) == :gap
             end)
    end

    test "a window of 0 drops the ring at once" do
      {instance, id} = retention_session(sse_resume_window_ms: 0)

      post_stream(instance, id, 1, "st")
      :ok = Session.emit(instance, id, {:request, 1}, "x")

      assert {:sse, "st:2"} =
               Utils.close_request(instance, id, 1, "st", {:response, "y", false})

      assert Utils.events_after(instance, id, "st", nil) == :gap
    end

    test "a final event for a stream with no entry gives :gone and logs nothing" do
      {instance, id} = retention_session(sse_resume_window_ms: 50)

      assert :gone = Utils.close_request(instance, id, 1, "st2", {:response, "z", false})

      assert {:ok, []} = SessionProbe.events_after(instance, id, nil)

      # The window is over and no ring was made: no event can appear.
      #
      refute Utils.eventually(
               fn ->
                 match?({:ok, [_ | _]}, SessionProbe.events_after(instance, id, nil))
               end,
               150
             )
    end

    test "the ring of a stream with an owner that went down is dropped after the window" do
      {instance, id} = retention_session(sse_resume_window_ms: 50)

      owner =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      post_stream(instance, id, 9, "st3", owner)
      :ok = Session.emit(instance, id, {:request, 9}, "x")

      assert {:ok, [{"st3:1", "x"}]} = Utils.events_after(instance, id, "st3", nil)

      send(owner, :stop)

      # The owner is down: the session drops the ring after the window.
      #
      assert Utils.eventually(fn ->
               Utils.events_after(instance, id, "st3", nil) == :gap
             end)
    end

    test "a resume after the window logs at debug level, with no warning" do
      {instance, id} = retention_session(sse_resume_window_ms: 50)

      post_stream(instance, id, 1, "st")
      :ok = Session.emit(instance, id, {:request, 1}, "x")

      assert {:sse, "st:2"} =
               Utils.close_request(instance, id, 1, "st", {:response, "y", false})

      # The window is over: the ring is dropped, so the resume finds no stream.
      #
      assert Utils.eventually(fn ->
               Utils.events_after(instance, id, "st", nil) == :gap
             end)

      log =
        capture_log([level: :debug], fn ->
          assert {:error, :no_stream} = Session.open_stream(instance, id, :get, self(), "st:0")
        end)

      assert log =~ "a resumed POST stream is over and its event log was dropped"
      refute log =~ "the event log caps removed"
    end

    test "a gap in a live ring still gives the warning" do
      {instance, id} = retention_session(sse_resume_window_ms: 50, sse_event_log_size: 1)

      post_stream(instance, id, 1, "st")
      :ok = Session.emit(instance, id, {:request, 1}, "x")
      :ok = Session.emit(instance, id, {:request, 1}, "y")

      log =
        capture_log([level: :debug], fn ->
          assert {:ok, %{mode: :resume, replay: [{"st:2", "y"}]}} =
                   Session.open_stream(instance, id, :get, self(), "st:0")
        end)

      assert log =~ "the event log caps removed events of a resumed POST stream"
      refute log =~ "its event log was dropped"
    end

    test "a resume of a live stream whose ring the budget evicted gives the warning" do
      {instance, id} =
        retention_session(sse_event_log_session_bytes: 2048, sse_event_log_bytes: 1024)

      post_stream(instance, id, 1, "a")
      :ok = Session.emit(instance, id, {:request, 1}, big_1k())
      :ok = SessionProbe.append_event(instance, id, "b", {"b:1", big_1k()})
      :ok = SessionProbe.append_event(instance, id, "c", {"c:1", big_1k()})

      refute MapSet.member?(
               Support.Helpers.SessionLeak.snapshot(pid_for(instance, id)).log_streams,
               "a"
             )

      log =
        capture_log([level: :debug], fn ->
          assert {:ok, %{mode: :resume, replay: []}} =
                   Session.open_stream(instance, id, :get, self(), "a:0")
        end)

      assert log =~ "the event log caps removed events of a resumed POST stream"
      refute log =~ "its event log was dropped"
    end

    test "the rings of ended streams go away and the maps go back to their idle size" do
      {instance, id} = retention_session(sse_resume_window_ms: 50)

      for n <- 1..20 do
        post_stream(instance, id, n, "st#{n}")
        :ok = Session.emit(instance, id, {:request, n}, "x")
        final = "st#{n}:2"

        assert {:sse, ^final} =
                 Utils.close_request(instance, id, n, "st#{n}", {:response, "y", false})

        :ok = Session.end_request(instance, id, n)
      end

      # The windows are over: every ring is dropped and the maps are idle again.
      #
      assert Utils.eventually(fn ->
               Support.Helpers.SessionLeak.snapshot(pid_for(instance, id)).log_streams ==
                 MapSet.new()
             end)

      snap = Support.Helpers.SessionLeak.snapshot(pid_for(instance, id))

      assert MapSet.size(snap.log_streams) == 0
      assert snap.log_bytes == 0
      assert snap.streams == 0
      assert snap.requests == 0
      assert snap.outbound == 0
      assert snap.refs == 0
    end

    test "within the window the rings of the ended streams stay" do
      {instance, id} = retention_session([])

      for n <- 1..5 do
        post_stream(instance, id, n, "st#{n}")
        :ok = Session.emit(instance, id, {:request, n}, "x")
        final = "st#{n}:2"

        assert {:sse, ^final} =
                 Utils.close_request(instance, id, n, "st#{n}", {:response, "y", false})

        :ok = Session.end_request(instance, id, n)
      end

      snap = Support.Helpers.SessionLeak.snapshot(pid_for(instance, id))

      assert snap.log_streams == MapSet.new(for n <- 1..5, do: "st#{n}")
    end

    test "the session budget evicts the oldest rings" do
      {instance, id} =
        retention_session(sse_event_log_session_bytes: 3072, sse_event_log_bytes: 1024)

      for n <- 1..10 do
        :ok = SessionProbe.append_event(instance, id, "st#{n}", {"st#{n}:1", big_1k()})
      end

      snap = Support.Helpers.SessionLeak.snapshot(pid_for(instance, id))

      assert snap.log_bytes <= 3072 + 1024
      refute MapSet.member?(snap.log_streams, "st1")
      assert MapSet.member?(snap.log_streams, "st10")
    end

    test "the cap on the number of rings evicts the oldest rings" do
      {instance, id} = retention_session(sse_event_log_max_streams: 3)

      for n <- 1..5 do
        :ok = SessionProbe.append_event(instance, id, "st#{n}", {"st#{n}:1", "x"})
      end

      snap = Support.Helpers.SessionLeak.snapshot(pid_for(instance, id))

      assert MapSet.size(snap.log_streams) == 3
      refute MapSet.member?(snap.log_streams, "st1")
      refute MapSet.member?(snap.log_streams, "st2")
      assert MapSet.member?(snap.log_streams, "st3")
      assert MapSet.member?(snap.log_streams, "st5")
      assert snap.log_bytes == 3
    end

    test "a resume of a live stream whose ring the cap evicted gives the warning" do
      {instance, id} = retention_session(sse_event_log_max_streams: 2)

      post_stream(instance, id, 1, "a")
      :ok = Session.emit(instance, id, {:request, 1}, "x")
      :ok = SessionProbe.append_event(instance, id, "b", {"b:1", "x"})
      :ok = SessionProbe.append_event(instance, id, "c", {"c:1", "x"})

      snap = Support.Helpers.SessionLeak.snapshot(pid_for(instance, id))

      assert MapSet.size(snap.log_streams) == 2
      refute MapSet.member?(snap.log_streams, "a")

      log =
        capture_log([level: :debug], fn ->
          assert {:ok, %{mode: :resume, replay: []}} =
                   Session.open_stream(instance, id, :get, self(), "a:0")
        end)

      assert log =~ "the event log caps removed events of a resumed POST stream"
      refute log =~ "its event log was dropped"
    end

    test "a resume of an ended POST stream whose ring the cap evicted gives :no_stream" do
      {instance, id} = retention_session(sse_event_log_max_streams: 2)

      post_stream(instance, id, 1, "a")
      :ok = Session.emit(instance, id, {:request, 1}, "x")

      assert {:sse, "a:2"} =
               Utils.close_request(instance, id, 1, "a", {:response, "y", false})

      :ok = Session.end_request(instance, id, 1)

      :ok = SessionProbe.append_event(instance, id, "b", {"b:1", "x"})
      :ok = SessionProbe.append_event(instance, id, "c", {"c:1", "x"})

      refute MapSet.member?(
               Support.Helpers.SessionLeak.snapshot(pid_for(instance, id)).log_streams,
               "a"
             )

      log =
        capture_log([level: :debug], fn ->
          assert {:error, :no_stream} = Session.open_stream(instance, id, :get, self(), "a:0")
        end)

      assert log =~ "a resumed POST stream is over and its event log was dropped"
      refute log =~ "the event log caps removed"
    end

    defp pid_for(instance, id) do
      {:ok, %{pid: pid}} = SessionProbe.view(instance, id)
      pid
    end

    defp big_1k, do: String.duplicate("x", 1024)
  end

  describe "the GET streams" do
    defp ready_session(extra \\ []) do
      instance = start_instance(extra)
      {pid, id} = start_session(instance)
      :ok = Session.initialized(instance, id)
      {instance, pid, id}
    end

    defp fake_stream, do: spawn(fn -> Process.sleep(:infinity) end)

    @notification ~s({"jsonrpc":"2.0","method":"notifications/tools/list_changed"})

    test "each stream gets its own id and the session counts the live streams" do
      {instance, _pid, id} = ready_session()
      first = fake_stream()
      second = fake_stream()

      assert {:ok, %{mode: :get, stream_id: first_id}} =
               Session.open_stream(instance, id, :get, first, nil)

      assert {:ok, %{mode: :get, stream_id: second_id}} =
               Session.open_stream(instance, id, :stdio, second, nil)

      assert first_id != second_id
      assert {:ok, %View{streams: 2}} = SessionProbe.view(instance, id)

      Process.exit(first, :kill)

      assert Utils.eventually(fn ->
               match?({:ok, %View{streams: 1}}, SessionProbe.view(instance, id))
             end)
    end

    test "an event of the session goes to the newest stream only, with its stream id" do
      {instance, _pid, id} = ready_session()
      me = self()
      other = spawn_link(fn -> relay_stream_messages(me) end)

      assert {:ok, %{stream_id: other_id}} = Session.open_stream(instance, id, :get, other, nil)
      assert {:ok, %{stream_id: my_id}} = Session.open_stream(instance, id, :get, me, nil)

      :ok = Session.emit(instance, id, :session, @notification)

      assert_receive {:oz_mcp_stream, ^my_id, {:event, event_id, @notification}}, 5_000
      refute_receive {:relayed, _}, 100
      assert other_id != my_id

      assert {:ok, [{^event_id, @notification}]} = SessionProbe.events_after(instance, id, nil)
    end

    test "a session that is not initialized sends and logs nothing" do
      instance = start_instance()
      {_pid, id} = start_session(instance)

      assert {:ok, %{stream_id: _}} = Session.open_stream(instance, id, :get, self(), nil)
      :ok = Session.emit(instance, id, :session, @notification)

      :ok =
        OzMcp.PubSub.Registry.broadcast(
          instance,
          :initialized,
          {:session_event, nil, @notification}
        )

      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
      assert {:ok, []} = SessionProbe.events_after(instance, id, nil)
    end

    test "a resume from the priming id replays the events that came after it" do
      {instance, _pid, id} = ready_session()

      assert {:ok, %{priming_id: priming_id, replay: []}} =
               Session.open_stream(instance, id, :get, self(), nil)

      :ok = Session.emit(instance, id, :session, @notification)
      assert_receive {:oz_mcp_stream, _, {:event, event_id, _}}, 5_000

      assert {:ok, %{mode: :get, replay: [{^event_id, @notification}], priming_id: nil}} =
               Session.open_stream(instance, id, :get, fake_stream(), priming_id)
    end

    test "a fresh GET stream starts at its own id 0 and numbers its events" do
      {instance, _pid, id} = ready_session()

      assert {:ok, %{stream_id: stream_id, priming_id: priming_id}} =
               Session.open_stream(instance, id, :get, self(), nil)

      assert String.starts_with?(stream_id, "g.")
      assert priming_id == "#{stream_id}:0"

      :ok = Session.emit(instance, id, :session, @notification)
      assert_receive {:oz_mcp_stream, ^stream_id, {:event, first, @notification}}, 5_000

      :ok = Session.emit(instance, id, :session, @notification)
      assert_receive {:oz_mcp_stream, ^stream_id, {:event, second, @notification}}, 5_000

      assert first == "#{stream_id}:1"
      assert second == "#{stream_id}:2"

      # The log holds the events of the stream and no marker.
      #
      assert {:ok, [{^first, @notification}, {^second, @notification}]} =
               SessionProbe.events_after(instance, id, nil)
    end

    test "each live GET stream has its own ring: a resume replays its own events only" do
      {instance, _pid, id} = ready_session()
      me = self()
      other = spawn_link(fn -> relay_stream_messages(me) end)

      assert {:ok, %{stream_id: a}} = Session.open_stream(instance, id, :get, other, nil)
      :ok = Session.emit(instance, id, :session, @notification)
      assert_receive {:relayed, {:oz_mcp_stream, ^a, {:event, a1, @notification}}}, 5_000

      assert {:ok, %{stream_id: b}} = Session.open_stream(instance, id, :get, me, nil)
      :ok = Session.emit(instance, id, :session, @notification)
      assert_receive {:oz_mcp_stream, ^b, {:event, b1, @notification}}, 5_000
      refute_receive {:relayed, _}, 100

      # Each event went to the ring of the stream that got it.
      #
      assert {:ok, [{^a1, @notification}]} = Utils.events_after(instance, id, a, nil)
      assert {:ok, [{^b1, @notification}]} = Utils.events_after(instance, id, b, nil)

      # A resume of one stream replays nothing of the other one.
      #
      assert {:ok, %{replay: []}} = Session.open_stream(instance, id, :get, me, "#{a}:1")
    end

    test "the stdio stream gets ids of its own and writes no ring" do
      {instance, _pid, id} = ready_session()

      assert {:ok, %{stream_id: stream_id}} =
               Session.open_stream(instance, id, :stdio, self(), nil)

      assert String.starts_with?(stream_id, "g.")

      :ok = Session.emit(instance, id, :session, @notification)
      assert_receive {:oz_mcp_stream, ^stream_id, {:event, event_id, @notification}}, 5_000
      assert event_id == "#{stream_id}:1"

      # The stdio stream cannot resume: its event went in no log.
      #
      assert :gap = Utils.events_after(instance, id, stream_id, nil)
      assert {:ok, []} = SessionProbe.events_after(instance, id, nil)
    end

    test "the budget evicts the ring of a GET stream; the ring that got the append stays" do
      {instance, _pid, id} =
        ready_session(sse_event_log_bytes: 1024, sse_event_log_session_bytes: 1024)

      assert {:ok, %{stream_id: stream_id}} = Session.open_stream(instance, id, :get, self(), nil)

      :ok = Session.emit(instance, id, :session, @notification)
      assert_receive {:oz_mcp_stream, ^stream_id, {:event, _, _}}, 5_000

      # An event of a POST stream takes the whole budget: the ring of the
      # GET stream is the oldest, so it goes.
      #
      :ok = SessionProbe.append_event(instance, id, "st", {"st:1", big_1k()})

      snap = Support.Helpers.SessionLeak.snapshot(pid_for(instance, id))
      assert MapSet.to_list(snap.log_streams) == ["st"]
    end

    test "max_streams_per_session counts the live streams, the session drops a dead one" do
      {instance, _pid, id} = ready_session(max_streams_per_session: 1)
      first = fake_stream()

      assert {:ok, _} = Session.open_stream(instance, id, :get, first, nil)

      # A stdio stream is never replaced: the dead GET stream still holds
      # the slot.
      #
      assert {:error, :too_many_streams} =
               Session.open_stream(instance, id, :stdio, fake_stream(), nil)

      Process.exit(first, :kill)

      assert Utils.eventually(fn ->
               match?({:ok, _}, Session.open_stream(instance, id, :stdio, fake_stream(), nil))
             end)
    end

    test "a fresh GET over the limit ends the oldest stream and keeps its ring" do
      {instance, _pid, id} = ready_session(max_streams_per_session: 1)

      assert {:ok, %{stream_id: first_id, priming_id: priming_id}} =
               Session.open_stream(instance, id, :get, self(), nil)

      :ok =
        Sessions.notify_all(instance, %{
          "jsonrpc" => "2.0",
          "method" => "notifications/tools/list_changed"
        })

      assert_receive {:oz_mcp_stream, ^first_id, {:event, event_id, _}}, 5_000

      # The second fresh stream ends the first one and takes the slot.
      #
      me = self()
      second = spawn_link(fn -> relay_stream_messages(me) end)

      assert {:ok, %{stream_id: second_id}} =
               Session.open_stream(instance, id, :get, second, nil)

      assert_receive {:oz_mcp_stream, ^first_id, :terminate}, 5_000
      assert {:ok, %View{streams: 1}} = SessionProbe.view(instance, id)

      # The ring of the ended stream survives: the resume replays its
      # event and the resume itself ends the second stream.
      #
      assert {:ok, %{replay: [{^event_id, _}]}} =
               Session.open_stream(instance, id, :get, fake_stream(), priming_id)

      assert_receive {:relayed, {:oz_mcp_stream, ^second_id, :terminate}}, 5_000
    end

    test "a resume of a live stream counts the stream it replaces one time" do
      {instance, _pid, id} = ready_session(max_streams_per_session: 1)

      assert {:ok, %{stream_id: stream_id, priming_id: priming_id}} =
               Session.open_stream(instance, id, :get, fake_stream(), nil)

      assert {:ok, %{stream_id: ^stream_id, replay: []}} =
               Session.open_stream(instance, id, :get, fake_stream(), priming_id)

      assert {:ok, %View{streams: 1}} = SessionProbe.view(instance, id)

      assert {:error, :too_many_streams} =
               Session.open_stream(instance, id, :stdio, fake_stream(), nil)
    end

    test "the end of the session sends :terminate with the id of each stream" do
      {instance, _pid, id} = ready_session()

      assert {:ok, %{stream_id: stream_id}} = Session.open_stream(instance, id, :get, self(), nil)
      assert :ok = Session.close(instance, id)

      assert_receive {:oz_mcp_stream, ^stream_id, :terminate}, 5_000
    end
  end

  describe "the subscription limit" do
    defp limited_session(extra) do
      instance = start_instance(extra)
      {_pid, id} = start_session(instance)
      :ok = Session.initialized(instance, id)
      {instance, id}
    end

    test "a third new uri over the limit is refused, the set holds two uris" do
      {instance, id} = limited_session(max_subscriptions_per_session: 2)

      assert :ok = Session.subscribe(instance, id, "file:///a.md")
      assert :ok = Session.subscribe(instance, id, "file:///b.md")

      assert {:error, :too_many_subscriptions} = Session.subscribe(instance, id, "file:///c.md")
      assert Utils.subscriptions(instance, id) == ["file:///a.md", "file:///b.md"]
    end

    test "a repeat subscribe of a uri in the set gives :ok at the limit" do
      {instance, id} = limited_session(max_subscriptions_per_session: 2)

      assert :ok = Session.subscribe(instance, id, "file:///a.md")
      assert :ok = Session.subscribe(instance, id, "file:///b.md")
      assert :ok = Session.subscribe(instance, id, "file:///a.md")

      assert Utils.subscriptions(instance, id) == ["file:///a.md", "file:///b.md"]
    end

    test "after an unsubscribe, a new subscribe works again" do
      {instance, id} = limited_session(max_subscriptions_per_session: 2)

      assert :ok = Session.subscribe(instance, id, "file:///a.md")
      assert :ok = Session.subscribe(instance, id, "file:///b.md")
      assert {:error, :too_many_subscriptions} = Session.subscribe(instance, id, "file:///c.md")

      assert :ok = Session.unsubscribe(instance, id, "file:///a.md")
      assert :ok = Session.subscribe(instance, id, "file:///c.md")

      assert Utils.subscriptions(instance, id) == ["file:///b.md", "file:///c.md"]
    end

    test "nil removes the limit" do
      {instance, id} = limited_session(max_subscriptions_per_session: nil)

      for i <- 1..5, do: assert(:ok = Session.subscribe(instance, id, "file:///#{i}.md"))

      assert length(Utils.subscriptions(instance, id)) == 5
    end

    test "a session restored with more uris than the limit keeps them, a new uri is refused" do
      {instance, _id} = limited_session(max_subscriptions_per_session: 2)

      snapshot = %{
        principal_key: nil,
        protocol_version: nil,
        client_info: %{"name" => "session-test", "version" => "1"},
        client_capabilities: %{},
        log_level: nil,
        subscriptions: ["file:///a.md", "file:///b.md", "file:///c.md"]
      }

      assert {:ok, _view} = Sessions.start_restored(instance, "stored-id", snapshot)

      assert Utils.subscriptions(instance, "stored-id") == [
               "file:///a.md",
               "file:///b.md",
               "file:///c.md"
             ]

      assert {:error, :too_many_subscriptions} =
               Session.subscribe(instance, "stored-id", "file:///d.md")

      # A repeat subscribe of a uri the restored session holds gives :ok.
      #
      assert :ok = Session.subscribe(instance, "stored-id", "file:///a.md")
    end
  end

  describe "the subscriptions and the scopes" do
    defp scoped_session(instance, uri, required) do
      {_pid, id} = start_session(instance)
      :ok = Session.initialized(instance, id)
      :ok = Session.subscribe(instance, id, uri, required)
      id
    end

    defp broadcast(instance, uri, message) do
      OzMcp.PubSub.Registry.broadcast(
        instance,
        {:subscription, uri},
        {:session_event, nil, message}
      )
    end

    test "a touch with fewer scopes ends the subscription that needs a scope" do
      ref = TelemetryCapture.attach()
      instance = start_instance()
      id = scoped_session(instance, "file:///secret.md", ["files:write"])
      assert {:ok, %{stream_id: stream_id}} = Session.open_stream(instance, id, :get, self(), nil)

      {:ok, pid} = Instance.whereis(instance, {:session, id})
      before = SessionLeak.snapshot(pid)

      :ok = Session.touch(instance, id, ["files:read"])

      assert Utils.eventually(
               fn ->
                 Utils.subscriptions(instance, id) == [] and
                   Utils.session_data(instance, id).subscription_scopes == %{}
               end,
               2_000
             )

      # The topic entry is gone: an update sends nothing.
      #
      broadcast(instance, "file:///secret.md", "sub")
      refute_receive {:oz_mcp_stream, ^stream_id, {:event, _, "sub"}}, 200

      assert [{[:oz_mcp, :subscription, :dropped], %{count: 1}, meta}] =
               TelemetryCapture.drain(ref, instance)
               |> Enum.filter(fn {name, _, _} -> name == [:oz_mcp, :subscription, :dropped] end)

      assert meta.reason == :scope
      assert SessionLeak.snapshot(pid) == before
    end

    test "a touch with all the scopes keeps the subscription" do
      ref = TelemetryCapture.attach()
      instance = start_instance()
      id = scoped_session(instance, "file:///secret.md", ["files:write"])

      :ok = Session.touch(instance, id, ["files:read", "files:write"])

      assert Utils.subscriptions(instance, id) == ["file:///secret.md"]

      assert [] =
               TelemetryCapture.drain(ref, instance)
               |> Enum.filter(fn {name, _, _} -> name == [:oz_mcp, :subscription, :dropped] end)
    end

    test "a touch with nil and the touch of no request keep the subscription" do
      instance = start_instance()
      id = scoped_session(instance, "file:///secret.md", ["files:write"])

      :ok = Session.touch(instance, id, nil)
      assert Utils.subscriptions(instance, id) == ["file:///secret.md"]

      :ok = Session.touch(instance, id)
      assert Utils.subscriptions(instance, id) == ["file:///secret.md"]
    end

    test "a uri that needs no scope is never dropped" do
      instance = start_instance()
      id = scoped_session(instance, "file:///public.md", [])

      # An empty list of granted scopes is a request of a principal that
      # holds no scope: only the uris that need scopes can go.
      #
      :ok = Session.touch(instance, id, [])

      assert Utils.subscriptions(instance, id) == ["file:///public.md"]
      assert Utils.session_data(instance, id).subscription_scopes == %{}
    end

    test "a repeat subscribe replaces the entry of the scopes" do
      instance = start_instance()
      id = scoped_session(instance, "file:///secret.md", ["files:read"])

      :ok = Session.subscribe(instance, id, "file:///secret.md", ["files:write"])

      assert Utils.session_data(instance, id).subscription_scopes == %{
               "file:///secret.md" => ["files:write"]
             }

      # An empty list of required scopes removes the entry.
      #
      :ok = Session.subscribe(instance, id, "file:///secret.md", [])
      assert Utils.session_data(instance, id).subscription_scopes == %{}
    end

    test "an unsubscribe removes the entry of the scopes" do
      instance = start_instance()
      id = scoped_session(instance, "file:///secret.md", ["files:write"])

      :ok = Session.unsubscribe(instance, id, "file:///secret.md")

      assert Utils.subscriptions(instance, id) == []
      assert Utils.session_data(instance, id).subscription_scopes == %{}
    end

    test "a snapshot keeps the entry of the scopes over a restore" do
      instance = start_instance()

      snapshot = %{
        principal_key: nil,
        protocol_version: nil,
        client_info: %{"name" => "session-test", "version" => "1"},
        client_capabilities: %{},
        log_level: nil,
        subscriptions: ["file:///secret.md"],
        subscription_scopes: %{"file:///secret.md" => ["files:write"]}
      }

      assert {:ok, _view} = Sessions.start_restored(instance, "stored-id", snapshot)

      assert Utils.session_data(instance, "stored-id").subscription_scopes ==
               snapshot.subscription_scopes

      # The restored subscription is checked at the next touch.
      #
      :ok = Session.touch(instance, "stored-id", ["files:read"])
      assert Utils.subscriptions(instance, "stored-id") == []
    end

    test "a snapshot without the key of the scopes starts a session" do
      instance = start_instance()

      snapshot = %{
        principal_key: nil,
        protocol_version: nil,
        client_info: %{"name" => "session-test", "version" => "1"},
        client_capabilities: %{},
        log_level: nil,
        subscriptions: ["file:///a.md"]
      }

      assert {:ok, _view} = Sessions.start_restored(instance, "stored-id", snapshot)
      assert Utils.session_data(instance, "stored-id").subscription_scopes == %{}
      assert Utils.subscriptions(instance, "stored-id") == ["file:///a.md"]
    end
  end

  describe "the GET streams that ended" do
    test "a resume of an ended GET stream replays its own events only" do
      {instance, _pid, id} = ready_session()
      me = self()
      other = spawn_link(fn -> relay_stream_messages(me) end)

      assert {:ok, %{stream_id: a}} = Session.open_stream(instance, id, :get, other, nil)
      :ok = Session.emit(instance, id, :session, @notification)
      assert_receive {:relayed, {:oz_mcp_stream, ^a, {:event, a1, @notification}}}, 5_000

      assert {:ok, %{stream_id: b}} = Session.open_stream(instance, id, :get, me, nil)
      :ok = Session.emit(instance, id, :session, @notification)
      assert_receive {:oz_mcp_stream, ^b, {:event, _b1, @notification}}, 5_000
      refute_receive {:relayed, _}, 100

      # A ends. A resume of it gets the events of A only, never the ones
      # that went out on B.
      #
      assert :ok = Session.close_stream(instance, id, other)

      assert {:ok, %{mode: :get, stream_id: ^a, replay: [{^a1, @notification}]}} =
               Session.open_stream(instance, id, :get, me, "#{a}:0")
    end

    test "an event that arrives after the end of a GET stream replays on its resume" do
      {instance, _pid, id} = ready_session()
      me = self()

      assert {:ok, %{stream_id: stream_id, priming_id: _}} =
               Session.open_stream(instance, id, :get, me, nil)

      :ok = Session.emit(instance, id, :session, @notification)
      assert_receive {:oz_mcp_stream, ^stream_id, {:event, first, @notification}}, 5_000

      # The stream ends. The event that comes after it waits in the ring of
      # the stream, for the resume.
      #
      assert :ok = Session.close_stream(instance, id, me)
      :ok = Session.emit(instance, id, :session, @notification)
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100

      # The resume keeps the id and the counter of the stream: the replayed
      # event carries the next number of the same stream.
      #
      assert {:ok, %{mode: :get, stream_id: ^stream_id, replay: [{second, @notification}]}} =
               Session.open_stream(instance, id, :get, me, first)

      assert second == "#{stream_id}:2"

      # The stream is live again and it continues its own counter.
      #
      :ok = Session.emit(instance, id, :session, @notification)
      assert_receive {:oz_mcp_stream, ^stream_id, {:event, third, @notification}}, 5_000
      assert third == "#{stream_id}:3"
    end

    test "a resume of an ended GET stream counts the stream as live again" do
      {instance, _pid, id} = ready_session()

      {:ok, %{stream_id: stream_id}} = Session.open_stream(instance, id, :get, self(), nil)

      :ok = Session.emit(instance, id, :session, @notification)
      assert_receive {:oz_mcp_stream, ^stream_id, {:event, event_id, _}}, 5_000

      assert :ok = Session.close_stream(instance, id, self())
      assert {:ok, %{streams: 0}} = SessionProbe.view(instance, id)

      assert {:ok, %{mode: :get, stream_id: ^stream_id}} =
               Session.open_stream(instance, id, :get, self(), event_id)

      assert {:ok, %{streams: 1}} = SessionProbe.view(instance, id)
      assert {:ok, %{stream?: true}} = Sessions.delivery(instance, id)
    end

    test "a resume of a live GET stream keeps the count of the live streams" do
      {instance, _pid, id} = ready_session()
      me = self()
      old = spawn_link(fn -> relay_stream_messages(me) end)

      assert {:ok, %{stream_id: stream_id}} = Session.open_stream(instance, id, :get, old, nil)

      :ok = Session.emit(instance, id, :session, @notification)

      assert_receive {:relayed, {:oz_mcp_stream, ^stream_id, {:event, first, @notification}}},
                     5_000

      assert {:ok, %{streams: 1}} = SessionProbe.view(instance, id)

      # The resume takes the place of the old connection: the stream is
      # still one live stream, not two and not none.
      #
      assert {:ok, %{mode: :get, stream_id: ^stream_id}} =
               Session.open_stream(instance, id, :get, me, first)

      assert {:ok, %{streams: 1}} = SessionProbe.view(instance, id)
      assert {:ok, %{stream?: true}} = Sessions.delivery(instance, id)

      # The close of the replaced process changes nothing: the stream is
      # live with the process of the resume.
      #
      assert :ok = Session.close_stream(instance, id, old)
      assert {:ok, %{streams: 1}} = SessionProbe.view(instance, id)
    end

    test "an unknown GET id or an id with no colon starts a fresh stream, with a warning" do
      {instance, _pid, id} = ready_session()

      for last_id <- ["g.nothere000001:4", "no-colon-id"] do
        log =
          capture_log(fn ->
            assert {:ok, %{mode: :get, replay: [], priming_id: priming_id}} =
                     Session.open_stream(instance, id, :get, fake_stream(), last_id)

            assert is_binary(priming_id)
          end)

        assert log =~ "Last-Event-ID"
      end

      # An unknown id of a POST stream is not a fresh stream: there is
      # nothing to resume and the session stays valid.
      #
      assert {:error, :no_stream} = Session.open_stream(instance, id, :get, self(), "forged:3")
    end

    test "the ring of a closed GET stream goes after the resume window" do
      {instance, _pid, id} = ready_session(sse_resume_window_ms: 50)
      stream_pid = fake_stream()

      {:ok, %{stream_id: stream_id}} = Session.open_stream(instance, id, :get, stream_pid, nil)
      :ok = Session.emit(instance, id, :session, @notification)
      assert {:ok, [_]} = Utils.events_after(instance, id, stream_id, nil)

      assert :ok = Session.close_stream(instance, id, stream_pid)
      assert {:ok, [_]} = Utils.events_after(instance, id, stream_id, nil)

      # The window is over: the ring of the closed GET stream is dropped.
      #
      assert Utils.eventually(fn ->
               Utils.events_after(instance, id, stream_id, nil) == :gap
             end)

      assert closed_gets(pid_for(instance, id)) == []
    end

    test "a window of 0 keeps no closed GET stream" do
      {instance, _pid, id} = ready_session(sse_resume_window_ms: 0)
      stream_pid = fake_stream()

      {:ok, %{stream_id: stream_id}} = Session.open_stream(instance, id, :get, stream_pid, nil)
      :ok = Session.emit(instance, id, :session, @notification)

      assert {:ok, [{event_id, @notification}]} =
               Utils.events_after(instance, id, stream_id, nil)

      assert :ok = Session.close_stream(instance, id, stream_pid)

      # The ring is gone at once and a resume of the id starts a fresh
      # stream, with a warning.
      #
      assert Utils.events_after(instance, id, stream_id, nil) == :gap

      log =
        capture_log(fn ->
          assert {:ok, %{mode: :get, replay: [], priming_id: priming_id}} =
                   Session.open_stream(instance, id, :get, self(), event_id)

          assert is_binary(priming_id)
        end)

      assert log =~ "Last-Event-ID"
      assert closed_gets(pid_for(instance, id)) == []
    end

    test "the cap of the closed GET streams drops the ring of the oldest one" do
      {instance, _pid, id} = ready_session()

      closed =
        for _ <- 1..17 do
          stream_pid = fake_stream()

          {:ok, %{stream_id: stream_id}} =
            Session.open_stream(instance, id, :get, stream_pid, nil)

          :ok = Session.emit(instance, id, :session, @notification)
          assert {:ok, [_]} = Utils.events_after(instance, id, stream_id, nil)
          assert :ok = Session.close_stream(instance, id, stream_pid)
          stream_id
        end

      [oldest | _] = closed
      [newest | _] = Enum.reverse(closed)

      # The 17th close removed the ring of the oldest one: its resume
      # starts a fresh stream.
      #
      assert Utils.events_after(instance, id, oldest, nil) == :gap

      assert {:ok, %{replay: [], priming_id: priming_id}} =
               Session.open_stream(instance, id, :get, fake_stream(), "#{oldest}:1")

      assert is_binary(priming_id)

      # The 16 newest ones stay and the newest one can be resumed.
      #
      assert {:ok, [_]} = Utils.events_after(instance, id, newest, nil)
      assert length(closed_gets(pid_for(instance, id))) == 16

      assert {:ok, %{mode: :get, stream_id: ^newest, replay: []}} =
               Session.open_stream(instance, id, :get, self(), "#{newest}:1")
    end

    test "a resume of a live GET stream ends the old connection and keeps the stream" do
      {instance, _pid, id} = ready_session()
      me = self()
      old = spawn_link(fn -> relay_stream_messages(me) end)

      assert {:ok, %{stream_id: stream_id}} = Session.open_stream(instance, id, :get, old, nil)
      :ok = Session.emit(instance, id, :session, @notification)

      assert_receive {:relayed, {:oz_mcp_stream, ^stream_id, {:event, first, @notification}}},
                     5_000

      # The client came back before the server saw the end of the old
      # connection: the old process is told to end, the stream goes on.
      #
      assert {:ok, %{mode: :get, stream_id: ^stream_id, replay: []}} =
               Session.open_stream(instance, id, :get, me, first)

      assert_receive {:relayed, {:oz_mcp_stream, ^stream_id, :terminate}}, 5_000

      # The later close of the old process changes nothing: the stream is
      # live again, with the process of the resume.
      #
      assert :ok = Session.close_stream(instance, id, old)

      :ok = Session.emit(instance, id, :session, @notification)
      assert_receive {:oz_mcp_stream, ^stream_id, {:event, second, @notification}}, 5_000
      assert second == "#{stream_id}:2"
      refute_receive {:relayed, _}, 100
      assert closed_gets(pid_for(instance, id)) == []
    end

    test "the budget evicts the ring of a closed GET stream: the resume warns of the gap" do
      {instance, _pid, id} =
        ready_session(sse_event_log_bytes: 1024, sse_event_log_session_bytes: 1024)

      stream_pid = fake_stream()

      {:ok, %{stream_id: stream_id}} = Session.open_stream(instance, id, :get, stream_pid, nil)

      :ok = Session.emit(instance, id, :session, @notification)

      assert {:ok, [{first, @notification}]} =
               Utils.events_after(instance, id, stream_id, nil)

      :ok = Session.emit(instance, id, :session, @notification)
      assert {:ok, [_, _]} = Utils.events_after(instance, id, stream_id, nil)

      assert :ok = Session.close_stream(instance, id, stream_pid)

      # An event of a POST stream takes the whole budget: the ring of the
      # closed GET stream is the oldest, so it goes.
      #
      :ok = SessionProbe.append_event(instance, id, "st", {"st:1", big_1k()})

      log =
        capture_log(fn ->
          assert {:ok, %{mode: :get, stream_id: ^stream_id, replay: []}} =
                   Session.open_stream(instance, id, :get, self(), first)
        end)

      assert log =~ "the event log caps removed events of a resumed GET stream"
      refute log =~ "resumed POST stream"
    end

    defp closed_gets(pid) do
      {_state, core} = SessionProbe.core(pid)
      core.closed_gets
    end
  end

  describe "the events with no GET stream" do
    test "an event with no GET stream goes to the first GET that opens" do
      {instance, _pid, id} = ready_session()

      # No GET stream is open: the event waits in a stream the session
      # makes for it.
      #
      :ok = Session.emit(instance, id, :session, @notification)
      assert {:ok, [{event_id, @notification}]} = SessionProbe.events_after(instance, id, nil)

      # The first GET with no Last-Event-ID takes the stream: it gets the
      # waiting event as its replay and the stream goes on with its id
      # and its counter.
      #
      assert {:ok,
              %{
                mode: :get,
                stream_id: stream_id,
                replay: [{^event_id, @notification}],
                priming_id: nil
              }} = Session.open_stream(instance, id, :get, self(), nil)

      assert event_id == "#{stream_id}:1"

      :ok = Session.emit(instance, id, :session, @notification)
      assert_receive {:oz_mcp_stream, ^stream_id, {:event, second, @notification}}, 5_000
      assert second == "#{stream_id}:2"

      assert closed_gets(pid_for(instance, id)) == []
    end

    test "a GET with an unknown id also takes the events that waited" do
      {instance, _pid, id} = ready_session()
      :ok = Session.emit(instance, id, :session, @notification)
      assert {:ok, [{event_id, @notification}]} = SessionProbe.events_after(instance, id, nil)

      log =
        capture_log(fn ->
          assert {:ok,
                  %{
                    mode: :get,
                    stream_id: stream_id,
                    replay: [{^event_id, @notification}],
                    priming_id: nil
                  }} =
                   Session.open_stream(instance, id, :get, self(), "g.nothere000001:9")

          assert event_id == "#{stream_id}:1"
        end)

      assert log =~ "Last-Event-ID"
    end

    test "a GET with an id that cannot be parsed also takes the events that waited" do
      {instance, _pid, id} = ready_session()
      :ok = Session.emit(instance, id, :session, @notification)
      assert {:ok, [{event_id, @notification}]} = SessionProbe.events_after(instance, id, nil)

      log =
        capture_log(fn ->
          #
          # An id of an older version: it has no colon, so the session
          # cannot read a stream and a number from it.
          #
          assert {:ok,
                  %{
                    mode: :get,
                    stream_id: stream_id,
                    replay: [{^event_id, @notification}],
                    priming_id: nil
                  }} =
                   Session.open_stream(instance, id, :get, self(), "event-id-of-an-old-version")

          assert event_id == "#{stream_id}:1"
        end)

      assert log =~ "Last-Event-ID"
    end

    test "the stdio stream does not take the events that waited" do
      {instance, _pid, id} = ready_session()
      :ok = Session.emit(instance, id, :session, @notification)
      assert {:ok, [{event_id, @notification}]} = SessionProbe.events_after(instance, id, nil)

      assert {:ok, %{stream_id: stream_id, replay: [], priming_id: nil}} =
               Session.open_stream(instance, id, :stdio, self(), nil)

      # The waiting event stays in its ring: the stdio stream got nothing
      # of it and it can be resumed by a GET.
      #
      assert {:ok, [{^event_id, @notification}]} = SessionProbe.events_after(instance, id, nil)
      assert length(closed_gets(pid_for(instance, id))) == 1

      assert {:ok, %{mode: :get, stream_id: get_id, replay: [{^event_id, @notification}]}} =
               Session.open_stream(instance, id, :get, self(), nil)

      assert event_id == "#{get_id}:1"
      assert get_id != stream_id
    end

    test "a window of 0 keeps no event that has no GET stream" do
      {instance, _pid, id} = ready_session(sse_resume_window_ms: 0)
      :ok = Session.emit(instance, id, :session, @notification)

      assert {:ok, []} = SessionProbe.events_after(instance, id, nil)
      assert closed_gets(pid_for(instance, id)) == []

      assert {:ok, %{stream_id: stream_id, replay: [], priming_id: priming_id}} =
               Session.open_stream(instance, id, :get, self(), nil)

      assert priming_id == "#{stream_id}:0"
    end

    test "the events that waited go after the resume window when no GET opens" do
      {instance, _pid, id} = ready_session(sse_resume_window_ms: 50)
      :ok = Session.emit(instance, id, :session, @notification)
      assert {:ok, [_]} = SessionProbe.events_after(instance, id, nil)
      assert length(closed_gets(pid_for(instance, id))) == 1

      # The window is over: the ring of the events that waited is dropped.
      #
      assert Utils.eventually(fn ->
               SessionProbe.events_after(instance, id, nil) == {:ok, []}
             end)

      assert closed_gets(pid_for(instance, id)) == []
    end

    test "the budget evicts the ring of the events that waited: the next GET starts fresh" do
      {instance, _pid, id} =
        ready_session(sse_event_log_bytes: 1024, sse_event_log_session_bytes: 1024)

      :ok = Session.emit(instance, id, :session, @notification)
      assert {:ok, [{event_id, @notification}]} = SessionProbe.events_after(instance, id, nil)

      # An event of a POST stream takes the whole budget: the ring of the
      # waiting events is the oldest, so it goes.
      #
      :ok = SessionProbe.append_event(instance, id, "st", {"st:1", big_1k()})
      assert {:ok, [{_post_id, big}]} = SessionProbe.events_after(instance, id, nil)
      assert big == big_1k()

      # The next GET finds a ring with nothing in it: the stream starts
      # fresh, with its priming event.
      #
      assert {:ok, %{stream_id: stream_id, replay: [], priming_id: priming_id}} =
               Session.open_stream(instance, id, :get, self(), nil)

      assert priming_id == "#{stream_id}:0"
      refute event_id == "#{stream_id}:1"
      assert closed_gets(pid_for(instance, id)) == []
    end

    test "a GET that takes the events that waited counts as live" do
      {instance, _pid, id} = ready_session()

      :ok = Session.emit(instance, id, :session, @notification)
      assert {:ok, [_]} = SessionProbe.events_after(instance, id, nil)
      assert {:ok, %{streams: 0}} = SessionProbe.view(instance, id)

      assert {:ok, %{mode: :get, replay: [_], priming_id: nil}} =
               Session.open_stream(instance, id, :get, self(), nil)

      assert {:ok, %{streams: 1}} = SessionProbe.view(instance, id)
      assert {:ok, %{stream?: true}} = Sessions.delivery(instance, id)
    end
  end

  describe "the stream target of a request" do
    test "a message for a request whose stream did not start is numbered and logged" do
      {instance, _pid, id} = ready_session()

      :ok = Utils.open_request(instance, id, 7, self(), {"st1", :sse})
      assert {:ok, {self(), "st1"}} == Session.stream_owner(instance, id, 7)

      :ok = Session.emit(instance, id, {:request, 7}, ~s({"a":1}))
      assert_receive {:oz_mcp_stream, "st1", {:event, "st1:1", ~s({"a":1})}}, 5_000

      # The session logged the event before the owner wrote it.
      #
      assert {:ok, [{"st1:1", ~s({"a":1})}]} = SessionProbe.events_after(instance, id, nil)
    end

    test "a second request with the same id is refused" do
      {instance, _pid, id} = ready_session()
      owner = self()

      :ok = Utils.open_request(instance, id, 7, owner, {"st1", :sse})

      assert {:error, :duplicate} =
               Utils.open_request(instance, id, 7, owner, {"st2", :sse})

      assert {:ok, {^owner, "st1"}} = Session.stream_owner(instance, id, 7)
    end

    test "close_request with :detach gives :ok one time, then the request has no owner" do
      {instance, _pid, id} = ready_session()

      :ok = Utils.open_request(instance, id, 7, self(), {"st1", :sse})

      assert :gone = Utils.close_request(instance, id, 7, "other", :detach)
      assert :ok = Utils.close_request(instance, id, 7, "st1", :detach)
      assert :gone = Utils.close_request(instance, id, 7, "st1", :detach)
      assert :none = Session.stream_owner(instance, id, 7)
    end

    test "the end of the owner removes the target" do
      {instance, _pid, id} = ready_session()
      owner = fake_stream()

      :ok = Utils.open_request(instance, id, 7, owner, {"st1", :sse})
      Process.exit(owner, :kill)

      assert Utils.eventually(fn -> Session.stream_owner(instance, id, 7) == :none end)
    end

    test "a request with no stream sends to the GET stream with request_or_session" do
      {instance, _pid, id} = ready_session()
      {:ok, %{stream_id: stream_id}} = Session.open_stream(instance, id, :get, self(), nil)

      :ok = Session.emit(instance, id, {:request_or_session, 99}, ~s({"a":1}))
      assert_receive {:oz_mcp_stream, ^stream_id, {:event, _event_id, ~s({"a":1})}}, 5_000
    end
  end

  describe "the POST streams" do
    test "ids on one POST stream are unique under concurrent emits" do
      {instance, _pid, id} = ready_session()

      {:ok, stream} = PostStream.begin(instance, id, "r1", conn(:post, "/"), & &1)

      emitters =
        for w <- 1..4 do
          Task.async(fn ->
            for k <- 1..50,
                do: :ok = Session.emit(instance, id, {:request, "r1"}, Utils.note("#{w}-#{k}"))
          end)
        end

      # The owner writes each event while the emitters run and the
      # response comes after all of them.
      #
      stream = Utils.relay_until_done(stream, emitters)

      {{:streamed, conn}, _stream} =
        PostStream.answer(%{"jsonrpc" => "2.0", "id" => "r1", "result" => %{}}, stream)

      ids = Utils.sse_ids(conn) |> Enum.reject(&String.ends_with?(&1, ":0"))

      assert ids == Enum.map(1..201, &"#{stream.stream_id}:#{&1}")
    end

    test "a resumer with no event gets the response and the end of the stream" do
      {instance, _pid, id} = ready_session()
      owner = fake_stream()

      :ok = Utils.open_request(instance, id, 7, owner, {"st1", :sse})

      # A client can resume the id of a stream that gave no event yet (the
      # entry exists from the registration of the stream).
      #
      assert {:ok, %{mode: :resume, ended: false}} =
               Session.open_stream(instance, id, :get, self(), "st1:0")

      # The response is the final event, although no event went out before
      # it: the resumer would wait with no end otherwise.
      #
      assert {:sse, "st1:1"} =
               Utils.close_request(instance, id, 7, "st1", {:response, "{}", false})

      assert_receive {:oz_mcp_stream, "st1", {:event, "st1:1", "{}"}}, 5_000
      assert_receive {:oz_mcp_stream, "st1", :end}, 5_000

      assert {:ok, %{mode: :resume, ended: true, replay: [{"st1:1", "{}"}]}} =
               Session.open_stream(instance, id, :get, self(), "st1:0")
    end

    test "an emit is in the log with its id before the owner writes it" do
      {instance, _pid, id} = ready_session()

      {:ok, stream} = PostStream.begin(instance, id, 7, conn(:post, "/"), & &1)

      :ok = Session.emit(instance, id, {:request, 7}, ~s({"a":1}))
      Utils.sync_server(instance, id)

      # The session logged the event and gave it the first id of the
      # stream. The owner has not written anything yet.
      #
      first_id = "#{stream.stream_id}:1"
      assert {:ok, [{^first_id, ~s({"a":1})}]} = SessionProbe.events_after(instance, id, nil)

      refute stream.started
    end

    test "a plain JSON response leaves no entry, no ring and no owner monitor" do
      {instance, _pid, id} = ready_session()

      {:ok, stream} = PostStream.begin(instance, id, 7, conn(:post, "/"), & &1)

      # The connection of the owner stays open: the end of the stream is
      # the forget of the owner, not the end of the process.
      #
      assert {:not_streamed, _stream} =
               PostStream.answer(%{"jsonrpc" => "2.0", "id" => 7, "result" => %{}}, stream)

      Session.end_request(instance, id, 7)
      Utils.sync_server(instance, id)

      snap = Support.Helpers.SessionLeak.snapshot(pid_for(instance, id))
      assert snap.streams == 0
      assert MapSet.size(snap.log_streams) == 0
      assert snap.log_bytes == 0
      assert snap.refs == 0
      assert snap.requests == 0
    end

    test "a sink gets events with no id and no GET can resume it" do
      {instance, _pid, id} = ready_session()
      me = self()

      {:ok, stream} =
        PostStream.begin_sink(instance, id, 7, fn data -> send(me, {:sink, data}) end)

      :ok = Session.emit(instance, id, {:request, 7}, ~s({"a":1}))

      # The message of a sink carries no id: a transport with no HTTP
      # response has no event ids and no log.
      #
      assert {:oz_mcp_stream, stream_id, {:event, nil, ~s({"a":1})}} =
               Utils.receive_stream_message(stream.stream_id)

      assert stream_id == stream.stream_id
      assert {:ok, []} = SessionProbe.events_after(instance, id, nil)

      assert {:error, :no_stream} =
               Session.open_stream(instance, id, :get, fake_stream(), "#{stream.stream_id}:0")
    end

    test "the owner and the session never give the same id" do
      {instance, _pid, id} = ready_session()

      {:ok, stream} = PostStream.begin(instance, id, "r1", conn(:post, "/"), & &1)

      for k <- 1..3, do: :ok = Session.emit(instance, id, {:request, "r1"}, Utils.note(k))
      Utils.sync_server(instance, id)

      # The owner writes one message: the stream starts (head and priming
      # event) and the event that the session numbered follows.
      #
      stream = PostStream.relay(stream, Utils.receive_stream_message(stream.stream_id))
      Utils.sync_server(instance, id)

      :ok = Session.emit(instance, id, {:request, "r1"}, Utils.note(4))
      Utils.sync_server(instance, id)

      {{:streamed, conn}, _stream} =
        PostStream.answer(%{"jsonrpc" => "2.0", "id" => "r1", "result" => %{}}, stream)

      ids = Utils.sse_ids(conn) |> Enum.reject(&String.ends_with?(&1, ":0"))

      assert ids == Enum.map(1..5, &"#{stream.stream_id}:#{&1}")
    end

    test "after the final event the request has no stream owner" do
      {instance, _pid, id} = ready_session()

      :ok = Utils.open_request(instance, id, 7, self(), {"st1", :sse})
      assert {:ok, {owner, "st1"}} = Session.stream_owner(instance, id, 7)
      assert owner == self()

      :ok = Session.emit(instance, id, {:request, 7}, "{}")
      assert_receive {:oz_mcp_stream, "st1", {:event, "st1:1", "{}"}}, 5_000

      assert {:sse, "st1:2"} =
               Utils.close_request(instance, id, 7, "st1", {:response, "{}", false})

      # A late emit for the request gets no stream: it goes to the GET
      # stream of the session, as after a forget of the owner.
      #
      assert :none = Session.stream_owner(instance, id, 7)
      assert :gone = Utils.close_request(instance, id, 7, "st1", {:response, "{}", false})
    end

    test "the forget of a started stream with a resumer ends the resumer" do
      {instance, _pid, id} = ready_session()
      owner = fake_stream()

      :ok = Utils.open_request(instance, id, 7, owner, {"st1", :sse})
      :ok = Session.emit(instance, id, {:request, 7}, "{}")

      assert {:ok, %{mode: :resume}} = Session.open_stream(instance, id, :get, self(), "st1:0")

      # The owner forgot the stream before the response: the resumer ends
      # and the entry goes. The ring of the stream stays for the window.
      #
      assert :ok = Utils.close_request(instance, id, 7, "st1", :detach)

      assert_receive {:oz_mcp_stream, "st1", :end}, 5_000

      data = Utils.session_data(instance, id)
      assert data.streams == %{}
      assert {:ok, [{"st1:1", "{}"}]} = Utils.events_after(instance, id, "st1", nil)
    end
  end

  describe "the broadcasts" do
    defp broadcast(instance, topic, filter, message),
      do: OzMcp.PubSub.Registry.broadcast(instance, topic, {:session_event, filter, message})

    test "each session decides: the topics, the level and the principal" do
      instance = start_instance()
      {_pid, id} = start_session(instance)
      :ok = Session.initialized(instance, id)
      assert {:ok, %{stream_id: stream_id}} = Session.open_stream(instance, id, :get, self(), nil)

      broadcast(instance, {:subscription, "file:///a"}, nil, "sub")
      refute_receive {:oz_mcp_stream, _, {:event, _, "sub"}}, 100

      :ok = Session.subscribe(instance, id, "file:///a")
      broadcast(instance, {:subscription, "file:///a"}, nil, "sub")
      assert_receive {:oz_mcp_stream, ^stream_id, {:event, _, "sub"}}, 5_000

      broadcast(instance, :initialized, {:log, :error}, "log")
      refute_receive {:oz_mcp_stream, _, {:event, _, "log"}}, 100

      :ok = Session.update_view(instance, id, log_level: :warning)
      broadcast(instance, :initialized, {:log, :error}, "log")
      assert_receive {:oz_mcp_stream, ^stream_id, {:event, _, "log"}}, 5_000

      broadcast(instance, {:principal, "other"}, {:log, :error}, "log-other")
      broadcast(instance, {:principal, "p1"}, {:log, :error}, "log-p1")
      assert_receive {:oz_mcp_stream, ^stream_id, {:event, _, "log-p1"}}, 5_000
      refute_receive {:oz_mcp_stream, _, {:event, _, "log-other"}}, 100

      :ok = Session.unsubscribe(instance, id, "file:///a")
      broadcast(instance, {:subscription, "file:///a"}, nil, "sub2")
      refute_receive {:oz_mcp_stream, _, {:event, _, "sub2"}}, 100
    end
  end

  describe "the rate of the log notifications" do
    @log ~s({"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"hi"}})

    test "a log cast over the rate is dropped by the session" do
      instance = start_instance(max_log_rate: 1)
      {_pid, id} = start_session(instance)
      :ok = Session.initialized(instance, id)
      assert {:ok, %{stream_id: stream_id}} = Session.open_stream(instance, id, :get, self(), nil)

      # The bucket of the session holds one second of tokens: with a rate
      # of 1, only the first message of the loop passes and the refill
      # comes 1000 ms after it.
      #
      for _ <- 1..5, do: :ok = Session.emit_log(instance, id, :session, @log)

      assert_receive {:oz_mcp_stream, ^stream_id, {:event, _, @log}}, 5_000
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 500

      assert {:ok, [_event]} = SessionProbe.events_after(instance, id, nil)
    end

    test "a log cast with no rate passes for each message" do
      instance = start_instance(max_log_rate: nil)
      {_pid, id} = start_session(instance)
      :ok = Session.initialized(instance, id)
      assert {:ok, %{stream_id: stream_id}} = Session.open_stream(instance, id, :get, self(), nil)

      for _ <- 1..5, do: :ok = Session.emit_log(instance, id, :session, @log)

      for _ <- 1..5 do
        assert_receive {:oz_mcp_stream, ^stream_id, {:event, _, @log}}, 5_000
      end
    end
  end

  describe "the requests of the session" do
    test "open_request/5 registers a request and its stream in one call" do
      instance = start_instance()
      {pid, id} = start_session(instance)
      owner = self()

      assert :ok = Session.open_request(instance, id, 7, owner, {"st1", :sse})
      assert {:error, :duplicate} = Session.open_request(instance, id, 7, owner, nil)

      {_state, core} = SessionProbe.core(pid)

      assert %{requests: %{7 => %{owner: ^owner, stream_id: "st1"}}, streams: %{"st1" => _}} =
               core

      assert {:ok, {^owner, "st1"}} = Session.stream_owner(instance, id, 7)
    end

    test "open_request/5 with no stream registers a plain request" do
      instance = start_instance()
      {pid, id} = start_session(instance)
      owner = self()

      assert :ok = Session.open_request(instance, id, 7, owner, nil)

      {_state, core} = SessionProbe.core(pid)
      assert %{requests: %{7 => %{owner: ^owner, stream_id: nil}}, streams: %{}} = core
      assert :none = Session.stream_owner(instance, id, 7)
    end

    test "close_request/5 ends a response stream and frees the request" do
      instance = start_instance()
      {pid, id} = start_session(instance)
      owner = self()

      assert :ok = Session.open_request(instance, id, 7, owner, {"st1", :sse})
      assert :ok = Session.emit(instance, id, {:request, 7}, "{}")
      assert_receive {:oz_mcp_stream, "st1", {:event, "st1:1", "{}"}}, 5_000

      assert {:sse, "st1:2"} =
               Session.close_request(instance, id, 7, "st1", {:response, "{}", false})

      assert :gone = Session.close_request(instance, id, 7, "st1", {:response, "{}", false})

      {_state, core} = SessionProbe.core(pid)
      assert core.requests == %{}
      assert core.streams == %{}
    end

    test "close_request/5 with a detach ends a sink stream" do
      instance = start_instance()
      {pid, id} = start_session(instance)
      owner = self()

      assert :ok = Session.open_request(instance, id, 7, owner, {"st1", :sink})
      assert :ok = Session.close_request(instance, id, 7, "st1", :detach)
      assert :gone = Session.close_request(instance, id, 7, "st1", :detach)

      {_state, core} = SessionProbe.core(pid)
      assert core.requests == %{}
      assert core.streams == %{}
    end

    test "end_request frees the request and drops its stream" do
      instance = start_instance()
      {pid, id} = start_session(instance)
      owner = self()

      assert :ok = Session.open_request(instance, id, 7, owner, {"st1", :sse})
      assert :ok = Session.end_request(instance, id, 7)
      assert :ok = Session.touch(instance, id)

      {_state, core} = SessionProbe.core(pid)
      assert core.requests == %{}
      assert core.streams == %{}
    end

    test "open_request/5 registers a request, the end of the owner frees the id" do
      instance = start_instance()
      {pid, id} = start_session(instance)
      owner = spawn(fn -> Process.sleep(:infinity) end)
      runner = spawn(fn -> Process.sleep(:infinity) end)

      assert :ok = Utils.open_request(instance, id, 7, owner)
      assert {:error, :duplicate} = Utils.open_request(instance, id, 7, self())
      assert :ok = Session.attach_runner(instance, id, 7, runner)
      {_state, core} = SessionProbe.core(pid)
      assert %{requests: %{7 => %{runner: ^runner}}} = core

      # The end is a cast: this call orders the read after it.
      #
      :ok = Session.touch(instance, id)
      Process.exit(owner, :kill)

      assert Utils.eventually(fn ->
               case SessionProbe.core(pid) do
                 {_state, core} -> core.requests == %{}
                 _other -> false
               end
             end)
    end

    @tag :capture_log
    test "the death of the owner stops the callback in two steps" do
      instance = start_instance(request_cancel_grace_ms: 300)
      {_pid, id} = start_session(instance)
      owner = spawn(fn -> Process.sleep(:infinity) end)
      parent = self()

      runner =
        spawn(fn ->
          Process.flag(:trap_exit, true)

          receive do
            {:EXIT, _from, :shutdown} -> send(parent, :got_shutdown)
          end

          ignore_everything()
        end)

      assert :ok = Utils.open_request(instance, id, 7, owner)
      assert :ok = Session.attach_runner(instance, id, 7, runner)

      Process.exit(owner, :kill)

      assert_receive :got_shutdown, 5_000

      # The callback keeps the grace period to clean up, then it is killed:
      # the DOWN of the runner must not arrive at once.
      #
      grace_ref = Process.monitor(runner)
      refute_receive {:DOWN, ^grace_ref, :process, ^runner, _}, 100
      assert Utils.eventually(fn -> not Process.alive?(runner) end, 1_000)
    end

    test "the death of the owner with no callback process yet only frees the id" do
      instance = start_instance()
      {pid, id} = start_session(instance)
      owner = spawn(fn -> Process.sleep(:infinity) end)

      assert :ok = Utils.open_request(instance, id, 7, owner)
      Process.exit(owner, :kill)

      assert Utils.eventually(fn ->
               case SessionProbe.core(pid) do
                 {_state, core} -> core.requests == %{}
                 _other -> false
               end
             end)
    end

    @tag :capture_log
    test "the death of the owner sends notifications/cancelled for the requests to the client" do
      instance = start_instance()
      {_pid, id} = start_session(instance)
      :ok = Session.initialized(instance, id)
      owner = spawn(fn -> Process.sleep(:infinity) end)

      runner =
        spawn(fn ->
          {:ok, _out_id, _session_pid} =
            Session.request_client(instance, id, {:request, nil}, self(), "ping", nil)

          receive do
            :never -> :ok
          end
        end)

      stream = self()

      assert :ok = Utils.open_request(instance, id, 7, owner)
      assert :ok = Session.attach_runner(instance, id, 7, runner)

      # A GET stream of the session: the notices go to it (the POST request
      # of the owner is gone).
      #
      {:ok, _} = Session.open_stream(instance, id, :get, stream, nil)

      # The request of the runner is pending before the death of the owner.
      #
      assert Utils.eventually(
               fn ->
                 match?([_ | _], SessionProbe.pending_outbound_ids(instance, id))
               end,
               1_000
             )

      Process.exit(owner, :kill)

      assert_receive {:oz_mcp_stream, _stream_id, {:event, _, encoded}}, 5_000
      assert encoded =~ "notifications/cancelled"
      assert Utils.eventually(fn -> not Process.alive?(runner) end, 1_000)
    end

    @tag :capture_log
    test "a duplicate request id is refused and the log bounds the id" do
      instance = start_instance()
      {_pid, id} = start_session(instance)
      request_id = "a\nb" <> String.duplicate("x", 5_000)

      assert :ok = Utils.open_request(instance, id, request_id, self())

      log =
        capture_log(fn ->
          assert {:error, :duplicate} = Utils.open_request(instance, id, request_id, self())
        end)

      assert log =~ "request id \"a\\nb"
      refute log =~ "a\nb"
      assert byte_size(log) < 1_000
    end

    test "cancel/4 sends the cancel message to the owner" do
      instance = start_instance()
      {_pid, id} = start_session(instance)

      assert :ok = Utils.open_request(instance, id, 7, self())
      assert :ok = Session.cancel(instance, id, 7, "user aborted")

      assert_receive {:oz_mcp_cancel, 7, "user aborted"}, 5_000
    end

    test "the end of the session cancels its requests" do
      instance = start_instance()
      {_pid, id} = start_session(instance)

      :ok = Utils.open_request(instance, id, 1, self())
      :ok = Utils.open_request(instance, id, 2, self())

      assert :ok = Session.close(instance, id, :terminated)

      assert_receive {:oz_mcp_cancel, 1, :session_terminated}
      assert_receive {:oz_mcp_cancel, 2, :session_terminated}
    end
  end

  defp relay_stream_messages(parent) do
    receive do
      {:oz_mcp_stream, _, _} = message ->
        send(parent, {:relayed, message})
        relay_stream_messages(parent)
    end
  end

  defp ignore_everything do
    receive do
      :never -> :ok
    end

    ignore_everything()
  end
end
