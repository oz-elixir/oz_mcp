#
# Attach a handler to all the events of a prefix. It sends each event to
# the test process.
#
defmodule Support.Helpers.TelemetryCapture do
  @tails [
    [:request, :start],
    [:request, :stop],
    [:request, :exception],
    [:callback, :start],
    [:callback, :stop],
    [:callback, :exception],
    [:session, :start],
    [:session, :stop],
    [:session, :restore],
    [:task, :start],
    [:task, :stop],
    [:client_request, :start],
    [:client_request, :stop],
    [:client_request, :exception],
    [:client_task, :start],
    [:client_task, :stop],
    [:client_task, :exception],
    [:auth, :refused],
    [:limit, :reached],
    [:log, :dropped],
    [:snapshot, :write],
    [:principal, :revoked],
    [:subscription, :dropped]
  ]

  # Call it from a test or a setup block. The handler of `:telemetry` is
  # global and stays after the end of the test process, so the helper
  # detaches it in `on_exit/1`.
  #
  def attach(prefix \\ [:oz_mcp]) do
    events = Enum.map(@tails, &(prefix ++ &1))
    ref = :telemetry_test.attach_event_handlers(self(), events)
    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(ref) end)
    ref
  end

  # Collect the events of one instance that are in the mailbox. Each
  # message is `{event, ref, measurements, metadata}`.
  #
  def drain(ref, instance) do
    receive do
      {event, ^ref, measurements, %{instance: ^instance} = meta} ->
        [{event, measurements, meta} | drain(ref, instance)]
    after
      0 -> []
    end
  end

  # Collect the events of one instance that are in the mailbox and wait
  # for the next event of the instance when the mailbox is empty. The wait
  # is for an event of the library, not for a fixed time. Gives `[]` when
  # no event of the instance arrives within `timeout` ms. The deadline is
  # fixed at the start of the call: an event of another instance does not
  # make the wait longer.
  #
  def drain_wait(ref, instance, timeout) do
    do_drain_wait(ref, instance, deadline(timeout))
  end

  # The deadline of a wait and the time that is left before it. A caller
  # that loops keeps one deadline across its loop.
  #
  def deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  def time_left(deadline), do: max(0, deadline - System.monotonic_time(:millisecond))

  defp do_drain_wait(ref, instance, deadline) do
    case drain(ref, instance) do
      [] ->
        receive do
          {event, ^ref, measurements, %{instance: ^instance} = meta} ->
            [{event, measurements, meta} | drain(ref, instance)]

          {_event, ^ref, _measurements, _metadata} ->
            #
            # An event of another instance: the collector takes no note of it.
            #
            do_drain_wait(ref, instance, deadline)
        after
          time_left(deadline) -> []
        end

      events ->
        events
    end
  end
end
