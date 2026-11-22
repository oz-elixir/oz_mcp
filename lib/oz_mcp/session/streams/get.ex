#
# The GET streams of a session and the stdio stream. It owns the fields
# `get_streams` and `closed_gets` of `OzMcp.Session.Core`.
#
# A GET stream that ends keeps its ring in the event log for the resume
# window and the list of the closed GET streams holds its id and its
# counter. When no GET stream is live, an event opens a virtual closed
# stream: the first GET that opens takes its id, its counter and its
# ring.
#
# `open/4` opens a GET stream or the stdio stream. A `last_event_id` of
# a GET stream (`g.<stream>:<n>`) resumes that GET stream; a GET with
# no `Last-Event-ID` takes the events that arrived while no GET stream
# was open.
#
defmodule OzMcp.Session.Streams.Get do
  @moduledoc false

  alias OzMcp.Session.{Core, Effect, EventLog, Replay, Streams}

  # The largest number of the closed GET streams of the resume window.
  #
  @max_closed_gets 16

  @type stream :: %{
          id: String.t(),
          pid: pid(),
          kind: :get | :stdio,
          seq: non_neg_integer()
        }

  # Opens a stream of the client, of the kind `:get` or `:stdio`.
  #
  @spec open(Core.t(), :get | :stdio, Replay.target(), pid()) ::
          {Core.t(), [Effect.t()]}
  def open(core, :get, {:get, id, n}, pid) do
    live = Enum.find(core.get_streams, &(&1.id == id))
    closed = Enum.find(core.closed_gets, &(&1.id == id and &1.opened?))

    cond do
      #
      # The stream takes over its own slot: it needs no room.
      #
      live ->
        {core, drop} = drop_live(core, live)
        {core, rest} = resume(core, pid, id, live.seq, n, [])

        {core, [{:send, live.pid, {:oz_mcp_stream, id, :terminate}} | drop ++ rest]}

      closed ->
        cancel = [{:timeout, {:timeout, {:log, id}}, :cancel, nil}]
        ready = drop_closed(core, closed)

        with_room(core, ready, &resume(&1, pid, id, closed.seq, n, cancel))

      true ->
        {core, warn} = warn_lost_position(core)
        {core, fresh} = open(core, :get, :fresh, pid)
        {core, warn ++ fresh}
    end
  end

  def open(core, :get, :invalid, pid) do
    {core, warn} = warn_lost_position(core)
    {core, fresh} = open(core, :get, :fresh, pid)
    {core, warn ++ fresh}
  end

  def open(core, :get, :fresh, pid) do
    case Enum.find(core.closed_gets, &(not &1.opened?)) do
      nil ->
        with_room(core, core, &new_get(&1, :get, pid, []))

      virtual ->
        replay = Replay.after_stream(EventLog.events(core.log, virtual.id), virtual.id, 0)
        cancel = [{:timeout, {:timeout, {:log, virtual.id}}, :cancel, nil}]
        ready = drop_closed(core, virtual)

        if replay.events == [] do
          with_room(core, ready, &new_get(&1, :get, pid, cancel))
        else
          with_room(core, ready, &resume(&1, pid, virtual.id, virtual.seq, 0, cancel))
        end
    end
  end

  def open(core, :stdio, :fresh, pid) do
    if over_limit?(core) do
      refuse(core)
    else
      new_get(core, :stdio, pid, [])
    end
  end

  # Closes each stream of the connection that `pid` owns.
  #
  @spec close(Core.t(), pid()) :: {Core.t(), [Effect.t()]}
  def close(core, pid) do
    {gone, kept} = Enum.split_with(core.get_streams, &(&1.pid == pid))
    core = %{core | get_streams: kept}
    {core, close} = close_gone(core, gone)
    {core, view} = Core.put_view(core, streams: length(kept))
    demonitors = Enum.map(gone, &{:demonitor, {:get, &1.id}})

    {core, demonitors ++ view ++ [{:reply, :ok}] ++ close ++ [:idle_check]}
  end

  # The process of a stream is gone: the stream ends.
  #
  @spec down(Core.t(), String.t()) :: {Core.t(), [Effect.t()]}
  def down(core, id) do
    {gone, kept} = Enum.split_with(core.get_streams, &(&1.id == id))
    core = %{core | get_streams: kept}
    {core, close} = close_gone(core, gone)
    {core, view} = Core.put_view(core, streams: length(kept))

    {core, close ++ view ++ [:idle_check]}
  end

  # Drops the monitor and the entry of a live stream.
  #
  @spec drop_live(Core.t(), stream()) :: {Core.t(), [Effect.t()]}
  def drop_live(core, live) do
    get_streams = List.delete(core.get_streams, live)
    {core, view} = Core.put_view(%{core | get_streams: get_streams}, streams: length(get_streams))

    {core, [{:demonitor, {:get, live.id}}] ++ view}
  end

  # Puts a stream live, with its replay and its priming id.
  #
  @spec go_live(
          Core.t(),
          stream(),
          [Replay.entry()],
          String.t() | nil,
          [Effect.t()]
        ) :: {Core.t(), [Effect.t()]}
  def go_live(core, stream, replay, priming_id, actions) do
    get_streams = [stream | core.get_streams]
    {core, view} = Core.put_view(%{core | get_streams: get_streams}, streams: length(get_streams))

    reply =
      {:ok,
       %{
         mode: :get,
         stream_id: stream.id,
         replay: replay,
         priming_id: priming_id,
         session_pid: core.pid
       }}

    {core,
     [{:monitor, stream.pid, {:get, stream.id}}] ++
       view ++ [{:reply, reply}] ++ actions ++ [:idle_check]}
  end

  # Ends a stream. A GET stream keeps its ring and its counter for the
  # resume window; a stdio stream keeps nothing.
  #
  @spec close_get(Core.t(), stream()) :: {Core.t(), [Effect.t()]}
  def close_get(%Core{opts: %{sse_resume_window_ms: 0}} = core, %{kind: :get, id: id}),
    do: {Streams.drop_log(core, id), []}

  def close_get(core, %{kind: :get, id: id, seq: seq}) do
    closed = [%{id: id, seq: seq, opened?: true} | core.closed_gets]
    {keep, old} = Enum.split(closed, @max_closed_gets)

    core = Enum.reduce(old, %{core | closed_gets: keep}, &Streams.drop_log(&2, &1.id))

    {core, effects} = Streams.retire_log(core, id)
    {core, effects ++ Enum.map(old, &{:timeout, {:timeout, {:log, &1.id}}, :cancel, nil})}
  end

  def close_get(core, _stdio), do: {core, []}

  # True when a new stream would go over `max_streams_per_session`.
  #
  @spec over_limit?(Core.t()) :: boolean()
  def over_limit?(core) do
    case core.opts.max_streams_per_session do
      nil -> false
      max -> length(core.get_streams) >= max
    end
  end

  # An event of the session, numbered on the stream that gets it.
  #
  @spec emit(Core.t(), iodata()) :: {Core.t(), [Effect.t()]}
  def emit(%Core{view: %{initialized: false}} = core, _message), do: {core, []}

  def emit(
        %Core{get_streams: [%{id: id, pid: pid, kind: kind, seq: seq} = stream | rest]} = core,
        message
      ) do
    n = seq + 1
    event_id = Streams.event_id(id, n)
    core = %{core | get_streams: [%{stream | seq: n} | rest]}
    core = if kind == :get, do: Streams.log(core, id, {event_id, message}), else: core

    {core, [{:send, pid, {:oz_mcp_stream, id, {:event, event_id, message}}}]}
  end

  def emit(
        %Core{get_streams: [], closed_gets: [%{id: id, seq: seq} = closed | rest]} = core,
        message
      ) do
    n = seq + 1
    core = Streams.log(core, id, {Streams.event_id(id, n), message})

    {%{core | closed_gets: [%{closed | seq: n} | rest]}, []}
  end

  def emit(%Core{opts: %{sse_resume_window_ms: 0}} = core, _message), do: {core, []}

  def emit(%Core{get_streams: [], closed_gets: []} = core, message) do
    id = core.ids.get_stream_id()
    core = %{core | closed_gets: [%{id: id, seq: 0, opened?: false}]}
    {core, retire} = Streams.retire_log(core, id)
    {core, _effects} = emit(core, message)

    {core, retire}
  end

  # The timer of the resume window elapsed for a stream. A stream that is
  # live again keeps its ring; otherwise the ring and the closed GET entry
  # go away.
  #
  @spec window_over(Core.t(), String.t()) :: {Core.t(), [Effect.t()]}
  def window_over(core, stream_id) do
    if Map.has_key?(core.streams, stream_id) or live?(core, stream_id) do
      {core, []}
    else
      closed_gets = Enum.reject(core.closed_gets, &(&1.id == stream_id))
      {Streams.drop_log(%{core | closed_gets: closed_gets}, stream_id), []}
    end
  end

  # The end of the session ends each live stream.
  #
  @spec end_all(Core.t()) :: {Core.t(), [Effect.t()]}
  def end_all(core) do
    effects =
      for %{pid: pid, id: id} <- core.get_streams do
        {:send, pid, {:oz_mcp_stream, id, :terminate}}
      end

    {core, effects}
  end

  defp refuse(core) do
    {core,
     [
       {:limit, :max_streams_per_session, core.opts.max_streams_per_session},
       {:reply, {:error, :too_many_streams}}
     ]}
  end

  # Makes room for one more live GET stream, then opens it with
  # `open_fun`.
  #
  defp with_room(core, ready, open_fun) do
    cond do
      not over_limit?(ready) ->
        open_fun.(ready)

      oldest = oldest_get(ready) ->
        {ready, replaced} = replace(ready, oldest)
        {ready, opened} = open_fun.(ready)
        {ready, replaced ++ opened}

      true ->
        refuse(core)
    end
  end

  # The oldest stream is the last one of `get_streams`; a `:stdio`
  # stream is never replaced.
  #
  defp oldest_get(core),
    do: core.get_streams |> Enum.reverse() |> Enum.find(&(&1.kind == :get))

  # The same steps as the resume of a live stream (`drop_live/2`, then
  # `:terminate`) and the stream keeps its ring.
  #
  defp replace(core, oldest) do
    {core, drop} = drop_live(core, oldest)
    {core, keep} = close_get(core, oldest)

    effects =
      [{:limit, :max_streams_per_session, core.opts.max_streams_per_session, :replaced}] ++
        drop ++
        [{:send, oldest.pid, {:oz_mcp_stream, oldest.id, :terminate}}] ++
        keep

    {core, effects}
  end

  defp warn_lost_position(core) do
    {core,
     [
       {:log, :warning,
        "Last-Event-ID is not in the event log of the session: " <>
          "the GET stream starts fresh, the client can miss events"}
     ]}
  end

  # The priming event gives the client its first position
  # (`<stream id>:0`).
  #
  defp new_get(core, kind, pid, actions) do
    id = core.ids.get_stream_id()
    priming_id = if kind == :get, do: Streams.event_id(id, 0), else: nil
    stream = %{id: id, pid: pid, kind: kind, seq: 0}
    go_live(core, stream, [], priming_id, actions)
  end

  # The stream resumes the id and the counter of the one it replaces and
  # has no priming event.
  #
  defp resume(core, pid, id, seq, n, actions) do
    logged = EventLog.logged?(core.log, id)
    replay = Replay.after_stream(EventLog.events(core.log, id), id, n)
    replay = if logged, do: replay, else: %{replay | gap: seq > n}
    warnings = Streams.warn_resume(replay, "GET", false, logged)
    stream = %{id: id, pid: pid, kind: :get, seq: seq}
    {core, live} = go_live(core, stream, replay.events, nil, actions)

    {core, warnings ++ live}
  end

  defp drop_closed(core, virtual),
    do: %{core | closed_gets: List.delete(core.closed_gets, virtual)}

  defp close_gone(core, gone) do
    Enum.reduce(gone, {core, []}, fn stream, {core, effects} ->
      {core, more} = close_get(core, stream)
      {core, effects ++ more}
    end)
  end

  defp live?(core, stream_id), do: Enum.any?(core.get_streams, &(&1.id == stream_id))
end
