#
# The POST streams of a session. It owns the field `streams` of
# `OzMcp.Session.Core`.
#
# A POST stream belongs to a request: the owner is the process that owns
# the connection and a resumer (a GET that resumed the stream) can take
# it over. The owner of the request can be another process: the entry
# holds the two and the session monitors both. The entry exists from
# the registration of the stream, so every message that an `emit` sends
# is numbered, even before the first write of the owner. A stream with
# no live owner is a normal state: its events go to the log and to a
# resumer. A sink cannot be resumed: its messages have no id and go in
# no log.
#
# `finish/5` is the response of a POST request: the session numbers it
# as the final event of the stream, logs it and sends it to the
# resumer. The answer tells the owner what to write: `{:sse, event_id}`
# (the stream was started), `:plain` (no event went out) or `:gone`
# (nothing is written). A call that the session cannot answer returns
# the error.
#
defmodule OzMcp.Session.Streams.Post do
  @moduledoc false

  alias OzMcp.Session.{Core, Effect, EventLog, Replay, Requests, Streams}

  @type entry :: %{
          owner: pid() | nil,
          resumer: pid() | nil,
          request_id: String.t() | integer(),
          seq: non_neg_integer(),
          mode: :sse | :sink,
          started: boolean()
        }

  # Makes the entry of a stream and gives its owner monitor.
  #
  @spec new(Core.t(), String.t(), pid(), String.t() | integer(), :sse | :sink) ::
          {Core.t(), [Effect.t()]}
  def new(core, stream_id, owner, request_id, mode) do
    entry = %{
      owner: owner,
      resumer: nil,
      request_id: request_id,
      seq: 0,
      mode: mode,
      started: false
    }

    {put_in(core.streams[stream_id], entry), [{:monitor, owner, {:owner, stream_id}}]}
  end

  # The stream starts: the head and the priming event of the writer follow.
  #
  @spec promote(Core.t(), String.t()) :: {Core.t(), [Effect.t()]}
  def promote(core, stream_id) do
    case Map.fetch(core.streams, stream_id) do
      {:ok, entry} ->
        {put_in(core.streams[stream_id], %{entry | started: true}), [{:reply, :ok}]}

      :error ->
        {core, [{:reply, :gone}]}
    end
  end

  # The stream has no live owner: its events go to the log and to a resumer.
  #
  @spec hand_off(Core.t(), String.t()) :: {Core.t(), [Effect.t()]}
  def hand_off(core, stream_id) do
    case Map.fetch(core.streams, stream_id) do
      {:ok, entry} ->
        entry = %{entry | owner: nil, started: true}

        {put_in(core.streams[stream_id], entry),
         [{:demonitor, {:owner, stream_id}}, {:reply, :ok}]}

      :error ->
        {core, [{:reply, :gone}]}
    end
  end

  # The process of the connection is gone while another process still owns
  # the request (the worker that runs the callback): the stream becomes a
  # hand-off. The callback goes on and the later events and the response
  # go to the log and to a resumer. No reply and no demonitor: the caller
  # is the DOWN of the owner and the monitor is gone with it.
  #
  @spec connection_down(Core.t(), String.t()) :: {Core.t(), [Effect.t()]}
  def connection_down(core, stream_id) do
    case Map.fetch(core.streams, stream_id) do
      {:ok, entry} ->
        {put_in(core.streams[stream_id], %{entry | owner: nil, started: true}), []}

      :error ->
        {core, []}
    end
  end

  # The response of the request is the final event of its stream.
  #
  @spec finish(Core.t(), String.t() | integer(), String.t(), iodata(), boolean()) ::
          {Core.t(), [Effect.t()]}
  def finish(core, request_id, stream_id, response, started?) do
    case Map.fetch(core.streams, stream_id) do
      {:ok, %{request_id: ^request_id, mode: :sse, seq: seq, resumer: resumer} = entry} ->
        #
        # A stream that a hand-off marked started counts as started.
        #
        if seq > 0 or started? or is_pid(resumer) or entry.started do
          started(core, request_id, stream_id, seq, response)
        else
          plain(core, request_id, stream_id)
        end

      _no_entry_or_other_request ->
        {core, [{:reply, :gone}]}
    end
  end

  defp started(core, request_id, stream_id, seq, response) do
    event_id = Streams.event_id(stream_id, seq + 1)
    core = Streams.log(core, stream_id, {event_id, response})
    {core, forward} = forward(core, stream_id, event_id, response)
    core = Requests.clear_stream(core, request_id)
    {core, retire} = Streams.retire_log(core, stream_id)
    {core, forward ++ retire ++ [{:reply, {:sse, event_id}}]}
  end

  defp plain(core, request_id, stream_id) do
    core = Requests.clear_stream(core, request_id)
    {core, effects} = drop(core, stream_id)
    {core, effects ++ [{:reply, :plain}]}
  end

  # The owner forgets its stream. A live resumer ends.
  #
  @spec detach(Core.t(), String.t()) :: {Core.t(), [Effect.t()]}
  def detach(core, stream_id) do
    case Map.get(core.streams, stream_id) do
      %{resumer: pid} when is_pid(pid) ->
        {core, effects} = forget(core, stream_id)
        {core, [{:send, pid, {:oz_mcp_stream, stream_id, :end}}] ++ effects}

      _entry_or_gone ->
        forget(core, stream_id)
    end
  end

  # The resumer is done: the stream can be resumed again.
  #
  @spec detach_resume(Core.t(), String.t(), pid()) :: {Core.t(), [Effect.t()]}
  def detach_resume(core, stream_id, pid) do
    case Map.fetch(core.streams, stream_id) do
      {:ok, %{resumer: ^pid} = entry} ->
        {put_in(core.streams[stream_id], clear_resumer(entry)),
         [{:demonitor, {:resumer, stream_id}}]}

      _no_entry_or_other_resumer ->
        {core, []}
    end
  end

  # The resumer takes the stream over from the owner.
  #
  @spec take_over(Core.t(), String.t(), pid()) :: {Core.t(), [Effect.t()]}
  def take_over(core, stream_id, pid) do
    {core, ended} = end_resumer(core, stream_id)
    entry = Map.fetch!(core.streams, stream_id)
    core = put_in(core.streams[stream_id], %{entry | resumer: pid})

    # A stream with no live owner (a hand-off) has nobody to tell.
    #
    taken_over =
      if is_pid(entry.owner),
        do: [{:send, entry.owner, {:oz_mcp_stream, stream_id, :taken_over}}],
        else: []

    {core, ended ++ taken_over ++ [{:monitor, pid, {:resumer, stream_id}}]}
  end

  # Ends the resumer of a stream, when it has one.
  #
  @spec end_resumer(Core.t(), String.t()) :: {Core.t(), [Effect.t()]}
  def end_resumer(core, stream_id) do
    case Map.fetch(core.streams, stream_id) do
      {:ok, %{resumer: nil}} ->
        {core, []}

      {:ok, %{resumer: pid} = entry} ->
        {put_in(core.streams[stream_id], clear_resumer(entry)),
         [
           {:send, pid, {:oz_mcp_stream, stream_id, :end}},
           {:demonitor, {:resumer, stream_id}}
         ]}

      :error ->
        {core, []}
    end
  end

  # Clears the resumer of an entry.
  #
  @spec clear_resumer(entry()) :: entry()
  def clear_resumer(entry), do: %{entry | resumer: nil}

  # A GET resumes a POST stream: it takes the stream over when it is live.
  #
  @spec resume(Core.t(), pid(), String.t(), non_neg_integer(), boolean()) ::
          {Core.t(), [Effect.t()]}
  def resume(core, pid, stream_id, seq, ended?) do
    case Map.get(core.streams, stream_id) do
      %{mode: :sink} ->
        {core, [{:reply, {:error, :no_stream}}, :idle_check]}

      _entry_or_gone ->
        resume_sse(core, pid, stream_id, seq, ended?)
    end
  end

  # The owner of a stream is gone: a live resumer ends.
  #
  @spec owner_down(Core.t(), String.t()) :: {Core.t(), [Effect.t()]}
  def owner_down(core, stream_id) do
    case Map.get(core.streams, stream_id) do
      %{resumer: pid} when is_pid(pid) ->
        {core, effects} = forget(core, stream_id)

        {core,
         [
           {:log, :warning,
            "the request of a resumed POST stream stopped before its response: " <>
              "the client does not get a response"},
           {:send, pid, {:oz_mcp_stream, stream_id, :end}}
         ] ++ effects}

      _no_resumer ->
        forget(core, stream_id)
    end
  end

  # The resumer is gone with no detach: the stream can be resumed again.
  #
  @spec resumer_down(Core.t(), String.t()) :: {Core.t(), [Effect.t()]}
  def resumer_down(core, stream_id) do
    case Map.fetch(core.streams, stream_id) do
      {:ok, entry} -> {put_in(core.streams[stream_id], clear_resumer(entry)), []}
      :error -> {core, []}
    end
  end

  # The final event of a stream, to its resumer and the entry goes.
  #
  @spec forward(Core.t(), String.t(), String.t(), iodata()) :: {Core.t(), [Effect.t()]}
  def forward(core, stream_id, event_id, encoded) do
    case Map.get(core.streams, stream_id) do
      %{resumer: pid} when is_pid(pid) ->
        {core, effects} = drop(core, stream_id)

        {core,
         [
           {:send, pid, {:oz_mcp_stream, stream_id, {:event, event_id, encoded}}},
           {:send, pid, {:oz_mcp_stream, stream_id, :end}}
         ] ++ effects}

      _no_entry_or_no_resumer ->
        drop(core, stream_id)
    end
  end

  # A message for a stream id: it is numbered and logged, except for a sink.
  #
  @spec emit(Core.t(), String.t(), iodata()) :: {Core.t(), [Effect.t()]}
  def emit(core, stream_id, message) do
    case Map.get(core.streams, stream_id) do
      %{seq: seq} = entry ->
        n = seq + 1
        core = put_in(core.streams[stream_id], %{entry | seq: n})
        send_event(core, entry, stream_id, Streams.event_id(stream_id, n), message)

      nil ->
        {core, []}
    end
  end

  # A message for the stream of a request: no stream gives no effect.
  #
  @spec emit_request(Core.t(), String.t() | integer(), iodata()) :: {Core.t(), [Effect.t()]}
  def emit_request(core, request_id, message) do
    case Map.get(core.requests, request_id) do
      %{stream_id: stream_id} when is_binary(stream_id) -> emit(core, stream_id, message)
      _no_stream -> {core, []}
    end
  end

  # The end of the session ends each live resumer.
  #
  @spec end_all(Core.t()) :: {Core.t(), [Effect.t()]}
  def end_all(core) do
    effects =
      for {stream_id, %{resumer: pid}} <- core.streams, is_pid(pid) do
        {:send, pid, {:oz_mcp_stream, stream_id, :terminate}}
      end

    {core, effects}
  end

  defp resume_sse(core, pid, stream_id, seq, ended?) do
    logged = EventLog.logged?(core.log, stream_id)

    if ended? and not logged do
      {core,
       [
         {:log, :debug, "a resumed POST stream is over and its event log was dropped"},
         {:reply, {:error, :no_stream}},
         :idle_check
       ]}
    else
      replay = Replay.after_stream(EventLog.events(core.log, stream_id), stream_id, seq)
      replay = evicted_gap(replay, core, stream_id, ended?, logged, seq)
      warnings = Streams.warn_resume(replay, "POST", ended?, logged)
      {core, taken_over} = if ended?, do: {core, []}, else: take_over(core, stream_id, pid)

      reply =
        {:ok,
         %{
           mode: :resume,
           stream_id: stream_id,
           replay: replay.events,
           ended: ended?,
           session_pid: core.pid
         }}

      {core, warnings ++ taken_over ++ [{:reply, reply}, :idle_check]}
    end
  end

  # A session cap evicted the ring of a live stream: the events after
  # `seq` are gone and the replay finds no gap, so this marks it.
  #
  defp evicted_gap(replay, core, stream_id, false = _ended, false = _logged, seq) do
    if Map.fetch!(core.streams, stream_id).seq > seq, do: %{replay | gap: true}, else: replay
  end

  defp evicted_gap(replay, _core, _stream_id, _ended, _logged, _seq), do: replay

  defp forget(core, stream_id) do
    {core, effects} = drop(core, stream_id)

    if EventLog.logged?(core.log, stream_id) do
      {core, retire} = Streams.retire_log(core, stream_id)
      {core, effects ++ retire}
    else
      {core, effects}
    end
  end

  defp send_event(core, %{mode: :sink, owner: owner}, stream_id, _event_id, message) do
    {core, [{:send, owner, {:oz_mcp_stream, stream_id, {:event, nil, message}}}]}
  end

  # A stream with no resumer and no owner logs the event only: a client
  # that resumes the stream gets it.
  #
  defp send_event(core, entry, stream_id, event_id, message) do
    core = Streams.log(core, stream_id, {event_id, message})

    case entry.resumer || entry.owner do
      nil ->
        {core, []}

      pid ->
        {core,
         [
           {:send, pid, {:oz_mcp_stream, stream_id, {:event, event_id, message}}}
         ]}
    end
  end

  defp drop(core, stream_id) do
    case Map.pop(core.streams, stream_id) do
      {nil, _streams} ->
        {core, []}

      {entry, streams} ->
        effects =
          [{:demonitor, {:owner, stream_id}}] ++
            if(is_pid(entry.resumer), do: [{:demonitor, {:resumer, stream_id}}], else: [])

        {%{core | streams: streams}, effects}
    end
  end
end
