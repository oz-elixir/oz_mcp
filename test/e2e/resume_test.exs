#
# The resumability of the streams over the wire: a client that lost its
# connection reconnects with a `Last-Event-ID` and the event log gives
# the events the gap hid. A resume of the stream of a POST also gets the
# response of the request and the stream ends after it.
#
defmodule OzMcp.E2E.ResumeTest do
  use OzMcp.E2ECase, async: true

  alias OzMcp.Sessions
  alias Support.Helpers.Utils
  alias Support.Servers

  @capabilities %{
    "elicitation" => %{"form" => %{}, "url" => %{}},
    "sampling" => %{},
    "roots" => %{}
  }

  @answer_timeout 10_000

  test "a GET that reconnects with its Last-Event-ID gets the events it missed", %{
    base_url: url,
    instance: instance
  } do
    client = url |> Client.new() |> Client.ready!()
    {resp1, sse1} = Client.open_get(client)

    :ok = Support.Helpers.Broadcast.notify_all(instance)
    {:ok, first, _sse1} = Client.next_event(resp1, sse1)

    # The client loses the stream. The server gives the stream up when a
    # write to it fails: the notifications below wake it until then. Each
    # one goes to the event log, so the reconnect replays the gap.
    #
    Client.cancel_stream(resp1)

    wait_until("the session has no stream", fn ->
      :ok = Support.Helpers.Broadcast.notify_all(instance)

      match?(
        {:ok, %{stream?: false}},
        Sessions.delivery(instance, client.session_id)
      )
    end)

    # The notification of the gap: no stream is open, so it goes to the
    # event log only.
    #
    :ok = Support.Helpers.Broadcast.notify_all(instance)

    # The reconnect: the log replays the two notifications of the gap,
    # oldest first.
    #
    {resp2, sse2} = Client.open_get(client, last_event_id: first.id)
    {:ok, replayed, sse2} = Client.next_event(resp2, sse2)
    assert %{"method" => "notifications/tools/list_changed"} = JSON.decode!(replayed.data)
    assert replayed.id != first.id

    # The stream is live again.
    #
    :ok = Support.Helpers.Broadcast.notify_all(instance)
    {:ok, live, _sse} = Client.next_event(resp2, sse2)
    assert live.id != replayed.id
  end

  @tag server_opts: %{sse_heartbeat_ms: 50}
  test "a resume of one GET stream replays its own events only", %{
    base_url: url,
    instance: instance
  } do
    client = url |> Client.new() |> Client.ready!()

    {resp_a, sse_a} = Client.open_get(client)
    :ok = Support.Helpers.Broadcast.notify_all(instance)
    {:ok, a1, _sse_a} = Client.next_event(resp_a, sse_a)

    # A second GET stream: the notifications go to it only.
    #
    {resp_b, sse_b} = Client.open_get(client)
    :ok = Support.Helpers.Broadcast.notify_all(instance)
    {:ok, _b1, _sse_b} = Client.next_event(resp_b, sse_b)

    # The connection of the first stream is gone. The server gives the
    # stream up when a write to it fails: the notifications below wake it
    # until then.
    #
    Client.cancel_stream(resp_a)

    wait_until("the session has one stream", fn ->
      match?({:ok, %{streams: 1}}, Sessions.lookup(instance, client.session_id))
    end)

    # The reconnect with the id of the first stream: it replays nothing of
    # the second one and the stream keeps its id and its counter.
    #
    {resp_c, sse_c} = Client.open_get(client, last_event_id: a1.id)

    :ok = Support.Helpers.Broadcast.notify_all(instance)
    {:ok, live, _sse_c} = Client.next_event(resp_c, sse_c)

    [a_stream, "1"] = String.split(a1.id, ":")
    [resumed_stream, "2"] = String.split(live.id, ":")
    assert resumed_stream == a_stream
    assert String.starts_with?(resumed_stream, "g.")
  end

  test "a Last-Event-ID that is not in the log starts a fresh stream and warns", %{
    base_url: url,
    instance: instance
  } do
    client = url |> Client.new() |> Client.ready!()

    {_result, log} =
      ExUnit.CaptureLog.with_log(fn ->
        stream = Client.open_get(client, last_event_id: "no-such-id")
        send(self(), {:stream, stream})
        :ok
      end)

    assert log =~ "Last-Event-ID"

    {resp, sse} =
      receive do
        {:stream, stream} -> stream
      end

    # The stream is fresh: it starts from the position after the attach.
    #
    :ok = Support.Helpers.Broadcast.notify_all(instance)
    {:ok, event, _sse} = Client.next_event(resp, sse)
    assert %{"method" => "notifications/tools/list_changed"} = JSON.decode!(event.data)
  end

  test "a notification before the first GET stream waits for it", %{
    base_url: url,
    instance: instance
  } do
    client = url |> Client.new() |> Client.ready!()

    # No GET stream is open: the notification waits for the first one
    # and the client gets it on the stream it opens.
    #
    :ok = Support.Helpers.Broadcast.notify_all(instance)

    {resp, sse} = Client.open_get(client)
    {:ok, event, _sse} = Client.next_event(resp, sse)
    assert %{"method" => "notifications/tools/list_changed"} = JSON.decode!(event.data)

    # The stream is live: the next notification goes out on it at once.
    #
    :ok = Support.Helpers.Broadcast.notify_all(instance)
    {:ok, live, _sse} = Client.next_event(resp, sse)
    assert live.id != event.id
  end

  @tag server: Servers.Outbound
  test "a GET resumes the stream of a POST request and gets the rest and the response", %{
    base_url: url
  } do
    client = url |> Client.new() |> Client.ready!(capabilities: @capabilities)

    {client, resp1, sse1} = call_outbound(client, "elicit_form")

    {:ok, elicitation, _sse1} = Client.next_event(resp1, sse1)
    elicitation_message = JSON.decode!(elicitation.data)
    assert %{"method" => "elicitation/create"} = elicitation_message

    # The ids of the events of a POST stream are `<stream id>:<n>`: the id
    # of the first event tells the stream the client resumes.
    #
    assert [_stream_id, "1"] = String.split(elicitation.id, ":")

    # The connection of the request is gone. The framework does not cancel
    # the request: the callback goes on.
    #
    Client.cancel_stream(resp1)

    # A GET resumes the stream of the POST: it gets the events after the id
    # of the client, then the response of the request.
    #
    {resp2, sse2} = Client.open_get(client, last_event_id: elicitation.id)

    {_client, {202, _headers, nil}} =
      Client.answer(client, elicitation_message, %{
        "action" => "accept",
        "content" => %{"name" => "Ada"}
      })

    {:ok, answer_event, _sse} = Client.next_event(resp2, sse2)

    assert %{"id" => 2, "result" => %{"content" => [%{"text" => text}]}} =
             JSON.decode!(answer_event.data)

    assert text =~ "\"Ada\""

    # The resumed stream ends after the response of the request.
    #
    {:ended, _sse} = Client.next_frame(resp2, sse2)
  end

  @tag server: Servers.Outbound
  test "a resume of the first stream between two requests of one connection does not fail the second stream",
       %{base_url: url} do
    #
    # HTTP/1.1 keep-alive: the host server may run the two POST requests of
    # one connection in the same handler process (Bandit does), or in a new
    # process per request (Cowboy does). The takeover of the first stream
    # carries the id of that stream: a message that reaches a process late
    # is dropped by the stream of the second request, whose id is a
    # different one.
    #
    keep_alive = :"e2e_keep_alive_#{System.unique_integer([:positive])}"
    start_supervised!({Finch, name: keep_alive, pools: %{default: [size: 1, count: 1]}})

    client =
      url |> Client.new() |> Client.ready!(capabilities: @capabilities, finch: keep_alive)

    # The first request: its callback waits for an elicitation.
    #
    {client, resp1, sse1} = call_outbound(client, "elicit_form", finch: keep_alive)
    {:ok, elicitation, sse1} = Client.next_event(resp1, sse1)

    # A resume of the first stream between the two requests: the stream is
    # taken over, the events of the request go to the resumed connection.
    #
    {resp2, sse2} = Client.open_get(client, last_event_id: elicitation.id)

    {client, {202, _headers, nil}} =
      Client.answer(client, JSON.decode!(elicitation.data), %{
        "action" => "accept",
        "content" => %{"name" => "Ada"}
      })

    # The first request is complete: its response went to the resumed
    # connection and its own connection is free for the next request.
    #
    {:ok, _response1, _sse} = Client.next_event(resp2, sse2)
    {:ended, _sse} = Client.next_frame(resp2, sse2)
    {:ended, _frames1, _sse1} = Client.drain(resp1, sse1, 10_000)

    # The second request reuses the connection (a pool of one connection).
    #
    {client, resp3, sse3} = call_outbound(client, "elicit_form", finch: keep_alive)
    {:ok, elicitation2, sse3} = Client.next_event(resp3, sse3)
    assert %{"method" => "elicitation/create"} = JSON.decode!(elicitation2.data)

    {_client, {202, _headers, nil}} =
      Client.answer(client, JSON.decode!(elicitation2.data), %{
        "action" => "accept",
        "content" => %{"name" => "Grace"}
      })

    {:ok, answer_event, _sse} = Client.next_event(resp3, sse3)

    assert %{"id" => 3, "result" => %{"content" => [%{"text" => text}]}} =
             JSON.decode!(answer_event.data)

    assert text =~ "\"Grace\""
    {:ended, _sse} = Client.next_frame(resp3, sse3)
  end

  test "the resume of an ended stream writes no retry field", %{
    base_url: url,
    instance: instance
  } do
    client = url |> Client.new() |> Client.ready!()

    {client, resp1, sse1} =
      Client.stream_request(client, "tools/call", %{
        "name" => "progress",
        "arguments" => %{},
        "_meta" => %{"progressToken" => "p1"}
      })

    # The request is complete: the stream of its POST is over and the log
    # holds its events (the priming event, two progress notifications, the
    # response).
    #
    {:ended, frames1, _sse} = Client.drain(resp1, sse1, 10_000)
    [_priming, progress1, _progress2, _response] = frames1

    # Wait for the session to see the end of the stream: the resume of an
    # over stream replays and ends, it does not stay open.
    #
    wait_until("the session has no POST stream", fn ->
      Utils.session_data(instance, client.session_id).streams == %{}
    end)

    {resp2, sse2} = Client.open_get(client, last_event_id: progress1.id)
    {:ended, frames2, _sse} = Client.drain(resp2, sse2, 10_000)

    # No retry field: the stream is over, the client must not connect again.
    #
    assert Enum.all?(frames2, &is_nil(&1.retry))
    assert length(frames2) == 2

    assert %{"id" => 2, "result" => %{"content" => [%{"text" => "progress done"}]}} =
             JSON.decode!(List.last(frames2).data)
  end

  @tag server: Servers.Outbound
  @tag server_opts: %{sse_max_stream_ms: 500, sse_retry_ms: 250}
  test "a resume of a live POST stream closes at sse_max_stream_ms and a second resume gets the rest",
       %{base_url: url} do
    client = url |> Client.new() |> Client.ready!(capabilities: @capabilities)

    {client, resp1, sse1} = call_outbound(client, "elicit_form")

    {:ok, elicitation, _sse1} = Client.next_event(resp1, sse1)
    elicitation_message = JSON.decode!(elicitation.data)

    # The resume takes the live stream over and closes itself at
    # sse_max_stream_ms: the opening retry hint, then the closing one.
    #
    {resp2, sse2} = Client.open_get(client, last_event_id: elicitation.id)
    {:ended, frames2, _sse2} = Client.drain(resp2, sse2, 10_000)

    assert %{retry: 250} = List.last(frames2)

    refute Enum.any?(frames2, fn frame ->
             frame.data != "" and String.contains?(frame.data, "\"result\"")
           end)

    last_id = last_event_id(frames2, elicitation.id)

    {_client, {202, _headers, nil}} =
      Client.answer(client, elicitation_message, %{
        "action" => "accept",
        "content" => %{"name" => "Grace"}
      })

    # The second resume from the last id gets the response.
    #
    {resp3, sse3} = Client.open_get(client, last_event_id: last_id)

    {answer, _sse3} = wait_for_answer(resp3, sse3, 2)

    assert %{"id" => 2, "result" => %{"content" => [%{"text" => text}]}} = answer
    assert text =~ "\"Grace\""

    {:ended, _sse3} = Client.next_frame(resp3, sse3)

    # The first connection ends too: the stream was taken over.
    #
    {:ended, _frames1, _sse1} = Client.drain(resp1, sse1, 10_000)
  end

  defp last_event_id(frames, default) do
    frames
    |> Enum.reverse()
    |> Enum.find_value(default, fn frame -> frame.id end)
  end

  defp wait_for_answer(resp, sse, request_id, tries \\ 40)

  defp wait_for_answer(_resp, _sse, _request_id, 0),
    do: flunk("no result arrived on the resumed stream")

  defp wait_for_answer(resp, sse, request_id, tries) do
    case Client.next_event(resp, sse, 5_000) do
      {:ok, event, sse} ->
        case JSON.decode!(event.data) do
          %{"id" => ^request_id} = answer -> {answer, sse}
          _other -> wait_for_answer(resp, sse, request_id, tries - 1)
        end

      {:ended, _sse} ->
        flunk("the resumed stream ended before the result")
    end
  end

  defp call_outbound(client, feature, opts \\ []) do
    Client.stream_request(
      client,
      "tools/call",
      %{
        "name" => "outbound",
        "arguments" => %{"feature" => feature, "timeout" => @answer_timeout}
      },
      opts
    )
  end
end
