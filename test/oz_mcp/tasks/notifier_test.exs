defmodule OzMcp.Tasks.NotifierTest do
  use ExUnit.Case, async: true

  alias OzMcp.PubSub
  alias OzMcp.Sessions
  alias OzMcp.Tasks.Notifier
  alias Support.Helpers.Utils
  alias Support.Servers

  @server Module.concat(Servers.Default, __MODULE__)
  @key {"https://test.example", "alice"}

  setup do
    Utils.start_instance(Servers.Default, name: @server)
    :ok
  end

  test "the attached streams get the message with the id the session gives, the topic gets nothing" do
    :ok = PubSub.Registry.subscribe(@server, {:principal, @key})

    session_id = Utils.create_session(@server, initialized: true, principal_key: @key)
    streams = [stream("stream-1", session_id)]
    :ok = Notifier.deliver(@server, record({:principal, @key}), streams, status("task-1"))

    assert {"stream-1:1",
            %{"method" => "notifications/tasks/status", "params" => %{"taskId" => "task-1"}}} =
             stream_event("stream-1")

    refute_receive {:oz_mcp_broadcast, _}, 100
  end

  test "a stream with no id counts as no stream" do
    :ok = PubSub.Registry.subscribe(@server, {:principal, @key})

    streams = [stream(nil)]
    :ok = Notifier.deliver(@server, record({:principal, @key}), streams, status("task-1"))

    assert {:session_event, nil, json} = broadcast()
    assert %{"method" => "notifications/tasks/status"} = JSON.decode!(json)
  end

  test "a stream with no session gets no event and counts as no stream" do
    :ok = PubSub.Registry.subscribe(@server, {:principal, @key})

    streams = [stream("stream-1")]
    :ok = Notifier.deliver(@server, record({:principal, @key}), streams, status("task-1"))

    assert {:session_event, nil, json} = broadcast()
    assert %{"method" => "notifications/tasks/status"} = JSON.decode!(json)
    refute_receive {:oz_mcp_stream, "stream-1", _}, 100
  end

  test "no stream and a principal owner: the topic of the principal gets the message" do
    :ok = PubSub.Registry.subscribe(@server, {:principal, @key})

    :ok = Notifier.deliver(@server, record({:principal, @key}), [], status("task-1"))

    assert {:session_event, nil, json} = broadcast()

    assert %{"method" => "notifications/tasks/status", "params" => %{"taskId" => "task-1"}} =
             JSON.decode!(json)
  end

  test "no stream and no principal: the session of the task gets the message" do
    session_id = Utils.create_session(@server, initialized: true, streams: [self()])
    record = record({:session, session_id})

    :ok = Notifier.deliver(@server, record, [], status("task-1"))

    assert {_id, %{"method" => "notifications/tasks/status"}} = Utils.receive_event(5_000)
  end

  test "a log on the topic follows the level of each session" do
    :ok = PubSub.Registry.subscribe(@server, {:principal, @key})

    quiet =
      Utils.create_session(@server, initialized: true, streams: [self()], principal_key: @key)

    :ok = Sessions.set_log_level(@server, quiet, :warning)

    :ok =
      Notifier.deliver(@server, record({:principal, @key}), [], status("task-1"), {:log, :info})

    refute_receive {:oz_mcp_stream, _, _}, 100
    assert {:session_event, {:log, :info}, _json} = broadcast()

    :ok = Sessions.set_log_level(@server, quiet, :debug)

    :ok =
      Notifier.deliver(@server, record({:principal, @key}), [], status("task-1"), {:log, :info})

    assert {_id, %{"method" => "notifications/tasks/status"}} = Utils.receive_event(5_000)
  end

  test "a log for the session of the task follows the level of that session" do
    session_id = Utils.create_session(@server, initialized: true, streams: [self()])
    record = record({:session, session_id})

    :ok = Notifier.deliver(@server, record, [], status("task-1"), {:log, :info})
    refute_receive {:oz_mcp_stream, _, _}, 100

    :ok = Sessions.set_log_level(@server, session_id, :debug)
    :ok = Notifier.deliver(@server, record, [], status("task-1"), {:log, :info})

    assert {_id, %{"method" => "notifications/tasks/status"}} = Utils.receive_event(5_000)
  end

  test "an uninitialized session gets no message from the topic" do
    Utils.create_session(@server, streams: [self()], principal_key: @key)
    :ok = PubSub.Registry.subscribe(@server, {:principal, @key})

    :ok = Notifier.deliver(@server, record({:principal, @key}), [], status("task-1"))

    assert {:session_event, nil, _json} = broadcast()
    refute_receive {:oz_mcp_stream, _, _}, 100
  end

  test "a log goes only to the streams whose session level accepts it" do
    :ok = PubSub.Registry.subscribe(@server, {:principal, @key})

    loud = Utils.create_session(@server, initialized: true, principal_key: @key)
    :ok = Sessions.set_log_level(@server, loud, :debug)

    quiet = Utils.create_session(@server, initialized: true, principal_key: @key)
    :ok = Sessions.set_log_level(@server, quiet, :error)

    streams = [stream("loud", loud), stream("quiet", quiet)]

    :ok =
      Notifier.deliver(
        @server,
        record({:principal, @key}),
        streams,
        status("task-1"),
        {:log, :info}
      )

    assert {event_id, _json} = stream_event("loud")
    assert String.starts_with?(event_id, "loud:")
    refute_receive {:oz_mcp_stream, "quiet", _}, 100
    refute_receive {:oz_mcp_broadcast, _}, 100
  end

  test "a stream of a session with no level gets no log and gets a status" do
    :ok = PubSub.Registry.subscribe(@server, {:principal, @key})

    session_id = Utils.create_session(@server, initialized: true, principal_key: @key)
    streams = [stream("stream-1", session_id)]

    :ok =
      Notifier.deliver(
        @server,
        record({:principal, @key}),
        streams,
        status("task-1"),
        {:log, :info}
      )

    refute_receive {:oz_mcp_stream, "stream-1", _}, 100
    refute_receive {:oz_mcp_broadcast, _}, 100

    :ok = Notifier.deliver(@server, record({:principal, @key}), streams, status("task-1"))

    assert {"stream-1:1", %{"method" => "notifications/tasks/status"}} = stream_event("stream-1")
    refute_receive {:oz_mcp_broadcast, _}, 100
  end

  defp record(owner_key), do: %{owner_key: owner_key}

  # A stream of a `tasks/result` request that the test process owns. A
  # stream with a session is registered in it (the entry that the owner of
  # a stream makes): the session sends the events of the stream through
  # it. A stream with no session has no entry and no session can send it
  # an event.
  #
  defp stream(stream_id, session_id \\ nil)

  defp stream(_stream_id, nil) do
    %{pid: self(), stream_id: nil, ref: make_ref(), session_id: nil, capabilities: %{}}
  end

  defp stream(stream_id, session_id) do
    request_id = "req-" <> stream_id
    :ok = Utils.open_request(@server, session_id, request_id, self(), {stream_id, :sse})

    %{
      pid: self(),
      stream_id: stream_id,
      ref: make_ref(),
      session_id: session_id,
      capabilities: %{}
    }
  end

  defp status(task_id) do
    OzMcp.Utils.JsonRpc.notification("notifications/tasks/status", %{
      "taskId" => task_id,
      "status" => "working"
    })
  end

  defp stream_event(stream_id) do
    receive do
      {:oz_mcp_stream, ^stream_id, {:event, event_id, json}} ->
        {event_id, json |> IO.iodata_to_binary() |> JSON.decode!()}
    after
      5_000 -> flunk("no event received for #{stream_id}")
    end
  end

  defp broadcast do
    receive do
      {:oz_mcp_broadcast, event} -> event
    after
      5_000 -> flunk("no broadcast received")
    end
  end
end
