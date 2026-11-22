defmodule OzMcp.SessionsInstanceTest do
  use ExUnit.Case, async: true
  alias OzMcp.Session
  alias OzMcp.Sessions
  alias OzMcp.Tasks
  alias Support.Helpers.SessionProbe
  alias Support.Helpers.Utils
  alias Support.Servers

  @server_module Servers.Default
  @other_module Servers.RuntimeOther
  @other Module.concat(@other_module, __MODULE__)

  @server Module.concat(@server_module, __MODULE__)
  setup context do
    opts = Map.get(context, :task_opts) || %{}

    Utils.start_instance(@server_module, [name: @server] ++ Map.to_list(opts))
    :ok
  end

  describe "create_session/2" do
    test "creates a new session and returns the session id" do
      assert session_id = Utils.create_session(@server)
      assert is_binary(session_id)
      assert byte_size(session_id) == 40
    end

    test "returns a unique session id for each call" do
      id1 = Utils.create_session(@server)
      id2 = Utils.create_session(@server)
      id3 = Utils.create_session(@server)

      ids = [id1, id2, id3]
      assert length(Enum.uniq(ids)) == length(ids)
    end
  end

  describe "max_sessions" do
    test "a create over the limit is refused" do
      Utils.stop_instance(@server)

      Utils.start_instance(@server_module, [name: @server] ++ Map.to_list(%{max_sessions: 2}))

      id1 = Utils.create_session(@server, streams: [self()])
      _id2 = Utils.create_session(@server, streams: [self()])

      assert Sessions.start(@server) ==
               {:error, :too_many_sessions}

      # The end of one session frees a slot.
      #
      assert :ok = Sessions.terminate(@server, id1)
      assert {:ok, id3} = Sessions.start(@server)
      assert is_binary(id3)
    end

    test "a refused session leaves no session" do
      Utils.stop_instance(@server)

      Utils.start_instance(@server_module, [name: @server] ++ Map.to_list(%{max_sessions: 1}))

      _id = Utils.create_session(@server, streams: [self()])
      assert Sessions.start(@server) == {:error, :too_many_sessions}

      assert Utils.session_count(@server) == 1
    end
  end

  describe "max_sessions_per_principal" do
    test "a second create of one principal is refused, another key passes" do
      Utils.stop_instance(@server)

      Utils.start_instance(
        @server_module,
        [name: @server] ++ Map.to_list(%{max_sessions_per_principal: 1})
      )

      alice = {"https://idp.example.com", "alice"}
      bob = {"https://idp.example.com", "bob"}

      assert {:ok, id} = Sessions.start(@server, principal_key: alice)
      assert {:ok, _} = OzMcp.Session.open_stream(@server, id, :get, self(), nil)

      assert Sessions.start(@server, principal_key: alice) ==
               {:error, :too_many_sessions}

      assert {:ok, _id} = Sessions.start(@server, principal_key: bob)

      # A session with no principal key does not count for the limit.
      #
      assert {:ok, _id} = Sessions.start(@server)
    end
  end

  describe "max_streams_per_session" do
    setup do
      Utils.stop_instance(@server)

      Utils.start_instance(
        @server_module,
        [name: @server] ++ Map.to_list(%{max_streams_per_session: 1})
      )

      :ok
    end

    test "a second open_stream over the limit ends the first stream" do
      stream1 = self()
      stream2 = spawn_fake_stream()
      session_id = Utils.create_session(@server, initialized: true)

      assert {:ok, %{stream_id: first_id}} =
               Session.open_stream(@server, session_id, :get, stream1, nil)

      assert {:ok, _} = Session.open_stream(@server, session_id, :get, stream2, nil)

      # The oldest stream ended with its terminate message and the new
      # stream took the only slot. The replacement logged nothing.
      #
      assert_receive {:oz_mcp_stream, ^first_id, :terminate}
      assert {:ok, %{streams: 1}} = Sessions.lookup(@server, session_id)
      assert {:ok, []} = SessionProbe.events_after(@server, session_id, "")
    end

    test "the limit counts the stdio stream too" do
      stream1 = spawn_fake_stream()
      stream2 = spawn_fake_stream()
      session_id = Utils.create_session(@server, initialized: true)

      assert {:ok, %{mode: :get}} =
               Session.open_stream(@server, session_id, :stdio, stream1, nil)

      assert Session.open_stream(@server, session_id, :stdio, stream2, nil) ==
               {:error, :too_many_streams}

      assert Session.open_stream(@server, session_id, :get, stream2, nil) ==
               {:error, :too_many_streams}
    end

    test "after close_stream a new open_stream passes" do
      stream1 = spawn_fake_stream()
      stream2 = spawn_fake_stream()
      session_id = Utils.create_session(@server, initialized: true)

      assert {:ok, _} = Session.open_stream(@server, session_id, :get, stream1, nil)
      assert :ok = Session.close_stream(@server, session_id, stream1)

      assert {:ok, _} = Session.open_stream(@server, session_id, :get, stream2, nil)
      assert {:ok, %{streams: 1}} = Sessions.lookup(@server, session_id)
    end

    test "after the stream process stops a new open_stream passes" do
      stream1 = spawn_fake_stream()
      stream2 = spawn_fake_stream()
      session_id = Utils.create_session(@server, initialized: true)

      assert {:ok, _} = Session.open_stream(@server, session_id, :get, stream1, nil)

      Process.exit(stream1, :kill)

      wait_until(fn ->
        match?({:ok, %{streams: 0}}, Sessions.lookup(@server, session_id))
      end)

      assert {:ok, _} = Session.open_stream(@server, session_id, :get, stream2, nil)
      assert {:ok, %{streams: 1}} = Sessions.lookup(@server, session_id)
    end
  end

  describe "max_streams_per_session with no limit" do
    @describetag task_opts: %{max_streams_per_session: nil}
    test "ten streams open" do
      session_id = Utils.create_session(@server, initialized: true)
      streams = for _ <- 1..10, do: spawn_fake_stream()

      Enum.each(streams, fn stream ->
        assert {:ok, _} = Session.open_stream(@server, session_id, :get, stream, nil)
      end)

      assert {:ok, %{streams: 10}} = Sessions.lookup(@server, session_id)
    end
  end

  describe "is_session_initialized/2" do
    test "returns false for newly created session" do
      #
      # session_id = Utils.create_session(@server)
      #
      session_id = Utils.create_session(@server)

      assert SessionProbe.initialized?(@server, session_id) == false
    end

    test "returns {:error, :no_session} for unknown session" do
      assert SessionProbe.initialized?(@server, "nonexistent") == {:error, :no_session}
    end
  end

  describe "set_session_initialized/2" do
    test "marks session as initialized" do
      #
      # session_id = Utils.create_session(@server)
      #
      session_id = Utils.create_session(@server)

      assert :ok = Sessions.set_initialized(@server, session_id)
      assert SessionProbe.initialized?(@server, session_id) == true
    end

    test "returns {:error, :no_session} for unknown session" do
      assert Sessions.set_initialized(@server, "nonexistent") == {:error, :no_session}
    end
  end

  describe "set_session_log_level/3" do
    test "stores the given level on the session" do
      session_id = Utils.create_session(@server)

      assert :ok = Sessions.set_log_level(@server, session_id, :notice)
      assert {:ok, %{log_level: :notice}} = Sessions.lookup(@server, session_id)
    end

    test "returns {:error, :no_session} for unknown session" do
      assert Sessions.set_log_level(@server, "nonexistent", :info) == {:error, :no_session}
    end
  end

  describe "terminate_session/2" do
    test "terminates an existing session" do
      session_id = Utils.create_session(@server)

      assert :ok = Sessions.terminate(@server, session_id)

      assert SessionProbe.initialized?(@server, session_id) == {:error, :no_session}
    end

    test "returns {:error, :no_session} for unknown session" do
      assert Sessions.terminate(@server, "nonexistent") == {:error, :no_session}
    end
  end

  describe "terminate_session/2 cascade (031)" do
    test "terminates the streams of the session only" do
      s1 = start_sse_stream()
      s2 = start_sse_stream()
      foreign = start_sse_stream()

      session_id = Utils.create_session(@server, initialized: true, streams: [s1, s2])
      Utils.create_session(@server, initialized: true, streams: [foreign])

      assert :ok = Sessions.terminate(@server, session_id)

      assert_receive {:stream_terminated, ^s1}, 5_000
      assert_receive {:stream_terminated, ^s2}, 5_000
      refute_received {:stream_terminated, ^foreign}
    end

    test "the streams get the stream id that the session gave them" do
      s1 = start_sse_stream()
      session_id = Utils.create_session(@server, initialized: true, streams: [s1])

      assert [%{id: stream_id}] = Utils.session_streams(@server, session_id)
      assert :ok = Sessions.terminate(@server, session_id)

      assert_receive {:stream_terminated, ^s1, ^stream_id}, 5_000
    end

    test "returns {:error, :no_session} for an unknown session without touching streams" do
      stream = start_sse_stream()
      session_id = Utils.create_session(@server, initialized: true, streams: [stream])

      assert {:error, :no_session} = Sessions.terminate(@server, "nonexistent")

      refute_received {:stream_terminated, ^stream}

      assert Utils.stream_pids(@server, session_id) == [stream]
    end

    test "termination succeeds even when the tasks table is down (A2)" do
      {:ok, table} = OzMcp.Instance.whereis(@server, :tasks_table)
      {:dictionary, dictionary} = Process.info(table, :dictionary)
      [server_supervisor | _] = Keyword.fetch!(dictionary, :"$ancestors")

      :ok = Supervisor.terminate_child(server_supervisor, {OzMcp.Tasks.Table, @server})

      session_id = Utils.create_session(@server, initialized: true)

      assert :ok = Sessions.terminate(@server, session_id)
      assert SessionProbe.initialized?(@server, session_id) == {:error, :no_session}
    end
  end

  describe "terminate_session/2 with a task process that does not answer" do
    @describetag :tasks_instance

    setup context do
      opts = Map.get(context, :task_opts) || %{}
      instance = Module.concat(Servers.TasksTest, SessionsInstanceTasks)
      Utils.start_instance(Servers.TasksTest, [name: instance] ++ Map.to_list(opts))
      Support.Entities.Tools.TaskSlowTest.use_instance(instance)

      doomed = Utils.create_session(instance, initialized: true)
      other = Utils.create_session(instance, initialized: true)

      {:ok, task} =
        Tasks.create(instance, %{
          session_id: doomed,
          tool: {Support.Entities.Tools.TaskSlowTest, "task_slow"},
          request: %{"name" => "task_slow", "arguments" => %{}}
        })

      wait_until(fn -> Support.Entities.Tools.TaskSlowTest.last_runner_pid() != nil end)
      {:ok, task_pid} = OzMcp.Instance.whereis(instance, {:task, task.taskId})

      %{
        instance: instance,
        doomed: doomed,
        other: other,
        task_pid: task_pid,
        task_id: task.taskId
      }
    end

    test "a suspended task process does not block the Server and ends after resume", ctx do
      %{instance: instance, doomed: doomed, other: other, task_pid: task_pid} = ctx
      {:ok, server_pid} = OzMcp.Instance.whereis(instance, :sessions)

      :ok = :sys.suspend(task_pid)

      try do
        {micros, result} = :timer.tc(fn -> Sessions.terminate(instance, doomed) end)

        assert result == :ok
        assert micros < 1_000_000
        assert {:ok, ^server_pid} = OzMcp.Instance.whereis(instance, :sessions)
        assert SessionProbe.initialized?(instance, other) == true
        assert SessionProbe.initialized?(instance, doomed) == {:error, :no_session}
      after
        :sys.resume(task_pid)
      end

      # The order to stop waited in the mailbox of the task process.
      #
      ref = Process.monitor(task_pid)
      assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, 5_000
      assert OzMcp.Tasks.EtsStore.get(instance, ctx.task_id) == :not_found
    end

    @tag :capture_log
    test "a killed task process does not stop the Server", ctx do
      %{instance: instance, doomed: doomed, other: other, task_pid: task_pid} = ctx
      {:ok, server_pid} = OzMcp.Instance.whereis(instance, :sessions)

      Process.exit(task_pid, :kill)

      assert :ok = Sessions.terminate(instance, doomed)

      assert {:ok, ^server_pid} = OzMcp.Instance.whereis(instance, :sessions)
      assert SessionProbe.initialized?(instance, other) == true
    end

    # The task does not follow the session, so it does not hold it and the
    # idle timer runs.
    #
    @tag task_opts: %{session_timeout_ms: 1_000, tasks_follow_session: false}
    test "the idle timer ends a session while the task process is suspended", ctx do
      %{instance: instance, doomed: doomed, task_pid: task_pid} = ctx
      {:ok, server_pid} = OzMcp.Instance.whereis(instance, :sessions)

      :ok = :sys.suspend(task_pid)

      try do
        wait_until(fn -> Sessions.lookup(instance, doomed) == {:error, :no_session} end, 2500)

        assert {:ok, ^server_pid} = OzMcp.Instance.whereis(instance, :sessions)
      after
        :sys.resume(task_pid)
      end
    end
  end

  describe "sessions_of/2" do
    @alice {"https://issuer.test", "alice"}
    @bob {"https://issuer.test", "bob"}

    test "lists the sessions of a principal key" do
      a1 = Utils.create_session(@server, principal_key: @alice)
      _b1 = Utils.create_session(@server, principal_key: @bob)

      assert {:ok, [^a1]} = Sessions.list_principal(@server, @alice)
    end

    test "lists every session of the key, initialized or not" do
      a1 = Utils.create_session(@server, principal_key: @alice, initialized: true)
      a2 = Utils.create_session(@server, principal_key: @alice)

      assert {:ok, ids} = Sessions.list_principal(@server, @alice)
      assert Enum.sort(ids) == Enum.sort([a1, a2])
    end

    test "returns an empty list for an unknown key" do
      Utils.create_session(@server, principal_key: @alice)

      assert {:ok, []} = Sessions.list_principal(@server, {"https://issuer.test", "nobody"})
    end

    test "accepts a key with no issuer and matches only a key with no issuer" do
      none = Utils.create_session(@server, principal_key: {nil, "alice"})
      _other = Utils.create_session(@server, principal_key: @alice)

      assert {:ok, [^none]} = Sessions.list_principal(@server, {nil, "alice"})
    end

    test "returns an empty list for nil, so an open server keeps its sessions" do
      Utils.create_session(@server)

      assert {:ok, []} = Sessions.list_principal(@server, nil)
    end

    test "returns {:error, :unavailable} when the runtime does not have the server" do
      assert {:error, :unavailable} = Sessions.list_principal(@other, @alice)
    end
  end

  describe "terminate_sessions/2" do
    @alice {"https://issuer.test", "alice"}
    @bob {"https://issuer.test", "bob"}

    test "ends every session of the principal, initialized or not" do
      a1 = Utils.create_session(@server, principal_key: @alice, initialized: true)
      a2 = Utils.create_session(@server, principal_key: @alice)

      assert {:ok, ended} = Sessions.terminate_principal(@server, @alice)
      assert Enum.sort(ended) == Enum.sort([a1, a2])
      assert Sessions.state(@server, a1) == {:error, :no_session}
      assert Sessions.state(@server, a2) == {:error, :no_session}
    end

    test "does not change a session of another principal" do
      _a1 = Utils.create_session(@server, principal_key: @alice)
      b1 = Utils.create_session(@server, principal_key: @bob, initialized: true)

      assert {:ok, [_one]} = Sessions.terminate_principal(@server, @alice)
      assert {:ok, %{initialized: true}} = Sessions.state(@server, b1)
    end

    test "terminates the streams of the principal only" do
      s_alice = start_sse_stream()
      s_bob = start_sse_stream()

      Utils.create_session(@server,
        principal_key: @alice,
        initialized: true,
        streams: [s_alice]
      )

      Utils.create_session(@server, principal_key: @bob, initialized: true, streams: [s_bob])

      assert {:ok, [_one]} = Sessions.terminate_principal(@server, @alice)

      assert_receive {:stream_terminated, ^s_alice}, 5_000
      refute_received {:stream_terminated, ^s_bob}
    end

    test "accepts a principal struct" do
      a1 = Utils.create_session(@server, principal_key: @alice)
      principal = OzMcp.Auth.Principal.new!(issuer: "https://issuer.test", subject: "alice")

      assert {:ok, [^a1]} = Sessions.terminate_principal(@server, principal)
    end

    test "returns an empty list for a principal with no session" do
      Utils.create_session(@server, principal_key: @bob)

      assert {:ok, []} = Sessions.terminate_principal(@server, {"https://issuer.test", "nobody"})
    end

    test "returns {:error, :unavailable} when the runtime does not have the server" do
      assert {:error, :unavailable} = Sessions.terminate_principal(@other, @alice)
    end

    test "a key with a wrong shape raises in the caller and the Server stays" do
      Utils.create_session(@server, principal_key: @alice)
      {:ok, pid} = OzMcp.Instance.whereis(@server, :sessions)

      for key <- [{:_, "alice"}, {"iss", :_}, {"iss", ""}, {1, "a"}, "alice", :_] do
        assert_raise FunctionClauseError, fn -> Sessions.list_principal(@server, key) end
        assert_raise FunctionClauseError, fn -> Sessions.terminate_principal(@server, key) end
      end

      assert {:ok, ^pid} = OzMcp.Instance.whereis(@server, :sessions)
      assert {:ok, [_one]} = Sessions.list_principal(@server, @alice)
    end

    test "a principal built by new!/1 always has a key that the runtime accepts" do
      for issuer <- [nil, "", "https://issuer.test"] do
        principal = OzMcp.Auth.Principal.new!(subject: "alice", issuer: issuer)
        id = Utils.create_session(@server, principal_key: OzMcp.Auth.Principal.key(principal))

        assert {:ok, [^id]} =
                 Sessions.list_principal(@server, OzMcp.Auth.Principal.key(principal))

        assert {:ok, [^id]} = Sessions.terminate_principal(@server, principal)
      end
    end

    test "a wildcard key ends nothing" do
      a1 = Utils.create_session(@server, principal_key: {"https://issuer.test", "alice"})
      a2 = Utils.create_session(@server, principal_key: {"https://other.test", "alice"})

      assert_raise FunctionClauseError, fn ->
        Sessions.terminate_principal(@server, {:_, "alice"})
      end

      assert {:ok, _} = Sessions.state(@server, a1)
      assert {:ok, _} = Sessions.state(@server, a2)
    end
  end

  describe "register_stream/3" do
    test "registers a stream for an existing session" do
      session_id = Utils.create_session(@server)

      assert {:ok, _} = Session.open_stream(@server, session_id, :get, self(), nil)
    end

    test "returns {:error, :no_session} for unknown session" do
      assert Session.open_stream(@server, "nonexistent", :get, self(), nil) ==
               {:error, :no_session}
    end
  end

  describe "unregister_stream/3" do
    test "returns {:error, :unavailable} when the server does not exist" do
      assert Session.close_stream(:nonexistent_server, "whatever", self()) ==
               {:error, :unavailable}
    end

    test "returns {:error, :no_session} for unknown session" do
      assert Session.close_stream(@server, "nonexistent", self()) == {:error, :no_session}
    end

    test "removes the stream from the session and keeps other streams" do
      stream1 = start_stream_collector()
      stream2 = start_stream_collector()

      session_id =
        Utils.create_session(@server, initialized: true, streams: [stream1, stream2])

      assert :ok = Session.close_stream(@server, session_id, stream1)

      assert Utils.stream_pids(@server, session_id) == [stream2]
    end

    test "does not deliver notifications to an unregistered stream" do
      stream = start_stream_collector()
      session_id = Utils.create_session(@server, initialized: true, streams: [stream])

      assert :ok = Session.close_stream(@server, session_id, stream)

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

      assert :ok = Sessions.notify_all(@server, notification)
      refute_receive {:oz_mcp_event, _, _, _}, 100
    end

    test "monitor path still cleans up when a stream pid goes down" do
      stream = spawn_fake_stream()
      session_id = Utils.create_session(@server, initialized: true, streams: [stream])

      Process.exit(stream, :kill)

      wait_until(fn -> stream not in Utils.stream_pids(@server, session_id) end)

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

      assert :ok = Sessions.notify_all(@server, notification)
      refute_receive {:oz_mcp_event, _, _, _}, 100
    end
  end

  describe "notify_all/2" do
    test "returns {:error, :unavailable} when the server does not exist" do
      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

      assert Sessions.notify_all(:nonexistent_server, notification) == {:error, :unavailable}
    end

    test "returns :ok when the server exists but has no streams" do
      Utils.create_session(@server)
      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

      assert Sessions.notify_all(@server, notification) == :ok
    end

    test "sends the notification to a registered stream" do
      Utils.create_session(@server, initialized: true, streams: [self()])

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

      assert :ok = Sessions.notify_all(@server, notification)
      {_, ^notification} = Utils.receive_event(5_000)
    end

    test "sends the notification to a single stream per session" do
      stream1 = start_stream_collector()
      stream2 = start_stream_collector()

      Utils.create_session(@server, initialized: true, streams: [stream1, stream2])

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

      assert :ok = Sessions.notify_all(@server, notification)

      assert_receive {:oz_mcp_event, _, ^notification, _pid}, 5_000
      refute_receive {:oz_mcp_event, _, _, _}, 100
    end

    test "sends the notification to streams across multiple sessions" do
      Utils.create_session(@server, initialized: true, streams: [self()])
      Utils.create_session(@server, initialized: true, streams: [self()])

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

      assert :ok = Sessions.notify_all(@server, notification)

      {_, ^notification} = Utils.receive_event(5_000)
      {_, ^notification} = Utils.receive_event(5_000)
    end

    test "does not send to a session without registered streams" do
      Utils.create_session(@server, initialized: true)

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

      assert :ok = Sessions.notify_all(@server, notification)
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    test "does not send to a non-initialized session" do
      Utils.create_session(@server, streams: [self()])

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

      assert :ok = Sessions.notify_all(@server, notification)
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    test "sends only to initialized sessions when both exist" do
      initialized_stream = start_stream_collector()
      Utils.create_session(@server, initialized: true, streams: [initialized_stream])
      Utils.create_session(@server, streams: [self()])

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

      assert :ok = Sessions.notify_all(@server, notification)

      assert_receive {:oz_mcp_event, _, ^notification, ^initialized_stream}, 5_000
      refute_receive {:oz_mcp_event, _, _, _}, 100
    end
  end

  describe "notify_session/3" do
    test "returns {:error, :unavailable} when the server does not exist" do
      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

      assert Sessions.emit(:nonexistent_server, "whatever", :session, notification) ==
               {:error, :unavailable}
    end

    # TODO: Do we want this behaviour? (maybe returnn {:error, :no_session})
    #
    test "returns :ok when the server exists but the session is unknown" do
      Utils.create_session(@server)

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

      assert Sessions.emit(@server, "nonexistent-session", :session, notification) == :ok
    end

    test "sends the notification only to the target session" do
      target_stream = start_stream_collector()
      other_stream = start_stream_collector()

      target_session =
        Utils.create_session(@server, initialized: true, streams: [target_stream])

      Utils.create_session(@server, initialized: true, streams: [other_stream])

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

      assert :ok = Sessions.emit(@server, target_session, :session, notification)

      assert_receive {:oz_mcp_event, _, ^notification, ^target_stream}, 5_000
      refute_receive {:oz_mcp_event, _, _, _}, 100
    end

    test "sends the notification to a single stream within the target session" do
      stream1 = start_stream_collector()
      stream2 = start_stream_collector()

      session_id =
        Utils.create_session(@server, initialized: true, streams: [stream1, stream2])

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

      assert :ok = Sessions.emit(@server, session_id, :session, notification)

      assert_receive {:oz_mcp_event, _, ^notification, _pid}, 5_000
      refute_receive {:oz_mcp_event, _, _, _}, 100
    end

    test "does not send when the target session has no registered streams" do
      session_id = Utils.create_session(@server, initialized: true)

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

      assert :ok = Sessions.emit(@server, session_id, :session, notification)
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    test "does not send to a non-initialized target session" do
      session_id = Utils.create_session(@server, streams: [self()])

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

      assert :ok = Sessions.emit(@server, session_id, :session, notification)
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end
  end

  describe "subscribe_resource/3" do
    test "returns {:error, :unavailable} when the server does not exist" do
      assert Sessions.subscribe(:nonexistent_server, "whatever", "file:///a.md") ==
               {:error, :unavailable}
    end

    test "returns {:error, :no_session} for unknown session" do
      assert Sessions.subscribe(@server, "nonexistent", "file:///a.md") ==
               {:error, :no_session}
    end

    test "adds the uri to the session subscriptions" do
      session_id = Utils.create_session(@server)

      assert :ok = Sessions.subscribe(@server, session_id, "file:///a.md")
      assert Utils.subscriptions(@server, session_id) == ["file:///a.md"]
    end

    test "does not duplicate an already subscribed uri" do
      session_id = Utils.create_session(@server)
      :ok = Sessions.subscribe(@server, session_id, "file:///a.md")

      assert :ok = Sessions.subscribe(@server, session_id, "file:///a.md")

      assert Utils.subscriptions(@server, session_id) == ["file:///a.md"]
    end
  end

  describe "unsubscribe_resource/3" do
    test "returns {:error, :unavailable} when the server does not exist" do
      assert Sessions.unsubscribe(:nonexistent_server, "whatever", "file:///a.md") ==
               {:error, :unavailable}
    end

    test "returns {:error, :no_session} for unknown session" do
      assert Sessions.unsubscribe(@server, "nonexistent", "file:///a.md") ==
               {:error, :no_session}
    end

    test "removes the subscription" do
      session_id = Utils.create_session(@server)
      :ok = Sessions.subscribe(@server, session_id, "file:///a.md")

      assert :ok = Sessions.unsubscribe(@server, session_id, "file:///a.md")
      assert Utils.subscriptions(@server, session_id) == []
    end

    test "returns :ok for a non subscribed uri" do
      session_id = Utils.create_session(@server)

      assert :ok = Sessions.unsubscribe(@server, session_id, "file:///a.md")
    end
  end

  describe "notify_subscribers/3" do
    test "returns {:error, :unavailable} when the server does not exist" do
      notification = %{"jsonrpc" => "2.0", "method" => "notifications/resources/updated"}

      assert Sessions.notify_subscribers(:nonexistent_server, "file:///a.md", notification) ==
               {:error, :unavailable}
    end

    test "sends the notification to a subscribed initialized session stream" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])
      :ok = Sessions.subscribe(@server, session_id, "file:///a.md")

      notification = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/resources/updated",
        "params" => %{"uri" => "file:///a.md"}
      }

      assert :ok = Sessions.notify_subscribers(@server, "file:///a.md", notification)
      {_, ^notification} = Utils.receive_event(5_000)
    end

    test "sends to a single stream per subscribed session" do
      stream1 = start_stream_collector()
      stream2 = start_stream_collector()

      session_id =
        Utils.create_session(@server, initialized: true, streams: [stream1, stream2])

      :ok = Sessions.subscribe(@server, session_id, "file:///a.md")

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/resources/updated"}

      assert :ok = Sessions.notify_subscribers(@server, "file:///a.md", notification)

      assert_receive {:oz_mcp_event, _, ^notification, _pid}, 5_000
      refute_receive {:oz_mcp_event, _, _, _}, 100
    end

    test "sends across multiple subscribed sessions" do
      s1 = Utils.create_session(@server, initialized: true, streams: [self()])
      :ok = Sessions.subscribe(@server, s1, "file:///a.md")

      s2 = Utils.create_session(@server, initialized: true, streams: [self()])
      :ok = Sessions.subscribe(@server, s2, "file:///a.md")

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/resources/updated"}

      assert :ok = Sessions.notify_subscribers(@server, "file:///a.md", notification)

      {_, ^notification} = Utils.receive_event(5_000)
      {_, ^notification} = Utils.receive_event(5_000)
    end

    test "does not send to a non subscribed session" do
      Utils.create_session(@server, initialized: true, streams: [self()])

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/resources/updated"}

      assert :ok = Sessions.notify_subscribers(@server, "file:///a.md", notification)
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    test "does not send for a different uri" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])
      :ok = Sessions.subscribe(@server, session_id, "file:///a.md")

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/resources/updated"}

      assert :ok = Sessions.notify_subscribers(@server, "file:///other.md", notification)
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    test "does not send to a non-initialized subscribed session" do
      session_id = Utils.create_session(@server, streams: [self()])
      :ok = Sessions.subscribe(@server, session_id, "file:///a.md")

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/resources/updated"}

      assert :ok = Sessions.notify_subscribers(@server, "file:///a.md", notification)
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    test "stops sending after unsubscribe" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])
      :ok = Sessions.subscribe(@server, session_id, "file:///a.md")
      :ok = Sessions.unsubscribe(@server, session_id, "file:///a.md")

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/resources/updated"}

      assert :ok = Sessions.notify_subscribers(@server, "file:///a.md", notification)
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end
  end

  describe "notify_log_message/3" do
    test "returns {:error, :unavailable} when the server does not exist" do
      notification = %{"jsonrpc" => "2.0", "method" => "notifications/message"}

      assert Sessions.notify_log_message(:nonexistent_server, :info, notification) ==
               {:error, :unavailable}
    end

    test "sends to a session whose level equals the message level" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])
      :ok = Sessions.set_log_level(@server, session_id, :warning)

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/message"}

      assert :ok = Sessions.notify_log_message(@server, :warning, notification)
      {_, ^notification} = Utils.receive_event(5_000)
    end

    test "sends when the message severity is above the session level" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])
      :ok = Sessions.set_log_level(@server, session_id, :info)

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/message"}

      assert :ok = Sessions.notify_log_message(@server, :emergency, notification)
      {_, ^notification} = Utils.receive_event(5_000)
    end

    test "does not send when the message severity is below the session level" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])
      :ok = Sessions.set_log_level(@server, session_id, :info)

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/message"}

      assert :ok = Sessions.notify_log_message(@server, :debug, notification)
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    test "does not send when the session level is unset" do
      Utils.create_session(@server, initialized: true, streams: [self()])

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/message"}

      assert :ok = Sessions.notify_log_message(@server, :debug, notification)
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    test "does not send to a non-initialized session even with a matching level" do
      session_id = Utils.create_session(@server, streams: [self()])
      :ok = Sessions.set_log_level(@server, session_id, :debug)

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/message"}

      assert :ok = Sessions.notify_log_message(@server, :debug, notification)
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    test "sends only to sessions whose level accepts the message" do
      accepting_stream = start_stream_collector()
      rejecting_stream = start_stream_collector()

      accepting_session =
        Utils.create_session(@server, initialized: true, streams: [accepting_stream])

      :ok = Sessions.set_log_level(@server, accepting_session, :notice)

      rejecting_session =
        Utils.create_session(@server, initialized: true, streams: [rejecting_stream])

      :ok = Sessions.set_log_level(@server, rejecting_session, :error)

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/message"}

      assert :ok = Sessions.notify_log_message(@server, :warning, notification)

      assert_receive {:oz_mcp_event, _, ^notification, ^accepting_stream}, 5_000
      refute_receive {:oz_mcp_event, _, _, _}, 100
    end

    @tag :capture_log
    test "a session level that is not a level does not stop the Server" do
      {:ok, server_pid} = OzMcp.Instance.whereis(@server, :sessions)
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])

      # Write a bad level directly in the view of the session.
      #
      :ok = OzMcp.Session.update_view(@server, session_id, log_level: :verbose)

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/message"}
      assert :ok = Sessions.notify_log_message(@server, :info, notification)
      Utils.sync_server(@server, session_id)

      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
      assert {:ok, ^server_pid} = OzMcp.Instance.whereis(@server, :sessions)
    end
  end

  describe "notify_log_message/4 with a principal key" do
    test "sends only to the sessions of the principal" do
      alice = {"https://issuer", "alice"}
      bob = {"https://issuer", "bob"}

      alice_stream = start_stream_collector()
      bob_stream = start_stream_collector()

      a =
        Utils.create_session(@server,
          initialized: true,
          streams: [alice_stream],
          principal_key: alice
        )

      b =
        Utils.create_session(@server,
          initialized: true,
          streams: [bob_stream],
          principal_key: bob
        )

      :ok = Sessions.set_log_level(@server, a, :debug)
      :ok = Sessions.set_log_level(@server, b, :debug)

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/message", "params" => %{}}
      assert :ok = Sessions.notify_log_message(@server, :info, notification, alice)

      assert_receive {:oz_mcp_event, _, %{"method" => "notifications/message"}, ^alice_stream},
                     5_000

      refute_receive {:oz_mcp_event, _, _, ^bob_stream}, 100
    end

    test "sends to every session without a key" do
      stream = start_stream_collector()

      session_id = Utils.create_session(@server, initialized: true, streams: [stream])
      :ok = Sessions.set_log_level(@server, session_id, :debug)

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/message", "params" => %{}}
      assert :ok = Sessions.notify_log_message(@server, :info, notification)

      assert_receive {:oz_mcp_event, _, ^notification, ^stream}, 5_000
    end

    test "a key matches no session of an open server" do
      stream = start_stream_collector()

      session_id = Utils.create_session(@server, initialized: true, streams: [stream])
      :ok = Sessions.set_log_level(@server, session_id, :debug)

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/message", "params" => %{}}
      assert :ok = Sessions.notify_log_message(@server, :info, notification, {nil, "alice"})

      refute_receive {:oz_mcp_event, _, _, ^stream}, 100
    end

    test "a key with a bad shape raises FunctionClauseError" do
      assert_raise FunctionClauseError, fn ->
        Sessions.notify_log_message(@server, :info, %{}, :all)
      end
    end

    test "returns {:error, :unavailable} when the server does not exist" do
      notification = %{"jsonrpc" => "2.0", "method" => "notifications/message"}

      assert Sessions.notify_log_message(:nonexistent_server, :info, notification, {
               "https://issuer",
               "alice"
             }) == {:error, :unavailable}
    end
  end

  describe "a notification that JSON cannot encode" do
    test "a log message with a pid in the data is refused and sends nothing" do
      {:ok, server_pid} = OzMcp.Instance.whereis(@server, :sessions)
      stream = start_stream_collector()
      session_id = Utils.create_session(@server, initialized: true, streams: [stream])
      :ok = Sessions.set_log_level(@server, session_id, :debug)

      bad = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/message",
        "params" => %{"level" => "info", "data" => %{"pid" => self()}}
      }

      log =
        Utils.capture_log([level: :error], fn ->
          assert Sessions.notify_log_message(@server, :info, bad) == {:error, :not_encodable}
          Utils.sync_server(@server, session_id)
        end)

      assert log == ""
      refute_receive {:oz_mcp_event, _, _, _}, 100

      assert {:ok, ^server_pid} = OzMcp.Instance.whereis(@server, :sessions)
      assert SessionProbe.initialized?(@server, session_id) == true
    end

    test "Sessions.emit, notify_all and notify_subscribers return the error and send nothing" do
      stream = start_stream_collector()
      session_id = Utils.create_session(@server, initialized: true, streams: [stream])
      :ok = Sessions.subscribe(@server, session_id, "file:///a")

      bad = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/x",
        "params" => %{"ref" => make_ref()}
      }

      assert Sessions.emit(@server, session_id, :session, bad) == {:error, :not_encodable}
      assert Sessions.notify_all(@server, bad) == {:error, :not_encodable}
      assert Sessions.notify_subscribers(@server, "file:///a", bad) == {:error, :not_encodable}

      refute_receive {:oz_mcp_event, _, _, _}, 100
      assert SessionProbe.initialized?(@server, session_id) == true
    end

    test "a resource update with a reference in _meta is refused" do
      {:ok, server_pid} = OzMcp.Instance.whereis(@server, :sessions)
      session_id = Utils.create_session(@server, initialized: true)
      :ok = Sessions.subscribe(@server, session_id, "file:///a")

      assert OzMcp.Notify.resource_updated(@server, "file:///a", _meta: %{"ref" => make_ref()}) ==
               {:error, :not_encodable}

      assert {:ok, ^server_pid} = OzMcp.Instance.whereis(@server, :sessions)
      assert SessionProbe.initialized?(@server, session_id) == true
    end

    test "a good notification after a bad one is delivered" do
      stream = start_stream_collector()
      session_id = Utils.create_session(@server, initialized: true, streams: [stream])

      bad = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/tools/list_changed",
        "params" => %{"bad" => self()}
      }

      assert Sessions.notify_all(@server, bad) == {:error, :not_encodable}

      Support.Helpers.Broadcast.notify_all(@server)

      assert_receive {:oz_mcp_event, _event_id, %{"method" => "notifications/tools/list_changed"},
                      ^stream},
                     1_000

      refute_received {:oz_mcp_event, _, %{"params" => _}, ^stream}
      assert SessionProbe.initialized?(@server, session_id) == true
    end
  end

  describe "notification event log (D4)" do
    @notification %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

    test "logs notifications while no live stream is alive" do
      session_id = Utils.create_session(@server, initialized: true)

      # A GET stream opens and ends: the session keeps it for the resume
      # and the notifications go in its ring.
      #
      assert {:ok, %{stream_id: _}} =
               Session.open_stream(@server, session_id, :get, self(), nil)

      assert :ok = Session.close_stream(@server, session_id, self())

      assert :ok = Sessions.notify_all(@server, @notification)
      assert :ok = Sessions.notify_all(@server, @notification)

      # Barrier: both casts are processed before the read of the log.
      #
      :ok = Utils.sync_server(@server, session_id)

      assert {:ok, events} = SessionProbe.events_after(@server, session_id, "")
      assert length(events) == 2

      Enum.each(events, fn {id, encoded} ->
        assert String.match?(id, ~r/^g\.[A-Za-z0-9]+:\d+$/)
        assert encoded == Utils.encode_json(@notification)
      end)
    end

    test "does not log notifications for a non-initialized session" do
      session_id = Utils.create_session(@server, streams: [self()])

      assert :ok = Sessions.notify_all(@server, @notification)

      # Barrier: the cast is processed before the lookup.
      #
      :ok = Utils.sync_server(@server, session_id)

      assert SessionProbe.initialized?(@server, session_id) == false

      assert {:ok, []} = SessionProbe.events_after(@server, session_id, "")
    end

    @tag task_opts: %{sse_event_log_size: 3}
    test "honors the sse_event_log_size cap, keeping the newest events" do
      session_id = Utils.create_session(@server, initialized: true)

      # A GET stream opens and ends: the notifications go in its ring.
      #
      assert {:ok, %{stream_id: _stream_id}} =
               Session.open_stream(@server, session_id, :get, self(), nil)

      assert :ok = Session.close_stream(@server, session_id, self())

      for _ <- 1..5 do
        assert :ok = Sessions.notify_all(@server, @notification)
      end

      # Barrier: every cast is processed before the lookup.
      #
      :ok = Utils.sync_server(@server, session_id)

      assert SessionProbe.initialized?(@server, session_id) == true

      assert {:ok, events} = SessionProbe.events_after(@server, session_id, "")
      assert length(events) == 3

      assert {:ok, retained} = SessionProbe.events_after(@server, session_id, "nope")
      assert retained == events
    end
  end

  describe "the open POST streams" do
    test "an open_request call adds an entry, the stop of the owner removes it" do
      session_id = Utils.create_session(@server, initialized: true)
      owner = spawn_fake_stream()

      assert :ok = Utils.open_request(@server, session_id, 7, owner, {"strm1", :sse})
      Utils.sync_server(@server, session_id)

      assert %{"strm1" => %{owner: ^owner, request_id: 7}} =
               Utils.session_data(@server, session_id).streams

      Process.exit(owner, :kill)

      wait_until(fn ->
        data = Utils.session_data(@server, session_id)
        data.streams == %{} and data.refs == %{}
      end)
    end

    test "a close_request call removes the entry" do
      session_id = Utils.create_session(@server, initialized: true)
      owner = spawn_fake_stream()

      assert :ok = Utils.open_request(@server, session_id, 7, owner, {"strm1", :sse})
      Utils.sync_server(@server, session_id)
      assert map_size(Utils.session_data(@server, session_id).streams) == 1

      # No event went out and no resumer holds the stream: the response is
      # the plain JSON one. The entry goes all the same.
      #
      assert :plain =
               Utils.close_request(@server, session_id, 7, "strm1", {:response, "{}", false})

      assert :ok = Session.end_request(@server, session_id, 7)
      Utils.sync_server(@server, session_id)

      assert %{streams: streams, refs: refs} = Utils.session_data(@server, session_id)
      assert streams == %{}
      assert refs == %{}
    end

    test "a final event for a stream with no entry gives :gone and adds nothing" do
      session_id = Utils.create_session(@server, initialized: true)

      assert :gone =
               Utils.close_request(@server, session_id, 7, "strm1", {:response, "{}", false})

      Utils.sync_server(@server, session_id)

      assert Utils.session_data(@server, session_id).streams == %{}
      assert {:ok, []} = SessionProbe.events_after(@server, session_id, "")
    end

    test "an emit for a POST stream delivers nothing to the GET streams of the session" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])
      owner = spawn_fake_stream()

      assert :ok = Utils.open_request(@server, session_id, 7, owner, {"strm1", :sse})

      encoded =
        Utils.encode_json(%{"jsonrpc" => "2.0", "method" => "notifications/progress"})

      assert :ok = Sessions.emit(@server, session_id, {:request, 7}, encoded)
      Utils.sync_server(@server, session_id)

      assert {:ok, [{"strm1:1", ^encoded}]} = SessionProbe.events_after(@server, session_id, "")

      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    test "the terminate of the session drops its stream entries" do
      session_id = Utils.create_session(@server, initialized: true)
      owner = spawn_fake_stream()

      assert :ok = Utils.open_request(@server, session_id, 7, owner, {"strm1", :sse})
      Utils.sync_server(@server, session_id)
      assert map_size(Utils.session_data(@server, session_id).streams) == 1

      assert :ok = Sessions.terminate(@server, session_id)

      assert Utils.session_data(@server, session_id) == nil
    end
  end

  describe "emit/4 to a request" do
    test "goes to the owner of the stream with the next id and never to a GET stream" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])
      owner = spawn_forwarder()

      :ok = Utils.open_request(@server, session_id, 7, owner, {"strm1", :sse})
      message = ~s({"jsonrpc":"2.0","method":"notifications/progress"})

      assert :ok = Sessions.emit(@server, session_id, {:request, 7}, message)
      assert :ok = Sessions.emit(@server, session_id, {:request, 7}, message)

      assert_receive {:forwarded, {:oz_mcp_stream, "strm1", {:event, "strm1:1", ^message}}}, 5_000
      assert_receive {:forwarded, {:oz_mcp_stream, "strm1", {:event, "strm1:2", ^message}}}, 5_000
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100

      assert {:ok, [{"strm1:1", ^message}, {"strm1:2", ^message}]} =
               SessionProbe.events_after(@server, session_id, "")
    end

    test "goes to the resumer, not to the owner, when the stream was resumed" do
      session_id = Utils.create_session(@server, initialized: true)
      owner = spawn_forwarder()

      :ok = Utils.open_request(@server, session_id, 7, owner, {"strm1", :sse})

      assert {:ok, %{mode: :resume}} =
               Session.open_stream(@server, session_id, :get, self(), "strm1:0")

      assert_receive {:forwarded, {:oz_mcp_stream, "strm1", :taken_over}}, 5_000

      message = ~s({"jsonrpc":"2.0","method":"notifications/progress"})
      assert :ok = Sessions.emit(@server, session_id, {:request, 7}, message)

      assert_receive {:oz_mcp_stream, "strm1", {:event, "strm1:1", ^message}}, 5_000
      refute_receive {:forwarded, {:oz_mcp_stream, _, {:event, _, _}}}, 100
    end

    test "a request with no stream gets nothing: no event, no log, no GET stream" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])

      assert :ok = Sessions.emit(@server, session_id, {:request, 99}, ~s({"method":"x"}))
      Utils.sync_server(@server, session_id)

      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
      assert {:ok, []} = SessionProbe.events_after(@server, session_id, "")
    end
  end

  describe "the resume of a POST stream" do
    test "a resume of an open stream takes it over" do
      session_id = Utils.create_session(@server, initialized: true)
      owner = spawn_forwarder()

      :ok = Utils.open_request(@server, session_id, 7, owner, {"strm1", :sse})
      Utils.sync_server(@server, session_id)

      resumer = self()

      assert {:ok, %{mode: :resume, stream_id: "strm1", replay: [], ended: false}} =
               Session.open_stream(@server, session_id, :get, resumer, "strm1:0")

      assert_receive {:forwarded, {:oz_mcp_stream, "strm1", :taken_over}}, 5_000

      assert %{"strm1" => %{owner: ^owner, resumer: ^resumer}} =
               Utils.session_data(@server, session_id).streams
    end

    test "the live events of the stream go to the resumer" do
      session_id = Utils.create_session(@server, initialized: true)
      owner = spawn_forwarder()

      :ok = Utils.open_request(@server, session_id, 7, owner, {"strm1", :sse})

      assert {:ok, %{mode: :resume, ended: false}} =
               Session.open_stream(@server, session_id, :get, self(), "strm1:0")

      encoded = ~s({"jsonrpc":"2.0","method":"notifications/progress"})

      assert :ok = Sessions.emit(@server, session_id, {:request, 7}, encoded)

      Utils.sync_server(@server, session_id)

      assert_receive {:oz_mcp_stream, _, {:event, "strm1:1", ^encoded}}, 5_000
    end

    test "the final event ends the resumer and drops the entry" do
      session_id = Utils.create_session(@server, initialized: true)
      owner = spawn_forwarder()

      :ok = Utils.open_request(@server, session_id, 7, owner, {"strm1", :sse})

      assert {:ok, %{mode: :resume, ended: false}} =
               Session.open_stream(@server, session_id, :get, self(), "strm1:0")

      assert {:sse, "strm1:1"} =
               Utils.close_request(@server, session_id, 7, "strm1", {:response, "{}", false})

      assert :ok = Session.end_request(@server, session_id, 7)
      Utils.sync_server(@server, session_id)

      assert_receive {:oz_mcp_stream, _, {:event, "strm1:1", "{}"}}, 5_000
      assert_receive {:oz_mcp_stream, "strm1", :end}, 5_000

      assert %{streams: streams, refs: refs} = Utils.session_data(@server, session_id)
      assert streams == %{}
      assert refs == %{}
    end

    test "a second resume of the stream ends the first resumer" do
      session_id = Utils.create_session(@server, initialized: true)
      owner = spawn_forwarder()
      first = spawn_forwarder()

      :ok = Utils.open_request(@server, session_id, 7, owner, {"strm1", :sse})
      Utils.sync_server(@server, session_id)

      assert {:ok, %{mode: :resume, ended: false}} =
               Session.open_stream(@server, session_id, :get, first, "strm1:0")

      assert {:ok, %{mode: :resume, ended: false}} =
               Session.open_stream(@server, session_id, :get, self(), "strm1:0")

      assert_receive {:forwarded, {:oz_mcp_stream, "strm1", :end}}, 5_000

      me = self()
      data = Utils.session_data(@server, session_id)

      assert %{"strm1" => %{resumer: ^me}} = data.streams
      assert {:resumer, "strm1"} in Map.values(data.refs)
    end

    test "the stop of the owner ends the resumer and drops the entry" do
      session_id = Utils.create_session(@server, initialized: true)
      owner = spawn_forwarder()

      :ok = Utils.open_request(@server, session_id, 7, owner, {"strm1", :sse})
      Utils.sync_server(@server, session_id)

      assert {:ok, %{mode: :resume, ended: false}} =
               Session.open_stream(@server, session_id, :get, self(), "strm1:0")

      Process.exit(owner, :kill)

      assert_receive {:oz_mcp_stream, "strm1", :end}, 5_000

      wait_until(fn ->
        data = Utils.session_data(@server, session_id)
        data.streams == %{} and data.refs == %{}
      end)
    end

    test "the stop of the resumer clears it, a later event goes to the log only" do
      session_id = Utils.create_session(@server, initialized: true)
      owner = spawn_forwarder()
      resumer = spawn_forwarder()

      :ok = Utils.open_request(@server, session_id, 7, owner, {"strm1", :sse})
      Utils.sync_server(@server, session_id)

      assert {:ok, %{mode: :resume, ended: false}} =
               Session.open_stream(@server, session_id, :get, resumer, "strm1:0")

      Process.exit(resumer, :kill)

      wait_until(fn ->
        data = Utils.session_data(@server, session_id)
        match?(%{resumer: nil}, data.streams["strm1"])
      end)

      Sessions.emit(@server, session_id, {:request, 7}, "{}")

      Utils.sync_server(@server, session_id)

      assert {:ok, [{"strm1:1", "{}"}]} =
               SessionProbe.events_after(@server, session_id, "")

      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    test "a detach_resume clears the resumer from the entry" do
      session_id = Utils.create_session(@server, initialized: true)
      owner = spawn_forwarder()
      resumer = spawn_forwarder()

      :ok = Utils.open_request(@server, session_id, 7, owner, {"strm1", :sse})
      Utils.sync_server(@server, session_id)

      assert {:ok, %{mode: :resume, ended: false}} =
               Session.open_stream(@server, session_id, :get, resumer, "strm1:0")

      assert :ok = Session.detach_resume(@server, session_id, "strm1", resumer)

      assert %{"strm1" => %{owner: ^owner, resumer: nil}} =
               Utils.session_data(@server, session_id).streams

      # A resumer that is not the one of the entry: the call answers :ok.
      #
      assert :ok = Session.detach_resume(@server, session_id, "strm1", self())
    end

    test "a resume of a stream with no entry gives ended: true and the events of the log" do
      session_id = Utils.create_session(@server, initialized: true)

      assert :ok = SessionProbe.log_event(@server, session_id, "strm9:1", ~s({"p":1}))

      assert {:ok,
              %{
                mode: :resume,
                stream_id: "strm9",
                replay: [{"strm9:1", ~s({"p":1})}],
                ended: true
              }} =
               Session.open_stream(@server, session_id, :get, self(), "strm9:0")
    end

    test "a resume is not a GET stream of the session and logs no marker" do
      session_id = Utils.create_session(@server, initialized: true)
      owner = spawn_forwarder()

      :ok = Utils.open_request(@server, session_id, 7, owner, {"strm1", :sse})
      Utils.sync_server(@server, session_id)

      assert {:ok, %{mode: :resume, ended: false}} =
               Session.open_stream(@server, session_id, :get, self(), "strm1:0")

      assert Utils.session_data(@server, session_id).get_streams == []
      assert {:ok, %{streams: 0}} = Sessions.lookup(@server, session_id)

      assert {:ok, []} = SessionProbe.events_after(@server, session_id, "")
    end

    test "the terminate of the session ends the resumer and drops the entry" do
      session_id = Utils.create_session(@server, initialized: true)
      owner = spawn_forwarder()
      resumer = spawn_forwarder()

      :ok = Utils.open_request(@server, session_id, 7, owner, {"strm1", :sse})
      Utils.sync_server(@server, session_id)

      assert {:ok, %{mode: :resume, ended: false}} =
               Session.open_stream(@server, session_id, :get, resumer, "strm1:0")

      assert :ok = Sessions.terminate(@server, session_id)

      assert_receive {:forwarded, {:oz_mcp_stream, "strm1", :terminate}}, 5_000
      assert Utils.session_data(@server, session_id) == nil
    end

    test "a resume with a GET id keeps the behavior of a GET stream" do
      session_id = Utils.create_session(@server, initialized: true)

      assert {:ok, %{mode: :get, replay: [], priming_id: priming_id}} =
               Session.open_stream(@server, session_id, :get, self(), nil)

      assert priming_id =~ ~r/^g\.[0-9a-zA-Z]+:0$/

      # The priming id is the first position of the stream: the log holds
      # no entry for it.
      #
      assert {:ok, []} = SessionProbe.events_after(@server, session_id, "")
    end
  end

  describe "the open_stream payload" do
    test "the payload of a GET stream names the stream and the session process" do
      session_id = Utils.create_session(@server, initialized: true)
      {:ok, view} = Sessions.lookup(@server, session_id)

      assert {:ok,
              %{mode: :get, replay: [], priming_id: _, stream_id: id, session_pid: session_pid}} =
               Session.open_stream(@server, session_id, :get, self(), nil)

      assert session_pid == view.pid
      assert [%{id: ^id}] = Utils.session_streams(@server, session_id)
    end

    test "two GET streams of one session have two stream ids" do
      session_id = Utils.create_session(@server, initialized: true)

      assert {:ok, %{stream_id: first}} =
               Session.open_stream(@server, session_id, :get, spawn_fake_stream(), nil)

      assert {:ok, %{stream_id: second}} =
               Session.open_stream(@server, session_id, :get, spawn_fake_stream(), nil)

      assert first != second
    end

    test "the payload of a resumed POST stream names the session process" do
      session_id = Utils.create_session(@server, initialized: true)
      {:ok, view} = Sessions.lookup(@server, session_id)
      owner = spawn_forwarder()

      :ok = Utils.open_request(@server, session_id, 7, owner, {"strm1", :sse})
      Utils.sync_server(@server, session_id)

      assert {:ok, %{mode: :resume, ended: false, session_pid: session_pid}} =
               Session.open_stream(@server, session_id, :get, self(), "strm1:0")

      assert session_pid == view.pid
      assert_receive {:forwarded, {:oz_mcp_stream, "strm1", :taken_over}}, 5_000
    end
  end

  describe "the warning log of a lost position" do
    @response ~s({"jsonrpc":"2.0","id":1,"result":{}})
    @request ~s({"jsonrpc":"2.0","method":"ping","id":1})

    test "a GET resume with an id that is not in the log warns, with no id in the text" do
      session_id = Utils.create_session(@server, initialized: true)

      assert :ok = SessionProbe.log_event(@server, session_id, "g.knownstrm1:1", ~s({"p":1}))

      import ExUnit.CaptureLog

      logged =
        capture_log(fn ->
          assert {:ok, %{mode: :get, replay: [], priming_id: _}} =
                   Session.open_stream(@server, session_id, :get, self(), "g1aaaaaaaaaaaaa")
        end)

      assert logged =~ "the GET stream starts fresh"
      refute logged =~ "g1aaaaaaaaaaaaa"
    end

    test "a GET resume with an invalid id warns too" do
      session_id = Utils.create_session(@server, initialized: true)

      import ExUnit.CaptureLog

      logged =
        capture_log(fn ->
          assert {:ok, %{mode: :get, replay: [], priming_id: _}} =
                   Session.open_stream(@server, session_id, :get, self(), ":3")
        end)

      assert logged =~ "the GET stream starts fresh"

      # The captured lines carry the time of day, whose text can hold the
      # id by accident: the refutation reads the text without it.
      #
      refute strip_log_time(logged) =~ ":3"
    end

    @tag task_opts: %{sse_event_log_size: 2}
    test "a resume of a stream with a gap warns that the cap removed events" do
      session_id = Utils.create_session(@server, initialized: true)

      assert :ok = SessionProbe.log_event(@server, session_id, "strm1:1", @request)
      assert :ok = SessionProbe.log_event(@server, session_id, "strm1:4", @request)
      assert :ok = SessionProbe.log_event(@server, session_id, "strm1:5", @request)

      import ExUnit.CaptureLog

      logged =
        capture_log(fn ->
          assert {:ok, %{mode: :resume, replay: _, ended: true}} =
                   Session.open_stream(@server, session_id, :get, self(), "strm1:1")
        end)

      assert logged =~ "the event log caps removed events of a resumed POST stream"
    end

    test "a resume of a stream with no entry and no response in the log warns" do
      session_id = Utils.create_session(@server, initialized: true)

      assert :ok = SessionProbe.log_event(@server, session_id, "strm9:1", @request)

      import ExUnit.CaptureLog

      logged =
        capture_log(fn ->
          assert {:ok, %{mode: :resume, ended: true}} =
                   Session.open_stream(@server, session_id, :get, self(), "strm9:0")
        end)

      assert logged =~ "its response is not in the event log"
    end

    test "a resume of a stream with no entry and the response in the log does not warn" do
      session_id = Utils.create_session(@server, initialized: true)

      assert :ok = SessionProbe.log_event(@server, session_id, "strm9:1", @request)
      assert :ok = SessionProbe.log_event(@server, session_id, "strm9:2", @response)

      import ExUnit.CaptureLog

      logged =
        capture_log(fn ->
          assert {:ok, %{mode: :resume, ended: true}} =
                   Session.open_stream(@server, session_id, :get, self(), "strm9:0")
        end)

      refute logged =~ "resumed POST stream"
    end

    test "the kill of an owner with a resumer warns that the request stopped" do
      session_id = Utils.create_session(@server, initialized: true)
      owner = spawn_forwarder()

      :ok = Utils.open_request(@server, session_id, 7, owner, {"strm1", :sse})
      Utils.sync_server(@server, session_id)

      assert {:ok, %{mode: :resume, ended: false}} =
               Session.open_stream(@server, session_id, :get, self(), "strm1:0")

      import ExUnit.CaptureLog

      logged =
        capture_log(fn ->
          Process.exit(owner, :kill)
          assert_receive {:oz_mcp_stream, "strm1", :end}, 5_000
        end)

      assert logged =~ "stopped before its response"
    end
  end

  defp start_stream_collector do
    parent = self()
    spawn_link(fn -> stream_loop(parent) end)
  end

  defp start_sse_stream do
    parent = self()

    spawn_link(fn ->
      receive do
        {:oz_mcp_stream, stream_id, :terminate} ->
          send(parent, {:stream_terminated, self()})
          send(parent, {:stream_terminated, self(), stream_id})
      end
    end)
  end

  defp stream_loop(parent) do
    receive do
      {:oz_mcp_stream, _stream_id, {:event, event_id, data}} ->
        send(
          parent,
          {:oz_mcp_event, event_id, data |> IO.iodata_to_binary() |> :json.decode(), self()}
        )

        stream_loop(parent)
    end
  end

  defp spawn_fake_stream do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  # An owner of a POST stream (or a resumer of one) that forwards every
  # message it gets (the takeover message of the Server, the end of the
  # stream) to the test process, until it is killed.
  #
  defp spawn_forwarder do
    parent = self()
    spawn(fn -> forward_loop(parent) end)
  end

  defp forward_loop(parent) do
    receive do
      message ->
        send(parent, {:forwarded, message})
        forward_loop(parent)
    end
  end

  # Removes the time of day that precedes each captured log line.
  #
  defp strip_log_time(logged) do
    String.replace(logged, ~r/\n?\d{2}:\d{2}:\d{2}\.\d{3} /, "\n")
  end

  defp wait_until(fun, retries \\ 1_500) do
    if Utils.eventually(fun, retries * 5) do
      :ok
    else
      flunk("condition was not met in time")
    end
  end
end
