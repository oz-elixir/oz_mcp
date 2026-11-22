#
# The event log of a POST stream that is over goes away after the resume
# window: the memory of the ended streams does not pile up in the session.
#
defmodule OzMcp.E2E.LogRetentionTest do
  use OzMcp.E2ECase, async: true

  alias OzMcp.Sessions
  alias Support.Helpers.SessionLeak

  @tag server_opts: %{sse_resume_window_ms: 1_000}
  test "the event logs of the ended POST streams go away after the resume window", %{
    base_url: url,
    instance: instance
  } do
    #
    # One session runs the 20 calls: the rings of all the ended streams
    # pile up in the log of this session only.
    #
    client =
      url
      |> Client.new()
      |> Client.ready!()
      |> run_calls(20)

    session_id = client.session_id
    assert {:ok, view} = Sessions.lookup(instance, session_id)

    # Positive control: inside the window the rings of the ended streams
    # are still there.
    #
    assert MapSet.size(SessionLeak.snapshot(view.pid).log_streams) > 0

    wait_until("the log of the ended streams to go away", fn ->
      {:ok, view} = Sessions.lookup(instance, session_id)
      snap = SessionLeak.snapshot(view.pid)

      MapSet.size(snap.log_streams) == 0 and snap.streams == 0 and snap.refs == 0 and
        snap.closed_gets == 0
    end)

    assert {:ok, view} = Sessions.lookup(instance, session_id)
    snap = SessionLeak.snapshot(view.pid)

    assert MapSet.size(snap.log_streams) == 0
    assert snap.streams == 0
    assert snap.refs == 0
    assert snap.closed_gets == 0
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
