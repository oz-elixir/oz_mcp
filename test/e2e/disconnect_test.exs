#
# What the close of the connection of the client does to the work of the
# server: a close is not a cancel. The callback of a request goes on and
# its messages and its response reach the client through the event log of
# the stream. The cases cover a streaming `POST`, a plain `POST`, a
# request to the client, a `tasks/result` wait, the way each server finds
# a gone client and the idle timeout of the listener of Cowboy. Each
# case runs the two listeners in one run, one after the other.
#
defmodule OzMcp.E2E.DisconnectTest do
  use OzMcp.E2ECase, async: true

  alias OzMcp.Sessions
  alias Support.Helpers.Utils
  alias Support.Servers

  @capabilities %{"elicitation" => %{"form" => %{}}}
  @gate_wait 10_000

  # A close of the connection of a streaming `POST` does not cancel the
  # request, on Bandit and on Cowboy: the callback runs in a process of
  # the framework, which no host server owns. Bandit ends no process at
  # the close; Cowboy ends the process of the connection and the session
  # makes the stream a hand-off. On Cowboy the test waits for the end of
  # the process of the connection (the stream of the request has no live
  # owner then) before it opens the gate, so the close is proved to reach
  # the session while the callback still runs. The callback ends either
  # way and the response goes to the event log of the stream.
  #
  for kind <- [:bandit, :cowboy] do
    @tag http_server: kind
    test "the callback of a streaming POST goes on after the close (#{kind})", %{
      base_url: url,
      instance: instance,
      http_server: kind
    } do
      ref = make_ref()
      Support.Entities.Tools.GateTest.arm(instance, ref)
      on_exit(fn -> Support.Entities.Tools.GateTest.disarm(instance) end)

      client = url |> Client.new() |> Client.ready!()

      {client, resp, sse} =
        Client.stream_request(client, "tools/call", %{
          "name" => "gate",
          "arguments" => %{},
          "_meta" => %{"progressToken" => "p1"}
        })

      request_id = client.next_id - 1

      # The callback runs and the stream is on the wire: the tool
      # reported one step of progress on it.
      #
      assert_receive {^ref, :started, callback}, @gate_wait
      {:ok, %{data: ""}, sse} = Client.next_frame(resp, sse)
      {:ok, progress, _sse} = Client.next_event(resp, sse)
      assert is_binary(progress.id)

      Client.cancel_stream(resp)

      # On Cowboy the close ends the process of the connection at once:
      # wait for the session to see it, with the stream of the request as
      # a hand-off (no live owner) and with the callback still running.
      # The gate opens only then, so the callback cannot end before the
      # close reached the session.
      #
      if kind == :cowboy do
        wait_until("the session to see the end of the connection", fn ->
          case Utils.session_data(instance, client.session_id) do
            nil -> false
            data -> match?([%{owner: nil}], Map.values(data.streams))
          end
        end)

        assert Process.alive?(callback)
      end

      # The callback ends when the test opens the gate.
      #
      send(callback, {:gate, ref})
      assert_receive {^ref, :finished}, @gate_wait

      # The response went to the event log of the stream: a GET with the
      # last event id of the POST stream gets it and the stream ends.
      #
      wait_until("the request of the POST to be over", fn ->
        Utils.session_data(instance, client.session_id).streams == %{}
      end)

      {resp2, sse2} = Client.open_get(client, last_event_id: progress.id)
      {:ok, result, _sse2} = Client.next_event(resp2, sse2)

      assert %{
               "id" => ^request_id,
               "result" => %{"content" => [%{"type" => "text", "text" => "gate done"}]}
             } = JSON.decode!(result.data)

      {:ended, _sse2} = Client.next_frame(resp2, sse2)
    end
  end

  # A plain `POST` whose response stays JSON: the client closes the
  # connection before the answer. The callback still goes on, on Bandit
  # and on Cowboy: a tool call runs in the worker of the request and no
  # host server owns that process. Cowboy ends the process of the
  # connection at the close and the session makes the stream of the
  # request a hand-off; Bandit finds the close at the next write.
  # On Cowboy the test waits for the end of the process of the connection
  # (the stream of the request has no live owner then) before it opens
  # the gate, so the close is proved to reach the session while the
  # callback still runs. Neither server stops the callback and the
  # session stays valid on both.
  #
  for kind <- [:bandit, :cowboy] do
    @tag http_server: kind
    test "the callback of a plain POST goes on after the close (#{kind})", %{
      base_url: url,
      instance: instance,
      http_server: kind
    } do
      ref = make_ref()
      Support.Entities.Tools.GateTest.arm(instance, ref)
      on_exit(fn -> Support.Entities.Tools.GateTest.disarm(instance) end)

      client = url |> Client.new() |> Client.ready!()
      uri = URI.parse(url)

      body =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "gate", "arguments" => %{}}
        })

      headers = [
        {"content-type", "application/json"},
        {"accept", "application/json, text/event-stream"},
        {"origin", "http://localhost"},
        {"mcp-session-id", client.session_id},
        {"mcp-protocol-version", client.protocol_version}
      ]

      {:ok, socket} = RawHttp.connect(uri)
      :ok = RawHttp.request(socket, "POST", uri, headers, body)

      assert_receive {^ref, :started, callback}, @gate_wait

      # The connection is gone before the answer.
      #
      :ok = RawHttp.close(socket)

      # On Cowboy the close ends the process of the connection at once:
      # wait for the session to see it, with the stream of the request as
      # a hand-off (no live owner) and with the callback still running.
      # The gate opens only then, so the callback cannot end before the
      # close reached the session.
      #
      if kind == :cowboy do
        wait_until("the session to see the end of the connection", fn ->
          case Utils.session_data(instance, client.session_id) do
            nil -> false
            data -> match?([%{owner: nil}], Map.values(data.streams))
          end
        end)

        assert Process.alive?(callback)
      end

      send(callback, {:gate, ref})
      assert_receive {^ref, :finished}, @gate_wait

      # The session stays valid: a ping answers.
      #
      {_client, {200, _headers, %{"result" => %{}}}} = Client.request(client, "ping")
    end
  end

  # A request to the client (an elicitation) survives the close of the
  # stream of its POST, on Bandit and on Cowboy: the client resumes the
  # stream with a GET and the last event id, answers the request there
  # and the callback ends with the answer.
  #
  for kind <- [:bandit, :cowboy] do
    @tag http_server: kind
    @tag server: Servers.Outbound
    test "a request to the client stays open after the close of its stream (#{kind})", %{
      base_url: url
    } do
      client = url |> Client.new() |> Client.ready!(capabilities: @capabilities)

      {client, resp1, sse1} =
        Client.stream_request(client, "tools/call", %{
          "name" => "outbound",
          "arguments" => %{"feature" => "elicit_form", "timeout" => @gate_wait}
        })

      request_id = client.next_id - 1

      {:ok, elicitation, _sse1} = Client.next_event(resp1, sse1)
      elicitation_message = JSON.decode!(elicitation.data)
      assert %{"method" => "elicitation/create"} = elicitation_message

      Client.cancel_stream(resp1)

      # The resume replays nothing (the request was the last event) and
      # the live events of the request go to the resumed connection.
      #
      {resp2, sse2} = Client.open_get(client, last_event_id: elicitation.id)

      {_client, {202, _headers, nil}} =
        Client.answer(client, elicitation_message, %{
          "action" => "accept",
          "content" => %{"name" => "Ada"}
        })

      {:ok, answer_event, sse2} = Client.next_event(resp2, sse2)

      assert %{
               "id" => ^request_id,
               "result" => %{"content" => [%{"type" => "text", "text" => text}]}
             } = JSON.decode!(answer_event.data)

      assert text =~ "\"Ada\""

      # The resumed stream ends after the response of the request.
      #
      {:ended, _sse2} = Client.next_frame(resp2, sse2)
    end
  end

  # A `tasks/result` wait is a POST whose response becomes an event
  # stream at the first idle interval. The close of its connection does
  # not touch the task, on Bandit and on Cowboy: the task stays working
  # and a later wait reads the outcome.
  #
  for kind <- [:bandit, :cowboy] do
    @tag http_server: kind
    @tag server_opts: %{sse_heartbeat_ms: 100}
    test "a tasks/result wait survives the close of its connection (#{kind})", %{
      base_url: url
    } do
      client = url |> Client.new() |> Client.ready!()

      {client, {200, _headers, %{"result" => %{"task" => %{"taskId" => task_id}}}}} =
        Client.request(client, "tools/call", %{"name" => "task_slow", "task" => %{}})

      # The wait becomes an event stream at the first idle interval.
      #
      {client, resp1, sse1} =
        Client.stream_request(client, "tasks/result", %{"taskId" => task_id})

      assert {:ok, %{data: "", id: _priming}, _sse1} = Client.next_frame(resp1, sse1)

      Client.cancel_stream(resp1)

      # The task is not touched.
      #
      assert task_status(client, task_id) == "working"

      # The runner of the task is not up at once: wait for it, so the
      # finish below reaches it (a finish for a runner that is not up
      # is lost and the tool ends at its safety timeout).
      #
      wait_until("the runner of the task to run", fn ->
        Support.Entities.Tools.TaskSlowTest.last_runner_pid() != nil
      end)

      # The task ends and a later wait reads the outcome.
      #
      Support.Entities.Tools.TaskSlowTest.finish()

      wait_until("the task to be completed", fn ->
        task_status(client, task_id) == "completed"
      end)

      {_client, {200, _headers, body}} =
        Client.request(client, "tasks/result", %{"taskId" => task_id})

      assert %{"result" => result} = result_message(body)
      assert result["content"] == [%{"type" => "text", "text" => "slow done"}]
    end
  end

  # The way each server finds a gone client when no event is in flight:
  # on Bandit the write of the first heartbeat fails and the session
  # gives the stream up then. On Cowboy the close of the connection ends
  # the process of the request at once and the session sees it with no
  # write at all. The wait bounds the detection of each server at two
  # seconds.
  #
  for {kind, heartbeat} <- [bandit: 100, cowboy: :infinity] do
    @tag http_server: kind
    @tag server_opts: %{sse_heartbeat_ms: heartbeat}
    test "the session finds a closed GET stream (#{kind})", %{base_url: url, instance: instance} do
      client = url |> Client.new() |> Client.ready!()
      {resp, _sse} = Client.open_get(client)
      Client.cancel_stream(resp)

      # No event is sent: only the server itself can find the close.
      #
      wait_until(
        "the session to give the stream up",
        fn ->
          match?({:ok, %{stream?: false}}, Sessions.delivery(instance, client.session_id))
        end,
        200
      )
    end
  end

  # The listener of Cowboy closes a connection after `idle_timeout` with
  # no bytes from the client, also while a response streams: the
  # heartbeats of the server do not hold it, unless every write resets
  # the timer. These two cases fix the options of the listener that a
  # mount on Cowboy needs: `idle_timeout` above the heartbeat interval
  # and `reset_idle_timeout_on_send: true` for the streams.
  #
  @tag http_server: :cowboy
  @tag http_server_opts: [protocol_options: [idle_timeout: 500]]
  @tag server_opts: %{sse_heartbeat_ms: 100}
  test "an idle timeout of the Cowboy listener ends a GET stream although the heartbeats write",
       %{
         base_url: url,
         instance: instance
       } do
    client = url |> Client.new() |> Client.ready!()
    {resp, _sse} = Client.open_get(client)

    # The listener closes the response after about one idle timeout: the
    # client sees the end of it.
    #
    start = System.monotonic_time(:millisecond)
    :ok = await_connection_closed(resp, 3_000)
    elapsed = System.monotonic_time(:millisecond) - start

    # About one idle timeout after the request: not the close of a write.
    #
    assert elapsed in 300..2_500

    # The end of the request process reaches the session at once.
    #
    wait_until(
      "the session to give the stream up",
      fn ->
        match?({:ok, %{stream?: false}}, Sessions.delivery(instance, client.session_id))
      end,
      200
    )
  end

  @tag http_server: :cowboy
  @tag http_server_opts: [
         protocol_options: [idle_timeout: 500, reset_idle_timeout_on_send: true]
       ]
  @tag server_opts: %{sse_heartbeat_ms: 100}
  test "a GET stream of the Cowboy listener stays open when every write resets the idle timeout",
       %{
         base_url: url,
         instance: instance
       } do
    client = url |> Client.new() |> Client.ready!()
    {resp, _sse} = Client.open_get(client)

    # Sixteen heartbeats in a row, one heartbeat interval apart: every
    # write resets the idle timer of the listener, so the stream stays
    # open far past the idle timeout.
    #
    assert_heartbeats(resp, 16)

    assert {:ok, %{stream?: true}} = Sessions.delivery(instance, client.session_id)
  end

  defp task_status(client, task_id) do
    case Client.request(client, "tasks/get", %{"taskId" => task_id}) do
      {_client, {200, _headers, %{"result" => %{"status" => status}}}} -> status
      _other -> nil
    end
  end

  # The answer of a `tasks/result` wait is JSON when the task is done at
  # once and SSE when the wait lasted for one heartbeat.
  #
  defp result_message(%{} = message), do: message

  defp result_message(events) when is_list(events) do
    events
    |> Enum.reject(&(&1.data == ""))
    |> List.last()
    |> Map.fetch!(:data)
    |> JSON.decode!()
  end

  # Waits until the host server closes the connection of the response:
  # the end arrives as a clean end of the response (`:done`), or as a
  # transport error of the client (the connection was cut, not ended).
  #
  defp await_connection_closed(resp, timeout)

  defp await_connection_closed(%Req.Response{body: %Req.Response.Async{ref: ref}} = resp, timeout) do
    receive do
      {^ref, _} = message ->
        case Req.parse_message(resp, message) do
          {:ok, chunks} ->
            if :done in chunks, do: :ok, else: await_connection_closed(resp, timeout)

          {:error, _reason} ->
            :ok

          :unknown ->
            await_connection_closed(resp, timeout)
        end
    after
      timeout -> flunk("the host server did not close the connection")
    end
  end

  # Reads the raw chunks of the stream until the given number of
  # heartbeat comments arrived (the priming event and the retry hint
  # come first). `tries` bounds the read of non-heartbeat chunks, so a
  # stream that writes nothing but heartbeats never blocks the test.
  #
  defp assert_heartbeats(resp, count, tries \\ 30)

  defp assert_heartbeats(_resp, 0, _tries), do: :ok

  defp assert_heartbeats(_resp, _count, 0), do: flunk("no heartbeat arrived on the stream")

  defp assert_heartbeats(resp, count, tries) do
    case Client.next_raw(resp, 1_000) do
      {:ok, data} ->
        if String.contains?(data, ": heartbeat"),
          do: assert_heartbeats(resp, count - 1, tries),
          else: assert_heartbeats(resp, count, tries - 1)

      :ended ->
        flunk("the stream ended before #{count} heartbeats arrived")
    end
  end
end
