#
# The unit tests of the `GET` stream: the answers of the route and each
# message of the loop. The stream runs on the `Plug` test connection and
# the writes of a dead connection come from the closed-connection test
# adapter. The end-to-end suite drives the same paths over a real
# connection.
#
defmodule OzMcp.Transport.Http.GetStreamTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias OzMcp.Auth.Principal
  alias OzMcp.Sessions
  alias OzMcp.Stream.Timers
  alias OzMcp.Transport.Http.GetStream
  alias Support.Helpers.Utils
  alias Support.Servers

  @server Servers.Default
  @retry_ms 1_000
  @answer_timeout 2_000

  # The instance that serves the server module of this file.
  #
  defp inst, do: Module.concat(@server, __MODULE__)

  setup do
    Utils.start_instance(@server, name: inst())
    %{session_id: Utils.create_session(inst(), initialized: true)}
  end

  describe "the route answers" do
    test "a fresh stream opens with the retry hint and the priming event", %{
      session_id: session_id
    } do
      pid = open_stream(session_id)
      wait_stream(session_id)
      Utils.terminate_stream(inst(), session_id, pid)

      assert_receive {:stream_answer, ^pid, conn}, @answer_timeout

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
      assert get_resp_header(conn, "cache-control") == ["no-cache"]
      assert conn.resp_body =~ ~r/^retry: #{@retry_ms}\n\n/
      #
      # The priming event: the first position of the stream and an empty
      # data field, then the last retry hint of the terminate.
      #
      assert conn.resp_body =~ ~r/id: g\.[0-9a-zA-Z]+:0\ndata: \n\nretry: #{@retry_ms}\n\n\z/
    end

    test "a GET without the SSE media type answers 406", %{session_id: session_id} do
      conn =
        conn(:get, "/")
        |> put_req_header("accept", "application/json")
        |> put_req_header("mcp-session-id", session_id)
        |> put_private(:instance, inst())
        |> GetStream.call()

      assert conn.status == 406
      assert conn.resp_body =~ "client must accept text/event-stream"
    end

    test "a GET that refuses SSE with q=0 before a wildcard answers 406", %{
      session_id: session_id
    } do
      conn =
        conn(:get, "/")
        |> put_req_header("accept", "text/event-stream;q=0, */*")
        |> put_req_header("mcp-session-id", session_id)
        |> put_private(:instance, inst())
        |> GetStream.call()

      assert conn.status == 406
    end

    test "a GET for a session that is gone answers 404" do
      conn = get_call("no-such-session")

      assert conn.status == 404
      assert conn.resp_body =~ "invalid session"
    end

    test "a GET over the stream limit of the session ends the oldest stream" do
      name = test_instance(max_streams_per_session: 1)
      session_id = Utils.create_session(name, initialized: true)

      first = open_stream(session_id, instance: name)
      wait_stream(session_id, name)

      # The second stream ends the first one and takes the slot.
      #
      second = open_stream(session_id, instance: name)

      assert_receive {:stream_answer, ^first, first_conn}, @answer_timeout
      assert first_conn.status == 200
      assert first_conn.resp_body =~ ~r/retry: #{@retry_ms}\n\n\z/

      Utils.terminate_stream(name, session_id, second)

      assert_receive {:stream_answer, ^second, second_conn}, @answer_timeout
      assert second_conn.status == 200
      assert second_conn.resp_body =~ ~r/^retry: #{@retry_ms}\n\n/
    end

    test "a failed write of the response head leaves the stream to the session", %{
      session_id: session_id
    } do
      pid = open_stream(session_id, ok_chunks: 0)
      assert_receive {:stream_answer, ^pid, conn}, @answer_timeout

      # The head was committed before the failed chunk: the answer is the
      # stream response, cut short.
      #
      assert conn.status == 200

      wait_until("the stream to leave the session", fn ->
        match?({:ok, %{stream?: false}}, Sessions.delivery(inst(), session_id))
      end)
    end

    test "a stream closes itself after sse_max_stream_ms and touches the session" do
      name = test_instance(sse_max_stream_ms: 50)
      session_id = Utils.create_session(name, initialized: true)

      pid = open_stream(session_id, instance: name)
      assert_receive {:stream_answer, ^pid, conn}, @answer_timeout

      # The stream opens with the retry hint and the priming event and
      # the poll close ends it with a retry hint: the client connects
      # again with the id of the last event it saw.
      #
      assert conn.resp_body ==
               "retry: #{@retry_ms}\n\n" <>
                 priming_of(conn.resp_body) <>
                 "retry: #{@retry_ms}\n\n"

      # The poll close touched the session: it is still there.
      #
      assert match?({:ok, _}, Sessions.state(name, session_id))
    end

    test "a resume of a POST stream that the session never had gets 204", %{
      session_id: session_id
    } do
      conn = get_call(session_id, last_event_id: "forged-stream:3")

      assert conn.status == 204
      assert conn.resp_body == ""
      assert get_resp_header(conn, "content-type") == []
    end

    test "a resume after sse_resume_window_ms gets 204" do
      name = test_instance(sse_resume_window_ms: 0)
      session_id = Utils.create_session(name, initialized: true)

      :ok = Utils.open_request(name, session_id, 1, self(), {"st", :sse})
      :ok = Sessions.emit(name, session_id, {:request, 1}, "{}")

      assert {:sse, "st:2"} =
               Utils.close_request(name, session_id, 1, "st", {:response, "{}", false})

      # The window is over: the ring of the ended stream is dropped.
      #
      assert Utils.eventually(fn ->
               Utils.events_after(name, session_id, "st", nil) == :gap
             end)

      conn = get_call(session_id, instance: name, last_event_id: "st:0")

      assert conn.status == 204
      assert conn.resp_body == ""
    end
  end

  describe "the messages of the loop" do
    test "an event of the session is written with its id", %{session_id: session_id} do
      send(
        self(),
        {:oz_mcp_stream, nil, {:event, "e1", ~s({"jsonrpc":"2.0","method":"notifications/ping"})}}
      )

      send(self(), {:oz_mcp_stream, nil, :terminate})

      conn = GetStream.loop(loop_stream(session_id))

      assert conn.resp_body =~ "id: e1\nevent: message\ndata: "
      assert conn.resp_body =~ ~s("notifications/ping")
      #
      # The terminate writes the last retry hint after the event.
      #
      assert conn.resp_body =~ ~r/retry: #{@retry_ms}\n\n\z/
    end

    test "a GET stream of the session drops the messages of a POST stream", %{
      session_id: session_id
    } do
      #
      # An event of a POST stream never goes to a GET stream of the
      # session: the client gets it by resuming the stream.
      #
      send(self(), {:oz_mcp_stream, "stream999", {:event, "stream999:1", "{}"}})
      send(self(), {:oz_mcp_stream, "stream999", :terminate})
      send(self(), {:oz_mcp_stream, "stream999", :end})

      # The loop is not ended: the next event of the session is written.
      #
      send(self(), {:oz_mcp_stream, nil, {:event, "e1", "{}"}})
      send(self(), {:oz_mcp_stream, nil, :terminate})

      conn = GetStream.loop(loop_stream(session_id))

      assert conn.resp_body =~ "id: e1\nevent: message\ndata: {}"
      assert conn.resp_body =~ ~r/retry: #{@retry_ms}\n\n\z/
    end

    test "a failed event write leaves the stream to the session", %{session_id: session_id} do
      send(self(), {:oz_mcp_stream, nil, {:event, "e1", "{}"}})

      conn = GetStream.loop(loop_stream(session_id, conn: closed_conn(0)))

      assert conn.resp_body == ""

      wait_until("the stream to leave the session", fn ->
        match?({:ok, %{stream?: false}}, Sessions.delivery(inst(), session_id))
      end)
    end

    test "the terminate of the session ends the stream with a retry hint", %{
      session_id: session_id
    } do
      send(self(), {:oz_mcp_stream, nil, :terminate})

      conn = GetStream.loop(loop_stream(session_id))

      assert conn.resp_body == "retry: #{@retry_ms}\n\n"
    end

    test "the end of a resumed stream closes with no retry field", %{session_id: session_id} do
      send(self(), {:oz_mcp_stream, "abcdef1234", :end})

      conn =
        GetStream.loop(loop_stream(session_id, mode: :resume, stream_id: "abcdef1234"))

      # Nothing to resume: the client must not connect again.
      #
      assert conn.resp_body == ""
    end

    test "a message of another stream is dropped", %{session_id: session_id} do
      #
      # The events of the session carry no stream id: a resumed POST stream
      # gets none of them and none of the messages of another POST stream.
      #
      send(self(), {:oz_mcp_stream, nil, {:event, "e0", "{}"}})
      send(self(), {:oz_mcp_stream, "other999", {:event, "e1", "{}"}})
      send(self(), {:oz_mcp_stream, "other999", :terminate})
      send(self(), {:oz_mcp_stream, "other999", :end})

      # A dropped message does not end the loop: the next message of this
      # stream is still written.
      #
      send(self(), {:oz_mcp_stream, "abcdef1234", {:event, "e2", "{}"}})
      send(self(), {:oz_mcp_stream, "abcdef1234", :terminate})

      conn =
        GetStream.loop(loop_stream(session_id, mode: :resume, stream_id: "abcdef1234"))

      assert conn.resp_body =~ "id: e2\nevent: message\ndata: {}"
      #
      # The end of this stream, not the one of the other stream.
      #
      assert conn.resp_body =~ ~r/retry: #{@retry_ms}\n\n\z/
    end

    test "the poll close touches the session and closes with a retry hint", %{
      session_id: session_id
    } do
      handle = Timers.arm_poll(60_000)
      send(self(), {:sse_poll_close, Timers.token(handle)})

      conn = GetStream.loop(loop_stream(session_id, poll_timer: handle))

      assert conn.resp_body == "retry: #{@retry_ms}\n\n"
      assert match?({:ok, _}, Sessions.state(inst(), session_id))
    end

    test "the stop of the Server closes the stream with a retry hint", %{session_id: session_id} do
      victim =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      server_ref = Process.monitor(victim)
      Process.exit(victim, :kill)

      conn = GetStream.loop(loop_stream(session_id, server_ref: server_ref))

      assert conn.resp_body == "retry: #{@retry_ms}\n\n"
    end

    test "an expired principal ends the stream", %{session_id: session_id} do
      principal = Principal.new!(subject: "alice", expires_at: System.system_time(:second) - 10)
      token = make_ref()
      send(self(), {:principal_expired, token})

      conn =
        GetStream.loop(
          loop_stream(session_id, principal: principal, expiry_timer: {token, make_ref()})
        )

      assert conn.resp_body == "retry: #{@retry_ms}\n\n"
    end

    test "a principal that is not expired yet keeps the stream open", %{session_id: session_id} do
      principal =
        Principal.new!(subject: "alice", expires_at: System.system_time(:second) + 3_600)

      # The expiry message arrives too early: the loop waits for the rest.
      #
      token = make_ref()
      send(self(), {:principal_expired, token})
      send(self(), {:oz_mcp_stream, nil, {:event, "e1", "{}"}})
      send(self(), {:oz_mcp_stream, nil, :terminate})

      conn =
        GetStream.loop(
          loop_stream(session_id, principal: principal, expiry_timer: {token, make_ref()})
        )

      assert conn.resp_body =~ ~r/^id: e1\nevent: message\ndata: {}\n\n/
    end

    test "a stray expiry message of a stream with no principal is ignored", %{
      session_id: session_id
    } do
      send(self(), {:principal_expired, make_ref()})
      send(self(), {:oz_mcp_stream, nil, {:event, "e1", "{}"}})
      send(self(), {:oz_mcp_stream, nil, :terminate})

      conn = GetStream.loop(loop_stream(session_id))

      assert conn.resp_body =~ ~r/^id: e1\nevent: message\ndata: {}\n\n/
    end
  end

  describe "the heartbeat" do
    test "an idle stream is kept alive with a heartbeat comment", %{session_id: session_id} do
      parent = self()

      child =
        spawn(fn ->
          answer = GetStream.loop(loop_stream(session_id, heartbeat_ms: 10))
          send(parent, {:stream_answer, self(), answer})
        end)

      # The wait is 50 times the interval: one heartbeat is enough, so a
      # loaded machine does not make the stream end with none.
      #
      Process.sleep(500)
      send(child, {:oz_mcp_stream, nil, :terminate})

      assert_receive {:stream_answer, ^child, conn}, @answer_timeout
      assert conn.resp_body =~ ": heartbeat\n\n"
    end

    test "a failed heartbeat write leaves the stream to the session", %{session_id: session_id} do
      parent = self()

      child =
        spawn(fn ->
          answer =
            GetStream.loop(loop_stream(session_id, conn: closed_conn(0), heartbeat_ms: 20))

          send(parent, {:stream_answer, self(), answer})
        end)

      assert_receive {:stream_answer, ^child, conn}, @answer_timeout
      assert conn.resp_body == ""

      wait_until("the stream to leave the session", fn ->
        match?({:ok, %{stream?: false}}, Sessions.delivery(inst(), session_id))
      end)
    end
  end

  # Runs the route in a process of its own: the stream loop blocks that
  # process until the stream ends and the conn of the answer comes back
  # to the test as `{:stream_answer, pid, conn}`.
  #
  defp open_stream(session_id, opts \\ []) do
    parent = self()

    spawn(fn ->
      conn =
        conn(:get, "/")
        |> put_req_header("accept", "text/event-stream")
        |> put_req_header("mcp-session-id", session_id)
        |> put_last_event_id(Keyword.get(opts, :last_event_id))
        |> wrap_closed_adapter(Keyword.get(opts, :ok_chunks))
        |> put_private(:instance, Keyword.get(opts, :instance, inst()))

      send(parent, {:stream_answer, self(), GetStream.call(conn)})
    end)
  end

  # A call that answers at once (a refusal): the route runs in the test
  # process.
  #
  defp get_call(session_id, opts \\ []) do
    conn(:get, "/")
    |> put_req_header("accept", "text/event-stream")
    |> put_req_header("mcp-session-id", session_id)
    |> put_last_event_id(Keyword.get(opts, :last_event_id))
    |> put_private(:instance, Keyword.get(opts, :instance, inst()))
    |> GetStream.call()
  end

  defp put_last_event_id(conn, nil), do: conn
  defp put_last_event_id(conn, id), do: put_req_header(conn, "last-event-id", id)

  defp wrap_closed_adapter(conn, nil), do: conn

  defp wrap_closed_adapter(conn, ok_chunks),
    do: Support.Helpers.AdapterClosed.wrap(conn, ok_chunks)

  # The instance of a test that needs server opts of its own.
  #
  defp test_instance(opts) do
    name = Module.concat(@server, :"T#{System.unique_integer([:positive])}")
    Utils.start_instance(@server, Keyword.merge([name: name, allowed_origins: []], opts))

    name
  end

  # The state of the loop for one message: the loop runs in the process of
  # the test, on a connection the test adapter of `Plug` chunks into
  # `resp_body`.
  #
  defp loop_stream(session_id, opts \\ []) do
    %GetStream{
      conn: Keyword.get_lazy(opts, :conn, &chunked_conn/0),
      instance: Keyword.get(opts, :instance, inst()),
      session_id: session_id,
      stream_id: Keyword.get(opts, :stream_id),
      mode: Keyword.get(opts, :mode, :get),
      heartbeat_ms: Keyword.get(opts, :heartbeat_ms, 5_000),
      retry_ms: @retry_ms,
      max_stream_ms: Keyword.get(opts, :max_stream_ms),
      server_ref: Keyword.get(opts, :server_ref),
      principal: Keyword.get(opts, :principal),
      poll_timer: Keyword.get(opts, :poll_timer),
      expiry_timer: Keyword.get(opts, :expiry_timer)
    }
  end

  defp chunked_conn do
    conn(:get, "/")
    |> put_resp_header("content-type", "text/event-stream")
    |> send_chunked(200)
  end

  # A connection whose first `ok_chunks` writes go through, then fail.
  #
  defp closed_conn(ok_chunks), do: Support.Helpers.AdapterClosed.wrap(chunked_conn(), ok_chunks)

  defp wait_stream(session_id, instance \\ inst()) do
    wait_until("the stream of the session", fn ->
      match?({:ok, %{stream?: true}}, Sessions.delivery(instance, session_id))
    end)
  end

  defp wait_until(what, fun, tries \\ 1_500) do
    if Utils.eventually(fun, tries * 10) do
      :ok
    else
      flunk(what <> " was not met in time")
    end
  end

  # The priming event of a stream body: the chunk between the first retry
  # hint and the last one.
  #
  defp priming_of(body) do
    case Regex.run(~r/id: g\.[0-9a-zA-Z]+:0\ndata: \n\n/, body) do
      [priming] -> priming
      _ -> flunk("no priming event in the stream body: #{inspect(body)}")
    end
  end
end
