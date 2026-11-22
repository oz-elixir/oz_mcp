#
# The resource bounds of the server over the wire: the size of the body
# of a `POST`, the number of the subscriptions of one session and the
# number of the event logs of one session.
#
defmodule OzMcp.E2E.ResourceBoundsTest do
  use OzMcp.E2ECase, async: true

  alias Support.Helpers.SessionLeak

  test "a body over the limit gets 413 with the error envelope and the endpoint stays usable", %{
    base_url: url
  } do
    uri = URI.parse(url)

    # The default limit is 1 MiB: a body of 2 MiB is over it. The read
    # stops at the limit, before the decode, so the body need not be
    # valid JSON.
    #
    {:ok, status, response} = RawHttp.post(uri, String.duplicate("x", 2 * 1024 * 1024))

    assert String.starts_with?(status, "HTTP/1.1 413")
    assert response =~ "request body too large"
    assert response =~ "-32600"

    # The refused request leaves the bytes that the server did not read on
    # its connection, so the client opens a new connection for the next
    # request. The endpoint answers it.
    #
    ping =
      ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"e2e","version":"0.0.0"}}})

    {:ok, status, response} = RawHttp.post(uri, ping)

    assert String.starts_with?(status, "HTTP/1.1 200")
    assert response =~ "protocolVersion"
  end

  @tag server_opts: %{max_subscriptions_per_session: 2}
  test "a third subscription of a new uri gets the error -32000 in a 200 answer", %{base_url: url} do
    client = url |> Client.new() |> Client.ready!()

    {client, {200, _h, %{"result" => %{}}}} =
      Client.request(client, "resources/subscribe", %{"uri" => "file:///marketing.md"})

    {client, {200, _h, %{"result" => %{}}}} =
      Client.request(client, "resources/subscribe", %{"uri" => "file:///gamma/1.md"})

    {_client, {200, _h, %{"error" => error}}} =
      Client.request(client, "resources/subscribe", %{"uri" => "file:///gamma/2.md"})

    assert error == %{
             "code" => -32000,
             "message" => "too many subscriptions",
             "data" => %{"limit" => "max_subscriptions_per_session"}
           }
  end

  @tag server_opts: %{sse_event_log_max_streams: 2}
  test "a session that runs four calls with an SSE answer keeps at most two event logs", %{
    base_url: url,
    instance: instance
  } do
    #
    # One session runs the four calls: the logs of all the streams pile
    # up in the log of this session only.
    #
    client =
      url
      |> Client.new()
      |> Client.ready!()
      |> run_calls(4)

    session_id = client.session_id
    assert {:ok, view} = OzMcp.Sessions.lookup(instance, session_id)

    size = MapSet.size(SessionLeak.snapshot(view.pid).log_streams)
    assert size in 1..2
  end

  defp run_calls(client, count) do
    Enum.reduce(1..count, client, fn _n, client ->
      {client, resp, sse} =
        Client.stream_request(client, "tools/call", %{
          "name" => "progress",
          "arguments" => %{},
          "_meta" => %{"progressToken" => "p1"}
        })

      {:ended, _frames, _sse} = Client.drain(resp, sse, 10_000)
      client
    end)
  end
end
