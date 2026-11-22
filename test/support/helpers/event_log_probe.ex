#
# Reads of the event log that the tests need and the server does not:
# the tests read the internal ring `{queue, bytes, events}`.
#
defmodule Support.Helpers.EventLogProbe do
  alias OzMcp.Session.EventLog

  @spec total_bytes(EventLog.t()) :: non_neg_integer()
  def total_bytes(%EventLog{total_bytes: total}), do: total

  @spec all(EventLog.t()) :: [EventLog.event()]
  def all(%EventLog{streams: streams}) do
    streams
    |> Enum.flat_map(fn {_stream, {queue, _bytes, _events}} -> :queue.to_list(queue) end)
    |> Enum.sort_by(&elem(&1, 2))
    |> Enum.map(&elem(&1, 0))
  end

  @spec after_id(EventLog.t(), EventLog.stream(), String.t() | nil) ::
          {:ok, [EventLog.event()]} | :gap
  def after_id(%EventLog{streams: streams}, stream_id, last_event_id) do
    case Map.fetch(streams, stream_id) do
      {:ok, {queue, _bytes, _events}} -> slice_after(:queue.to_list(queue), last_event_id)
      :error -> :gap
    end
  end

  @spec size(EventLog.t(), EventLog.stream()) :: {non_neg_integer(), non_neg_integer()}
  def size(%EventLog{streams: streams}, stream_id) do
    case Map.fetch(streams, stream_id) do
      {:ok, {_queue, bytes, events}} -> {events, bytes}
      :error -> {0, 0}
    end
  end

  # The entries after `last_id`, or `:gap` when the ring does not hold it.
  #
  defp slice_after(entries, nil), do: {:ok, Enum.map(entries, &elem(&1, 0))}

  defp slice_after(entries, last_id) do
    case Enum.drop_while(entries, fn {{id, _}, _size, _n} -> id != last_id end) do
      [] -> :gap
      [_last | rest] -> {:ok, Enum.map(rest, &elem(&1, 0))}
    end
  end
end
