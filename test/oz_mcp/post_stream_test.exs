defmodule OzMcp.PostStreamTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias OzMcp.{PostStream, Session, Sessions}
  alias Support.Helpers.SessionProbe
  alias Support.Helpers.Utils
  alias Support.Servers

  @server_module Servers.Default

  @server Module.concat(@server_module, __MODULE__)
  setup do
    Utils.start_instance(@server_module, name: @server)
    Process.put(:session_id, Utils.create_session(@server, initialized: true))

    %{conn: conn(:post, "/")}
  end

  defp sid, do: Process.get(:session_id)

  defp event_id(event), do: Regex.run(~r/^id: (\S+)/m, event, capture: :all_but_first) |> hd()

  defp wait_for_events(session_id, count, tries \\ 1_500) do
    unless Utils.eventually(
             fn ->
               case SessionProbe.events_after(@server, session_id, "none") do
                 {:ok, events} -> length(events) >= count
                 _error -> false
               end
             end,
             tries * 10
           ) do
      {:ok, events} = SessionProbe.events_after(@server, session_id, "none")
      flunk("expected #{count} logged events, got: #{inspect(events)}")
    end

    {:ok, elem(SessionProbe.events_after(@server, session_id, "none"), 1)}
  end

  defp decode(data), do: data |> IO.iodata_to_binary() |> :json.decode()

  defp prepare(conn), do: put_resp_header(conn, "x-prepared", "yes")

  # The JSON messages carried by the events of an SSE body.
  #
  defp events(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn event ->
      #
      # The priming event has an id and no data: it carries no message.
      #
      case Regex.run(~r/^data: (.+)$/m, event, capture: :all_but_first) do
        [data] ->
          assert event =~ "event: message\n"
          [:json.decode(data)]

        nil ->
          []
      end
    end)
  end

  # The session numbers the message and sends it to the owner of the
  # stream of the request. A stream with no registration has no session:
  # the message goes to the owner as it is.
  #
  defp queue(stream, message) do
    if is_nil(stream.registration) do
      send(
        self(),
        {:oz_mcp_stream, stream.stream_id, {:event, nil, Utils.encode_json(message)}}
      )
    else
      :ok = Sessions.emit(@server, stream.session_id, {:request, stream.request_id}, message)
    end

    stream
  end

  defp relay(stream, message) do
    stream = queue(stream, message)
    payload = Utils.receive_stream_message(stream.stream_id)
    PostStream.relay(stream, payload)
  end

  defp taken_over(stream),
    do: PostStream.relay(stream, {:oz_mcp_stream, stream.stream_id, :taken_over})

  describe "parse_event_id/1" do
    test "a POST stream id gives the stream and the sequence" do
      assert PostStream.parse_event_id("abc123:0") == {"abc123", 0}
      assert PostStream.parse_event_id("abc123:17") == {"abc123", 17}
    end

    test "an id with no colon is invalid" do
      assert PostStream.parse_event_id("nW8mKqA2xT9uZb1") == :invalid
    end

    test "any other text is invalid" do
      assert PostStream.parse_event_id(":3") == :invalid
      assert PostStream.parse_event_id("s:") == :invalid
      assert PostStream.parse_event_id("s:abc") == :invalid
      assert PostStream.parse_event_id("s:1x") == :invalid
      assert PostStream.parse_event_id("s:-1") == :invalid
      assert PostStream.parse_event_id(nil) == :invalid
      assert PostStream.parse_event_id(42) == :invalid
    end
  end

  describe "a connection that is gone" do
    setup do
      %{session_id: Utils.create_session(@server, initialized: true, streams: [self()])}
    end

    test "the events are logged under the ids of the stream, the request is not stopped",
         %{session_id: session_id, conn: conn} do
      #
      # the priming event is written, the next chunk fails
      #
      {:ok, stream} =
        Utils.begin_stream(
          @server,
          session_id,
          7,
          Support.Helpers.AdapterClosed.wrap(conn, 1),
          &prepare/1
        )

      stream = relay(stream, %{"method" => "ping"})
      stream = relay(stream, %{"method" => "again"})

      assert {{:streamed, _conn}, _stream} = PostStream.answer(%{"id" => 7}, stream)

      assert {:ok, [{first, ping}, {second, again}, {third, response}]} =
               wait_for_events(session_id, 3)

      assert [stream_id, "1"] = String.split(first, ":")
      assert stream_id == stream.stream_id
      assert second == "#{stream_id}:2"
      assert third == "#{stream_id}:3"
      assert :json.decode(ping) == %{"method" => "ping"}
      assert :json.decode(again) == %{"method" => "again"}
      assert :json.decode(response) == %{"id" => 7}
    end

    test "a connection that is gone at the priming event fails the same way",
         %{session_id: session_id, conn: conn} do
      {:ok, stream} =
        Utils.begin_stream(
          @server,
          session_id,
          7,
          Support.Helpers.AdapterClosed.wrap(conn, 0),
          &prepare/1
        )

      relay(stream, %{"method" => "ping"})

      assert {:ok, [{id, encoded}]} = wait_for_events(session_id, 1)
      assert [_stream_id, "1"] = String.split(id, ":")
      assert :json.decode(encoded) == %{"method" => "ping"}
    end

    test "events written before the connection was lost are not logged twice",
         %{session_id: session_id, conn: conn} do
      {:ok, stream} =
        Utils.begin_stream(
          @server,
          session_id,
          7,
          Support.Helpers.AdapterClosed.wrap(conn, 2),
          &prepare/1
        )

      relay(stream, %{"method" => "written"})
      relay(stream, %{"method" => "lost"})

      assert {:ok, [{_, written}, {_, lost}]} = wait_for_events(session_id, 2)
      assert :json.decode(written) == %{"method" => "written"}
      assert :json.decode(lost) == %{"method" => "lost"}
    end
  end

  describe "the stream and the session" do
    test "a stream that never starts (a plain JSON response) is unknown to the session",
         %{conn: conn} do
      session_id = Utils.create_session(@server, initialized: true)

      {:ok, stream} = Utils.begin_stream(@server, session_id, 7, conn, &prepare/1)
      assert {:not_streamed, _stream} = PostStream.answer(%{"id" => 7}, stream)

      # The sync makes the session empty its mailbox first: a begin_stream
      # cast that was sent would have been processed by now.
      #
      Session.end_request(@server, session_id, 7)
      Utils.sync_server(@server, session_id)

      assert %{streams: streams, refs: refs} = Utils.session_data(@server, session_id)
      assert streams == %{}
      assert refs == %{}
    end

    test "a started stream is known to the session, with the owner and the request id",
         %{conn: conn} do
      session_id = Utils.create_session(@server, initialized: true)
      owner = self()

      {:ok, stream} = Utils.begin_stream(@server, session_id, 7, conn, &prepare/1)
      stream = relay(stream, %{"method" => "ping"})
      Utils.sync_server(@server, session_id)

      assert [{stream_id, %{owner: ^owner, request_id: 7, seq: 1}}] =
               Map.to_list(Utils.session_data(@server, session_id).streams)

      assert stream_id == stream.stream_id

      assert {{:streamed, _conn}, _stream} = PostStream.answer(%{"id" => 7}, stream)
      Session.end_request(@server, session_id, 7)
      Utils.sync_server(@server, session_id)

      # The final event dropped the entry.
      #
      assert %{streams: streams, refs: refs} = Utils.session_data(@server, session_id)
      assert streams == %{}
      assert refs == %{}
    end

    test "an event that the session sends to the owner is written with the id of the session",
         %{conn: conn} do
      session_id = Utils.create_session(@server, initialized: true)

      {:ok, stream} = Utils.begin_stream(@server, session_id, 7, conn, &prepare/1)
      stream = relay(stream, %{"method" => "ping"})
      Utils.sync_server(@server, session_id)

      :ok = Sessions.emit(@server, session_id, {:request, 7}, %{"method" => "progress"})
      assert_receive {:oz_mcp_stream, stream_id, {:event, event_id, data}} = message
      assert stream_id == stream.stream_id
      assert event_id == stream_id <> ":2"

      stream = PostStream.relay(stream, message)
      assert :json.decode(IO.iodata_to_binary(data)) == %{"method" => "progress"}

      assert {{:streamed, conn}, _stream} = PostStream.answer(%{"id" => 7}, stream)

      assert events(conn.resp_body) == [
               %{"method" => "ping"},
               %{"method" => "progress"},
               %{"id" => 7}
             ]

      assert {:ok, [_, {^event_id, _}, _]} = wait_for_events(session_id, 3)
    end
  end

  describe "a stream that a resuming GET takes over" do
    test "relay of the takeover stops the writes, the later events go to the session", %{
      conn: conn
    } do
      session_id = Utils.create_session(@server, initialized: true)

      {:ok, stream} = Utils.begin_stream(@server, session_id, 7, conn, &prepare/1)
      stream = relay(stream, %{"method" => "ping"})

      stream = taken_over(stream)
      relay(stream, %{"method" => "again"})

      response = %{"jsonrpc" => "2.0", "id" => 7, "result" => %{}}
      assert {{:streamed, conn}, _stream} = PostStream.answer(response, stream)

      # The body holds the priming event and the first event only.
      #
      assert events(conn.resp_body) == [%{"method" => "ping"}]

      # The later events reached the session (its event log holds them).
      #
      assert {:ok, [_, {_, again}, {_, last}]} = wait_for_events(session_id, 3)
      assert :json.decode(again) == %{"method" => "again"}
      assert :json.decode(last) == response

      # The final event dropped the entry of the stream.
      #
      Utils.sync_server(@server, session_id)
      assert Utils.session_data(@server, session_id).streams == %{}
    end

    test "the takeover of a sink changes nothing" do
      parent = self()

      {:ok, stream} =
        Utils.begin_sink(@server, sid(), 7, fn message ->
          send(parent, {:sink, decode(message)})
        end)

      stream = taken_over(stream)
      refute stream.failed
      refute_receive {:sink, _}, 100
    end

    test "the takeover of another stream does not change this one", %{conn: conn} do
      {:ok, stream} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)

      stream =
        PostStream.relay(stream, {:oz_mcp_stream, "another-stream", :taken_over})

      refute stream.failed

      # The stream still writes: the message was not for it.
      #
      stream = relay(stream, %{"method" => "ping"})
      assert {{:streamed, conn}, _stream} = PostStream.answer(%{"id" => 7}, stream)
      assert events(conn.resp_body) == [%{"method" => "ping"}, %{"id" => 7}]
    end

    test "a message of another stream is dropped", %{conn: conn} do
      {:ok, stream} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)

      stream =
        PostStream.relay(
          stream,
          {:oz_mcp_stream, "another-stream", {:event, "another-stream:1", ~s({"method":"old"})}}
        )

      refute stream.started

      # The stream still writes: the message was not for it.
      #
      stream = relay(stream, %{"method" => "ping"})
      assert {{:streamed, conn}, _stream} = PostStream.answer(%{"id" => 7}, stream)
      assert events(conn.resp_body) == [%{"method" => "ping"}, %{"id" => 7}]
    end
  end

  describe "stream_method?/1" do
    test "is true for the methods that run a callback" do
      for method <- ~w(tools/call resources/read prompts/get completion/complete tasks/result) do
        assert PostStream.stream_method?(method), method
      end
    end

    test "is false for everything else" do
      for method <-
            [
              "ping",
              "initialize",
              "tools/list",
              "resources/list",
              "prompts/list",
              "tasks/get",
              "tasks/list",
              "tasks/cancel",
              "logging/setLevel",
              "notifications/cancelled",
              nil,
              5
            ] do
        refute PostStream.stream_method?(method), inspect(method)
      end
    end
  end

  describe "owner/3" do
    test "is the process that began the stream of the request, with the stream id", %{conn: conn} do
      {:ok, stream} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)

      assert PostStream.owner(@server, sid(), 7) == {:ok, {self(), stream.stream_id}}
    end

    test "tells the request id apart by type, session and server", %{conn: conn} do
      Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)

      assert PostStream.owner(@server, sid(), "7") == :none
      assert PostStream.owner(@server, "s2", 7) == :none
      assert PostStream.owner(Servers.ToolsOnly, sid(), 7) == :none
    end

    test "is none after close/1", %{conn: conn} do
      {:ok, stream} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)
      PostStream.close(stream)

      assert PostStream.owner(@server, sid(), 7) == :none
    end

    test "is none after answer/2", %{conn: conn} do
      {:ok, stream} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)
      assert {:not_streamed, _stream} = PostStream.answer(%{"id" => 7}, stream)

      assert PostStream.owner(@server, sid(), 7) == :none
    end

    test "is none when the owner process ends", %{conn: conn} do
      parent = self()
      session_id = sid()

      {pid, ref} =
        spawn_monitor(fn ->
          Utils.begin_stream(@server, session_id, 7, conn, &prepare/1)
          send(parent, :began)
          Process.sleep(:infinity)
        end)

      assert_receive :began
      assert {:ok, {^pid, _stream_id}} = PostStream.owner(@server, sid(), 7)

      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      wait_until(fn -> PostStream.owner(@server, sid(), 7) == :none end)
    end

    test "has no stream for a request without a usable id or session", %{conn: conn} do
      for {session_id, request_id} <- [{sid(), nil}, {nil, 7}, {sid(), 1.5}] do
        Utils.begin_stream(@server, session_id, request_id, conn, &prepare/1)

        assert PostStream.owner(@server, session_id, request_id) == :none
      end
    end

    test "does not fail when the runtime is not running" do
      Utils.stop_instance(@server)

      assert PostStream.owner(@server, sid(), 7) == :none
    end

    test "a duplicate request id is an error, the first request keeps its stream", %{
      conn: conn
    } do
      {:ok, _first} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)
      session_id = sid()

      task =
        Task.async(fn ->
          Utils.begin_stream(@server, session_id, 7, conn, &prepare/1)
        end)

      assert {:error, :duplicate} = Task.await(task, 30_000)
      assert {:ok, {owner, _stream_id}} = PostStream.owner(@server, sid(), 7)
      assert owner == self()
    end
  end

  describe "relay/2 and answer/2" do
    test "a request without a message gets no stream", %{conn: conn} do
      {:ok, stream} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)

      assert {:not_streamed, _stream} = PostStream.answer(%{"id" => 7}, stream)
    end

    test "the first message starts the stream; the response is its last event", %{conn: conn} do
      {:ok, stream} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)

      stream = relay(stream, %{"jsonrpc" => "2.0", "id" => "a", "method" => "ping"})
      stream = relay(stream, %{"jsonrpc" => "2.0", "method" => "notifications/x"})

      response = %{"jsonrpc" => "2.0", "id" => 7, "result" => %{"ok" => true}}
      assert {{:streamed, conn}, _stream} = PostStream.answer(response, stream)

      assert conn.status == 200
      assert conn.state == :chunked
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
      assert get_resp_header(conn, "cache-control") == ["no-cache"]
      assert get_resp_header(conn, "x-prepared") == ["yes"]

      assert events(conn.resp_body) == [
               %{"jsonrpc" => "2.0", "id" => "a", "method" => "ping"},
               %{"jsonrpc" => "2.0", "method" => "notifications/x"},
               response
             ]
    end

    test "the stream starts with a priming event; every event has an id of the stream",
         %{conn: conn} do
      {:ok, stream} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)
      stream = relay(stream, %{"method" => "ping"})

      assert {{:streamed, conn}, _stream} = PostStream.answer(%{"id" => 7}, stream)

      assert [priming, first, last] = String.split(conn.resp_body, "\n\n", trim: true)
      assert [stream_id, "0"] = priming |> event_id() |> String.split(":")
      assert priming == "id: #{stream_id}:0\ndata: "
      assert event_id(first) == "#{stream_id}:1"
      assert event_id(last) == "#{stream_id}:2"
      assert PostStream.parse_event_id("#{stream_id}:2") == {stream_id, 2}
    end

    test "the events are kept in the event log of the session", %{conn: conn} do
      session_id = Utils.create_session(@server, initialized: true)
      {:ok, stream} = Utils.begin_stream(@server, session_id, 7, conn, &prepare/1)
      stream = relay(stream, %{"method" => "ping"})
      assert {{:streamed, conn}, _stream} = PostStream.answer(%{"id" => 7}, stream)

      [priming, _, _] = String.split(conn.resp_body, "\n\n", trim: true)
      {stream_id, 0} = priming |> event_id() |> PostStream.parse_event_id()
      assert stream_id == stream.stream_id

      # the log is written by the server process: wait for it
      #
      assert {:ok, events} = wait_for_events(session_id, 2)

      first = "#{stream_id}:1"
      second = "#{stream_id}:2"
      assert [{^first, ping}, {^second, response}] = events
      assert :json.decode(ping) == %{"method" => "ping"}
      assert :json.decode(response) == %{"id" => 7}
    end

    test "the head keeps the headers already on the connection", %{conn: conn} do
      conn = put_resp_header(conn, "mcp-session-id", "abc")
      {:ok, stream} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)
      stream = relay(stream, %{"method" => "ping"})

      assert {{:streamed, conn}, _stream} = PostStream.answer(%{"id" => 7}, stream)
      assert get_resp_header(conn, "mcp-session-id") == ["abc"]
    end

    test "answer/2 writes the messages that are still queued before the response",
         %{conn: conn} do
      {:ok, stream} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)
      queue(stream, %{"method" => "one"})
      queue(stream, %{"method" => "two"})

      assert {{:streamed, conn}, _stream} = PostStream.answer(%{"id" => 7}, stream)
      assert [%{"method" => "one"}, %{"method" => "two"}, %{"id" => 7}] = events(conn.resp_body)
    end

    test "answer/2 accepts an encoded response", %{conn: conn} do
      {:ok, stream} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)
      stream = relay(stream, %{"method" => "ping"})

      assert {{:streamed, conn}, _stream} = PostStream.answer(~s({"id":7}), stream)
      assert [%{"method" => "ping"}, %{"id" => 7}] = events(conn.resp_body)
    end

    test "answer/2 writes a -32603 response when the response cannot be encoded",
         %{conn: conn} do
      {:ok, stream} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)
      stream = relay(stream, %{"method" => "ping"})

      response = %{"jsonrpc" => "2.0", "id" => 7, "result" => %{"text" => <<0xFF>>}}
      assert {{:streamed, conn}, _stream} = PostStream.answer(response, stream)

      assert [
               %{"method" => "ping"},
               %{"id" => 7, "error" => %{"code" => -32603}}
             ] = events(conn.resp_body)
    end

    test "answer/2 of a process that owns no stream is not streamed" do
      assert {:not_streamed, _stream} = PostStream.answer(%{"id" => 7}, nil)
    end

    test "nothing is written after close/1", %{conn: conn} do
      {:ok, stream} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)
      PostStream.close(stream)

      assert {:not_streamed, _stream} = PostStream.answer(%{"id" => 7}, stream)
    end

    test "the state does not survive answer/2", %{conn: conn} do
      {:ok, stream} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)
      stream = relay(stream, %{"method" => "ping"})
      assert {{:streamed, _conn}, _stream} = PostStream.answer(%{"id" => 7}, stream)

      assert {:not_streamed, _stream} = PostStream.answer(%{"id" => 7}, stream)
    end

    test "a second answer/2 with the same struct writes nothing", %{conn: conn} do
      session_id = Utils.create_session(@server, initialized: true)
      {:ok, stream} = Utils.begin_stream(@server, session_id, 7, conn, &prepare/1)

      response = %{"jsonrpc" => "2.0", "id" => 7, "result" => %{}}

      # The first answer ends the stream (a plain response): the entry of
      # the stream goes.
      #
      assert {:not_streamed, _stream} = PostStream.answer(response, stream)

      # A second answer finds no entry: nothing is written, the response
      # is not repeated.
      #
      assert {:not_streamed, _stream} = PostStream.answer(response, stream)
      assert is_nil(conn.resp_body)
    end

    test "two requests of one process carry a state of their own", %{conn: conn} do
      {:ok, first} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)
      {:ok, second} = Utils.begin_stream(@server, sid(), 8, conn(:post, "/"), &prepare/1)

      assert first.stream_id != second.stream_id

      first = relay(first, %{"method" => "one"})
      second = relay(second, %{"method" => "two"})
      assert {{:streamed, first_conn}, _stream} = PostStream.answer(%{"id" => 7}, first)
      assert events(first_conn.resp_body) == [%{"method" => "one"}, %{"id" => 7}]

      assert {{:streamed, second_conn}, _stream} = PostStream.answer(%{"id" => 8}, second)
      assert events(second_conn.resp_body) == [%{"method" => "two"}, %{"id" => 8}]
    end
  end

  describe "heartbeat/2" do
    test "writes a comment on a started stream, between the events", %{conn: conn} do
      {:ok, stream} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)
      stream = relay(stream, %{"method" => "ping"})

      stream = PostStream.heartbeat(stream, [])
      stream = PostStream.heartbeat(stream, [])

      response = %{"jsonrpc" => "2.0", "id" => 7, "result" => %{}}
      assert {{:streamed, conn}, _stream} = PostStream.answer(response, stream)

      assert conn.resp_body =~
               "data: {\"method\":\"ping\"}\n\n: heartbeat\n\n: heartbeat\n\n"

      # A comment is no message and takes no event id.
      #
      assert events(conn.resp_body) == [%{"method" => "ping"}, response]

      assert conn.resp_body |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "id: ")) ==
               3
    end

    test "does nothing while the response is not upgraded", %{conn: conn} do
      {:ok, stream} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)

      stream = PostStream.heartbeat(stream, [])

      # Nothing was written: the request still gets the plain response.
      #
      assert {:not_streamed, _stream} = PostStream.answer(%{"id" => 7}, stream)
    end

    test "does nothing for a process that owns no stream" do
      assert PostStream.heartbeat(nil, []) == nil
    end

    test "with start: true upgrades a plain response and writes the comment", %{conn: conn} do
      {:ok, stream} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)

      stream = PostStream.heartbeat(stream, start: true)

      response = %{"jsonrpc" => "2.0", "id" => 7, "result" => %{}}
      assert {{:streamed, conn}, _stream} = PostStream.answer(response, stream)

      # The stream started: head, priming event, then the comment.
      #
      assert conn.state == :chunked
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
      assert get_resp_header(conn, "x-prepared") == ["yes"]

      [priming, comment, last] = String.split(conn.resp_body, "\n\n", trim: true)
      assert priming == "id: #{priming |> event_id() |> String.split(":") |> hd()}:0\ndata: "
      assert comment == ": heartbeat"

      # The response is the last event of the stream.
      #
      assert events(conn.resp_body) == [response]
      assert last =~ ~r/^id: \S+:1\nevent: message\ndata: /

      # No event went out before it, but the stream was started: the
      # session numbered the response as the first event of the stream
      # and the log holds it.
      #
      assert {:ok, [{event_id, encoded}]} = wait_for_events(sid(), 1)
      assert event_id == "#{priming |> event_id() |> String.split(":") |> hd()}:1"
      assert :json.decode(encoded) == response
    end

    test "a write that fails marks the connection as gone" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])

      # the priming event and the first event are written, the heartbeat fails
      #
      {:ok, stream} =
        Utils.begin_stream(
          @server,
          session_id,
          7,
          Support.Helpers.AdapterClosed.wrap(conn(:post, "/"), 2),
          &prepare/1
        )

      stream = relay(stream, %{"method" => "ping"})

      PostStream.heartbeat(stream, [])

      # Later events go to the event log, as for any lost connection.
      #
      _ = relay(stream, %{"method" => "again"})
      assert {:ok, events} = wait_for_events(session_id, 2)
      assert {_, encoded} = List.last(events)
      assert :json.decode(encoded) == %{"method" => "again"}
    end
  end

  describe "write_retry/1" do
    test "a started stream writes the retry hint and stays open", %{conn: conn} do
      {:ok, stream} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)
      stream = relay(stream, %{"method" => "ping"})
      body = stream.conn.resp_body

      stream = PostStream.write_retry(stream)

      refute stream.failed

      assert stream.conn.resp_body ==
               body <> "retry: #{OzMcp.Instance.opts(@server).sse_retry_ms}\n\n"
    end

    test "a stream that failed writes nothing", %{conn: conn} do
      {:ok, stream} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)
      stream = relay(stream, %{"method" => "ping"}) |> taken_over()
      body = stream.conn.resp_body

      assert PostStream.write_retry(stream).conn.resp_body == body
    end

    test "a stream with no registration writes nothing", %{conn: conn} do
      {:ok, stream} = Utils.begin_stream(@server, nil, 7, conn, &prepare/1)

      assert is_nil(PostStream.write_retry(stream).conn.resp_body)
    end

    test "a stream with no connection writes nothing" do
      {:ok, sink} =
        Utils.begin_sink(@server, sid(), 7, fn _message -> :ok end)

      assert %PostStream{conn: nil} = PostStream.write_retry(sink)
    end
  end

  describe "a message that JSON cannot encode" do
    test "route/4 gives {:error, :not_encodable} and sends nothing", %{conn: conn} do
      {:ok, stream} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)

      assert PostStream.route(@server, sid(), 7, %{
               "method" => "ping",
               "params" => %{"pid" => self()}
             }) == {:error, :not_encodable}

      refute_receive {:oz_mcp_stream, _, _}, 50
      assert {:not_streamed, _stream} = PostStream.answer(%{"id" => 7}, stream)
    end

    test "route/4 gives {:error, :not_encodable} to the GET stream path too" do
      assert PostStream.route(@server, sid(), 99, %{"params" => {:a, :tuple}}) ==
               {:error, :not_encodable}
    end
  end

  describe "begin/5" do
    test "drops the messages a previous request left in the mailbox", %{conn: conn} do
      send(self(), {:oz_mcp_stream, "stale", {:event, "stale:1", ~s({"method":"stale"})}})

      {:ok, stream} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)

      assert {:not_streamed, _stream} = PostStream.answer(%{"id" => 7}, stream)
      refute_received {:oz_mcp_stream, _, _}
    end

    test "close/1 forgets the stream the process owned before", %{conn: conn} do
      {:ok, first} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)
      relay(first, %{"method" => "ping"})

      PostStream.close(first)

      {:ok, second} = Utils.begin_stream(@server, sid(), 8, conn, &prepare/1)

      assert PostStream.owner(@server, sid(), 7) == :none
      assert PostStream.owner(@server, sid(), 8) == {:ok, {self(), second.stream_id}}
      assert {:not_streamed, _stream} = PostStream.answer(%{"id" => 8}, second)
    end
  end

  describe "begin_sink/4" do
    test "relay/2 gives the messages to the sink, in order" do
      parent = self()

      {:ok, stream} =
        Utils.begin_sink(@server, sid(), 7, fn message ->
          send(parent, {:sink, decode(message)})
        end)

      stream = relay(stream, %{"method" => "notifications/x"})
      stream = relay(stream, %{"method" => "ping", "id" => "a"})

      assert_receive {:sink, %{"method" => "notifications/x"}}
      assert_receive {:sink, %{"method" => "ping", "id" => "a"}}

      assert PostStream.owner(@server, sid(), 7) == {:ok, {self(), stream.stream_id}}
    end

    # This test is the only one that fails if `finish/2` writes the response
    # before `drain/1`. A stdio test cannot hold this rule. A message that
    # another process sends before the result is read is written in order by
    # the wait loop of `Invoke`. Only a message that arrives between the
    # result and `finish/2` is drained here and a test cannot place a
    # message in that window.
    #
    test "a message that another process sends is written before the response" do
      parent = self()
      session_id = sid()

      {:ok, stream} =
        Utils.begin_sink(@server, session_id, 7, fn message ->
          send(parent, {:sink, decode(message)})
        end)

      Task.await(
        Task.async(fn ->
          Sessions.emit(@server, session_id, {:request, 7}, %{"method" => "one"})
        end),
        30_000
      )

      Task.await(
        Task.async(fn ->
          Sessions.emit(@server, session_id, {:request, 7}, %{"method" => "two"})
        end),
        30_000
      )

      assert :ok = PostStream.finish(%{"id" => 7, "result" => %{}}, stream)

      # `receive` and not `assert_receive`: the messages must arrive in
      # this order, the response is the last one.
      #
      assert %{"method" => "one"} = sink_message!()
      assert %{"method" => "two"} = sink_message!()
      assert %{"id" => 7, "result" => %{}} = sink_message!()
    end

    test "finish/2 accepts an encoded response" do
      parent = self()

      {:ok, stream} =
        Utils.begin_sink(@server, sid(), 7, fn message ->
          send(parent, {:sink, decode(message)})
        end)

      assert :ok = PostStream.finish(~s({"id":7,"result":{}}), stream)
      assert_receive {:sink, %{"id" => 7, "result" => %{}}}
    end

    test "finish/2 writes a -32603 response when the response cannot be encoded" do
      parent = self()

      {:ok, stream} =
        Utils.begin_sink(@server, sid(), 7, fn message ->
          send(parent, {:sink, decode(message)})
        end)

      response = %{"jsonrpc" => "2.0", "id" => 7, "result" => %{"text" => <<0xFF>>}}
      assert :ok = PostStream.finish(response, stream)

      assert_receive {:sink,
                      %{
                        "id" => 7,
                        "error" => %{"code" => -32603, "message" => "internal server error"}
                      }}
    end

    test "finish/2 unregisters the request, the stream is done" do
      parent = self()

      {:ok, stream} =
        Utils.begin_sink(@server, sid(), 7, fn message ->
          send(parent, {:sink, decode(message)})
        end)

      assert :ok = PostStream.finish(%{"id" => 7}, stream)
      assert_receive {:sink, %{"id" => 7}}

      assert PostStream.owner(@server, sid(), 7) == :none
      assert :ok = PostStream.finish(%{"id" => 7}, stream)
      refute_receive {:sink, _}, 100
    end

    test "route/4 gives the message to the process that owns the sink" do
      parent = self()
      session_id = sid()

      {:ok, pid} =
        Task.start(fn ->
          {:ok, stream} =
            Utils.begin_sink(@server, session_id, 9, fn message ->
              send(parent, {:sink, decode(message)})
            end)

          send(parent, {:ready, stream.stream_id})

          receive do
            :finish -> PostStream.finish(%{"id" => 9, "result" => %{}}, stream)
          end
        end)

      assert_receive {:ready, stream_id}
      assert PostStream.owner(@server, sid(), 9) == {:ok, {pid, stream_id}}

      assert :ok = PostStream.route(@server, sid(), 9, %{"method" => "ping"})

      send(pid, :finish)
      assert_receive {:sink, %{"method" => "ping"}}
      assert_receive {:sink, %{"id" => 9, "result" => %{}}}
    end

    test "heartbeat/2 does nothing and does not raise, with or without start" do
      parent = self()

      {:ok, stream} =
        Utils.begin_sink(@server, sid(), 7, fn message ->
          send(parent, {:sink, decode(message)})
        end)

      PostStream.heartbeat(stream, [])
      PostStream.heartbeat(stream, start: true)
      refute_receive {:sink, _}, 100
    end

    test "forget the stream that the process owned before, in both directions", %{conn: conn} do
      {:ok, first} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)
      PostStream.close(first)

      {:ok, sink} = Utils.begin_sink(@server, sid(), 8, fn _message -> :ok end)
      assert PostStream.owner(@server, sid(), 7) == :none
      assert PostStream.owner(@server, sid(), 8) == {:ok, {self(), sink.stream_id}}

      PostStream.close(sink)
      {:ok, third} = Utils.begin_stream(@server, sid(), 9, conn, &prepare/1)

      assert PostStream.owner(@server, sid(), 8) == :none
      assert PostStream.owner(@server, sid(), 9) == {:ok, {self(), third.stream_id}}
    end

    test "a request id that is not a string or an integer registers nothing, the sink still works" do
      for request_id <- [nil, 1.5] do
        parent = self()

        {:ok, stream} =
          Utils.begin_sink(@server, sid(), request_id, fn message ->
            send(parent, {:sink, decode(message)})
          end)

        assert PostStream.owner(@server, sid(), request_id) == :none

        relay(stream, %{"method" => "ping"})
        assert_receive {:sink, %{"method" => "ping"}}

        PostStream.close(stream)
      end
    end
  end

  describe "the split of the answer" do
    test "close_in_session/2 numbers the response and write_answer/3 writes it", %{conn: conn} do
      {:ok, stream} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)
      stream = relay(stream, %{"method" => "ping"})

      encoded = Utils.encode_json(%{"id" => 7, "result" => %{}})
      assert {:sse, event_id} = PostStream.close_in_session(stream, encoded)
      assert event_id == "#{stream.stream_id}:2"

      assert {{:streamed, streamed}, stream} =
               PostStream.write_answer(stream, {:sse, event_id}, encoded)

      assert stream.ended
      assert events(streamed.resp_body) == [%{"method" => "ping"}, %{"id" => 7, "result" => %{}}]
    end

    test "a stream that never started gets :plain and write_answer/3 writes nothing", %{
      conn: conn
    } do
      {:ok, stream} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)

      assert :plain = PostStream.close_in_session(stream, ~s({"id":7}))

      assert {:not_streamed, stream} = PostStream.write_answer(stream, :plain, ~s({"id":7}))
      assert stream.ended
      assert is_nil(conn.resp_body)
    end

    test "an answered stream gives :gone and write_answer/3 writes nothing", %{conn: conn} do
      {:ok, stream} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)
      assert {:not_streamed, stream} = PostStream.answer(%{"id" => 7}, stream)

      assert :gone = PostStream.close_in_session(stream, ~s({"id":7}))

      assert {:not_streamed, stream} = PostStream.write_answer(stream, :gone, ~s({"id":7}))
      assert stream.ended
      assert is_nil(conn.resp_body)
    end

    test "answer/2 is close_in_session/2 followed by write_answer/3", %{conn: conn} do
      {:ok, stream} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)
      stream = relay(stream, %{"method" => "ping"})

      response = %{"jsonrpc" => "2.0", "id" => 7, "result" => %{}}
      encoded = Utils.encode_json(response)

      assert {{:streamed, conn}, _stream} = PostStream.answer(response, stream)

      {:ok, other} = Utils.begin_stream(@server, sid(), 8, conn(:post, "/"), &prepare/1)
      other = relay(other, %{"method" => "ping"})
      {:sse, event_id} = PostStream.close_in_session(other, encoded)

      assert {{:streamed, split_conn}, _stream} =
               PostStream.write_answer(other, {:sse, event_id}, encoded)

      assert events(conn.resp_body) == events(split_conn.resp_body)
    end
  end

  describe "begin/6" do
    test "request_owner registers the owner of the request, the caller stays the owner of the stream",
         %{conn: conn} do
      parent = self()

      worker =
        spawn(fn ->
          receive do
            message -> send(parent, {:cancel, message})
          end
        end)

      {:ok, stream} = PostStream.begin(@server, sid(), 7, conn, &prepare/1, request_owner: worker)

      assert PostStream.owner(@server, sid(), 7) == {:ok, {self(), stream.stream_id}}

      # The cancel of the request reaches the owner of the request.
      #
      assert :ok = Sessions.cancel(@server, sid(), 7, "test")
      assert_receive {:cancel, {:oz_mcp_cancel, 7, "test"}}, 5_000
      refute_received {:oz_mcp_cancel, _, _}

      # The death of the owner of the request drops the stream of the request.
      #
      Process.exit(worker, :kill)
      wait_until(fn -> PostStream.owner(@server, sid(), 7) == :none end)
    end

    test "drops the answer of a worker of a previous request from the mailbox", %{conn: conn} do
      send(self(), {:oz_mcp_loop, make_ref(), {:answer, :plain}})
      send(self(), {:oz_mcp_stream, "stale", {:event, "stale:1", "{}"}})

      {:ok, stream} = PostStream.begin(@server, sid(), 7, conn, &prepare/1, request_owner: self())

      assert {:not_streamed, _stream} = PostStream.answer(%{"id" => 7}, stream)
      refute_received {:oz_mcp_loop, _, _}
      refute_received {:oz_mcp_stream, _, _}
    end
  end

  describe "start_stream/1" do
    test "a stream of a live request starts, with the head and the priming event", %{conn: conn} do
      {:ok, stream} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)

      stream = PostStream.start_stream(stream)
      assert stream.started
      refute stream.failed

      assert get_resp_header(stream.conn, "content-type") == ["text/event-stream"]
      assert get_resp_header(stream.conn, "x-prepared") == ["yes"]

      assert [priming] = String.split(stream.conn.resp_body, "\n\n", trim: true)
      assert priming == "id: #{stream.stream_id}:0\ndata: "
    end

    test "a request that ended already: the stream does not start and writes nothing", %{
      conn: conn
    } do
      {:ok, stream} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)
      Utils.close_request(@server, sid(), 7, stream.stream_id, :detach)

      stream = PostStream.start_stream(stream)
      refute stream.started
      assert is_nil(stream.conn.resp_body)
    end

    test "a stream that started already comes back as it is", %{conn: conn} do
      {:ok, stream} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)
      stream = relay(stream, %{"method" => "ping"})
      body = stream.conn.resp_body

      stream = PostStream.start_stream(stream)
      assert stream.conn.resp_body == body
    end

    test "a stream with no registration starts with no call", %{conn: conn} do
      {:ok, stream} = Utils.begin_stream(@server, nil, 7, conn, &prepare/1)
      assert stream.registration == nil

      stream = PostStream.start_stream(stream)
      assert stream.started

      assert [priming] = String.split(stream.conn.resp_body, "\n\n", trim: true)
      assert priming == "id: #{stream.stream_id}:0\ndata: "
    end

    test "a stream that a resumer took over still gets the head", %{conn: conn} do
      {:ok, stream} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)
      stream = taken_over(stream)
      assert stream.failed
      refute stream.started

      stream = PostStream.start_stream(stream)
      assert stream.started

      assert [priming] = String.split(stream.conn.resp_body, "\n\n", trim: true)
      assert priming == "id: #{stream.stream_id}:0\ndata: "
    end
  end

  describe "hand_off/1" do
    test "a live stream is handed off: the conn is kept and the owner is gone", %{conn: conn} do
      {:ok, stream} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)
      stream = relay(stream, %{"method" => "ping"})
      body = stream.conn.resp_body

      assert {:handed_off, stream} = PostStream.hand_off(stream)
      assert stream.failed
      assert stream.detached
      assert stream.started
      assert stream.conn.resp_body == body

      # The stream has no live owner, but the request still has its stream.
      #
      assert PostStream.owner(@server, sid(), 7) == {:ok, {nil, stream.stream_id}}

      # A later event goes to the log only: no send to a nil owner and
      # nothing is written.
      #
      assert :ok = Sessions.emit(@server, sid(), {:request, 7}, %{"method" => "later"})
      refute_received {:oz_mcp_stream, _, _}
      assert stream.conn.resp_body == body

      # The heartbeat writes nothing, with or without the start.
      #
      stream = PostStream.heartbeat(stream, [])
      stream = PostStream.heartbeat(stream, start: true)
      assert stream.conn.resp_body == body

      assert {:ok, [_, {_, encoded}]} = wait_for_events(sid(), 2)
      assert :json.decode(encoded) == %{"method" => "later"}
    end

    test "a request that ended already gives {:answered, stream}", %{conn: conn} do
      {:ok, stream} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)
      Utils.close_request(@server, sid(), 7, stream.stream_id, :detach)

      assert {:answered, stream} = PostStream.hand_off(stream)
      refute stream.detached
      refute stream.failed
    end

    test "close/1 of a detached stream sends nothing", %{conn: conn} do
      {:ok, stream} = Utils.begin_stream(@server, sid(), 7, conn, &prepare/1)
      stream = relay(stream, %{"method" => "ping"})
      {:handed_off, stream} = PostStream.hand_off(stream)

      assert :ok = PostStream.close(stream)

      # The entry of the stream stays: a resumer gets the response later.
      #
      Utils.sync_server(@server, sid())
      assert PostStream.owner(@server, sid(), 7) == {:ok, {nil, stream.stream_id}}
    end
  end

  describe "when the session cannot answer" do
    #
    # The session process stops: the call of the answer gets an error, but
    # the stream and its connection are alive. This is the loss of a
    # session while a callback is running (a DELETE of the session, a stop
    # of the session process).
    #
    defp stop_session(session_id) do
      :ok = Sessions.terminate(@server, session_id)

      wait_until(fn ->
        OzMcp.Instance.whereis(@server, {:session, session_id}) == :not_running
      end)
    end

    test "a started stream with events writes the response with no id, as {:streamed}", %{
      conn: conn
    } do
      session_id = Utils.create_session(@server, initialized: true)
      {:ok, stream} = Utils.begin_stream(@server, session_id, 7, conn, &prepare/1)
      stream = relay(stream, %{"method" => "ping"})

      stop_session(session_id)

      response = %{"jsonrpc" => "2.0", "id" => 7, "result" => %{}}
      assert {{:streamed, streamed_conn}, _stream} = PostStream.answer(response, stream)

      # The body holds what went out before the session stopped, then the
      # response as an event with no id: the connection of the stream must
      # carry the response of the request.
      #
      assert events(streamed_conn.resp_body) == [%{"method" => "ping"}, response]

      # The response event has no id line: the session never gave it one.
      #
      assert Utils.sse_ids(streamed_conn.resp_body) == [
               "#{stream.stream_id}:0",
               "#{stream.stream_id}:1"
             ]

      assert get_resp_header(streamed_conn, "content-type") == ["text/event-stream"]
    end

    test "a started stream with no events writes the response with no id, as {:streamed}", %{
      conn: conn
    } do
      session_id = Utils.create_session(@server, initialized: true)
      {:ok, stream} = Utils.begin_stream(@server, session_id, 7, conn, &prepare/1)

      # The head and the priming event go out with no event of a message.
      #
      stream = PostStream.heartbeat(stream, start: true)
      assert stream.started

      stop_session(session_id)

      response = %{"jsonrpc" => "2.0", "id" => 7, "result" => %{}}
      assert {{:streamed, streamed_conn}, _stream} = PostStream.answer(response, stream)

      # The response is the only event, with no id line: the session never
      # gave it a number.
      #
      assert events(streamed_conn.resp_body) == [response]
      assert Utils.sse_ids(streamed_conn.resp_body) == ["#{stream.stream_id}:0"]
    end

    test "a stream that never started is :not_streamed when the session stopped", %{conn: conn} do
      session_id = Utils.create_session(@server, initialized: true)
      {:ok, stream} = Utils.begin_stream(@server, session_id, 7, conn, &prepare/1)

      stop_session(session_id)

      assert {:not_streamed, _stream} = PostStream.answer(%{"id" => 7}, stream)
      assert is_nil(conn.resp_body)
    end

    test "close_in_session/2 gives the error, write_answer/3 writes the response with no id", %{
      conn: conn
    } do
      session_id = Utils.create_session(@server, initialized: true)
      {:ok, stream} = Utils.begin_stream(@server, session_id, 7, conn, &prepare/1)
      stream = relay(stream, %{"method" => "ping"})

      stop_session(session_id)

      encoded = ~s({"id":7})
      assert {:error, _reason} = PostStream.close_in_session(stream, encoded)

      assert {{:streamed, streamed}, stream} =
               PostStream.write_answer(stream, {:error, :gone}, encoded)

      assert stream.ended
      assert events(streamed.resp_body) == [%{"method" => "ping"}, %{"id" => 7}]

      assert Utils.sse_ids(streamed.resp_body) == [
               "#{stream.stream_id}:0",
               "#{stream.stream_id}:1"
             ]
    end

    test "a stream that a resumer took over with no event is :not_streamed and the resumer gets the response",
         %{
           conn: conn
         } do
      session_id = Utils.create_session(@server, initialized: true)
      parent = self()

      # The owner is a process of its own, as in a real request: it begins
      # the stream, relays the takeover and answers with its own struct.
      #
      owner =
        spawn(fn ->
          {:ok, stream} =
            Utils.begin_stream(@server, session_id, 7, conn, &prepare/1)

          receive do
            {:oz_mcp_stream, _id, :taken_over} -> :ok
          end

          stream = PostStream.relay(stream, {:oz_mcp_stream, stream.stream_id, :taken_over})
          assert stream.failed
          refute stream.started

          response = %{"jsonrpc" => "2.0", "id" => 7, "result" => %{}}
          send(parent, {:answer, elem(PostStream.answer(response, stream), 0)})
          Process.sleep(:infinity)
        end)

      wait_until(fn ->
        match?({:ok, {^owner, _stream_id}}, PostStream.owner(@server, session_id, 7))
      end)

      {:ok, {_owner, stream_id}} = PostStream.owner(@server, session_id, 7)

      # A resumer takes the stream before any event went out: the owner got
      # only the takeover notice, so its connection never started.
      #
      assert {:ok, %{mode: :resume}} =
               Session.open_stream(@server, session_id, :get, self(), "#{stream_id}:0")

      assert_receive {:answer, :not_streamed}, 5_000
      assert is_nil(conn.resp_body)

      # The resumer holds the stream: the response is its final event and
      # the end of the stream comes after it.
      #
      assert {:oz_mcp_stream, ^stream_id, {:event, event_id, data}} =
               Utils.receive_stream_message(stream_id)

      assert event_id == "#{stream_id}:1"

      assert :json.decode(IO.iodata_to_binary(data)) == %{
               "jsonrpc" => "2.0",
               "id" => 7,
               "result" => %{}
             }

      assert {:oz_mcp_stream, ^stream_id, :end} = Utils.receive_stream_message(stream_id)
    end
  end

  defp wait_until(fun, tries \\ 3_000) do
    if Utils.eventually(fun, tries * 5) do
      :ok
    else
      flunk("condition was not met in time")
    end
  end

  defp sink_message!(timeout \\ 5_000) do
    receive do
      {:sink, message} -> message
    after
      timeout -> flunk("no message from the sink")
    end
  end
end
