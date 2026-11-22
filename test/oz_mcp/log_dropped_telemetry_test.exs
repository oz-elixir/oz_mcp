#
# The `log_dropped` event: one event for each window of one second in
# which the session dropped log notifications over `max_log_rate`. The
# measurements hold the count of the drops of the window. The metadata
# holds no data, no level, no logger name and no id of a session.
#
defmodule OzMcp.LogDroppedTelemetryTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias OzMcp.Notify
  alias OzMcp.Session
  alias OzMcp.Sessions
  alias Support.Helpers.TelemetryCapture
  alias Support.Servers

  @server Servers.RuntimeTest
  @log_level :debug

  setup context do
    ref = TelemetryCapture.attach()
    rate = Map.get(context, :max_log_rate, 2)
    name = :"log_dropped_test_#{System.unique_integer([:positive])}"

    start_supervised!(
      {OzMcp, server: @server, name: name, allowed_origins: [], max_log_rate: rate}
    )

    %{ref: ref, instance: name}
  end

  defp session_with_stream(instance) do
    attrs = %{
      session_id: "sid-1",
      principal_key: "p1",
      protocol_version: "2025-11-25",
      client_info: %{"name" => "c"},
      client_capabilities: %{}
    }

    {:ok, _pid} = Session.start(instance, attrs)
    :ok = Session.initialized(instance, "sid-1")
    :ok = Sessions.set_log_level(instance, "sid-1", @log_level)
    assert {:ok, %{stream_id: _}} = Session.open_stream(instance, "sid-1", :get, self(), nil)

    :ok
  end

  defp dropped?(name), do: name == [:oz_mcp, :log, :dropped]

  # The events of the drop in the mailbox. The report comes one second
  # after the first drop of the window and other events of the instance
  # (the spans, the writes of the snapshot) can arrive before it: the wait
  # goes on until the event of the drop comes or the time is over. The
  # deadline is fixed at the start of the call: an event that is not a
  # drop does not make the wait longer.
  #
  defp wait_drop_event(ref, instance, timeout) do
    do_wait_drop_event(ref, instance, TelemetryCapture.deadline(timeout))
  end

  defp do_wait_drop_event(ref, instance, deadline) do
    case TelemetryCapture.drain_wait(ref, instance, TelemetryCapture.time_left(deadline)) do
      [] ->
        []

      events ->
        case Enum.filter(events, fn {name, _, _} -> dropped?(name) end) do
          [] -> do_wait_drop_event(ref, instance, deadline)
          dropped -> dropped
        end
    end
  end

  defp flood(instance, data),
    do: for(_n <- 1..30, do: :ok = Notify.log_session(instance, "sid-1", :info, data))

  defp one_drop_event(ref, instance) do
    assert [event] = wait_drop_event(ref, instance, 5_000)
    event
  end

  @tag max_log_rate: 2
  test "a flood gives one event with the count of the drops", %{ref: ref, instance: instance} do
    :ok = session_with_stream(instance)
    _ = TelemetryCapture.drain(ref, instance)

    flood(instance, %{n: System.unique_integer([:positive])})

    assert [event] = wait_drop_event(ref, instance, 5_000)
    {_, measurements, meta} = event

    assert measurements.count > 0
    assert measurements.count < 30
    assert meta.instance == instance
    assert meta.server == @server
    assert MapSet.new(Map.keys(meta)) == MapSet.new([:instance, :server])
  end

  @tag max_log_rate: 2
  test "a second flood after a report gives a second event", %{ref: ref, instance: instance} do
    :ok = session_with_stream(instance)
    _ = TelemetryCapture.drain(ref, instance)

    flood(instance, "first")
    assert [_event] = wait_drop_event(ref, instance, 5_000)

    flood(instance, "second")
    {_, measurements, _meta} = one_drop_event(ref, instance)

    assert measurements.count > 0
  end

  @tag max_log_rate: nil
  test "no drop gives no event", %{ref: ref, instance: instance} do
    :ok = session_with_stream(instance)
    _ = TelemetryCapture.drain(ref, instance)

    flood(instance, "no-drop")

    # Longer than the window of the report: no event of a drop comes.
    #
    assert [] = wait_drop_event(ref, instance, 1_200)
  end

  test "the guide section of the event gives the measurement and the metadata" do
    guide = Path.join(File.cwd!(), "guides/runtime/telemetry.md")
    [_, rest] = String.split(File.read!(guide), "## The log dropped event", parts: 2)

    body =
      case String.split(rest, "\n## ", parts: 2) do
        [body] -> body
        [body, _after] -> body
      end

    body = String.replace(body, ~r/\s+/, " ")

    assert body =~ "The measurement `count`"
    assert body =~ "the messages that the session dropped in the window"
    assert body =~ "only the `instance` and the `server` keys"
    refute body =~ "the metadata holds the count"
  end

  @tag max_log_rate: 2
  test "the report line holds the count and no data of the dropped messages", %{
    ref: ref,
    instance: instance
  } do
    :ok = session_with_stream(instance)
    _ = TelemetryCapture.drain(ref, instance)

    log =
      capture_log(fn ->
        flood(instance, "secret-data-42")
        assert [_event] = wait_drop_event(ref, instance, 5_000)

        # A second flood and its report: the event of the second report
        # comes after the line of the first report was written, so the
        # capture holds the line with no wait of a fixed length.
        #
        flood(instance, "secret-data-42")
        assert [_event] = wait_drop_event(ref, instance, 5_000)
      end)

    assert log =~ "log notifications were dropped by max_log_rate"
    refute log =~ "secret-data-42"
  end
end
