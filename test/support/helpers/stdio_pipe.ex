#
# In-memory pipe for the stdio tests: the client side of stdin and stdout.
#
defmodule Support.Helpers.StdioPipe do
  use GenServer
  alias Support.Helpers.Utils

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil)

  # The function that the transport takes as `:read`.
  #
  def reader(pipe), do: fn -> GenServer.call(pipe, :read, :infinity) end

  # The function that the transport takes as `:write`.
  #
  def writer(pipe),
    do: fn iodata -> GenServer.call(pipe, {:write, IO.iodata_to_binary(iodata)}) end

  # Sends one line from the client, as a map or as a raw binary.
  #
  def send_line(pipe, message) when is_map(message),
    do: send_line(pipe, Utils.encode_json(message))

  def send_line(pipe, line) when is_binary(line), do: GenServer.cast(pipe, {:input, line <> "\n"})

  # Closes the input of the pipe. Later reads return `:eof`.
  #
  def close_input(pipe), do: GenServer.cast(pipe, :close_input)

  # The next line of stdout, decoded, or `:timeout`.
  #
  def recv(pipe, timeout \\ 10_000), do: GenServer.call(pipe, {:recv, timeout}, timeout + 500)

  # Every line of stdout that is waiting, as raw binaries.
  #
  def lines(pipe), do: GenServer.call(pipe, :lines)

  @impl true
  def init(nil) do
    {:ok, %{input: :queue.new(), input_closed: false, output: [], reader: nil, receiver: nil}}
  end

  @impl true
  def handle_call(:read, from, %{reader: nil} = state) do
    case :queue.out(state.input) do
      {{:value, line}, rest} ->
        {:reply, {:ok, line}, %{state | input: rest}}

      {:empty, _} ->
        if state.input_closed do
          {:reply, :eof, state}
        else
          {:noreply, %{state | reader: from}}
        end
    end
  end

  def handle_call({:write, data}, _from, state) do
    {:reply, :ok, deliver(%{state | output: state.output ++ split(data)})}
  end

  def handle_call({:recv, timeout}, from, state) do
    case state.output do
      [line | rest] ->
        {:reply, decode(line), %{state | output: rest}}

      [] ->
        Process.send_after(self(), {:recv_timeout, from}, timeout)
        {:noreply, %{state | receiver: from}}
    end
  end

  def handle_call(:lines, _from, state), do: {:reply, state.output, state}

  @impl true
  def handle_cast({:input, data}, %{reader: from} = state) when not is_nil(from) do
    [line | rest] = split(data)
    GenServer.reply(from, {:ok, line})
    {:noreply, %{state | reader: nil, input: push_lines(state.input, rest)}}
  end

  def handle_cast({:input, data}, state) do
    {:noreply, %{state | input: push_lines(state.input, split(data))}}
  end

  def handle_cast(:close_input, %{reader: from} = state) when not is_nil(from) do
    GenServer.reply(from, :eof)
    {:noreply, %{state | input_closed: true, reader: nil}}
  end

  def handle_cast(:close_input, state), do: {:noreply, %{state | input_closed: true}}

  @impl true
  def handle_info({:recv_timeout, from}, %{receiver: from} = state) do
    GenServer.reply(from, :timeout)
    {:noreply, %{state | receiver: nil}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp push_lines(queue, lines), do: Enum.reduce(lines, queue, &:queue.in(&1, &2))

  defp split(data) do
    {lines, [last]} = String.split(data, "\n") |> Enum.split(-1)
    lines = Enum.map(lines, &(&1 <> "\n"))
    if last == "", do: lines, else: lines ++ [last]
  end

  defp deliver(%{receiver: nil} = state), do: state

  defp deliver(%{receiver: from, output: [line | rest]} = state) do
    GenServer.reply(from, decode(line))
    %{state | output: rest, receiver: nil}
  end

  defp decode(line) do
    text = String.trim_trailing(line, "\n")

    try do
      :json.decode(text)
    rescue
      _error -> text
    end
  end
end
