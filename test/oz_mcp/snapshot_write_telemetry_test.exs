#
# The `snapshot write` event: the time and the outcome of each write of
# the snapshot store. The writer of the instance runs the saves and the
# deletes: a save runs for a change of a session, a delete runs after
# the end of the session.
# The metadata holds the action and the result only, next to the keys
# that every event carries: no snapshot and no session id goes out.
#
defmodule OzMcp.SnapshotWriteTelemetryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias OzMcp.Sessions
  alias Support.Helpers.PersistentSnapshot
  alias Support.Helpers.TelemetryCapture
  alias Support.Helpers.Utils
  alias Support.Servers

  @server_module Servers.Default

  setup do
    ref = TelemetryCapture.attach()
    name = Module.concat(@server_module, "W#{System.unique_integer([:positive])}")
    Utils.start_instance(@server_module, name: name, session_snapshot: PersistentSnapshot)

    %{ref: ref, instance: name}
  end

  test "a write that the store took gives the action save and the result ok", %{
    ref: ref,
    instance: instance
  } do
    session_id = Utils.create_session(instance, initialized: true)
    assert wait_until(fn -> PersistentSnapshot.get(instance, session_id) != nil end)

    assert [event] = write_events(ref, instance, :save)
    {_, measurements, meta} = event

    assert meta.action == :save
    assert meta.result == :ok
    assert meta.instance == instance
    assert meta.server == @server_module
    assert is_integer(measurements.duration) and measurements.duration >= 0
  end

  test "a write that the store refused gives the result error", %{ref: ref, instance: instance} do
    PersistentSnapshot.fail(instance, :save, :raise)

    log =
      capture_log(fn ->
        #
        # The capture is open before the session starts: the save of the
        # start runs in a task of the writer and its log can come before
        # the call of create_session/2 answers.
        #
        _session_id = Utils.create_session(instance, initialized: true)

        assert wait_until(fn -> PersistentSnapshot.calls(instance, :save) >= 1 end)

        # The event of the write keeps the capture open until the log of
        # the failure ran: the guard logs before the writer emits the
        # event. The event goes back to the mailbox for the drain below.
        #
        assert_receive {[:oz_mcp, :snapshot, :write] = name, ^ref, measurements,
                        %{instance: ^instance, action: :save, result: :error} = meta},
                       5_000

        send(self(), {name, ref, measurements, meta})
      end)

    assert log =~ "session snapshot save failed"

    assert [event] = write_events(ref, instance, :save)
    {_, _measurements, meta} = event

    assert meta.action == :save
    assert meta.result == :error
    assert meta.instance == instance
    assert meta.server == @server_module
  end

  test "a write that the end of the session stopped gives the result stopped", %{
    ref: ref,
    instance: instance
  } do
    #
    # A store that blocks longer than the time limit of a save. The end
    # of the session hands the delete to the writer and answers: the
    # writer stops the save at the time limit and tells it with the
    # event and the delete runs after that.
    #
    PersistentSnapshot.slow(instance, :save, 10_000)

    session_id = Utils.create_session(instance, initialized: true)
    assert wait_until(fn -> PersistentSnapshot.calls(instance, :save) >= 1 end)

    {_id, pid} = session_process(instance, session_id)
    down_ref = Process.monitor(pid)

    log =
      capture_log(fn ->
        assert :ok = Sessions.terminate(instance, session_id)
        assert_receive {:DOWN, ^down_ref, :process, ^pid, _reason}

        # The stop of the save comes at the time limit, after the end of
        # the session and the delete event comes after that. The wait
        # of the event keeps the capture open until the log ran. The
        # event goes back to the mailbox for the drain below.
        #
        assert_receive {[:oz_mcp, :snapshot, :write] = name, ^ref, measurements,
                        %{instance: ^instance, action: :delete} = meta},
                       10_000

        send(self(), {name, ref, measurements, meta})
      end)

    assert log =~ "session snapshot save stopped"

    events = TelemetryCapture.drain(ref, instance)
    writes = Enum.filter(events, fn {name, _, _} -> name == [:oz_mcp, :snapshot, :write] end)

    assert %{stopped: 1, ok: 1} =
             Enum.frequencies_by(writes, fn {_name, _m, meta} -> meta.result end),
           "the events of the writes: #{inspect(writes)}"

    for {_, measurements, meta} <- writes do
      assert meta.action in [:save, :delete]
      assert is_integer(measurements.duration) and measurements.duration >= 0
      assert meta.instance == instance
      assert meta.server == @server_module
      assert MapSet.new(Map.keys(meta)) == MapSet.new([:instance, :server, :action, :result])
    end

    assert {_, delete_measurements, _} =
             Enum.find(writes, fn {_name, _m, meta} -> meta.action == :delete end)

    save_native = System.convert_time_unit(3_000, :millisecond, :native)

    assert delete_measurements.duration < save_native,
           "the time of the delete holds the wait for the stopped save " <>
             "(#{delete_measurements.duration} >= #{save_native})"
  after
    PersistentSnapshot.clear_slow(instance, :save)
  end

  test "the end of a session gives the action delete and the result ok", %{
    ref: ref,
    instance: instance
  } do
    session_id = Utils.create_session(instance, initialized: true)
    assert wait_until(fn -> PersistentSnapshot.get(instance, session_id) != nil end)

    {_id, pid} = session_process(instance, session_id)
    down_ref = Process.monitor(pid)

    assert :ok = Sessions.terminate(instance, session_id)
    assert_receive {:DOWN, ^down_ref, :process, ^pid, _reason}

    assert [event] = write_events(ref, instance, :delete)
    {_, measurements, meta} = event

    assert meta.action == :delete
    assert meta.result == :ok
    assert meta.instance == instance
    assert meta.server == @server_module
    assert is_integer(measurements.duration) and measurements.duration >= 0

    assert PersistentSnapshot.get(instance, session_id) == nil
  end

  test "a delete that the store refused gives the result error", %{ref: ref, instance: instance} do
    PersistentSnapshot.fail(instance, :delete, :raise)

    session_id = Utils.create_session(instance, initialized: true)
    assert wait_until(fn -> PersistentSnapshot.get(instance, session_id) != nil end)

    {_id, pid} = session_process(instance, session_id)
    down_ref = Process.monitor(pid)

    log =
      capture_log(fn ->
        assert :ok = Sessions.terminate(instance, session_id)
        assert_receive {:DOWN, ^down_ref, :process, ^pid, _reason}

        # The delete runs in the writer, after the end of the session:
        # the wait of the event keeps the capture open until the log of
        # the failure ran. The event goes back to the mailbox for the
        # drain below.
        #
        assert_receive {[:oz_mcp, :snapshot, :write] = name, ^ref, measurements,
                        %{instance: ^instance, action: :delete, result: :error} = meta},
                       5_000

        send(self(), {name, ref, measurements, meta})
      end)

    assert log =~ "session snapshot delete failed"

    assert [event] = write_events(ref, instance, :delete)
    {_, _measurements, meta} = event

    assert meta.action == :delete
    assert meta.result == :error
    assert meta.instance == instance
    assert meta.server == @server_module
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp session_process(instance, session_id) do
    {:ok, pid} = OzMcp.Instance.whereis(instance, {:session, session_id})
    {session_id, pid}
  end

  # The events of one write action. The drain consumes the mailbox and
  # an event can still be in flight when the store already shows the
  # write: the helper polls until one event of the action arrives.
  #
  defp write_events(ref, instance, action, tries \\ 100)

  defp write_events(_ref, _instance, _action, 0), do: flunk("no event of the write arrived")

  defp write_events(ref, instance, action, tries),
    do: write_events(ref, instance, action, tries, [])

  defp write_events(ref, instance, action, tries, extra) do
    found =
      (TelemetryCapture.drain(ref, instance) ++ extra)
      |> Enum.filter(fn {name, _, meta} ->
        name == [:oz_mcp, :snapshot, :write] and meta.action == action
      end)

    if found != [] do
      found
    else
      case TelemetryCapture.drain_wait(ref, instance, 100) do
        [] -> write_events(ref, instance, action, tries - 1)
        events -> write_events(ref, instance, action, tries - 1, events)
      end
    end
  end

  defp wait_until(fun, tries \\ 200) do
    if Utils.eventually(fun, tries * 20) do
      true
    else
      flunk("the wait of the store ran out")
    end
  end
end
