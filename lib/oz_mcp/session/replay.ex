#
# Chooses the events that a client gets again when it resumes a stream.
#
# The session gives the events of one stream, in the order that they were
# written (see OzMcp.Session.EventLog). The id of an event tells the
# stream of the event and its number (see `parse_event_id/1`).
# The functions work on a list of entries, so the module is pure.
#
# `target/1` tells the kind of a `Last-Event-ID`. A resume of a `POST`
# stream or of a `GET` stream uses `after_stream/3`: it gives the events
# to send again and it tells whether the log cap left a gap (`gap`) and,
# for a `POST` stream, whether the response of the request is in the log
# (`response`). The log cap can remove events of any stream: when the
# first retained event of a stream has a number above the resume
# position, the client misses the events before it.
#
defmodule OzMcp.Session.Replay do
  @moduledoc false

  alias OzMcp.Wire

  @type entry :: {String.t(), iodata()}

  @type target ::
          :fresh
          | {:post, String.t(), non_neg_integer()}
          | {:get, String.t(), non_neg_integer()}
          | :invalid

  @type stream_replay :: %{events: [entry()], gap: boolean(), response: boolean()}

  # The kind of a `Last-Event-ID`.
  #
  #   * `nil`: `:fresh`, no resume.
  #   * the id of a `GET` stream (`g.<stream>:<n>`): `{:get, stream, n}`.
  #   * any other id of the form `<stream>:<n>`: `{:post, stream, n}`, a
  #     resume of a `POST` stream.
  #   * any other text: `:invalid`.
  #
  @spec target(String.t() | nil) :: target()
  def target(nil), do: :fresh

  def target(last_event_id) do
    case parse_event_id(last_event_id) do
      {"g." <> _ = stream, n} -> {:get, stream, n}
      {stream, n} -> {:post, stream, n}
      :invalid -> :invalid
    end
  end

  # Splits an event id. The id of an event is `<stream>:<n>`.
  #
  # Returns `{stream, n}` for an id of the form `<stream>:<n>` and `:invalid`
  # for any other text. The id of a GET stream starts with `g.`; the id of a
  # POST stream never holds a dot.
  #
  @spec parse_event_id(term()) :: {String.t(), non_neg_integer()} | :invalid
  def parse_event_id(event_id) when is_binary(event_id) do
    case String.split(event_id, ":", parts: 2) do
      [stream, seq] when stream != "" ->
        case Integer.parse(seq) do
          {n, ""} when n >= 0 -> {stream, n}
          _ -> :invalid
        end

      _ ->
        :invalid
    end
  end

  def parse_event_id(_event_id), do: :invalid

  # The events of the stream `stream` after the sequence number `seq`,
  # oldest first.
  #
  # `gap` is true when the log cap removed events of the stream after `seq`:
  # the first event that stays has a number above `seq + 1`. When no event
  # of the stream after `seq` stays, a gap cannot be found.
  #
  # `response` is true when the last of these events is the JSON-RPC
  # response of the request of a `POST` stream: the stream is complete.
  #
  @spec after_stream([entry()], String.t(), non_neg_integer()) :: stream_replay()
  def after_stream(log, stream, seq) do
    events =
      Enum.filter(log, fn {id, _data} ->
        match?({^stream, n} when n > seq, parse_event_id(id))
      end)

    %{events: events, gap: gap?(events, seq), response: response?(List.last(events))}
  end

  defp gap?([], _seq), do: false

  defp gap?([{id, _data} | _rest], seq) do
    {_stream, first} = parse_event_id(id)
    first > seq + 1
  end

  defp response?(nil), do: false

  defp response?({_id, data}) do
    case decode(data) do
      %{"id" => _id, "result" => _} = message -> not is_map_key(message, "method")
      %{"id" => _id, "error" => _} = message -> not is_map_key(message, "method")
      _ -> false
    end
  end

  defp decode(data) do
    data |> IO.iodata_to_binary() |> Wire.decode!()
  rescue
    _error -> nil
  end
end
