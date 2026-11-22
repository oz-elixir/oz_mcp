#
# The unit tests of the loop of a `POST` stream: each callback of the
# target and the route answers that the split of the processes gives.
# The route runs here on the `Plug` test connection: the writer is a
# process of its own when the request must wait, so the test can answer
# the client, cancel the request, or kill a process while the loop runs.
# The writes of a broken connection come from the closed-connection test
# adapter. The end-to-end suite drives the same paths over a real
# connection.
#
defmodule OzMcp.Transport.Http.PostLoopTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias OzMcp.{Instance, PostStream, Session}
  alias OzMcp.Stream.Loop
  alias OzMcp.Transport.Http.{Post, PostLoop}
  alias Support.Helpers.SessionProbe
  alias Support.Helpers.Utils
  alias Support.Servers

  @server Servers.ToolsOnly
  @outbound_server Servers.Outbound
  @accept "application/json, text/event-stream"
  @parsers Plug.Parsers.init(parsers: [:json], json_decoder: {OzMcp.Wire, :decode!, []})
  @answer_timeout 10_000

  describe "the callbacks of the target" do
    test "the answer of a plain response is a JSON body with the result of the request" do
      name = start_instance(@server)
      session_id = Utils.create_session(name, initialized: true)
      stream = begin_stream(name, session_id, 7, conn())

      halt =
        PostLoop.message(
          {:answer, :rpc_success, ~s({"jsonrpc":"2.0","id":7,"result":{}}), :plain},
          state(stream, 7)
        )

      assert {:halt, conn} = halt
      assert conn.status == 200
      assert :json.decode(conn.resp_body) == %{"jsonrpc" => "2.0", "id" => 7, "result" => %{}}
      assert conn.private[:oz_mcp_result] == :ok

      PostStream.close(stream)
    end

    test "the answer of a streamed response is the last event of the stream" do
      name = start_instance(@server)
      session_id = Utils.create_session(name, initialized: true)
      stream = begin_stream(name, session_id, 7, conn()) |> PostStream.start_stream()

      # The session numbers the response as the last event of the stream.
      #
      encoded = ~s({"jsonrpc":"2.0","id":7,"result":{}})
      reply = PostStream.close_in_session(stream, encoded)

      assert {:halt, conn} =
               PostLoop.message({:answer, :rpc_success, encoded, reply}, state(stream, 7))

      assert conn.status == 200
      assert conn.private[:oz_mcp_result] == :ok
      assert [final] = data_frames(conn)
      assert final == %{"jsonrpc" => "2.0", "id" => 7, "result" => %{}}
    end

    test "the answer of an error response carries the result of the error" do
      name = start_instance(@server)
      session_id = Utils.create_session(name, initialized: true)
      stream = begin_stream(name, session_id, 7, conn())

      encoded = ~s({"jsonrpc":"2.0","id":7,"error":{"code":-32603,"message":"internal"}})

      assert {:halt, conn} =
               PostLoop.message({:answer, :rpc_error, encoded, :plain}, state(stream, 7))

      assert conn.status == 200
      assert conn.private[:oz_mcp_result] == :rpc_error
      assert :json.decode(conn.resp_body)["error"]["code"] == -32603

      PostStream.close(stream)
    end

    test "the internal error of the worker answers 500 with the id of the request" do
      name = start_instance(@server)
      session_id = Utils.create_session(name, initialized: true)
      stream = begin_stream(name, session_id, 7, conn())

      assert {:halt, conn} = PostLoop.message({:answer, :internal_error}, state(stream, 7))

      assert conn.status == 500
      assert :json.decode(conn.resp_body)["id"] == 7

      PostStream.close(stream)
    end

    test "the death of the worker before the stream answers 500 with the id" do
      name = start_instance(@server)
      session_id = Utils.create_session(name, initialized: true)
      stream = begin_stream(name, session_id, 7, conn())

      assert {:halt, conn} = run_aux_down(stream, 7)

      assert conn.status == 500
      assert :json.decode(conn.resp_body)["id"] == 7

      PostStream.close(stream)
    end

    test "the death of the worker after the start ends the response with no result" do
      name = start_instance(@server)
      session_id = Utils.create_session(name, initialized: true)
      stream = begin_stream(name, session_id, 7, conn()) |> PostStream.start_stream()

      assert {:halt, conn} = run_aux_down(stream, 7)

      # The chunked head is out: the response ends with no result and the
      # events before the crash keep their ids.
      #
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
      assert conn.resp_body =~ ~r/id: [0-9a-zA-Z]+:0\ndata: \n\n\z/

      PostStream.close(stream)
    end

    test "the expiry of the principal closes the connection and hands the stream off" do
      name = start_instance(@server)
      session_id = Utils.create_session(name, initialized: true)
      stream = begin_stream(name, session_id, 7, conn()) |> PostStream.start_stream()

      assert {:halt, conn} = PostLoop.timer(:expired, state(stream, 7))

      assert conn.status == 200
      assert conn.private[:oz_mcp_result] == :ok
      assert conn.resp_body =~ ~r/retry: \d+\n\n\z/

      # The stream has no live owner and the request is still open: the
      # callback goes on.
      #
      assert %{owner: nil} = Utils.session_data(name, session_id).streams[stream.stream_id]
      assert Map.has_key?(Utils.session_data(name, session_id).requests, 7)
    end

    test "a poll close writes the retry hint and ends the connection" do
      name = start_instance(@server)
      session_id = Utils.create_session(name, initialized: true)
      stream = begin_stream(name, session_id, 7, conn()) |> PostStream.start_stream()

      assert {:halt, conn} = PostLoop.timer(:poll, state(stream, 7))

      assert conn.private[:oz_mcp_result] == :ok
      assert conn.resp_body =~ ~r/retry: \d+\n\n\z/
      assert %{owner: nil} = Utils.session_data(name, session_id).streams[stream.stream_id]
    end

    test "a close of a stream that did not start writes the head, the priming event and the retry" do
      name = start_instance(@server)
      session_id = Utils.create_session(name, initialized: true)
      stream = begin_stream(name, session_id, 7, conn())
      refute stream.started

      assert {:halt, conn} = PostLoop.timer(:poll, state(stream, 7))

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
      assert conn.resp_body =~ ~r/id: [0-9a-zA-Z]+:0\ndata: \n\nretry: \d+\n\n\z/
    end

    test "a close after the answer of the worker keeps the stream in the loop" do
      name = start_instance(@server)
      session_id = Utils.create_session(name, initialized: true)
      stream = begin_stream(name, session_id, 7, conn())

      # The worker answered first: the stream did not start and the
      # session freed the request.
      #
      encoded = ~s({"jsonrpc":"2.0","id":7,"result":{}})
      assert :plain = PostStream.close_in_session(stream, encoded)

      assert {:cont, %{stream: stream}} = PostLoop.timer(:expired, state(stream, 7))
      refute stream.started
    end

    test "the response of a handed-off stream goes to the event log" do
      name = start_instance(@server)
      session_id = Utils.create_session(name, initialized: true)
      stream = begin_stream(name, session_id, 7, conn()) |> PostStream.start_stream()

      assert {:halt, _conn} = PostLoop.timer(:poll, state(stream, 7))

      # The worker still holds a copy of the stream: its answer is
      # numbered as the last event, for a client that resumes.
      #
      encoded = ~s({"jsonrpc":"2.0","id":7,"result":{}})
      assert {:sse, event_id} = PostStream.close_in_session(stream, encoded)

      assert {:ok, events} = SessionProbe.events_after(name, session_id, "none")
      assert {^event_id, ^encoded} = List.last(events)
    end

    test "a poll close of a failed stream hands it off with no retry hint" do
      name = start_instance(@server)
      session_id = Utils.create_session(name, initialized: true)
      stream = begin_stream(name, session_id, 7, conn()) |> PostStream.start_stream()

      # A write on the connection failed already: the retry hint of the
      # close would not reach the client, so the close writes none.
      #
      failed = %{stream | failed: true}

      assert {:halt, conn} = PostLoop.timer(:poll, state(failed, 7))

      assert conn.private[:oz_mcp_result] == :ok
      refute conn.resp_body =~ "retry:"
      assert %{owner: nil} = Utils.session_data(name, session_id).streams[stream.stream_id]
    end
  end

  describe "the route with a worker" do
    test "a fast tool answers with the plain JSON response" do
      name = start_instance(@server)
      session_id = Utils.create_session(name, initialized: true)

      conn = rpc_request(name, session_id, 1, "tools/call", %{"name" => "get_date"})

      assert conn.status == 200
      assert decoded(conn)["result"]["content"]
      assert conn.private[:oz_mcp_result] == :ok
    end

    test "the request of the server starts the stream and the answer is its last event" do
      name = start_instance(@outbound_server)
      session_id = Utils.create_session(name, initialized: true)

      writer = spawn_writer(name, session_id, 1, outbound_params())
      id = wait_pending_request(name, session_id)

      conn = post_client_response(name, session_id, %{"id" => id, "result" => %{}})
      assert conn.status == 202

      assert_receive {:post_answer, ^writer, conn}, @answer_timeout

      assert conn.status == 200
      assert conn.private[:oz_mcp_result] == :ok

      # The request of the server is an event of the stream and the
      # response of the request is the event after it.
      #
      assert [ping, answer] = data_frames(conn)
      assert ping["method"] == "ping"
      assert answer["result"]["content"]
    end

    test "the cancel of the request stops the callback and answers -32800" do
      name = start_instance(@outbound_server)
      session_id = Utils.create_session(name, initialized: true)

      writer = spawn_writer(name, session_id, 1, outbound_params())
      _id = wait_pending_request(name, session_id)

      conn = post_cancelled(name, session_id, 1)
      assert conn.status == 202

      assert_receive {:post_answer, ^writer, conn}, @answer_timeout

      assert conn.private[:oz_mcp_result] == :rpc_error
      assert [error] = last_frames(conn, 1)
      assert error["error"]["code"] == -32800

      wait_requests_freed(name, session_id)
    end

    test "the end of the session stops the callback and answers the cancel" do
      name = start_instance(@outbound_server)
      session_id = Utils.create_session(name, initialized: true)

      # The callback sleeps before it reports: the stream never starts
      # and the end of the session cancels the request with no race.
      #
      writer =
        spawn_writer(name, session_id, 1, %{
          "name" => "progress",
          "arguments" => %{"delay" => 10_000}
        })

      wait_until("the worker to run", fn -> children(name) >= 2 end)

      :ok = Session.close(name, session_id)

      assert_receive {:post_answer, ^writer, conn}, @answer_timeout

      assert conn.private[:oz_mcp_result] == :rpc_error
      assert :json.decode(conn.resp_body)["error"]["code"] == -32800
    end

    test "the death of the writer stops the worker and the callback" do
      name = start_instance(@outbound_server)
      session_id = Utils.create_session(name, initialized: true)

      writer = spawn_writer(name, session_id, 1, outbound_params())
      _id = wait_pending_request(name, session_id)

      Process.exit(writer, :kill)

      # The worker is the owner of the request: its death stops the
      # callback and the request of the client is abandoned.
      #
      wait_until("the request of the client to be abandoned", fn ->
        SessionProbe.pending_outbound_ids(name, session_id) == [] and
          requests_of(name, session_id) == %{}
      end)

      wait_until("the workers to be gone", fn -> children(name) == 0 end)
    end

    test "a crash of the loop of the writer stops the worker and the callback" do
      name = start_instance(@outbound_server)
      session_id = Utils.create_session(name, initialized: true)

      # A long timeout of the request to the client: only the rule of the
      # session can stop the callback within the wait below.
      #
      params = %{"name" => "outbound", "arguments" => %{"timeout" => 60_000}}
      writer = spawn_writer(name, session_id, 1, params)
      _id = wait_pending_request(name, session_id)

      assert %{1 => %{stream_id: stream_id}} = requests_of(name, session_id)
      writer_ref = Process.monitor(writer)

      # An event with data that is not iodata: the write of the writer
      # raises inside the loop.
      #
      send(writer, {:oz_mcp_stream, stream_id, {:event, stream_id <> ":9", :not_iodata}})
      assert_receive {:DOWN, ^writer_ref, :process, ^writer, {:badarg, _stack}}, @answer_timeout

      # The worker is the owner of the request: the writer stops it, so the
      # session stops the callback and abandons the request of the client.
      #
      wait_until("the request of the client to be abandoned", fn ->
        SessionProbe.pending_outbound_ids(name, session_id) == [] and
          requests_of(name, session_id) == %{}
      end)

      wait_until("the workers to be gone", fn -> children(name) == 0 end)
    end

    test "the crash of the worker before the stream answers 500" do
      name = start_instance(@outbound_server)
      session_id = Utils.create_session(name, initialized: true)

      # The callback sleeps before it asks the client: the stream never
      # starts while the test kills the worker.
      #
      writer =
        spawn_writer(name, session_id, 1, %{
          "name" => "outbound",
          "arguments" => %{"delay" => 10_000}
        })

      wait_until("the worker to run", fn -> children(name) >= 2 end)

      kill_workers(name)

      assert_receive {:post_answer, ^writer, conn}, @answer_timeout

      assert conn.status == 500
      assert decoded(conn)["id"] == 1

      wait_requests_freed(name, session_id)
    end

    test "the crash of the worker after the start ends the response with no result" do
      name = start_instance(@outbound_server)
      session_id = Utils.create_session(name, initialized: true)

      writer = spawn_writer(name, session_id, 1, outbound_params())
      _id = wait_pending_request(name, session_id)

      # Kill only the owner of the request. The session then stops the
      # callback itself, so the DOWN order is fixed (the cancel of the
      # ping goes to the GET stream).
      #
      %{1 => %{owner: worker}} = requests_of(name, session_id)
      Process.exit(worker, :kill)

      assert_receive {:post_answer, ^writer, conn}, @answer_timeout

      # The chunked head is out: the response ends with no result and
      # the request of the server keeps its id in the log of the session.
      #
      assert conn.status == 200
      assert is_nil(conn.private[:oz_mcp_result])
      assert [ping] = data_frames(conn)
      assert ping["method"] == "ping"

      wait_requests_freed(name, session_id)
    end

    test "a second request with the id of one that runs is refused" do
      name = start_instance(@outbound_server)
      session_id = Utils.create_session(name, initialized: true)

      writer = spawn_writer(name, session_id, 1, outbound_params())
      _id = wait_pending_request(name, session_id)

      conn = rpc_request(name, session_id, 1, "tools/call", outbound_params())

      assert conn.status == 200
      assert decoded(conn)["error"]["code"] == -32600
      assert conn.private[:oz_mcp_error_code] == :rpc_duplicate_request_id

      release(name, session_id)
      assert_receive {:post_answer, ^writer, _conn}, @answer_timeout

      wait_until("the workers to be gone", fn -> children(name) == 0 end)
    end

    test "a write that fails leaves the answer to the log of the session" do
      name = start_instance(@outbound_server)
      session_id = Utils.create_session(name, initialized: true)

      writer = spawn_writer(name, session_id, 1, outbound_params(), ok_chunks: 0)
      _id = wait_pending_request(name, session_id)

      conn = post_client_response(name, session_id, %{"id" => nil, "result" => %{}})
      assert conn.status == 202

      assert_receive {:post_answer, ^writer, conn}, @answer_timeout

      # The head went out, no event reached the connection: the response
      # went to the log of the stream.
      #
      assert conn.status == 200
      assert conn.resp_body == ""

      wait_requests_freed(name, session_id)
    end

    test "a client that closes the connection leaves the answer to the log" do
      name = start_instance(@outbound_server)
      session_id = Utils.create_session(name, initialized: true)

      # The connection takes the start of the stream and the ping event,
      # then it is closed: the write of the answer fails on it.
      #
      writer = spawn_writer(name, session_id, 1, outbound_params(), ok_chunks: 2)
      _id = wait_pending_request(name, session_id)

      conn = post_client_response(name, session_id, %{"id" => nil, "result" => %{}})
      assert conn.status == 202

      assert_receive {:post_answer, ^writer, conn}, @answer_timeout

      # The event before the close is on the connection, the answer is not.
      #
      assert conn.status == 200
      assert [ping] = data_frames(conn)
      assert ping["method"] == "ping"

      wait_requests_freed(name, session_id)
    end

    test "a stray answer of another worker is dropped" do
      name = start_instance(@outbound_server)
      session_id = Utils.create_session(name, initialized: true)

      writer = spawn_writer(name, session_id, 1, outbound_params())
      id = wait_pending_request(name, session_id)

      # An answer that carries the tag of another worker (a previous
      # request of the same connection) is dropped: the loop waits for
      # the answer of its own worker.
      #
      send(writer, {:oz_mcp_loop, make_ref(), {:answer, :internal_error}})

      conn = post_client_response(name, session_id, %{"id" => id, "result" => %{}})
      assert conn.status == 202

      assert_receive {:post_answer, ^writer, conn}, @answer_timeout

      assert conn.private[:oz_mcp_result] == :ok
      assert [_ping, answer] = data_frames(conn)
      assert answer["result"]["content"]

      wait_requests_freed(name, session_id)
    end

    test "a POST that runs past sse_max_stream_ms closes and the callback goes on" do
      name = start_instance(@outbound_server, sse_max_stream_ms: 50, sse_retry_ms: 250)
      session_id = Utils.create_session(name, initialized: true)

      writer = spawn_writer(name, session_id, 1, outbound_params())
      id = wait_pending_request(name, session_id)

      # The connection closes at the poll time, before the client answers:
      # the writer returns with a retry hint and no result.
      #
      assert_receive {:post_answer, ^writer, conn}, @answer_timeout
      assert conn.private[:oz_mcp_result] == :ok
      assert conn.resp_body =~ ~r/retry: 250\n\n\z/
      refute Enum.any?(data_frames(conn), &Map.has_key?(&1, "result"))

      # The callback is still alive: it takes the answer of the client.
      #
      conn = post_client_response(name, session_id, %{"id" => id, "result" => %{}})
      assert conn.status == 202

      wait_requests_freed(name, session_id)

      # The response of the request went to the event log of the stream.
      #
      assert {:ok, events} = SessionProbe.events_after(name, session_id, "none")
      assert Enum.any?(events, fn {_id, data} -> Map.has_key?(:json.decode(data), "result") end)
    end

    test "a POST that ends before sse_max_stream_ms answers with plain JSON and no retry" do
      name = start_instance(@server, sse_max_stream_ms: 1_000)

      session_id = Utils.create_session(name, initialized: true)

      conn = rpc_request(name, session_id, 1, "tools/call", %{"name" => "get_date"})

      assert conn.status == 200
      refute conn.resp_body =~ "retry:"
      assert conn.private[:oz_mcp_result] == :ok
    end
  end

  defp start_instance(server, opts \\ []) do
    name = Module.concat(server, :"T#{System.unique_integer([:positive])}")
    Utils.start_instance(server, [name: name, allowed_origins: []] ++ opts)
    name
  end

  defp state(stream, rpc_id), do: %PostLoop{stream: stream, rpc_id: rpc_id, keep_alive: false}

  # The connection of a request whose response is still plain: the head
  # goes out when the stream starts.
  #
  defp conn, do: conn(:post, "/")

  defp begin_stream(instance, session_id, rpc_id, conn) do
    {:ok, stream} = PostStream.begin(instance, session_id, rpc_id, conn, fn conn -> conn end)
    stream
  end

  # The death of the worker: a monitor of a process that is gone, whose
  # `:DOWN` is in the mailbox of the loop.
  #
  defp run_aux_down(stream, rpc_id) do
    victim = spawn(fn -> :ok end)
    aux_ref = Process.monitor(victim)

    wait_until("the monitored process to be gone", fn -> not Process.alive?(victim) end)

    conn =
      %Loop{
        target: PostLoop,
        state: state(stream, rpc_id),
        stream_id: stream.stream_id,
        heartbeat_ms: 20_000,
        aux_ref: aux_ref
      }
      |> Loop.run()

    {:halt, conn}
  end

  # The writer runs the route in a process of its own and the conn of
  # the answer comes back to the test as `{:post_answer, pid, conn}`.
  #
  defp spawn_writer(instance, session_id, id, params, opts \\ []) do
    parent = self()

    spawn(fn ->
      conn =
        request_conn(instance, session_id, id, "tools/call", params)
        |> wrap_closed_adapter(Keyword.get(opts, :ok_chunks))

      send(parent, {:post_answer, self(), Post.call(conn)})
    end)
  end

  # A call that answers at once: the route runs in the process of the test.
  #
  defp rpc_request(instance, session_id, id, method, params) do
    request_conn(instance, session_id, id, method, params) |> Post.call()
  end

  defp request_conn(instance, session_id, id, method, params) do
    message = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

    conn(:post, "/", :json.encode(message) |> IO.iodata_to_binary())
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", @accept)
    |> put_req_header("mcp-session-id", session_id)
    |> put_private(:instance, instance)
    |> Plug.Parsers.call(@parsers)
  end

  defp post_client_response(instance, session_id, fields) do
    body = %{"jsonrpc" => "2.0"} |> Map.merge(fields) |> :json.encode() |> IO.iodata_to_binary()

    conn(:post, "/", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", @accept)
    |> put_req_header("mcp-session-id", session_id)
    |> put_private(:instance, instance)
    |> Plug.Parsers.call(@parsers)
    |> Post.call()
  end

  defp post_cancelled(instance, session_id, request_id) do
    message = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{"requestId" => request_id}
    }

    conn(:post, "/", :json.encode(message) |> IO.iodata_to_binary())
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", @accept)
    |> put_req_header("mcp-session-id", session_id)
    |> put_private(:instance, instance)
    |> Plug.Parsers.call(@parsers)
    |> Post.call()
  end

  defp outbound_params, do: %{"name" => "outbound", "arguments" => %{}}

  defp release(instance, session_id) do
    id = wait_pending_request(instance, session_id)
    conn = post_client_response(instance, session_id, %{"id" => id, "result" => %{}})
    assert conn.status == 202
    :ok
  end

  defp wait_pending_request(instance, session_id) do
    wait_until("the request of the server", fn ->
      SessionProbe.pending_outbound_ids(instance, session_id) != []
    end)

    assert [id] = SessionProbe.pending_outbound_ids(instance, session_id)
    id
  end

  defp wait_requests_freed(instance, session_id) do
    Utils.sync_server(instance, session_id)

    wait_until("the request to be freed", fn -> requests_of(instance, session_id) == %{} end)
  end

  defp requests_of(instance, session_id) do
    case Utils.session_data(instance, session_id) do
      nil -> :gone
      data -> data.requests
    end
  end

  defp children(instance) do
    {:ok, sup} = Instance.whereis(instance, :calls)
    length(DynamicSupervisor.which_children(sup))
  end

  defp kill_workers(instance) do
    {:ok, sup} = Instance.whereis(instance, :calls)

    for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(sup) do
      Process.exit(pid, :kill)
    end

    :ok
  end

  defp wrap_closed_adapter(conn, nil), do: conn

  defp wrap_closed_adapter(conn, ok_chunks),
    do: Support.Helpers.AdapterClosed.wrap(conn, ok_chunks)

  # The JSON messages carried by the data fields of a stream body.
  #
  defp data_frames(conn) do
    conn.resp_body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn event ->
      case Regex.run(~r/^data: (.+)$/m, event, capture: :all_but_first) do
        [data] -> [:json.decode(data)]
        nil -> []
      end
    end)
  end

  defp last_frames(conn, n), do: conn |> data_frames() |> Enum.reverse() |> Enum.take(n)

  defp decoded(conn), do: :json.decode(conn.resp_body)

  defp wait_until(what, fun, tries \\ 1_500) do
    if Utils.eventually(fun, tries * 10) do
      :ok
    else
      flunk(what <> " was not met in time")
    end
  end
end
