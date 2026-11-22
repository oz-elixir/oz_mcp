#
# A pure parser of Server-Sent Events frames.
#
# The parser keeps the state of a stream in a plain map (`new/0`, `feed/2`,
# `pop/2`) so the same code serves a whole body (`parse/1`) and the chunks
# of an open connection. It understands the `id`, `event`, `data` and
# `retry` fields, the multi-line `data` fields and the comment lines.
#
defmodule OzMcp.E2E.Sse do
  defstruct [:id, :event, :data, :retry]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          event: String.t() | nil,
          data: String.t(),
          retry: non_neg_integer() | nil
        }

  @type state :: %{buffer: binary(), events: [t()]}

  @spec new() :: state()
  def new, do: %{buffer: "", events: []}

  @spec parse(binary()) :: [t()]
  def parse(body) do
    state = new() |> feed(body)
    state = flush(state)
    state |> events() |> Enum.reverse()
  end

  @doc false
  @spec events(state()) :: [t()]
  def events(%{events: events}), do: events

  # A body ends when the connection closes: the last frame may have no
  # blank line after it. `parse/1` takes the tail as a final frame; the
  # incremental API keeps it in the buffer until the stream continues.
  #
  defp flush(%{buffer: ""} = state), do: state

  defp flush(%{buffer: buffer, events: events} = state) do
    frame = normalize(buffer) |> String.trim_trailing("\n")
    %{state | buffer: "", events: dispatch(frame, events)}
  end

  @doc false
  @spec feed(state(), binary()) :: state()
  def feed(%{buffer: buffer, events: events} = state, chunk) do
    {frames, rest} = split_frames(normalize(buffer <> chunk))
    events = Enum.reduce(frames, events, &dispatch/2)
    %{state | buffer: rest, events: events}
  end

  @doc false
  @spec pop(state()) :: {:ok, t(), state()} | :empty
  def pop(%{events: [event | rest]} = state), do: {:ok, event, %{state | events: rest}}
  def pop(%{events: []}), do: :empty

  defp normalize(binary) do
    binary
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end

  # A frame ends with a blank line. A chunk boundary can cut a frame in
  # two: the incomplete tail stays in the buffer.
  #
  defp split_frames(buffer) do
    case :binary.split(buffer, "\n\n", [:global]) do
      [whole] -> {[], whole}
      parts -> {Enum.drop(parts, -1), List.last(parts)}
    end
  end

  defp dispatch("", events), do: events

  defp dispatch(frame, events) do
    case frame_to_event(frame) do
      :skip -> events
      event -> [event | events]
    end
  end

  defp frame_to_event(frame) do
    fields = frame |> String.split("\n") |> Enum.reduce(%{data: []}, &field/2)
    retry = Map.get(fields, :retry)

    cond do
      fields.data != [] ->
        data = fields.data |> Enum.reverse() |> Enum.join("\n")

        %__MODULE__{
          id: Map.get(fields, :id),
          event: Map.get(fields, :event),
          data: data,
          retry: retry
        }

      # A frame with a `retry` field and no data is a reconnect hint: the
      # tests must see it, so it is kept as an event with empty data.
      #
      retry != nil ->
        %__MODULE__{data: "", retry: retry}

      true ->
        :skip
    end
  end

  defp field(":" <> _comment, acc), do: acc

  defp field(line, acc) do
    {name, value} = split_field(line)

    case name do
      "id" -> Map.put(acc, :id, value)
      "event" -> Map.put(acc, :event, value)
      "data" -> Map.update(acc, :data, [value], &[value | &1])
      "retry" -> Map.put(acc, :retry, retry(value))
      _ -> acc
    end
  end

  defp split_field(line) do
    case :binary.split(line, ":") do
      [name, value] -> {name, strip_space(value)}
      [name] -> {name, ""}
    end
  end

  defp strip_space(" " <> value), do: value
  defp strip_space(value), do: value

  defp retry(value) do
    case Integer.parse(value) do
      {n, _rest} when n >= 0 -> n
      _ -> nil
    end
  end
end
