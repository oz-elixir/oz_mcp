#
# The events of the streams of one session. Each stream has a ring
# buffer with two limits: a number of events and a number of bytes.
# The rings of a session together have two limits: a number of bytes
# and a number of rings.
#
defmodule OzMcp.Session.EventLog do
  @moduledoc false

  defstruct streams: %{},
            counter: 0,
            max_events: 256,
            max_bytes: 1_048_576,
            max_total_bytes: nil,
            max_streams: nil,
            total_bytes: 0

  @type stream :: String.t()
  @type event :: {event_id :: String.t(), iodata()}
  @type t :: %__MODULE__{}

  @spec new(pos_integer(), pos_integer(), pos_integer() | nil, pos_integer() | nil) :: t()
  def new(max_events, max_bytes, max_total_bytes \\ nil, max_streams \\ nil),
    do: %__MODULE__{
      max_events: max_events,
      max_bytes: max_bytes,
      max_total_bytes: max_total_bytes,
      max_streams: max_streams
    }

  @spec append(t(), stream(), event()) :: t()
  def append(%__MODULE__{} = log, stream_id, {_id, data} = event) do
    size = IO.iodata_length(data)
    n = log.counter + 1
    {queue, old_bytes, events} = ring(log, stream_id)
    ring = trim({:queue.in({event, size, n}, queue), old_bytes + size, events + 1}, log)

    %{
      log
      | streams: Map.put(log.streams, stream_id, ring),
        counter: n,
        total_bytes: log.total_bytes - old_bytes + elem(ring, 1)
    }
    |> enforce_budget(stream_id)
    |> enforce_ring_cap(stream_id)
  end

  # True when the log holds a ring for the stream.
  #
  @spec logged?(t(), stream()) :: boolean()
  def logged?(%__MODULE__{streams: streams}, stream_id), do: Map.has_key?(streams, stream_id)

  # Removes the ring of a stream. A stream with no ring is not an error.
  #
  @spec drop(t(), stream()) :: t()
  def drop(%__MODULE__{} = log, stream_id) do
    case Map.pop(log.streams, stream_id) do
      {nil, _streams} ->
        log

      {{_queue, bytes, _events}, streams} ->
        %{log | streams: streams, total_bytes: log.total_bytes - bytes}
    end
  end

  # The stream ids that have a ring.
  #
  @spec streams(t()) :: [stream()]
  def streams(%__MODULE__{streams: streams}), do: Map.keys(streams)

  # The retained entries of a stream, oldest first. An unknown stream has
  # none.
  #
  @spec events(t(), stream()) :: [event()]
  def events(%__MODULE__{} = log, stream_id) do
    case Map.fetch(log.streams, stream_id) do
      {:ok, {queue, _bytes, _events}} -> Enum.map(:queue.to_list(queue), &elem(&1, 0))
      :error -> []
    end
  end

  defp ring(log, stream_id), do: Map.get(log.streams, stream_id, {:queue.new(), 0, 0})

  # Keeps the total of the bytes under the budget of the session. Only
  # the ring that got the append stays for sure; the ring with the
  # oldest newest event goes first.
  #
  defp enforce_budget(%__MODULE__{max_total_bytes: nil} = log, _current), do: log

  defp enforce_budget(%__MODULE__{total_bytes: total, max_total_bytes: max} = log, _current)
       when total <= max,
       do: log

  defp enforce_budget(%__MODULE__{} = log, current) do
    case oldest_ring(log, current) do
      nil -> log
      {oldest, _ring} -> log |> drop(oldest) |> enforce_budget(current)
    end
  end

  # Keeps the number of the rings under the cap of the session: the rule
  # of the eviction is the rule of the byte budget.
  #
  defp enforce_ring_cap(%__MODULE__{max_streams: nil} = log, _current), do: log

  defp enforce_ring_cap(%__MODULE__{max_streams: max} = log, current) do
    if map_size(log.streams) <= max do
      log
    else
      case oldest_ring(log, current) do
        nil -> log
        {oldest, _ring} -> log |> drop(oldest) |> enforce_ring_cap(current)
      end
    end
  end

  defp oldest_ring(%__MODULE__{} = log, current) do
    log.streams
    |> Enum.reject(fn {stream_id, _ring} -> stream_id == current end)
    |> Enum.min_by(fn {_stream_id, ring} -> newest(ring) end, fn -> nil end)
  end

  # A ring is never empty: it starts with an append.
  #
  defp newest({queue, _bytes, _events}) do
    case :queue.peek_r(queue) do
      {:value, {_event, _size, n}} -> n
    end
  end

  # Removes the oldest entries while a limit is passed. The newest real
  # event stays.
  #
  defp trim({_queue, bytes, events} = ring, log) do
    if events > 1 and (events > log.max_events or bytes > log.max_bytes),
      do: ring |> drop_oldest_event() |> trim(log),
      else: ring
  end

  defp drop_oldest_event({queue, bytes, events}) do
    {{:value, {_event, size, _n}}, queue} = :queue.out(queue)
    {queue, bytes - size, events - 1}
  end
end
