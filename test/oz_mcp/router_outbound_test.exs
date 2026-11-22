#
# A real callback sends a request to the client through the router: the whole
# path `Context.to_ctx/1` -> `Invoke` runner -> `Outbound.request/4` ->
# `PostStream` -> answer of the client (`202`) is exercised, without a
# simulated callback.
#
defmodule OzMcp.RouterOutboundTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  import Plug.Test
  import Plug.Conn
  alias OzMcp.Session
  alias OzMcp.Sessions
  alias OzMcp.Tasks
  alias Support.Helpers.SessionProbe
  alias Support.Helpers.Utils
  alias Support.Servers

  @server_module Servers.Outbound

  @server Module.concat(@server_module, __MODULE__)
  setup context do
    server_opts = Map.get(context, :server_opts, %{})

    Utils.start_instance(@server_module, [name: @server] ++ Map.to_list(server_opts))
    :ok
  end

  test "the request of the callback travels on the POST stream and the answer reaches the callback" do
    session_id = Utils.create_session(@server, initialized: true)
    start_call(session_id, 5)
    id = wait_for_pending(session_id)

    assert post_response(session_id, %{"id" => id, "result" => %{}}).status == 202
    assert_receive {:call_conn, 5, conn}, 5_000

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/event-stream"]

    assert [request, response] = sse_messages(conn.resp_body)
    assert request == %{"jsonrpc" => "2.0", "id" => id, "method" => "ping"}
    assert %{"jsonrpc" => "2.0", "id" => 5, "result" => %{"content" => [content]}} = response
    assert content["text"] == "{:ok, %{}}"
    assert SessionProbe.pending_outbound_ids(@server, session_id) == []
  end

  test "an error answer of the client reaches the callback" do
    session_id = Utils.create_session(@server, initialized: true)
    start_call(session_id, 5)
    id = wait_for_pending(session_id)

    error = %{"code" => -32601, "message" => "no ping"}
    assert post_response(session_id, %{"id" => id, "error" => error}).status == 202
    assert_receive {:call_conn, 5, conn}, 5_000

    assert [_request, %{"id" => 5, "result" => %{"content" => [content]}}] =
             sse_messages(conn.resp_body)

    assert content["text"] =~ "{:error, {:rpc_error, %{"
    assert content["text"] =~ "no ping"
  end

  test "a request the client cannot handle is refused: nothing is sent, the POST stays plain JSON" do
    session_id = Utils.create_session(@server, initialized: true)

    conn = call_tool(session_id, 5, %{"method" => "roots/list"})

    assert conn.status == 200
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/json"
    assert [content] = :json.decode(conn.resp_body)["result"]["content"]
    assert content["text"] == "{:error, :capability_not_supported}"
    assert SessionProbe.pending_outbound_ids(@server, session_id) == []
  end

  test "a declared capability lets the callback send the request" do
    session_id =
      Utils.create_session(@server, initialized: true, client_capabilities: %{"roots" => %{}})

    start_call(session_id, 5, %{"method" => "roots/list"})
    id = wait_for_pending(session_id)

    result = %{"roots" => []}
    assert post_response(session_id, %{"id" => id, "result" => result}).status == 202
    assert_receive {:call_conn, 5, conn}, 5_000

    assert [%{"method" => "roots/list", "id" => ^id}, %{"id" => 5}] = sse_messages(conn.resp_body)
  end

  test "the timeout of the callback is reported to the callback and to the client" do
    session_id = Utils.create_session(@server, initialized: true)

    conn = call_tool(session_id, 5, %{"timeout" => 100})

    assert get_resp_header(conn, "content-type") == ["text/event-stream"]

    assert [
             %{"method" => "ping", "id" => id},
             %{"method" => "notifications/cancelled", "params" => %{"requestId" => id}},
             %{"id" => 5, "result" => %{"content" => [content]}}
           ] = sse_messages(conn.resp_body)

    assert content["text"] == "{:error, :timeout}"
  end

  test "cancelling the call while it waits for the client ends the call and the pending request" do
    session_id = Utils.create_session(@server, initialized: true)
    start_call(session_id, 5)
    wait_for_pending(session_id)

    cancel =
      post_json(nil, "notifications/cancelled", %{"requestId" => 5})
      |> put_req_header("mcp-session-id", session_id)
      |> call_router()

    assert cancel.status == 202
    assert_receive {:call_conn, 5, conn}, 5_000

    # The client is told to forget the ping before it gets the error.
    #
    assert [
             %{"method" => "ping", "id" => id},
             %{"method" => "notifications/cancelled", "params" => params},
             %{"id" => 5, "error" => %{"code" => -32800}}
           ] = sse_messages(conn.resp_body)

    assert params["requestId"] == id

    wait_until(fn -> SessionProbe.pending_outbound_ids(@server, session_id) == [] end)
  end

  describe "heartbeat of a POST stream" do
    #
    # The request waits 100 intervals of the heartbeat and the test needs 3
    # comments, so a loaded machine does not make the count fall short.
    #
    @tag server_opts: %{sse_heartbeat_ms: 10}
    test "keeps the stream alive while the request waits for the client" do
      session_id = Utils.create_session(@server, initialized: true)

      conn = call_tool(session_id, 5, %{"timeout" => 1_000})

      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
      assert length(String.split(conn.resp_body, ": heartbeat\n\n")) - 1 >= 3

      # The comments are no messages: the request, the cancel notice and the
      # response are all the client reads, in order.
      #
      assert [
               %{"method" => "ping"},
               %{"method" => "notifications/cancelled"},
               %{"id" => 5, "result" => _}
             ] = sse_messages(conn.resp_body)

      # The heartbeat comes after the priming event and never after the response.
      #
      [head | _] = String.split(conn.resp_body, ": heartbeat")
      assert head =~ ~r/\Aid: \S+:0\ndata: \n\n/
      assert String.ends_with?(conn.resp_body, "}\n\n")
    end

    @tag server_opts: %{sse_heartbeat_ms: 40}
    test "a request that was never upgraded keeps the plain JSON response" do
      session_id = Utils.create_session(@server, initialized: true)

      # A slow callback that sends nothing to the client.
      #
      conn = call_tool(session_id, 5, %{"method" => "unknown/method", "delay" => 200})

      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"
      refute conn.resp_body =~ "heartbeat"
    end

    @tag server_opts: %{sse_heartbeat_ms: :infinity}
    test "is off with :infinity" do
      session_id = Utils.create_session(@server, initialized: true)

      conn = call_tool(session_id, 5, %{"timeout" => 150})

      refute conn.resp_body =~ "heartbeat"
      assert [%{"method" => "ping"} | _] = sse_messages(conn.resp_body)
    end

    @tag server_opts: %{sse_heartbeat_ms: 10, request_timeout_ms: 1_000}
    test "does not move the deadline of the request" do
      session_id = Utils.create_session(@server, initialized: true)

      started = System.monotonic_time(:millisecond)
      conn = call_tool(session_id, 5, %{"timeout" => 20_000})
      elapsed = System.monotonic_time(:millisecond) - started

      # The deadline (1 s) ends the request long before the wait of the
      # callback (20 s) and the heartbeats do not push it back.
      #
      assert conn.resp_body =~ "heartbeat"
      assert elapsed < 10_000

      assert [_ping, _cancelled, %{"id" => 5, "error" => %{"code" => -32603}}] =
               sse_messages(conn.resp_body)
    end

    @tag server_opts: %{sse_heartbeat_ms: 40}
    test "a client that is gone ends the heartbeat: the response goes to the event log" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])

      # priming + ping are written, the next chunk (a heartbeat) fails
      #
      conn = call_tool(session_id, 5, %{"timeout" => 300}, ok_chunks: 2)

      refute conn.resp_body =~ "\"id\":5"
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100

      assert [{_, ping}, {_, cancelled}, {_, response}] = wait_for_log(session_id, 3)

      assert :json.decode(ping)["method"] == "ping"
      assert :json.decode(cancelled)["method"] == "notifications/cancelled"
      assert :json.decode(response)["id"] == 5
    end
  end

  @tag server_opts: %{request_timeout_ms: 200}
  test "the deadline of the call tells the client to cancel the pending request" do
    session_id = Utils.create_session(@server, initialized: true)

    conn = call_tool(session_id, 5, %{"timeout" => 10_000})

    assert [
             %{"method" => "ping", "id" => id},
             %{"method" => "notifications/cancelled", "params" => params},
             %{"id" => 5, "error" => %{"code" => -32603, "data" => %{"reason" => "timeout"}}}
           ] = sse_messages(conn.resp_body)

    assert params["requestId"] == id
    assert wait_no_pending(session_id)
  end

  defp wait_no_pending(session_id, retries \\ 200) do
    Utils.eventually(
      fn -> SessionProbe.pending_outbound_ids(@server, session_id) == [] end,
      retries * 10
    )
  end

  test "the death of the caller hands the stream of the request off: the callback goes on" do
    session_id = Utils.create_session(@server, initialized: true)

    caller = spawn(fn -> call_tool(session_id, 5, %{"timeout" => 10_000}) end)
    id = wait_for_pending(session_id)

    Process.exit(caller, :kill)

    # The stream of the request lost its connection (the process that owns
    # it is gone). The callback goes on: the stream becomes a hand-off
    # and the pending request stays open for an answer of the client.
    #
    wait_until(fn ->
      Utils.session_data(@server, session_id).streams
      |> Map.values()
      |> Enum.any?(&match?(%{owner: nil}, &1))
    end)

    # The ping of the request is in the event log for a resume.
    #
    assert [{ping_id, ping}] = wait_for_log(session_id, 1)

    assert [stream_id, "1"] = String.split(ping_id, ":")
    assert :json.decode(ping) == %{"jsonrpc" => "2.0", "method" => "ping", "id" => id}

    # The callback still waits for the answer: the client is not told to
    # cancel the request.
    #
    assert SessionProbe.pending_outbound_ids(@server, session_id) == [id]

    # The client answers the ping: the callback ends and its response goes
    # to the event log of the stream.
    #
    assert post_response(session_id, %{"id" => id, "result" => %{}}).status == 202

    assert [{^ping_id, ^ping}, {response_id, response}] = wait_for_log(session_id, 2)
    assert response_id == "#{stream_id}:2"
    assert :json.decode(response)["id"] == 5

    # A resume of the stream of the request replays both and ends.
    #
    assert [{_, %{"method" => "ping"}}, {_, %{"id" => 5}}] = resume(session_id, "#{stream_id}:0")
  end

  describe "a POST stream that loses its connection" do
    test "the request goes on; its events are logged and reach a resume and the body ends" do
      session_id = Utils.create_session(@server, initialized: true)

      # The priming event is written, the next chunk fails: the client is gone.
      #
      start_call(session_id, 5, %{}, ok_chunks: 1)
      id = wait_for_pending(session_id)

      assert post_response(session_id, %{"id" => id, "result" => %{}}).status == 202
      assert_receive {:call_conn, 5, _conn}, 5_000

      assert [{ping_id, ping}, {response_id, response}] = wait_for_log(session_id, 2)

      assert [stream_id, "1"] = String.split(ping_id, ":")
      assert response_id == "#{stream_id}:2"
      assert :json.decode(ping) == %{"jsonrpc" => "2.0", "method" => "ping", "id" => id}
      assert :json.decode(response)["id"] == 5

      # The response is logged with the ids of the stream and a resume
      # receives the ping request. The client answers it on the resume.
      #
      assert [{_, %{"method" => "ping"}} | _] = resume(session_id, "#{stream_id}:0")
    end

    test "a client that resumes with the priming id gets the events of that stream only" do
      session_id = Utils.create_session(@server, initialized: true)

      # An event of the session around the call: it never goes to the
      # stream of the request.
      #
      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}
      :ok = Sessions.emit(@server, session_id, :session, notification)

      # The client goes away after the priming chunk of the POST stream: the
      # ping of the request is logged instead of written.
      #
      start_call(session_id, 5, %{}, ok_chunks: 1)
      id = wait_for_pending(session_id)

      ping_of = fn events ->
        Enum.filter(events, fn {id, data} ->
          not String.starts_with?(id, "g.") and
            match?(%{"method" => "ping"}, :json.decode(data))
        end)
      end

      wait_until(fn ->
        {:ok, events} = SessionProbe.events_after(@server, session_id, "none")
        match?([_], ping_of.(events))
      end)

      assert {:ok, events} = SessionProbe.events_after(@server, session_id, "none")
      assert [{ping_id, _}] = ping_of.(events)

      assert [stream_id, "1"] = String.split(ping_id, ":")

      # A GET resumes the stream: it replays the events of the stream after
      # the priming id, then it receives the live events and it ends after
      # the response. It never gets the events of the GET stream.
      #
      parent = self()

      spawn(fn ->
        conn =
          conn(:get, "/")
          |> put_req_header("accept", "text/event-stream")
          |> put_req_header("last-event-id", "#{stream_id}:0")
          |> put_req_header("mcp-session-id", session_id)
          |> put_req_header("mcp-protocol-version", "2025-11-25")
          |> call_router()

        send(parent, {:resumed, conn})
      end)

      wait_for_resumer(session_id, stream_id)

      # The client answers the request on the resume: the response arrives
      # there and the body ends with no retry field after it.
      #
      assert post_response(session_id, %{"id" => id, "result" => %{}}).status == 202

      assert_receive {:resumed, resume_conn}, 5_000

      assert [
               {^ping_id, %{"method" => "ping", "id" => ^id}},
               {response_id, %{"id" => 5, "result" => _}}
             ] =
               resume_conn.resp_body
               |> String.split("\n\n", trim: true)
               |> Enum.flat_map(fn event ->
                 with [ev_id] <- Regex.run(~r/^id: (\S+)/m, event, capture: :all_but_first),
                      [data] <- Regex.run(~r/^data: (.+)$/m, event, capture: :all_but_first) do
                   [{ev_id, :json.decode(data)}]
                 else
                   _ -> []
                 end
               end)

      assert response_id == "#{stream_id}:2"
      refute resume_conn.resp_body =~ ~r/retry: \d+\n\n\z/
    end

    test "a client that resumes a GET stream does not get the events of a POST stream" do
      session_id = Utils.create_session(@server, initialized: true)
      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}

      # A GET stream opens and ends: the session keeps it for the resume
      # and the events of the gap go in its ring.
      #
      {:ok, %{stream_id: _get_stream}} =
        Session.open_stream(@server, session_id, :get, self(), nil)

      assert :ok = Session.close_stream(@server, session_id, self())

      :ok = Sessions.emit(@server, session_id, :session, notification)

      start_call(session_id, 5, %{}, ok_chunks: 1)
      id = wait_for_pending(session_id)
      assert post_response(session_id, %{"id" => id, "result" => %{}}).status == 202
      assert_receive {:call_conn, 5, _conn}, 5_000

      :ok = Sessions.emit(@server, session_id, :session, notification)
      wait_for_log(session_id, 4)

      assert {:ok, [{first_get_id, _} | _]} =
               SessionProbe.events_after(@server, session_id, "none")

      assert String.starts_with?(first_get_id, "g.")

      replayed = resume(session_id, first_get_id)

      assert [{_id, %{"method" => "notifications/tools/list_changed"}}] = replayed
    end

    test "a takeover: the POST connection is alive, the resume gets the later events" do
      session_id = Utils.create_session(@server, initialized: true)

      # The POST stream stays alive: the client does not go away. The ping
      # of the callback is written to the POST body and logged.
      #
      start_call(session_id, 5)
      id = wait_for_pending(session_id)

      assert [{ping_id, _}] = wait_for_log(session_id, 1)
      assert [stream_id, "1"] = String.split(ping_id, ":")

      # A GET resumes the stream with the id of the last event it saw: it
      # takes the stream over from the POST connection.
      #
      parent = self()

      spawn(fn ->
        conn =
          conn(:get, "/")
          |> put_req_header("accept", "text/event-stream")
          |> put_req_header("last-event-id", "#{stream_id}:1")
          |> put_req_header("mcp-session-id", session_id)
          |> put_req_header("mcp-protocol-version", "2025-11-25")
          |> call_router()

        send(parent, {:resumed, conn})
      end)

      wait_for_resumer(session_id, stream_id)

      # The client answers the ping. The response goes to the resume only.
      #
      assert post_response(session_id, %{"id" => id, "result" => %{}}).status == 202

      assert_receive {:call_conn, 5, post_conn}, 5_000
      assert_receive {:resumed, resume_conn}, 5_000

      # The POST body has the events written before the takeover and stops
      # there: the response never reaches it.
      #
      assert event_ids(post_conn.resp_body) == ["#{stream_id}:0", ping_id]

      # The resume gets the response and the body ends with no retry field
      # after it.
      #
      assert event_ids(resume_conn.resp_body) == ["#{stream_id}:2"]

      assert %{"id" => 5, "result" => _} =
               resume_conn.resp_body
               |> String.split("\n\n", trim: true)
               |> Enum.flat_map(fn event ->
                 case Regex.run(~r/^data: (.+)$/m, event, capture: :all_but_first) do
                   [data] -> [:json.decode(data)]
                   nil -> []
                 end
               end)
               |> List.last()

      refute resume_conn.resp_body =~ ~r/retry: \d+\n\n\z/
    end

    test "a live POST stream logs its events too (a client can resume later)" do
      session_id = Utils.create_session(@server, initialized: true)
      start_call(session_id, 5)
      id = wait_for_pending(session_id)
      assert post_response(session_id, %{"id" => id, "result" => %{}}).status == 202
      assert_receive {:call_conn, 5, conn}, 5_000

      assert [priming_id | _] = event_ids(conn.resp_body)
      wait_for_log(session_id, 2)
      assert [{_, %{"method" => "ping"}}, {_, %{"id" => 5}}] = resume(session_id, priming_id)
    end

    test "a POST stream that lost its connection is replayed from its priming id" do
      session_id = Utils.create_session(@server, initialized: true)

      # A notification of the session around the call: it never goes to the
      # stream of the request.
      #
      :ok =
        Sessions.emit(@server, session_id, :session, %{
          "jsonrpc" => "2.0",
          "method" => "notifications/tools/list_changed"
        })

      # The client goes away after the priming chunk of the POST stream: the
      # ping and the response of the request are logged instead of written.
      #
      start_call(session_id, 5, %{}, ok_chunks: 1)
      id = wait_for_pending(session_id)
      assert post_response(session_id, %{"id" => id, "result" => %{}}).status == 202
      assert_receive {:call_conn, 5, conn}, 5_000

      assert [priming_id | _] = event_ids(conn.resp_body)
      assert priming_id =~ ":0"

      wait_until(fn ->
        {:ok, events} = SessionProbe.events_after(@server, session_id, "none")

        match?(
          [_, _],
          Enum.filter(events, fn {id, _} -> not String.starts_with?(id, "g.") end)
        )
      end)

      # The priming id of the POST stream is never in the log: the resume
      # replays by stream and sequence number and only the events of that
      # stream come back.
      #
      assert [{_, %{"method" => "ping"}}, {_, %{"id" => 5}}] = resume(session_id, priming_id)
    end
  end

  describe "progress of the request" do
    test "is written on the response of the POST, in order, with the response last" do
      session_id = Utils.create_session(@server, initialized: true)

      conn = call_progress(session_id, 5, "tok-1")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]

      assert [first, second, response] = sse_messages(conn.resp_body)

      assert first == %{
               "jsonrpc" => "2.0",
               "method" => "notifications/progress",
               "params" => %{
                 "progress" => 1,
                 "progressToken" => "tok-1",
                 "total" => 2,
                 "message" => "step 1"
               }
             }

      assert second["params"] == %{"progress" => 2, "progressToken" => "tok-1", "total" => 2}
      assert %{"id" => 5, "result" => %{"content" => [_]}} = response
    end

    test "reaches the client without an open GET stream and not the GET stream" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])

      conn = call_progress(session_id, 5, "tok-1")

      assert length(sse_messages(conn.resp_body)) == 3
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    test "a message that JSON cannot encode is refused to the callback, the request completes" do
      session_id = Utils.create_session(@server, initialized: true)

      params = %{
        "name" => "progress",
        "arguments" => %{"bad" => true},
        "_meta" => %{"progressToken" => "tok-1"}
      }

      conn = call_tool_named(session_id, 5, params)

      assert conn.status == 200
      assert [first, response] = sse_messages(conn.resp_body)
      assert first["params"]["progress"] == 1
      assert %{"id" => 5, "result" => %{"content" => [content]}} = response
      assert content["text"] == "{:error, :not_encodable}"
    end

    test "a request without a progress token keeps the plain JSON response" do
      session_id = Utils.create_session(@server, initialized: true, streams: [self()])

      conn = call_progress(session_id, 5, nil)

      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"
      assert :json.decode(conn.resp_body)["id"] == 5
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end
  end

  describe "log messages of the request" do
    test "are written on the response of the POST, before the response" do
      session_id = Utils.create_session(@server, initialized: true)
      :ok = Sessions.set_log_level(@server, session_id, :debug)

      conn = call_log(session_id, 5)

      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
      assert [first, second, response] = sse_messages(conn.resp_body)

      assert first == %{
               "jsonrpc" => "2.0",
               "method" => "notifications/message",
               "params" => %{"level" => "debug", "data" => "step 1"}
             }

      assert second["params"] == %{
               "level" => "warning",
               "data" => %{"disk" => "92%"},
               "logger" => "tool"
             }

      assert %{"id" => 5, "result" => _} = response
    end

    test "the level of the session filters the messages" do
      session_id = Utils.create_session(@server, initialized: true)
      :ok = Sessions.set_log_level(@server, session_id, :warning)

      conn = call_log(session_id, 5)

      assert [only, _response] = sse_messages(conn.resp_body)
      assert only["params"]["level"] == "warning"
    end

    test "no level: the response stays plain JSON" do
      session_id = Utils.create_session(@server, initialized: true)

      conn = call_log(session_id, 5)

      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"
    end

    test "another session of the server gets nothing (no cross-tenant leak)" do
      caller =
        Utils.create_session(@server, initialized: true, principal_key: {"iss", "alice"})

      other =
        Utils.create_session(@server,
          initialized: true,
          streams: [self()],
          principal_key: {"iss", "bob"}
        )

      :ok = Sessions.set_log_level(@server, caller, :debug)
      :ok = Sessions.set_log_level(@server, other, :debug)

      conn = call_log(caller, 5)

      assert length(sse_messages(conn.resp_body)) == 3
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end
  end

  describe "stream target of a POST request" do
    test "only the methods that run a callback register one" do
      session_id = Utils.create_session(@server, initialized: true)

      registrations = fn rpc ->
        count_stream_registrations(fn ->
          post_json(rpc.id, rpc.method, rpc.params)
          |> put_req_header("mcp-session-id", session_id)
          |> call_router()
        end)
      end

      assert registrations.(%{id: 1, method: "ping", params: %{}}) == 0
      assert registrations.(%{id: 2, method: "tools/list", params: %{}}) == 0
      assert registrations.(%{id: 3, method: "resources/list", params: %{}}) == 0

      assert registrations.(%{
               id: nil,
               method: "notifications/cancelled",
               params: %{"requestId" => 9}
             }) == 0

      assert registrations.(%{
               id: 4,
               method: "tools/call",
               params: %{"name" => "outbound", "arguments" => %{"method" => "roots/list"}}
             }) == 1
    end

    test "the response of the client registers none" do
      session_id = Utils.create_session(@server, initialized: true)

      assert count_stream_registrations(fn ->
               post_response(session_id, %{"id" => "unknown", "result" => %{}})
             end) == 0
    end

    test "a task-augmented tools/call registers none (the callback runs detached)" do
      session_id = Utils.create_session(@server, initialized: true)

      assert count_stream_registrations(fn ->
               post_json(6, "tools/call", %{"name" => "outbound", "task" => %{"ttl" => 60_000}})
               |> put_req_header("mcp-session-id", session_id)
               |> call_router()
             end) == 0
    end
  end

  test "a late answer after the call ended is accepted and ignored" do
    session_id = Utils.create_session(@server, initialized: true)
    start_call(session_id, 5, %{"timeout" => 2_000})
    id = wait_for_pending(session_id)
    assert_receive {:call_conn, 5, _conn}, 5_000

    assert post_response(session_id, %{"id" => id, "result" => %{}}).status == 202
  end

  describe "client features (elicitation, sampling, roots)" do
    test "a form: the callback asks the user and gets the accepted content" do
      session_id = session_with(%{"elicitation" => %{}})
      start_call(session_id, 5, %{"feature" => "elicit_form"})
      id = wait_for_pending(session_id)

      content = %{"name" => "Ana", "age" => 30}
      answer = %{"id" => id, "result" => %{"action" => "accept", "content" => content}}
      assert post_response(session_id, answer).status == 202
      assert_receive {:call_conn, 5, conn}, 5_000

      assert [request, response] = sse_messages(conn.resp_body)
      assert %{"method" => "elicitation/create", "id" => ^id, "params" => params} = request
      assert params["mode"] == "form"
      assert params["message"] == "Who are you?"
      assert params["requestedSchema"]["required"] == ["name"]
      assert params["requestedSchema"]["properties"]["age"]["type"] == "integer"

      assert [%{"text" => text}] = response["result"]["content"]
      assert text == ~s({:ok, %{action: :accept, content: %{"age" => 30, "name" => "Ana"}}})
    end

    test "a form: content that does not match the schema reaches the callback as an error" do
      session_id = session_with(%{"elicitation" => %{}})
      start_call(session_id, 5, %{"feature" => "elicit_form"})
      id = wait_for_pending(session_id)

      answer = %{"id" => id, "result" => %{"action" => "accept", "content" => %{"age" => -3}}}
      post_response(session_id, answer)
      assert_receive {:call_conn, 5, conn}, 5_000

      assert [_request, %{"result" => %{"content" => [%{"text" => text}]}}] =
               sse_messages(conn.resp_body)

      assert text =~ "{:error, {:invalid_content,"
    end

    test "a form: the user declines" do
      session_id = session_with(%{"elicitation" => %{}})
      start_call(session_id, 5, %{"feature" => "elicit_form"})
      id = wait_for_pending(session_id)

      post_response(session_id, %{"id" => id, "result" => %{"action" => "decline"}})
      assert_receive {:call_conn, 5, conn}, 5_000

      assert [_request, %{"result" => %{"content" => [%{"text" => text}]}}] =
               sse_messages(conn.resp_body)

      assert text == "{:ok, %{action: :decline, content: nil}}"
    end

    test "a URL: the callback sends the user to a page" do
      session_id = session_with(%{"elicitation" => %{"url" => %{}}})
      start_call(session_id, 5, %{"feature" => "elicit_url"})
      id = wait_for_pending(session_id)

      post_response(session_id, %{"id" => id, "result" => %{"action" => "accept"}})
      assert_receive {:call_conn, 5, conn}, 5_000

      assert [request, %{"result" => %{"content" => [%{"text" => text}]}}] =
               sse_messages(conn.resp_body)

      assert request["params"] == %{
               "mode" => "url",
               "message" => "Authorize the access",
               "url" => "https://example.com/authorize",
               "elicitationId" => "elicit-1"
             }

      assert text == ~s({:ok, %{action: :accept, content: nil, elicitation_id: "elicit-1"}})
    end

    test "a client that only supports forms is not sent a URL elicitation" do
      session_id = session_with(%{"elicitation" => %{}})

      conn = call_tool(session_id, 5, %{"feature" => "elicit_url"})

      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"

      assert [%{"text" => "{:error, :capability_not_supported}"}] =
               :json.decode(conn.resp_body)["result"]["content"]
    end

    test "sampling: the callback gets the completion of the client" do
      session_id = session_with(%{"sampling" => %{}})
      start_call(session_id, 5, %{"feature" => "sample"})
      id = wait_for_pending(session_id)

      result = %{
        "role" => "assistant",
        "content" => %{"type" => "text", "text" => "Hello!"},
        "model" => "model-1",
        "stopReason" => "endTurn"
      }

      post_response(session_id, %{"id" => id, "result" => result})
      assert_receive {:call_conn, 5, conn}, 5_000

      assert [request, %{"result" => %{"content" => [%{"text" => text}]}}] =
               sse_messages(conn.resp_body)

      assert request["method"] == "sampling/createMessage"
      assert request["params"]["maxTokens"] == 50

      assert request["params"]["messages"] == [
               %{"role" => "user", "content" => %{"type" => "text", "text" => "Hello"}}
             ]

      assert text =~ ~s(model: "model-1")
      assert text =~ ~s(stop_reason: "endTurn")
      assert text =~ ~s("text" => "Hello!")
    end

    test "sampling with tools needs sampling.tools" do
      refused = session_with(%{"sampling" => %{}})
      conn = call_tool(refused, 5, %{"feature" => "sample_tools"})
      assert [%{"text" => text}] = :json.decode(conn.resp_body)["result"]["content"]
      assert text == "{:error, :capability_not_supported}"

      allowed = session_with(%{"sampling" => %{"tools" => %{}}})
      start_call(allowed, 6, %{"feature" => "sample_tools"})
      id = wait_for_pending(allowed)
      post_response(allowed, %{"id" => id, "error" => %{"code" => -1, "message" => "no"}})
      assert_receive {:call_conn, 6, conn}, 5_000

      assert [request, _response] = sse_messages(conn.resp_body)
      assert [%{"name" => "weather"}] = request["params"]["tools"]
      assert request["params"]["toolChoice"] == %{"mode" => "auto"}
    end

    test "roots: the callback gets the roots of the client" do
      session_id = session_with(%{"roots" => %{"listChanged" => true}})
      start_call(session_id, 5, %{"feature" => "roots"})
      id = wait_for_pending(session_id)

      roots = [%{"uri" => "file:///home/user/project", "name" => "Project"}]
      post_response(session_id, %{"id" => id, "result" => %{"roots" => roots}})
      assert_receive {:call_conn, 5, conn}, 5_000

      assert [%{"method" => "roots/list"}, %{"result" => %{"content" => [%{"text" => text}]}}] =
               sse_messages(conn.resp_body)

      assert text =~ ~s({:ok, [%{"name" => "Project", "uri" => "file:///home/user/project"}]})
    end

    test "a callback can answer with the error that asks for a URL interaction" do
      session_id = session_with(%{})

      conn = call_tool(session_id, 5, %{"feature" => "url_required"})

      assert conn.status == 200

      assert %{"id" => 5, "error" => error} = :json.decode(conn.resp_body)
      assert error["code"] == -32042

      assert error["data"] == %{
               "elicitations" => [
                 %{
                   "mode" => "url",
                   "message" => "Connect your account",
                   "url" => "https://example.com/connect",
                   "elicitationId" => "elicit-1"
                 }
               ]
             }
    end
  end

  describe "notifications/roots/list_changed" do
    test "calls the roots_list_changed/1 callback of the server with the ctx of the session" do
      session_id = session_with(%{"roots" => %{"listChanged" => true}})
      register_probe(session_id)

      assert notify_roots_changed(session_id).status == 202

      assert_receive {:roots_list_changed, ctx}, 5_000
      assert ctx.server == @server_module
      assert ctx.session_id == session_id
      assert ctx.request_id == nil
      assert ctx.client_capabilities == %{"roots" => %{"listChanged" => true}}
    end

    test "is ignored when the client did not declare roots" do
      session_id = session_with(%{"sampling" => %{}})
      register_probe(session_id)

      assert notify_roots_changed(session_id).status == 202
      refute_receive {:roots_list_changed, _ctx}, 200
    end

    test "a burst of notifications is one run in progress and one more run after it" do
      session_id = session_with(%{"roots" => %{}})
      register_probe(session_id, :gate)

      assert notify_roots_changed(session_id).status == 202
      assert_receive {:roots_blocked, first}, 5_000

      # 30 more while the callback runs: all accepted, none starts a process.
      #
      for _ <- 1..30, do: assert(notify_roots_changed(session_id).status == 202)
      refute_receive {:roots_blocked, _other}, 200

      # The run ends: one more run for all of them.
      #
      send(first, :release)
      assert_receive {:roots_blocked, second}, 5_000
      assert second != first

      send(second, :release)
      refute_receive {:roots_blocked, _third}, 300

      # Two runs in all (the first one and the one for the burst).
      #
      assert_received {:roots_list_changed, _}
      assert_received {:roots_list_changed, _}
      refute_received {:roots_list_changed, _}

      # The session is free again.
      #
      wait_until(fn ->
        roots_idle?(session_id)
      end)

      assert notify_roots_changed(session_id).status == 202
      assert_receive {:roots_blocked, third}, 5_000
      send(third, :release)
    end

    test "the sessions run independently" do
      one = session_with(%{"roots" => %{}})
      two = session_with(%{"roots" => %{}})
      register_probe(one, :gate)
      register_probe(two, :gate)

      notify_roots_changed(one)
      assert_receive {:roots_blocked, first}, 5_000

      # Not held back by the run of the other session.
      #
      notify_roots_changed(two)
      assert_receive {:roots_blocked, second}, 5_000

      send(first, :release)
      send(second, :release)
    end

    @tag server_opts: %{request_timeout_ms: 200}
    test "a callback that does not return is stopped at the deadline and the session is free" do
      session_id = session_with(%{"roots" => %{}})
      register_probe(session_id, :gate)

      capture_log(fn ->
        notify_roots_changed(session_id)
        assert_receive {:roots_blocked, blocked}, 5_000

        ref = Process.monitor(blocked)
        assert_receive {:DOWN, ^ref, :process, ^blocked, _reason}, 5_000

        wait_until(fn ->
          roots_idle?(session_id)
        end)
      end)

      notify_roots_changed(session_id)
      assert_receive {:roots_blocked, again}, 5_000
      send(again, :release)
    end

    test "a callback that fails is logged and does not stop later runs" do
      session_id = session_with(%{"roots" => %{}})
      register_probe(session_id, :raise)

      log =
        capture_log(fn ->
          assert notify_roots_changed(session_id).status == 202
          assert_receive {:roots_list_changed, _}, 5_000

          wait_until(fn ->
            roots_idle?(session_id)
          end)

          assert notify_roots_changed(session_id).status == 202
          assert_receive {:roots_list_changed, _}, 5_000
        end)

      assert log =~ "roots_list_changed/1 of Support.Servers.Outbound failed"
    end
  end

  describe "the requests of a task" do
    @elicit_caps %{"elicitation" => %{}}

    test "the task waits in input_required; tasks/result delivers the request and the result" do
      session_id = session_with(@elicit_caps)
      task_id = create_task(session_id, %{"feature" => "elicit_form"})

      wait_until(fn -> task_status(session_id, task_id) == "input_required" end)

      start_result(session_id, 8, task_id)
      wait_until(fn -> stream_attached?(session_id, task_id) end)
      id = wait_for_task_pending(task_id)

      answer = %{"id" => id, "result" => %{"action" => "accept", "content" => %{"name" => "Ana"}}}
      assert post_response(session_id, answer).status == 202
      assert_receive {:result_conn, 8, conn}, 5_000

      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
      assert [request, response] = sse_task_messages(conn)

      assert %{"method" => "elicitation/create", "id" => ^id, "params" => params} = request

      assert params["_meta"] == %{
               "io.modelcontextprotocol/related-task" => %{"taskId" => task_id}
             }

      assert params["mode"] == "form"

      assert %{"id" => 8, "result" => result} = response
      assert [%{"text" => text}] = result["content"]
      assert text =~ "action: :accept"

      assert result["_meta"] == %{
               "io.modelcontextprotocol/related-task" => %{"taskId" => task_id}
             }

      wait_until(fn -> task_status(session_id, task_id) == "completed" end)

      # The entry of the runner goes when the registry sees its exit.
      #
      wait_until(fn -> SessionProbe.pending_outbound_ids(@server, session_id) == [] end)
    end

    test "tasks/result opened first receives the request when the task asks" do
      session_id = session_with(@elicit_caps)
      task_id = create_task(session_id, %{"feature" => "elicit_form", "delay" => 300})

      start_result(session_id, 8, task_id)
      wait_until(fn -> stream_attached?(session_id, task_id) end)
      id = wait_for_task_pending(task_id)

      post_response(session_id, %{"id" => id, "result" => %{"action" => "decline"}})
      assert_receive {:result_conn, 8, conn}, 5_000

      assert [%{"method" => "elicitation/create", "id" => ^id}, %{"id" => 8, "result" => _}] =
               sse_task_messages(conn)
    end

    test "two tasks/result requests of one task both receive the request" do
      session_id = session_with(@elicit_caps)
      task_id = create_task(session_id, %{"feature" => "elicit_form", "delay" => 300})

      start_result(session_id, 8, task_id)
      wait_until(fn -> stream_attached?(session_id, task_id) end)
      start_result(session_id, 9, task_id)
      wait_until(fn -> stream_count(task_id) == 2 end)
      id = wait_for_task_pending(task_id)

      post_response(session_id, %{"id" => id, "result" => %{"action" => "decline"}})
      assert_receive {:result_conn, 8, first}, 5_000
      assert_receive {:result_conn, 9, second}, 5_000

      for {rpc_id, conn} <- [{8, first}, {9, second}] do
        assert [%{"method" => "elicitation/create", "id" => ^id}, %{"id" => ^rpc_id}] =
                 sse_task_messages(conn)
      end
    end

    test "a notifications/cancelled for tasks/result ends the wait and not the task" do
      session_id = session_with(@elicit_caps)
      task_id = create_task(session_id, %{"feature" => "elicit_form"})
      wait_until(fn -> task_status(session_id, task_id) == "input_required" end)

      start_result(session_id, 8, task_id)
      wait_until(fn -> stream_attached?(session_id, task_id) end)

      cancel =
        post_json(nil, "notifications/cancelled", %{"requestId" => 8})
        |> put_req_header("mcp-session-id", session_id)
        |> call_router()

      assert cancel.status == 202
      assert_receive {:result_conn, 8, conn}, 5_000

      assert Enum.any?(
               sse_messages(conn.resp_body),
               &match?(%{"error" => %{"code" => -32800}}, &1)
             )

      wait_until(fn -> not stream_attached?(session_id, task_id) end)
      assert task_status(session_id, task_id) == "input_required"
    end

    test "tasks/cancel tells the client to forget the request of the task" do
      session_id = session_with(@elicit_caps)
      task_id = create_task(session_id, %{"feature" => "elicit_form"})

      start_result(session_id, 8, task_id)
      wait_until(fn -> stream_attached?(session_id, task_id) end)
      id = wait_for_task_pending(task_id)

      cancel =
        post_json(9, "tasks/cancel", %{"taskId" => task_id})
        |> put_req_header("mcp-session-id", session_id)
        |> call_router()

      assert :json.decode(cancel.resp_body)["result"]["status"] == "cancelled"
      assert_receive {:result_conn, 8, conn}, 5_000

      assert [
               %{"method" => "elicitation/create", "id" => ^id},
               %{"method" => "notifications/cancelled", "params" => params},
               %{"id" => 8, "error" => _}
             ] = sse_task_messages(conn)

      assert params["requestId"] == id

      # The entry of the runner goes when the registry sees its exit.
      #
      wait_until(fn -> SessionProbe.pending_outbound_ids(@server, session_id) == [] end)
    end

    test "a request nobody collects times out and the task goes on" do
      session_id = session_with(@elicit_caps)

      task_id =
        create_task(session_id, %{"feature" => "elicit_form", "timeout" => 400})

      wait_until(fn -> task_status(session_id, task_id) == "input_required" end)

      # Nobody calls tasks/result: the request times out, the task goes on.
      #
      wait_until(fn -> task_status(session_id, task_id) == "completed" end)

      # The entry of the runner goes when the registry sees its exit.
      #
      wait_until(fn -> SessionProbe.pending_outbound_ids(@server, session_id) == [] end)
    end

    test "a client that does not declare the capability is never asked" do
      session_id = session_with(%{})
      task_id = create_task(session_id, %{"feature" => "elicit_form"})

      wait_until(fn -> task_status(session_id, task_id) == "completed" end)
    end

    test "another session cannot see the request of the task" do
      session_id = session_with(@elicit_caps)
      other = session_with(@elicit_caps)
      task_id = create_task(session_id, %{"feature" => "elicit_form"})
      wait_until(fn -> task_status(session_id, task_id) == "input_required" end)

      conn =
        post_json(9, "tasks/result", %{"taskId" => task_id})
        |> put_req_header("mcp-session-id", other)
        |> call_router()

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"
      assert :json.decode(conn.resp_body)["error"]["code"] == -32602
      assert task_status(session_id, task_id) == "input_required"
    end
  end

  describe "terminate_sessions/2" do
    @alice {"https://issuer.test", "alice"}
    @bob {"https://issuer.test", "bob"}

    test "stops the pending request and the task of the principal only" do
      alice_session = create_session_for(@alice)
      bob_session = create_session_for(@bob)

      alice_ping = start_outbound_ping(alice_session)
      bob_ping = start_outbound_ping(bob_session)
      wait_for_pending(alice_session)
      wait_for_pending(bob_session)

      alice_task = create_task(alice_session, %{"feature" => "elicit_form"})
      bob_task = create_task(bob_session, %{"feature" => "elicit_form"})

      wait_until(fn -> task_status(alice_session, alice_task) == "input_required" end)
      wait_until(fn -> task_status(bob_session, bob_task) == "input_required" end)

      assert {:ok, [^alice_session]} = Sessions.terminate_principal(@server, @alice)

      # The POST of alice ends and the client is told to forget the ping.
      # The callback and the stop of the request run side by side: the body
      # holds the outcome of the callback or the cancelled error, whichever
      # won the race.
      #
      alice_body = Task.await(alice_ping, 30_000)

      assert alice_body =~ ~s("code":-32800) or
               alice_body =~ "{:error, :session_terminated}"

      # The task of alice is gone. The Server starts the cascade of tasks
      # with a cast: the manager processes it a moment after the reply.
      #
      wait_until(fn ->
        Tasks.get(@server, Utils.owner(alice_session), alice_task) == {:error, :no_task}
      end)

      # The session of bob is untouched: its request still waits, its task
      # runs (the request of the task waits in the process of the task).
      #
      assert length(SessionProbe.pending_outbound_ids(@server, bob_session)) == 1

      assert {:ok, %{status: :input_required}} =
               Tasks.get(@server, Utils.owner(bob_session), bob_task)

      assert :ok = Sessions.terminate(@server, bob_session)
      Task.shutdown(bob_ping, :brutal_kill)
    end
  end

  defp start_call(session_id, rpc_id, arguments \\ %{}, opts \\ []) do
    parent = self()

    spawn_link(fn ->
      send(parent, {:call_conn, rpc_id, call_tool(session_id, rpc_id, arguments, opts)})
    end)
  end

  # `ok_chunks: n`: the client goes away after n chunks (see Support.Helpers.AdapterClosed).
  #
  defp call_tool(session_id, rpc_id, arguments, opts \\ []) do
    conn =
      post_json(rpc_id, "tools/call", %{"name" => "outbound", "arguments" => arguments})
      |> put_req_header("mcp-session-id", session_id)

    conn =
      case Keyword.fetch(opts, :ok_chunks) do
        {:ok, n} -> Support.Helpers.AdapterClosed.wrap(conn, n)
        :error -> conn
      end

    call_router(conn)
  end

  defp session_with(capabilities),
    do: Utils.create_session(@server, initialized: true, client_capabilities: capabilities)

  # The probe of the test for one session: the callback of the server
  # finds it under `{:roots_probe, session_id}` in the Names Registry of
  # the instance, with the mode of the callback (`nil`, `:raise` or
  # `:gate`). A global name or flag would reach a test that runs at the
  # same time.
  #
  defp register_probe(session_id, mode \\ nil) do
    Registry.register(OzMcp.Instance.names(@server), {:roots_probe, session_id}, mode)
    :ok
  end

  # A session bound to the principal key, with the capability to elicit.
  #
  defp create_session_for(principal_key) do
    Utils.create_session(@server,
      initialized: true,
      client_capabilities: %{"elicitation" => %{}},
      principal_key: principal_key
    )
  end

  # A call that waits for the answer of the client on its POST stream.
  #
  defp start_outbound_ping(session_id) do
    Task.async(fn ->
      conn = call_tool(session_id, 5, %{})
      conn.resp_body
    end)
  end

  defp roots_idle?(session_id),
    do: Utils.session_data(@server, session_id).roots.running == nil

  defp notify_roots_changed(session_id) do
    post_json(nil, "notifications/roots/list_changed", %{})
    |> put_req_header("mcp-session-id", session_id)
    |> call_router()
  end

  defp create_task(session_id, arguments) do
    conn =
      post_json(1, "tools/call", %{
        "name" => "outbound",
        "arguments" => arguments,
        "task" => %{"ttl" => 60_000}
      })
      |> put_req_header("mcp-session-id", session_id)
      |> call_router()

    assert %{"result" => %{"task" => %{"taskId" => task_id}}} = :json.decode(conn.resp_body)
    task_id
  end

  defp task_status(session_id, task_id) do
    conn =
      post_json(77, "tasks/get", %{"taskId" => task_id})
      |> put_req_header("mcp-session-id", session_id)
      |> call_router()

    :json.decode(conn.resp_body)["result"]["status"]
  end

  # The tasks/result request of the task is open and receives its requests.
  #
  defp stream_attached?(_session_id, task_id) do
    case OzMcp.Instance.whereis(@server, {:task, task_id}) do
      {:ok, pid} -> match?({_state, %{streams: [_ | _]}}, :sys.get_state(pid))
      :not_running -> false
    end
  end

  defp stream_count(task_id) do
    case OzMcp.Instance.whereis(@server, {:task, task_id}) do
      {:ok, pid} -> pid |> :sys.get_state() |> elem(1) |> Map.fetch!(:streams) |> length()
      :not_running -> 0
    end
  end

  defp start_result(session_id, rpc_id, task_id) do
    parent = self()

    spawn_link(fn ->
      conn =
        post_json(rpc_id, "tasks/result", %{"taskId" => task_id})
        |> put_req_header("mcp-session-id", session_id)
        |> call_router()

      send(parent, {:result_conn, rpc_id, conn})
    end)
  end

  defp event_ids(body),
    do: Regex.scan(~r/^id: (\S+)/m, body, capture: :all_but_first) |> List.flatten()

  # The events the server holds for the session, once `count` are logged (the
  # log is written by the server process).
  #
  defp wait_for_log(session_id, count) do
    wait_until(fn ->
      {:ok, events} = SessionProbe.events_after(@server, session_id, "none")
      length(events) >= count
    end)

    assert {:ok, events} = SessionProbe.events_after(@server, session_id, "none")
    events
  end

  # A GET with Last-Event-ID: the events that are replayed, with their ids.
  # A POST stream id (it holds a colon) ends the stream on its own: the
  # resumer of a stream that is over ends after the replay and the resumer
  # of a live stream ends after the response. A GET id leaves the stream
  # open: the helper terminates it.
  #
  defp resume(session_id, last_event_id) do
    parent = self()

    stream =
      spawn(fn ->
        conn =
          conn(:get, "/")
          |> put_req_header("accept", "text/event-stream")
          |> put_req_header("last-event-id", last_event_id)
          |> put_req_header("mcp-session-id", session_id)
          |> put_req_header("mcp-protocol-version", "2025-11-25")
          |> call_router()

        send(parent, {:resumed, conn})
      end)

    # A POST stream id (it holds a colon but no dot) ends the stream on its
    # own: the resumer of a stream that is over ends after the replay and
    # the resumer of a live stream ends after the response. A GET id (it
    # starts with `g.`) leaves the stream open: the helper terminates it.
    #
    if String.starts_with?(last_event_id, "g.") do
      Utils.wait_for_stream(@server, session_id, stream)
      Utils.terminate_stream(@server, session_id, stream)
    end

    assert_receive {:resumed, conn}, 5_000

    conn.resp_body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn event ->
      with [id] <- Regex.run(~r/^id: (\S+)/m, event, capture: :all_but_first),
           [data] <- Regex.run(~r/^data: (.+)$/m, event, capture: :all_but_first) do
        [{id, :json.decode(data)}]
      else
        _ -> []
      end
    end)
  end

  # Number of stream targets (`Session.open_request` calls with a stream)
  # the router registers for the requests it handles in this process. A
  # process cannot be its own tracer: a helper process collects the trace.
  #
  defp count_stream_registrations(fun) do
    parent = self()
    tracer = spawn_link(fn -> collect_registrations(parent, 0) end)

    :erlang.trace_pattern({OzMcp.Session, :open_request, :_}, true, [:local])
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      fun.()
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({OzMcp.Session, :open_request, 5}, false, [:local])
    end

    # Trace messages arrive asynchronously: wait for the last one.
    #
    ref = :erlang.trace_delivered(self())

    receive do
      {:trace_delivered, _pid, ^ref} -> :ok
    end

    send(tracer, :report)

    receive do
      {:registrations, count} -> count
    end
  end

  defp collect_registrations(parent, count) do
    receive do
      #
      # A registration of a request with no stream: the plain form (the
      # stream is the fifth argument) and the form with options.
      #
      {:trace, _pid, :call,
       {OzMcp.Session, :open_request, [_instance, _session_id, _request_id, _owner, nil]}} ->
        collect_registrations(parent, count)

      {:trace, _pid, :call,
       {OzMcp.Session, :open_request, [_instance, _session_id, _request_id, _owner, nil, _opts]}} ->
        collect_registrations(parent, count)

      {:trace, _pid, :call, {OzMcp.Session, :open_request, _args}} ->
        collect_registrations(parent, count + 1)

      {:trace, _pid, :call, _other} ->
        collect_registrations(parent, count)

      :report ->
        send(parent, {:registrations, count})
    end
  end

  defp call_progress(session_id, rpc_id, token) do
    params = %{"name" => "progress"}
    params = if token, do: Map.put(params, "_meta", %{"progressToken" => token}), else: params
    call_tool_named(session_id, rpc_id, params)
  end

  defp call_log(session_id, rpc_id), do: call_tool_named(session_id, rpc_id, %{"name" => "log"})

  # A tools/call with the raw params of the request (the tool name and its
  # arguments come from the caller).
  #
  defp call_tool_named(session_id, rpc_id, params) do
    post_json(rpc_id, "tools/call", params)
    |> put_req_header("mcp-session-id", session_id)
    |> call_router()
  end

  defp post_response(session_id, fields) do
    body = %{"jsonrpc" => "2.0"} |> Map.merge(fields) |> :json.encode() |> IO.iodata_to_binary()

    post_raw(body)
    |> put_req_header("mcp-session-id", session_id)
    |> call_router()
  end

  defp post_json(id, method, params) do
    %{"jsonrpc" => "2.0", "method" => method, "params" => params}
    |> then(fn rpc -> if id, do: Map.put(rpc, "id", id), else: rpc end)
    |> :json.encode()
    |> IO.iodata_to_binary()
    |> post_raw()
  end

  defp post_raw(body) do
    conn(:post, "/", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("mcp-protocol-version", "2025-11-25")
  end

  defp call_router(conn) do
    OzMcp.Router.call(
      conn,
      OzMcp.Router.init(instance: @server, server: @server_module, allowed_origins: [])
    )
  end

  # Returns the id of the pending request. The id comes from the same read
  # that sees it: a second read could find it gone (the call can end).
  #
  defp wait_for_pending(session_id, retries \\ 1_500) do
    assert Utils.eventually(
             fn -> SessionProbe.pending_outbound_ids(@server, session_id) != [] end,
             retries * 10
           )

    hd(SessionProbe.pending_outbound_ids(@server, session_id))
  end

  # The pending request of a task: it waits in the process of the task,
  # not in the session.
  #
  defp wait_for_task_pending(task_id, retries \\ 1_500) do
    assert Utils.eventually(
             fn -> Tasks.pending_request_ids(@server, task_id) != [] end,
             retries * 10
           )

    hd(Tasks.pending_request_ids(@server, task_id))
  end

  defp wait_until(fun, retries \\ 1_500) do
    if Utils.eventually(fun, retries * 10) do
      :ok
    else
      flunk("condition was not met in time")
    end
  end

  # Waits until the session holds a resumer for the POST stream. The attach
  # of the resumer is one step in the session: when the state shows it, the
  # takeover message has gone to the owner and the test can act on the
  # session without a race.
  #
  defp wait_for_resumer(session_id, stream_id) do
    wait_until(fn ->
      case Utils.session_data(@server, session_id) do
        nil -> false
        data -> match?(%{resumer: pid} when is_pid(pid), data.streams[stream_id])
      end
    end)
  end

  # The JSON messages carried by the events of an SSE body.
  # The attached streams also carry the status notifications of the task;
  # the request/result expectations below skip them.
  #
  defp sse_task_messages(conn) do
    conn.resp_body
    |> sse_messages()
    |> Enum.reject(&(&1["method"] == "notifications/tasks/status"))
  end

  defp sse_messages(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn event ->
      #
      # The priming event has an id and no data: it carries no message.
      #
      case Regex.run(~r/^data: (.+)$/m, event, capture: :all_but_first) do
        [data] -> [:json.decode(data)]
        nil -> []
      end
    end)
  end
end
