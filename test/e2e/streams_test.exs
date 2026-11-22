#
# The GET stream of the session over the wire: the notifications of the
# server reach it while it is open, the heartbeats keep an idle stream
# alive and the close of a poll gives a `retry` hint for the reconnect.
#
defmodule OzMcp.E2E.StreamsTest do
  use OzMcp.E2ECase, async: true

  test "an open GET stream carries the notifications of the server", %{
    base_url: url,
    instance: instance
  } do
    client = url |> Client.new() |> Client.ready!()
    {resp, sse} = Client.open_get(client)

    :ok = Support.Helpers.Broadcast.notify_all(instance)

    {:ok, event, _sse} = Client.next_event(resp, sse)

    assert %{"method" => "notifications/tools/list_changed"} = JSON.decode!(event.data)

    # An event of the GET stream has an id of its own: it names the GET
    # stream (`g.<stream>:<n>`), so a resume replays this stream only.
    #
    assert String.match?(event.id, ~r/^g\.[0-9a-zA-Z]+:\d+$/)
  end

  @tag server_opts: %{sse_heartbeat_ms: 100}
  test "an idle GET stream is kept alive with heartbeat comments", %{
    base_url: url,
    instance: _instance
  } do
    client = url |> Client.new() |> Client.ready!()
    {resp, _sse} = Client.open_get(client)

    {:ok, chunk} = wait_heartbeat(resp, 50)

    assert chunk =~ ": heartbeat"
  end

  @tag server_opts: %{sse_max_stream_ms: 300}
  test "a GET stream of a polling client closes itself with a retry hint", %{
    base_url: url,
    instance: _instance
  } do
    client = url |> Client.new() |> Client.ready!()
    {resp, sse} = Client.open_get(client)

    {:ended, frames, _sse} = Client.drain(resp, sse, 10_000)

    # The stream opens with a retry hint and a priming event and the poll
    # close ends it with a retry hint: the client connects again with the
    # id of the last event it saw and the log replays the gap.
    #
    assert [%{retry: 1000, data: ""}, %{data: ""}, %{retry: 1000, data: ""}] = frames
  end

  test "the events of a POST stream have ids that are unique and increase", %{
    base_url: url,
    instance: _instance
  } do
    client = url |> Client.new() |> Client.ready!()

    {_client, resp, sse} =
      Client.stream_request(client, "tools/call", %{
        "name" => "progress",
        "arguments" => %{},
        "_meta" => %{"progressToken" => "p1"}
      })

    # The stream ends with the response of the request.
    #
    {:ended, frames, _sse} = Client.drain(resp, sse, 10_000)

    # The ids on the wire are unique and strictly increase: the priming
    # event holds the position 0 of the stream, the events that the
    # session numbered follow and the response is the last event.
    #
    assert [%{id: priming, data: ""} | events] = for(frame <- frames, frame.id, do: frame)

    assert priming =~ ~r/\A[0-9a-zA-Z]+:0\z/
    stream_id = String.split(priming, ":") |> hd()

    assert Enum.map(events, & &1.id) == Enum.map(1..length(events), &"#{stream_id}:#{&1}")

    # The response of the request is the last event of the stream.
    #
    assert %{"id" => _, "result" => %{"content" => [%{"type" => "text"}]}} =
             JSON.decode!(List.last(events).data)
  end

  @max_streams 2

  @tag server_opts: %{max_streams_per_session: @max_streams}
  test "a client that opens and drops GET streams over the limit always gets 200", %{
    base_url: url
  } do
    client = url |> Client.new() |> Client.ready!()

    for _ <- 1..(@max_streams + 2) do
      {resp, _sse} = Client.open_get(client)
      assert resp.status == 200
      Client.cancel_stream(resp)
    end
  end

  @tag server_opts: %{max_streams_per_session: @max_streams}
  test "the ring of a replaced stream survives for the resume", %{
    base_url: url,
    instance: instance
  } do
    client = url |> Client.new() |> Client.ready!()

    {resp1, sse1} = Client.open_get(client)
    assert resp1.status == 200

    :ok = Support.Helpers.Broadcast.notify_all(instance)
    {:ok, event, _sse1} = Client.next_event(resp1, sse1)
    stream_id = event.id |> String.split(":") |> hd()
    priming = "#{stream_id}:0"

    Client.cancel_stream(resp1)

    # The opens that follow push the ended stream out of the live set, so
    # its ring goes into the closed streams of the session.
    #
    for _ <- 1..(@max_streams + 1) do
      {resp, _sse} = Client.open_get(client)
      assert resp.status == 200
      Client.cancel_stream(resp)
    end

    # The resume replays the event that the ring of the ended stream keeps.
    #
    {resume, resume_sse} = Client.open_get(client, last_event_id: priming)
    assert resume.status == 200

    {:ok, replayed, _resume_sse} = Client.next_event(resume, resume_sse)
    assert replayed.id == event.id
    assert JSON.decode!(replayed.data) == JSON.decode!(event.data)

    Client.cancel_stream(resume)
  end

  @tag server_opts: %{max_streams_per_session: @max_streams}
  test "a GET over the limit ends the oldest stream with a last retry hint", %{
    base_url: url
  } do
    client = url |> Client.new() |> Client.ready!()

    {resp1, sse1} = Client.open_get(client)
    assert resp1.status == 200

    # The stream opens with a retry hint and a priming event.
    #
    {:ok, %{retry: 1000, data: ""}, sse1} = Client.next_frame(resp1, sse1)
    {:ok, %{id: _priming, data: ""}, sse1} = Client.next_frame(resp1, sse1)

    {resp2, _sse2} = Client.open_get(client)
    assert resp2.status == 200

    # A third GET over the limit of two ends the first stream: it writes
    # a last retry hint and its response ends.
    #
    {resp3, _sse3} = Client.open_get(client)
    assert resp3.status == 200

    {:ok, %{retry: 1000, data: ""}, sse1} = Client.next_frame(resp1, sse1)
    assert {:ended, _sse1} = Client.next_frame(resp1, sse1)

    Client.cancel_stream(resp2)
    Client.cancel_stream(resp3)
  end

  defp wait_heartbeat(_resp, 0), do: flunk("no heartbeat comment on the stream")

  defp wait_heartbeat(resp, left) do
    case Client.next_raw(resp, 2_000) do
      {:ok, chunk} ->
        if String.contains?(chunk, ": heartbeat"),
          do: {:ok, chunk},
          else: wait_heartbeat(resp, left - 1)

      :ended ->
        flunk("the stream ended before a heartbeat")
    end
  end
end
