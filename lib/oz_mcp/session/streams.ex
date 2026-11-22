#
# The shared rules of the streams of a session. It owns the field `log`
# of `OzMcp.Session.Core`. The event numbering lives here: `event_id/2`
# is the only place that builds the id `<stream>:<n>`. The log holds a
# ring buffer for each stream (see `OzMcp.Session.EventLog`) and
# `OzMcp.Session.Replay` chooses the events of a resume. This module
# does not call `OzMcp.Session.Streams.Post` or
# `OzMcp.Session.Streams.Get`: no cycle.
#
defmodule OzMcp.Session.Streams do
  @moduledoc false

  alias OzMcp.Session.{Core, Effect, EventLog, Replay}

  # The id of the event number `n` of a stream.
  #
  @spec event_id(String.t(), non_neg_integer()) :: String.t()
  def event_id(stream_id, n), do: "#{stream_id}:#{n}"

  # Appends an event to the ring of a stream.
  #
  @spec log(Core.t(), String.t(), EventLog.event()) :: Core.t()
  def log(%Core{log: log} = core, stream_id, event),
    do: %{core | log: EventLog.append(log, stream_id, event)}

  # Ends the ring of a stream. A window of 0 drops it at once; another
  # window keeps it and gives the timer that drops it later.
  #
  @spec retire_log(Core.t(), String.t()) :: {Core.t(), [Effect.t()]}
  def retire_log(%Core{opts: %{sse_resume_window_ms: 0}} = core, stream_id),
    do: {drop_log(core, stream_id), []}

  def retire_log(%Core{opts: %{sse_resume_window_ms: ms}} = core, stream_id),
    do: {core, [{:timeout, {:timeout, {:log, stream_id}}, ms, :drop_log}]}

  # Drops the ring of a stream.
  #
  @spec drop_log(Core.t(), String.t()) :: Core.t()
  def drop_log(core, stream_id), do: %{core | log: EventLog.drop(core.log, stream_id)}

  # The warnings of a resume: a gap of the log, or a missing response.
  #
  @spec warn_resume(Replay.stream_replay(), String.t(), boolean(), boolean()) :: [Effect.t()]
  def warn_resume(%{gap: true}, kind, _ended, _logged) do
    [
      {:log, :warning,
       "the event log caps removed events of a resumed #{kind} stream: the client misses them " <>
         "(raise sse_event_log_size, sse_event_log_bytes, " <>
         "sse_event_log_session_bytes or sse_event_log_max_streams)"}
    ]
  end

  def warn_resume(%{response: false}, _kind, true = _ended, true = _logged) do
    [
      {:log, :warning,
       "a resumed POST stream is over and its response is not in the event log: " <>
         "the stream ends without a response"}
    ]
  end

  def warn_resume(_replay, _kind, _ended, _logged), do: []
end
