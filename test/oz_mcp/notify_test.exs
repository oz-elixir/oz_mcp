defmodule OzMcp.NotifyTest do
  use ExUnit.Case, async: true
  alias OzMcp.{Notify, Session, Sessions, Tasks, Tasks.RelatedTask}
  alias OzMcp.Structs.Task
  alias Support.Helpers.SessionProbe
  alias Support.Helpers.Utils
  alias Support.Servers

  @server_module Servers.Default

  @server Module.concat(@server_module, __MODULE__)
  setup do
    Utils.start_instance(@server_module, name: @server)

    :ok
  end

  @principal OzMcp.Auth.Principal.new!(issuer: "https://issuer.test", subject: "alice")

  describe "event delivery" do
    test "delivers the notification with a unique event id and replays it via Last-Event-ID" do
      session_id = Utils.create_session(@server, initialized: true)

      # A GET stream: its events go in the log, so a client can replay them.
      #
      assert {:ok, %{stream_id: stream_id}} =
               Session.open_stream(@server, session_id, :get, self(), nil)

      assert :ok = Support.Helpers.Broadcast.notify_all(@server)

      expected = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}
      {event_id, ^expected} = Utils.receive_event(5_000)
      assert String.match?(event_id, ~r/^g\.[0-9a-zA-Z]+:\d+$/)
      assert String.starts_with?(event_id, "#{stream_id}:")

      # The event is logged under its stream and is replayable
      # for a reconnecting client carrying an older/unknown Last-Event-ID.
      #
      assert {:ok, [{^event_id, encoded}]} =
               SessionProbe.events_after(@server, session_id, "nope")

      assert encoded == Utils.encode_json(expected)

      # A client that already saw the id gets nothing replayed.
      #
      assert {:ok, []} = SessionProbe.events_after(@server, session_id, event_id)
    end
  end

  describe "resource_updated/2" do
    @uri "file:///stations.md"

    test "sends resources/updated notification to the subscribed stream" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])
      :ok = Sessions.subscribe(@server, session_id, @uri)

      assert :ok = Notify.resource_updated(@server, @uri)

      expected = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/resources/updated",
        "params" => %{"uri" => @uri}
      }

      {_, ^expected} = Utils.receive_event(5_000)
    end

    test "sends to every subscribed session but only once each" do
      s1 = Utils.create_session(@server, initialized: true, streams: [self()])
      :ok = Sessions.subscribe(@server, s1, @uri)

      s2 = Utils.create_session(@server, initialized: true, streams: [self()])
      :ok = Sessions.subscribe(@server, s2, @uri)

      assert :ok = Notify.resource_updated(@server, @uri)

      assert_receive {:oz_mcp_stream, _, {:event, _, _}}, 5_000
      assert_receive {:oz_mcp_stream, _, {:event, _, _}}, 5_000
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    test "does not send to sessions that are not subscribed" do
      Utils.create_session(@server, initialized: true, streams: [self()])

      assert :ok = Notify.resource_updated(@server, @uri)
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    test "does not send for a different uri than the subscribed one" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])
      :ok = Sessions.subscribe(@server, session_id, @uri)

      assert :ok = Notify.resource_updated(@server, "file:///other.md")
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    test "stops sending after unsubscribe" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])
      :ok = Sessions.subscribe(@server, session_id, @uri)
      :ok = Sessions.unsubscribe(@server, session_id, @uri)

      assert :ok = Notify.resource_updated(@server, @uri)
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end
  end

  describe "resource_updated/3 params handling" do
    @uri "file:///stations.md"

    setup do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])
      :ok = Sessions.subscribe(@server, session_id, @uri)
      %{session_id: session_id}
    end

    test "includes params with uri and _meta when _meta is provided", %{session_id: _} do
      assert :ok = Notify.resource_updated(@server, @uri, _meta: %{"progressToken" => 42})

      expected = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/resources/updated",
        "params" => %{"uri" => @uri, "_meta" => %{"progressToken" => 42}}
      }

      {_, ^expected} = Utils.receive_event(5_000)
    end

    test "omits _meta field when not provided" do
      assert :ok = Notify.resource_updated(@server, @uri)

      {_, notification} = Utils.receive_event(5_000)
      assert notification["params"] == %{"uri" => @uri}
      refute Map.has_key?(notification["params"], "_meta")
    end

    test "returns {:error, :invalid_meta} when a _meta key is not valid" do
      assert {:error, :invalid_meta} =
               Notify.resource_updated(@server, @uri, _meta: %{"a b" => 1})

      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    test "returns {:error, :invalid_meta} when a _meta key has a reserved prefix" do
      assert {:error, :invalid_meta} =
               Notify.resource_updated(@server, @uri, _meta: %{"dev.mcp/x" => 1})

      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    test "sends the related-task _meta key that the framework writes" do
      assert :ok =
               Notify.resource_updated(@server, @uri,
                 _meta: %{
                   "io.modelcontextprotocol/related-task" => "t"
                 }
               )

      {_, notification} = Utils.receive_event(5_000)
      assert notification["params"]["_meta"] == %{"io.modelcontextprotocol/related-task" => "t"}
    end
  end

  describe "broadcast_log/4" do
    test "delivers notifications/message to a session at the same level" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])
      :ok = Sessions.set_log_level(@server, session_id, :debug)

      assert :ok = Notify.broadcast_log(@server, :debug, "cache miss")

      expected = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/message",
        "params" => %{"level" => "debug", "data" => "cache miss"}
      }

      {_, ^expected} = Utils.receive_event(5_000)
    end

    test "delivers notifications/message with a map payload" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])
      :ok = Sessions.set_log_level(@server, session_id, :info)

      assert :ok = Notify.broadcast_log(@server, :warning, %{disk: "92%"})

      {_, notification} = Utils.receive_event(5_000)
      assert notification["params"]["level"] == "warning"
      assert notification["params"]["data"] == %{"disk" => "92%"}
    end

    test "does not deliver when the session level is above the message level" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])
      :ok = Sessions.set_log_level(@server, session_id, :info)

      assert :ok = Notify.broadcast_log(@server, :debug, "cache miss")
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    test "delivers higher severity messages to a session with a lower level" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])
      :ok = Sessions.set_log_level(@server, session_id, :info)

      assert :ok = Notify.broadcast_log(@server, :emergency, "disk full")

      {_, notification} = Utils.receive_event(5_000)
      assert notification["params"]["level"] == "emergency"
    end

    test "does not deliver when the session level is unset" do
      Utils.create_session(@server, initialized: true, streams: [self()])

      assert :ok = Notify.broadcast_log(@server, :debug, "cache miss")
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    test "does not deliver to a non-initialized session" do
      session_id = Utils.create_session(@server, streams: [self()])
      :ok = Sessions.set_log_level(@server, session_id, :debug)

      assert :ok = Notify.broadcast_log(@server, :debug, "cache miss")
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    test "passes the logger field through to the notification" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])
      :ok = Sessions.set_log_level(@server, session_id, :info)

      assert :ok = Notify.broadcast_log(@server, :warning, %{disk: "92%"}, logger: "system")

      expected = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/message",
        "params" => %{"level" => "warning", "data" => %{"disk" => "92%"}, "logger" => "system"}
      }

      {_, ^expected} = Utils.receive_event(5_000)
    end

    test "omits the logger field when not provided" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])
      :ok = Sessions.set_log_level(@server, session_id, :info)

      assert :ok = Notify.broadcast_log(@server, :info, "hello")

      {_, notification} = Utils.receive_event(5_000)
      refute Map.has_key?(notification["params"], "logger")
    end

    test "delivers to every session whose level accepts the message" do
      accepting = Utils.create_session(@server, initialized: true, streams: [self()])
      :ok = Sessions.set_log_level(@server, accepting, :notice)

      rejecting = Utils.create_session(@server, initialized: true, streams: [self()])
      :ok = Sessions.set_log_level(@server, rejecting, :error)

      assert :ok = Notify.broadcast_log(@server, :warning, "low disk")

      assert_receive {:oz_mcp_stream, _, {:event, _, _}}, 5_000
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    test "returns {:error, :unavailable} when no server is running" do
      assert Notify.broadcast_log(Servers.ToolsOnly, :info, "hello") ==
               {:error, :unavailable}
    end

    test "raises when the level is not one of the RFC-5424 levels" do
      assert_raise FunctionClauseError, fn ->
        Notify.broadcast_log(@server, :verbose, "hello")
      end
    end
  end

  describe "broadcast_log/4 :principal option" do
    test "sends only to the sessions of the principal (a Principal struct)" do
      principal = OzMcp.Auth.Principal.new!(subject: "alice", issuer: "https://issuer")
      alice_stream = start_collector()
      bob_stream = start_collector()

      a =
        Utils.create_session(@server,
          initialized: true,
          streams: [alice_stream],
          principal_key: OzMcp.Auth.Principal.key(principal)
        )

      b =
        Utils.create_session(@server,
          initialized: true,
          streams: [bob_stream],
          principal_key: {"https://issuer", "bob"}
        )

      :ok = Sessions.set_log_level(@server, a, :debug)
      :ok = Sessions.set_log_level(@server, b, :debug)

      assert :ok = Notify.broadcast_log(@server, :info, "hello", principal: principal)

      assert_receive {:collected, ^alice_stream, %{"method" => "notifications/message"}}, 5_000
      refute_receive {:collected, ^bob_stream, _}, 100
    end

    test "sends only to the sessions of the principal (a raw key)" do
      alice_stream = start_collector()
      bob_stream = start_collector()

      a =
        Utils.create_session(@server,
          initialized: true,
          streams: [alice_stream],
          principal_key: {"https://issuer", "alice"}
        )

      b =
        Utils.create_session(@server,
          initialized: true,
          streams: [bob_stream],
          principal_key: {"https://issuer", "bob"}
        )

      :ok = Sessions.set_log_level(@server, a, :debug)
      :ok = Sessions.set_log_level(@server, b, :debug)

      assert :ok =
               Notify.broadcast_log(@server, :info, "hello",
                 principal: {"https://issuer", "alice"}
               )

      assert_receive {:collected, ^alice_stream, %{"method" => "notifications/message"}}, 5_000
      refute_receive {:collected, ^bob_stream, _}, 100
    end

    test "a principal with no issuer matches no session of an open server" do
      stream = start_collector()
      session_id = Utils.create_session(@server, initialized: true, streams: [stream])
      :ok = Sessions.set_log_level(@server, session_id, :debug)

      assert :ok = Notify.broadcast_log(@server, :info, "hello", principal: {nil, "alice"})
      refute_receive {:collected, ^stream, _}, 100
    end

    test "raises for a :principal with a bad shape" do
      assert_raise ArgumentError, fn ->
        Notify.broadcast_log(@server, :info, "x", principal: :all)
      end
    end
  end

  describe "broadcast_log/4 with data that JSON cannot encode" do
    @tag :capture_log
    test "refuses a map with the same key as an atom and as a string" do
      assert {:error, :not_encodable} = Notify.broadcast_log(@server, :info, %{"a" => 1, a: 2})
    end

    @tag :capture_log
    test "refuses the data, sends nothing and returns an error" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])
      :ok = Sessions.set_log_level(@server, session_id, :debug)

      assert {:error, :not_encodable} = Notify.broadcast_log(@server, :info, %{"pid" => self()})
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    @tag :capture_log
    test "refuses a struct, sends nothing and returns an error" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])
      :ok = Sessions.set_log_level(@server, session_id, :debug)

      assert {:error, :not_encodable} =
               Notify.broadcast_log(@server, :info, %{"at" => DateTime.utc_now()})

      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    test "the log text of a refused message holds the path, not the data" do
      log =
        Utils.capture_log(fn ->
          Notify.broadcast_log(@server, :info, %{"secret" => {:token, "abc"}})
        end)

      assert log =~ "not JSON-encodable at data.secret"
      refute log =~ "abc"
    end

    test "sends a good message after a refused one" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])
      :ok = Sessions.set_log_level(@server, session_id, :debug)

      assert {:error, :not_encodable} = Notify.broadcast_log(@server, :info, %{"pid" => self()})
      assert :ok = Notify.broadcast_log(@server, :info, "hello")

      {_, %{"params" => %{"data" => "hello"}}} = Utils.receive_event(5_000)
    end
  end

  describe "log/4 with a server module" do
    test "raises ArgumentError and names broadcast_log/4" do
      error = assert_raise ArgumentError, fn -> Notify.log(@server, :info, "hello") end
      assert error.message =~ "broadcast_log/4"
      assert error.message =~ "Notify.log/4"
    end
  end

  describe "log/4 with the ctx of a task" do
    test "the attached stream gets the message with the related-task _meta" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])
      :ok = Sessions.set_log_level(@server, session_id, :debug)
      task = start_task(@server, session_id)

      stream = attach_stream(@server, Utils.owner(session_id), session_id, task.taskId)

      assert :ok = Notify.log(task_ctx(session_id, task.taskId), :info, "working")

      assert {:event, message} = receive_stream_event(stream)

      assert message["params"] == %{
               "level" => "info",
               "data" => "working",
               "_meta" => %{"io.modelcontextprotocol/related-task" => %{"taskId" => task.taskId}}
             }

      # The attached stream is the only target: the GET stream of the
      # session gets nothing.
      #
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100

      finish_task()
    end

    test "the attached stream gets nothing when the level of its session does not accept the message" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])
      :ok = Sessions.set_log_level(@server, session_id, :error)
      task = start_task(@server, session_id)

      stream = attach_stream(@server, Utils.owner(session_id), session_id, task.taskId)

      assert :ok = Notify.log(task_ctx(session_id, task.taskId), :info, "working")
      refute_receive {:oz_mcp_stream, _, _}, 100

      # A higher level than the one of the session goes through.
      #
      assert :ok = Notify.log(task_ctx(session_id, task.taskId), :emergency, "disk full")

      assert {:event, message} = receive_stream_event(stream)
      assert message["params"]["level"] == "emergency"
      assert message["params"]["data"] == "disk full"

      finish_task()
    end

    test "no stream and a principal owner: each session of the owner applies its own level" do
      key = OzMcp.Auth.Principal.key(@principal)

      loud_stream = start_collector()

      loud =
        Utils.create_session(@server,
          initialized: true,
          streams: [loud_stream],
          principal_key: key
        )

      quiet_stream = start_collector()

      quiet =
        Utils.create_session(@server,
          initialized: true,
          streams: [quiet_stream],
          principal_key: key
        )

      :ok = Sessions.set_log_level(@server, loud, :debug)
      :ok = Sessions.set_log_level(@server, quiet, :error)

      creator = Utils.create_session(@server, initialized: true, principal_key: key)
      task = start_task(@server, creator, principal: @principal)

      assert :ok = Notify.log(task_ctx(creator, task.taskId), :info, "working")

      assert_receive {:collected, ^loud_stream, message}, 5_000
      assert message["params"]["level"] == "info"

      assert message["params"]["_meta"][RelatedTask.key()] == %{"taskId" => task.taskId}

      refute_receive {:collected, ^quiet_stream, _}, 100

      finish_task()
    end

    @tag :capture_log
    test "the stream of another session of the owner gets the log after the end of the creator session" do
      instance = start_instance_following_no_session()
      key = OzMcp.Auth.Principal.key(@principal)

      creator = Utils.create_session(instance, initialized: true, principal_key: key)
      other = Utils.create_session(instance, initialized: true, principal_key: key)
      :ok = Sessions.set_log_level(instance, other, :debug)
      task = start_task(instance, creator, principal: @principal)

      assert :ok = Sessions.terminate(instance, creator)
      Utils.sync_task(instance, task.taskId)

      owner = Tasks.owner_key(%{principal: @principal, session_id: other})
      stream = attach_stream(instance, owner, other, task.taskId)

      ctx = %{
        instance: instance,
        server: @server_module,
        session_id: creator,
        request_id: nil,
        task_id: task.taskId
      }

      assert :ok = Notify.log(ctx, :info, "working")

      assert {:event, %{"params" => %{"data" => "working"}}} = receive_stream_event(stream)

      finish_task()
    end

    test "a task that does not run changes nothing" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])

      ctx = task_ctx(session_id, "no-such-task")

      assert :ok = Notify.log(ctx, :info, "working")
      refute_receive {:oz_mcp_stream, _, _}, 100
    end
  end

  describe "log/4 with a ctx" do
    test "the ctx of a request with no stream sends to the GET stream of its session only" do
      stream = start_collector()
      other_stream = start_collector()
      session_id = Utils.create_session(@server, initialized: true, streams: [stream])
      other = Utils.create_session(@server, initialized: true, streams: [other_stream])
      :ok = Sessions.set_log_level(@server, session_id, :debug)
      :ok = Sessions.set_log_level(@server, other, :debug)

      ctx = %{
        instance: @server,
        server: @server_module,
        session_id: session_id,
        request_id: 7,
        task_id: nil
      }

      assert :ok = Notify.log(ctx, :info, "hello")

      assert_receive {:collected, ^stream, %{"params" => %{"data" => "hello"} = params}}, 5_000
      refute Map.has_key?(params, "_meta")
      refute_receive {:collected, ^other_stream, _}, 100
    end

    test "sends nothing when the session has no level" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])

      ctx = %{
        instance: @server,
        server: @server_module,
        session_id: session_id,
        request_id: nil,
        task_id: nil
      }

      assert :ok = Notify.log(ctx, :emergency, "disk full")
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    test "sends nothing when the session is not initialized" do
      session_id = Utils.create_session(@server, streams: [self()])
      :ok = Sessions.set_log_level(@server, session_id, :debug)

      ctx = %{
        instance: @server,
        server: @server_module,
        session_id: session_id,
        request_id: nil,
        task_id: nil
      }

      assert :ok = Notify.log(ctx, :emergency, "disk full")
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    test "sends nothing for an unknown session" do
      ctx = %{
        instance: @server,
        server: @server_module,
        session_id: "nope",
        request_id: nil,
        task_id: nil
      }

      assert :ok = Notify.log(ctx, :emergency, "disk full")
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    @tag :capture_log
    test "refuses data that JSON cannot encode" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])
      :ok = Sessions.set_log_level(@server, session_id, :debug)

      ctx = %{
        instance: @server,
        server: @server_module,
        session_id: session_id,
        request_id: nil,
        task_id: nil
      }

      assert {:error, :not_encodable} = Notify.log(ctx, :info, %{"pid" => self()})
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    @tag :capture_log
    test "refuses data with a string that is not valid UTF-8 and does not raise" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])
      :ok = Sessions.set_log_level(@server, session_id, :debug)

      ctx = %{
        instance: @server,
        server: @server_module,
        session_id: session_id,
        request_id: nil,
        task_id: nil
      }

      assert {:error, :not_encodable} = Notify.log(ctx, :info, %{"text" => <<0xFF>>})
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    test "accepts an OzMcp.Context struct" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])
      :ok = Sessions.set_log_level(@server, session_id, :debug)

      context = %OzMcp.Context{
        instance: @server,
        server: @server_module,
        session_id: session_id,
        rpc_id: nil
      }

      assert :ok = Notify.log(context, :info, "hello")

      assert {_, %{"method" => "notifications/message"}} = Utils.receive_event(5_000)
    end
  end

  describe "log_session/5" do
    test "sends to the session only" do
      stream = start_collector()
      other_stream = start_collector()
      session_id = Utils.create_session(@server, initialized: true, streams: [stream])
      other = Utils.create_session(@server, initialized: true, streams: [other_stream])
      :ok = Sessions.set_log_level(@server, session_id, :info)
      :ok = Sessions.set_log_level(@server, other, :info)

      assert :ok = Notify.log_session(@server, session_id, :warning, "low disk", logger: "app")

      assert_receive {:collected, ^stream, message}, 5_000
      assert message["params"] == %{"level" => "warning", "data" => "low disk", "logger" => "app"}
      refute_receive {:collected, ^other_stream, _}, 100
    end

    test "the level of the session filters the message" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])
      :ok = Sessions.set_log_level(@server, session_id, :error)

      assert :ok = Notify.log_session(@server, session_id, :info, "hello")
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    test "sends nothing when the session has no level" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])

      assert :ok = Notify.log_session(@server, session_id, :emergency, "disk full")
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    test "sends nothing to a session that is not initialized" do
      session_id = Utils.create_session(@server, streams: [self()])
      :ok = Sessions.set_log_level(@server, session_id, :debug)

      assert :ok = Notify.log_session(@server, session_id, :debug, "hello")
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    test "returns {:error, :no_session} for an unknown session" do
      assert Notify.log_session(@server, "nope", :info, "hello") == {:error, :no_session}
    end

    test "returns {:error, :unavailable} when the server is not running" do
      assert Notify.log_session(Servers.ToolsOnly, "s", :info, "x") ==
               {:error, :unavailable}
    end

    test "raises when the level is not one of the RFC-5424 levels" do
      assert_raise FunctionClauseError, fn ->
        Notify.log_session(@server, "s", :verbose, "hello")
      end
    end

    @tag :capture_log
    test "refuses data that JSON cannot encode" do
      session_id = Utils.create_session(@server, initialized: true)
      assert {:error, :not_encodable} = Notify.log_session(@server, session_id, :info, {:a, 1})
    end
  end

  # The rate of the log notifications: the session drops a log over
  # `max_log_rate` (the default of the schema, 100 messages for each
  # second). The counts below use bounds, not exact numbers: the clock
  # refills the bucket while the loop of the test runs.
  #
  describe "the rate of the log notifications" do
    test "a flood of logs keeps the response last on the stream of the request" do
      parent = self()
      session_id = Utils.create_session(@server, initialized: true)
      :ok = Sessions.set_log_level(@server, session_id, :info)

      {:ok, stream} =
        Utils.begin_sink(@server, session_id, 7, fn message ->
          send(parent, {:sink, message})
        end)

      ctx = %{
        instance: @server,
        server: @server_module,
        session_id: session_id,
        request_id: 7,
        task_id: nil
      }

      for _ <- 1..300, do: :ok = Notify.log(ctx, :info, "hi")
      Utils.sync_server(@server, session_id)

      assert :ok = OzMcp.PostStream.finish(~s({"id":7,"result":{}}), stream)

      messages = collect_sink()
      logs = Enum.count(messages, &(&1["method"] == "notifications/message"))

      assert logs in 1..200
      assert logs < 300

      # The response of the request is the last message the sink got.
      #
      assert [%{"id" => 7, "result" => %{}}] = Enum.take(messages, -1)
    end

    test "a flood of log_session messages on the GET stream is bounded" do
      stream = start_collector()
      session_id = Utils.create_session(@server, initialized: true, streams: [stream])
      :ok = Sessions.set_log_level(@server, session_id, :info)

      for _ <- 1..300, do: :ok = Notify.log_session(@server, session_id, :info, "hi")
      Utils.sync_server(@server, session_id)

      logs = collected_count(stream, "notifications/message")

      assert logs in 1..200
      assert logs < 300
    end

    test "a flood of broadcasts is bounded for each session: one bucket each" do
      stream1 = start_collector()
      stream2 = start_collector()
      s1 = Utils.create_session(@server, initialized: true, streams: [stream1])
      s2 = Utils.create_session(@server, initialized: true, streams: [stream2])
      :ok = Sessions.set_log_level(@server, s1, :info)
      :ok = Sessions.set_log_level(@server, s2, :info)

      for _ <- 1..300, do: :ok = Notify.broadcast_log(@server, :info, "hi")
      Utils.sync_server(@server, s1)
      Utils.sync_server(@server, s2)

      # A flood to every session does not drain one shared bucket: each
      # session keeps its own and both keep receiving messages.
      #
      logs1 = collected_count(stream1, "notifications/message")
      logs2 = collected_count(stream2, "notifications/message")

      assert logs1 in 1..200
      assert logs2 in 1..200
      assert logs1 < 300
      assert logs2 < 300
    end

    test "a flood of logs with the ctx of a task is bounded on the attached stream" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])
      :ok = Sessions.set_log_level(@server, session_id, :debug)
      task = start_task(@server, session_id)

      stream = attach_stream(@server, Utils.owner(session_id), session_id, task.taskId)

      ctx = task_ctx(session_id, task.taskId)

      for _ <- 1..300, do: :ok = Notify.log(ctx, :info, "working")
      Utils.sync_task(@server, task.taskId)
      Utils.sync_server(@server, session_id)

      logs = stream_event_count(stream.stream_id, "notifications/message")

      assert logs in 1..200
      assert logs < 300

      finish_task()
    end

    test "a message that the level refuses uses no token" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])
      :ok = Sessions.set_log_level(@server, session_id, :error)

      ctx = %{
        instance: @server,
        server: @server_module,
        session_id: session_id,
        request_id: nil,
        task_id: nil
      }

      for _ <- 1..1000, do: :ok = Notify.log(ctx, :debug, "noise")

      for _ <- 1..5, do: :ok = Notify.log(ctx, :error, "real")
      Utils.sync_server(@server, session_id)

      for _ <- 1..5, do: {_, %{"params" => %{"data" => "real"}}} = Utils.receive_event()

      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end
  end

  # The messages the sink of a `begin_sink` stream wrote, in order.
  #
  defp collect_sink(acc \\ []) do
    receive do
      {:sink, text} -> collect_sink([JSON.decode!(text) | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  # The number of the messages a collector stream got for one method.
  #
  defp collected_count(pid, method, count \\ 0) do
    receive do
      {:collected, ^pid, %{"method" => ^method}} -> collected_count(pid, method, count + 1)
      {:collected, ^pid, _other} -> collected_count(pid, method, count)
    after
      200 -> count
    end
  end

  # The number of the events of one stream that arrived here for a method.
  #
  defp stream_event_count(stream_id, method, count \\ 0) do
    receive do
      {:oz_mcp_stream, ^stream_id, {:event, _id, data}} ->
        message = data |> IO.iodata_to_binary() |> JSON.decode!()

        if message["method"] == method,
          do: stream_event_count(stream_id, method, count + 1),
          else: stream_event_count(stream_id, method, count)
    after
      200 -> count
    end
  end

  describe "task_status/3" do
    test "sends notifications/tasks/status with the flattened Task params" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])
      task = build_task()

      assert :ok = Notify.task_status(@server, session_id, task)

      expected = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/tasks/status",
        "params" => task |> Task.build() |> Utils.encode_json() |> decode()
      }

      {_, ^expected} = Utils.receive_event(5_000)
    end

    test "delivers to the owning session only" do
      owner = Utils.create_session(@server, initialized: true, streams: [self()])
      Utils.create_session(@server, initialized: true, streams: [self()])

      assert :ok = Notify.task_status(@server, owner, build_task())

      {_, notification} = Utils.receive_event(5_000)
      assert notification["method"] == "notifications/tasks/status"
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    test "delivers to a single stream of the owning session per event" do
      stream1 = start_stream_collector()
      stream2 = start_stream_collector()
      owner = Utils.create_session(@server, initialized: true, streams: [stream1, stream2])

      assert :ok = Notify.task_status(@server, owner, build_task())

      assert_receive {:oz_mcp_event, _event_id, notification, _pid}, 5_000
      assert notification["method"] == "notifications/tasks/status"
      refute_receive {:oz_mcp_event, _, _, _}, 100
    end

    test "returns {:error, :unavailable} when no server is running" do
      assert Notify.task_status(Servers.ToolsOnly, "session", build_task()) ==
               {:error, :unavailable}
    end
  end

  describe "task_progress/7" do
    test "sends notifications/progress with progress, progressToken and the related-task _meta" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])

      assert :ok =
               Notify.task_progress(@server, session_id, "task-1", "tok-42", 1, 10, "step 1")

      expected = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/progress",
        "params" => %{
          "progress" => 1,
          "progressToken" => "tok-42",
          "total" => 10,
          "message" => "step 1",
          "_meta" => %{RelatedTask.key() => %{"taskId" => "task-1"}}
        }
      }

      {_, ^expected} = Utils.receive_event(5_000)
    end

    test "omits total and message when nil" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])

      assert :ok =
               Notify.task_progress(@server, session_id, "task-1", "tok-42", 5, nil, nil)

      {_, notification} = Utils.receive_event(5_000)
      assert notification["method"] == "notifications/progress"

      assert notification["params"] == %{
               "progress" => 5,
               "progressToken" => "tok-42",
               "_meta" => %{RelatedTask.key() => %{"taskId" => "task-1"}}
             }
    end

    test "sends nothing and returns :ok when the progress token is nil" do
      Utils.create_session(@server, initialized: true, streams: [self()])

      assert :ok = Notify.task_progress(@server, "session", "task-1", nil, 5, 10, "step 5")

      # The wait is part of the check: no event of the stream arrives.
      #
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 150
    end

    test "drops a value that does not increase for the same token" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])

      assert :ok = Notify.task_progress(@server, session_id, "task-1", "tok-42", 5, nil, nil)
      assert :ok = Notify.task_progress(@server, session_id, "task-1", "tok-42", 4, nil, nil)

      {_, notification} = Utils.receive_event(5_000)
      assert notification["params"]["progress"] == 5

      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 150
    end

    test "delivers to a single stream of the owning session per event" do
      stream1 = start_stream_collector()
      stream2 = start_stream_collector()
      owner = Utils.create_session(@server, initialized: true, streams: [stream1, stream2])

      assert :ok =
               Notify.task_progress(@server, owner, "task-1", "tok-42", 1, 10, "step 1")

      assert_receive {:oz_mcp_event, _event_id, notification, _pid}, 5_000
      assert notification["method"] == "notifications/progress"
      refute_receive {:oz_mcp_event, _, _, _}, 100
    end

    test "returns {:error, :unavailable} when no server is running" do
      assert Notify.task_progress(
               Servers.ToolsOnly,
               "session",
               "task-1",
               "tok",
               1,
               2,
               nil
             ) == {:error, :unavailable}
    end
  end

  describe "progress/3 (ctx form)" do
    #
    # The callback runs in its own process, as under `Invoke`.
    #
    defp from_callback(fun), do: Elixir.Task.await(Elixir.Task.async(fun), 30_000)

    defp progress_ctx(session_id, request_id, token, task_id \\ nil),
      do: %{
        instance: @server,
        server: @server_module,
        session_id: session_id,
        request_id: request_id,
        progress_token: token,
        task_id: task_id
      }

    test "goes to the stream of the request, not to the GET stream" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])

      {:ok, stream} =
        Utils.begin_stream(@server, session_id, 7, Plug.Test.conn(:post, "/"), & &1)

      ctx = progress_ctx(session_id, 7, "tok-1")
      assert :ok = from_callback(fn -> Notify.progress(ctx, 1, total: 10, message: "step 1") end)

      assert {_event_id,
              %{
                "method" => "notifications/progress",
                "params" => %{
                  "progress" => 1,
                  "progressToken" => "tok-1",
                  "total" => 10,
                  "message" => "step 1"
                }
              }} = Utils.receive_event()

      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 50
      OzMcp.PostStream.close(stream)
    end

    test "omits total and message when not provided" do
      session_id = Utils.create_session(@server, initialized: true)

      {:ok, stream} =
        Utils.begin_stream(@server, session_id, 7, Plug.Test.conn(:post, "/"), & &1)

      assert :ok =
               from_callback(fn -> Notify.progress(progress_ctx(session_id, 7, "tok-1"), 5) end)

      {_event_id, %{"params" => params}} = Utils.receive_event()
      assert params == %{"progress" => 5, "progressToken" => "tok-1"}
      OzMcp.PostStream.close(stream)
    end

    test "drops a value that does not increase" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])

      {:ok, stream} =
        Utils.begin_stream(@server, session_id, 7, Plug.Test.conn(:post, "/"), & &1)

      ctx = progress_ctx(session_id, 7, "tok-1")

      for value <- [1, 3, 2, 3, 4] do
        assert :ok = from_callback(fn -> Notify.progress(ctx, value) end)
      end

      values =
        Enum.map(1..3, fn _ ->
          {_event_id, %{"params" => %{"progress" => value}}} = Utils.receive_event()
          value
        end)

      assert values == [1, 3, 4]
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 50
      OzMcp.PostStream.close(stream)
    end

    test "the ctx of a task sends through the task: the attached stream gets the notification" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])
      task = start_task(@server, session_id, progress_token: "tok-9")

      stream = attach_stream(@server, Utils.owner(session_id), session_id, task.taskId)

      ctx = progress_ctx(session_id, nil, "tok-9", task.taskId)
      assert :ok = Notify.progress(ctx, 1, total: 2, message: "step 1")

      assert {:event, message} = receive_stream_event(stream)

      assert message["params"] == %{
               "progress" => 1,
               "progressToken" => "tok-9",
               "total" => 2,
               "message" => "step 1",
               "_meta" => %{RelatedTask.key() => %{"taskId" => task.taskId}}
             }

      # The attached stream is the only target: the GET stream of the
      # session gets nothing.
      #
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100

      finish_task()
    end

    @tag :capture_log
    test "the ctx of a task refuses a message that JSON cannot encode and sends nothing" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])
      task = start_task(@server, session_id, progress_token: "tok-9")

      attach_stream(@server, Utils.owner(session_id), session_id, task.taskId)

      ctx = progress_ctx(session_id, nil, "tok-9", task.taskId)

      assert {:error, :not_encodable} = Notify.progress(ctx, 2, total: 2, message: self())
      assert {:error, :not_encodable} = Notify.progress(ctx, 2, total: {1, 2}, message: nil)

      refute_receive {:oz_mcp_stream, _, _}, 100

      assert {:ok, %Task{status: :working}} =
               Tasks.get(@server, Utils.owner(session_id), task.taskId)

      finish_task()
    end

    test "carries no related-task _meta when the ctx has no task id" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])

      ctx = progress_ctx(session_id, nil, "tok-1")
      assert :ok = from_callback(fn -> Notify.progress(ctx, 1) end)

      {_, notification} = Utils.receive_event(5_000)
      assert notification["method"] == "notifications/progress"
      refute Map.has_key?(notification["params"], "_meta")
    end

    test "falls back to the GET stream when the request has no stream" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])

      assert :ok = Notify.progress(progress_ctx(session_id, nil, "tok-1"), 1)

      assert {_, %{"method" => "notifications/progress"}} = Utils.receive_event()
    end

    test "sends nothing when the request carried no progress token" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])

      {:ok, stream} =
        Utils.begin_stream(@server, session_id, 7, Plug.Test.conn(:post, "/"), & &1)

      assert :ok = Notify.progress(progress_ctx(session_id, 7, nil), 1)

      refute_receive {:oz_mcp_stream, _, _}, 50
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 50
      OzMcp.PostStream.close(stream)
    end

    test "raises for a ctx with a progress token and no instance" do
      ctx = %{
        server: @server_module,
        session_id: "s",
        request_id: 1,
        progress_token: "t"
      }

      error = assert_raise ArgumentError, fn -> Notify.progress(ctx, 1) end
      assert error.message =~ "takes a ctx with :instance"
    end

    test "raises for a ctx with a nil instance and a progress token" do
      ctx = %{
        instance: nil,
        server: @server_module,
        session_id: "s",
        request_id: 1,
        progress_token: "t"
      }

      error = assert_raise ArgumentError, fn -> Notify.progress(ctx, 1) end
      assert error.message =~ "takes a ctx with :instance"
    end

    test "gives :ok when the token is nil and the instance is missing" do
      ctx = %{
        server: @server_module,
        session_id: "s",
        request_id: 1,
        progress_token: nil
      }

      assert :ok = Notify.progress(ctx, 1)
    end

    test "accepts a context struct" do
      session_id = Utils.create_session(@server, initialized: true)

      {:ok, stream} =
        Utils.begin_stream(@server, session_id, 7, Plug.Test.conn(:post, "/"), & &1)

      context = %OzMcp.Context{
        instance: @server,
        server: @server_module,
        session_id: session_id,
        rpc_id: 7,
        progress_token: "tok-1"
      }

      assert :ok = from_callback(fn -> Notify.progress(context, 3) end)
      assert {_event_id, %{"params" => %{"progress" => 3}}} = Utils.receive_event()
      OzMcp.PostStream.close(stream)
    end
  end

  describe "progress/5" do
    test "sends notifications/progress with progress and progressToken" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])

      assert :ok = Notify.progress(@server, session_id, "tok-42", 1, total: 10, message: "step 1")

      expected = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/progress",
        "params" => %{
          "progress" => 1,
          "progressToken" => "tok-42",
          "total" => 10,
          "message" => "step 1"
        }
      }

      {_, ^expected} = Utils.receive_event(5_000)
    end

    test "omits total and message when not provided" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])

      assert :ok = Notify.progress(@server, session_id, "tok-42", 5)

      {_, notification} = Utils.receive_event(5_000)
      assert notification["method"] == "notifications/progress"
      assert notification["params"] == %{"progress" => 5, "progressToken" => "tok-42"}
    end

    test "carries no related-task _meta" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])

      assert :ok = Notify.progress(@server, session_id, "tok-42", 1)

      {_, notification} = Utils.receive_event(5_000)
      assert notification["method"] == "notifications/progress"
      refute Map.has_key?(notification["params"], "_meta")
    end

    test "sends nothing and returns :ok when the progress token is nil" do
      Utils.create_session(@server, initialized: true, streams: [self()])

      assert :ok = Notify.progress(@server, "session", nil, 5, total: 10, message: "step 5")

      # The wait is part of the check: no event of the stream arrives.
      #
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 150
    end

    test "drops a value that does not increase for the same token" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])

      assert :ok = Notify.progress(@server, session_id, "tok-42", 1)
      assert :ok = Notify.progress(@server, session_id, "tok-42", 2)
      assert :ok = Notify.progress(@server, session_id, "tok-42", 2)
      assert :ok = Notify.progress(@server, session_id, "tok-42", 1)

      {_, first} = Utils.receive_event(5_000)
      {_, second} = Utils.receive_event(5_000)

      assert first["params"]["progress"] == 1
      assert second["params"]["progress"] == 2

      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 150
    end

    test "delivers to a single stream of the owning session per event" do
      stream1 = start_stream_collector()
      stream2 = start_stream_collector()
      owner = Utils.create_session(@server, initialized: true, streams: [stream1, stream2])

      assert :ok = Notify.progress(@server, owner, "tok-42", 1, total: 10, message: "step 1")

      assert_receive {:oz_mcp_event, _event_id, notification, _pid}, 5_000
      assert notification["method"] == "notifications/progress"
      refute_receive {:oz_mcp_event, _, _, _}, 100
    end

    test "delivers to the owning session only" do
      owner = Utils.create_session(@server, initialized: true, streams: [self()])
      Utils.create_session(@server, initialized: true, streams: [self()])

      assert :ok = Notify.progress(@server, owner, "tok-42", 1)

      {_, notification} = Utils.receive_event(5_000)
      assert notification["method"] == "notifications/progress"
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    test "does not deliver to a non-initialized session" do
      session_id = Utils.create_session(@server, streams: [self()])

      assert :ok = Notify.progress(@server, session_id, "tok-42", 1)

      # The wait is part of the check: no event of the stream arrives.
      #
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 150
    end

    test "returns {:error, :unavailable} when no server is running" do
      assert Notify.progress(Servers.ToolsOnly, "session", "tok", 1) ==
               {:error, :unavailable}
    end
  end

  defp decode(data), do: data |> IO.iodata_to_binary() |> :json.decode()

  defp start_stream_collector do
    parent = self()
    spawn_link(fn -> stream_loop(parent) end)
  end

  defp stream_loop(parent) do
    receive do
      {:oz_mcp_stream, _, {:event, event_id, data}} ->
        send(parent, {:oz_mcp_event, event_id, decode(data), self()})
        stream_loop(parent)
    end
  end

  defp start_collector do
    parent = self()
    spawn_link(fn -> collector_loop(parent) end)
  end

  defp collector_loop(parent) do
    receive do
      {:oz_mcp_stream, _, {:event, _event_id, data}} ->
        send(parent, {:collected, self(), decode(data)})
        collector_loop(parent)
    end
  end

  defp build_task do
    %Task{}
    |> Task.task_id("task-123")
    |> Task.status(:working)
    |> Task.status_message("in progress")
    |> Task.created_at("2025-11-25T10:30:00Z")
    |> Task.last_updated_at("2025-11-25T10:30:05Z")
    |> Task.ttl(60_000)
    |> Task.poll_interval(500)
  end

  describe "elicitation_complete/3" do
    test "notifies a client that declared the url mode" do
      session_id =
        Utils.create_session(@server,
          initialized: true,
          streams: [self()],
          client_capabilities: %{"elicitation" => %{"url" => %{}}}
        )

      assert :ok = Notify.elicitation_complete(@server, session_id, "e-1")

      expected = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/elicitation/complete",
        "params" => %{"elicitationId" => "e-1"}
      }

      {_, ^expected} = Utils.receive_event(5_000)
    end

    test "carries the related-task metadata of a task" do
      session_id =
        Utils.create_session(@server,
          initialized: true,
          streams: [self()],
          client_capabilities: %{"elicitation" => %{"url" => %{}}}
        )

      assert :ok = Notify.elicitation_complete(@server, session_id, "e-1", "task-1")

      expected = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/elicitation/complete",
        "params" => %{
          "elicitationId" => "e-1",
          "_meta" => %{"io.modelcontextprotocol/related-task" => %{"taskId" => "task-1"}}
        }
      }

      {_, ^expected} = Utils.receive_event(5_000)
    end

    test "sends nothing to a client without the url mode" do
      for capabilities <- [%{}, %{"elicitation" => %{}}, %{"elicitation" => %{"form" => %{}}}] do
        session_id =
          Utils.create_session(@server,
            initialized: true,
            streams: [self()],
            client_capabilities: capabilities
          )

        assert Notify.elicitation_complete(@server, session_id, "e-1") ==
                 {:error, :capability_not_supported}
      end

      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 50
    end

    test "reports an unknown session" do
      assert Notify.elicitation_complete(@server, "no-session", "e-1") ==
               {:error, :no_session}
    end

    test "only the session of the id is notified" do
      capabilities = %{"elicitation" => %{"url" => %{}}}

      mine =
        Utils.create_session(@server, initialized: true, client_capabilities: capabilities)

      Utils.create_session(@server,
        initialized: true,
        streams: [self()],
        client_capabilities: capabilities
      )

      assert :ok = Notify.elicitation_complete(@server, mine, "e-1")
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 50
    end

    test "a task that runs checks the capabilities of its record and sends to its streams" do
      #
      # The session of the caller declared no url mode: the check must
      # read the capabilities of the task record, not of the session.
      #
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])

      task =
        start_task(@server, session_id, client_capabilities: %{"elicitation" => %{"url" => %{}}})

      stream = attach_stream(@server, Utils.owner(session_id), session_id, task.taskId)

      assert :ok = Notify.elicitation_complete(@server, session_id, "e-1", task.taskId)

      assert {:event, message} = receive_stream_event(stream)
      assert message["method"] == "notifications/elicitation/complete"

      assert message["params"]["_meta"][RelatedTask.key()] == %{"taskId" => task.taskId}

      # The attached stream is the only target: the GET stream of the
      # session gets nothing.
      #
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100

      finish_task()
    end

    @tag :capture_log
    test "a task that runs sends to the owner after the end of the creator session" do
      instance = start_instance_following_no_session()
      key = OzMcp.Auth.Principal.key(@principal)

      creator = Utils.create_session(instance, initialized: true, principal_key: key)
      other = Utils.create_session(instance, initialized: true, principal_key: key)

      task =
        start_task(instance, creator,
          principal: @principal,
          client_capabilities: %{"elicitation" => %{"url" => %{}}}
        )

      assert :ok = Sessions.terminate(instance, creator)
      Utils.sync_task(instance, task.taskId)

      owner = Tasks.owner_key(%{principal: @principal, session_id: other})
      stream = attach_stream(instance, owner, other, task.taskId)

      assert :ok = Notify.elicitation_complete(instance, creator, "e-1", task.taskId)

      assert {:event, message} = receive_stream_event(stream)
      assert message["method"] == "notifications/elicitation/complete"
      assert message["params"]["elicitationId"] == "e-1"

      finish_task()
    end

    test "a task that ended keeps the session of the caller" do
      session_id =
        Utils.create_session(@server,
          initialized: true,
          streams: [self()],
          client_capabilities: %{"elicitation" => %{"url" => %{}}}
        )

      assert %Task{} = task = settled_task(session_id)

      assert :ok = Notify.elicitation_complete(@server, session_id, "e-1", task.taskId)

      expected = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/elicitation/complete",
        "params" => %{
          "elicitationId" => "e-1",
          "_meta" => %{
            RelatedTask.key() => %{"taskId" => task.taskId}
          }
        }
      }

      {_, ^expected} = Utils.receive_event(5_000)
    end

    test "a task that ended checks the capabilities of the session of the caller" do
      for capabilities <- [%{}, %{"elicitation" => %{}}, %{"elicitation" => %{"form" => %{}}}] do
        session_id =
          Utils.create_session(@server,
            initialized: true,
            streams: [self()],
            client_capabilities: capabilities
          )

        assert %Task{} = task = settled_task(session_id)

        assert Notify.elicitation_complete(@server, session_id, "e-1", task.taskId) ==
                 {:error, :capability_not_supported}
      end

      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 50
    end

    test "an instance that does not run reports an unknown session" do
      assert Notify.elicitation_complete(Servers.ToolsOnly, "no-session", "e-1") ==
               {:error, :no_session}
    end
  end

  # ---- The notifications of a task

  # The notifications of a task go through the process of the task. The
  # runner of the task blocks until the test ends it: the process of the
  # task stays alive and it holds the streams that the tests attach.
  #

  # A task that is terminal at its creation: its record stays in the
  # store and no process runs it.
  #
  defp settled_task(session_id) do
    settled = {:completed, "The tool finished.", {:ok, %{"done" => true}}}

    assert {:ok, task} =
             Tasks.create(@server, %{
               session_id: session_id,
               tool: {Support.Entities.Tools.TaskSlowTest, "task_slow"},
               request: %{"name" => "task_slow", "arguments" => %{}},
               ttl: 60_000,
               progress_token: nil,
               settled: settled
             })

    task
  end

  defp start_task(instance, session_id, attrs \\ %{}) do
    Support.Entities.Tools.TaskSlowTest.use_instance(instance)
    Support.Entities.Tools.TaskSlowTest.reset()

    assert {:ok, task} =
             Tasks.create(
               instance,
               Map.merge(
                 %{
                   session_id: session_id,
                   tool: {Support.Entities.Tools.TaskSlowTest, "task_slow"},
                   request: %{"name" => "task_slow", "arguments" => %{}},
                   ttl: nil,
                   progress_token: nil
                 },
                 Map.new(attrs)
               )
             )

    task
  end

  defp finish_task, do: Support.Entities.Tools.TaskSlowTest.finish()

  # The test process plays a `tasks/result` request of the task: it owns a
  # stream and attaches it. What the task sends arrives at the test
  # process as an event of the stream, with the id that the session gave.
  #
  defp attach_stream(instance, owner_key, session_id, task_id) do
    {:ok, capabilities} = Sessions.client_capabilities(instance, session_id)

    {:ok, stream} =
      Utils.begin_stream(instance, session_id, 99, Plug.Test.conn(:post, "/"), & &1)

    {:attached, _task} =
      Tasks.attach(instance, owner_key, task_id, stream.stream_id, %{
        session_id: session_id,
        client_capabilities: capabilities
      })

    stream
  end

  # The next event of the stream of the attached `tasks/result` request.
  # The test process can serve the GET stream of the session too, whose
  # events carry another stream id.
  #
  defp receive_stream_event(stream, timeout \\ 5_000) do
    stream_id = stream.stream_id

    receive do
      {:oz_mcp_stream, ^stream_id, {:event, _event_id, data}} ->
        {:event, data |> IO.iodata_to_binary() |> :json.decode()}
    after
      timeout -> flunk("no event received within #{timeout} ms")
    end
  end

  defp task_ctx(session_id, task_id) do
    %{
      instance: @server,
      server: @server_module,
      session_id: session_id,
      request_id: nil,
      task_id: task_id
    }
  end

  # An instance where the end of a session does not end the tasks of the
  # session.
  #
  defp start_instance_following_no_session do
    name =
      Module.concat(
        @server_module,
        "owner_" <> Integer.to_string(System.unique_integer([:positive]))
      )

    Utils.start_instance(@server_module, name: name, tasks_follow_session: false)
    name
  end
end
