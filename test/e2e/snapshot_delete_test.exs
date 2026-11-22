#
# The end of a session with a snapshot store that answers slowly, over a
# real connection: the `DELETE` request answers before the delete of the
# store ended, a request with the id of the ended session gives `404`
# with no read of the store and the telemetry holds the outcome of the
# marked id.
#
defmodule OzMcp.E2E.SnapshotDeleteTest do
  use OzMcp.E2ECase, async: true

  alias Support.Helpers.PersistentSnapshot
  alias Support.Helpers.TelemetryCapture
  alias Support.Helpers.Utils

  @tag server_opts: %{session_snapshot: PersistentSnapshot}
  test "a slow delete does not hold DELETE and the ended id restores no session", %{
    base_url: url,
    instance: instance
  } do
    ref = TelemetryCapture.attach()
    PersistentSnapshot.slow(instance, :delete, 10_000)

    client = url |> Client.new() |> Client.ready!()
    assert wait_snapshot(instance, client.session_id)

    {duration, {_client, {200, _headers, nil}}} = :timer.tc(fn -> Client.delete(client) end)
    assert duration < 1_000_000

    # The store still holds the snapshot (the delete of the store runs):
    # a request with the id of the ended session gives 404 and reads the
    # store zero times.
    #
    assert PersistentSnapshot.get(instance, client.session_id) != nil

    {_client, {404, _headers, %{"error" => %{"code" => -32001, "message" => "invalid session"}}}} =
      Client.request(client, "ping")

    assert PersistentSnapshot.calls(instance, :load) == 0

    # The read of the marked id tells its own outcome.
    #
    assert [%{outcome: :deleted}] =
             ref
             |> TelemetryCapture.drain(instance)
             |> Enum.filter(fn {name, _, _} -> name == [:oz_mcp, :session, :restore] end)
             |> Enum.map(&elem(&1, 2))
  end

  # The write of a snapshot runs in the writer of the instance, after
  # the change of the session: the test waits for the store.
  #
  defp wait_snapshot(instance, session_id) do
    assert Utils.eventually(fn -> PersistentSnapshot.get(instance, session_id) != nil end)
    :ok
  end
end
