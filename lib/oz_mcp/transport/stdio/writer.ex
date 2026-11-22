defmodule OzMcp.Transport.Stdio.Writer do
  @moduledoc false

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  # Queues a message, as encoded JSON text (iodata). The writer writes it as
  # one line. It never encodes: the sender of the message did.
  #
  def write(writer, data), do: GenServer.cast(writer, {:write, data})

  # Gives the writer the id of its stream (the session made it when it opened
  # the stream). The messages of the stream that came before are written
  # now, in order.
  #
  def attach(writer, stream_id), do: GenServer.cast(writer, {:attach, stream_id})

  # Returns when the messages that were queued before are written.
  #
  def flush(writer, timeout \\ 1_000), do: GenServer.call(writer, :flush, timeout)

  @impl true
  def init(opts) do
    #
    # The write can block while the pipe of stdout is full. The call runs
    # in the sink, so the writer keeps reading its mailbox and can count
    # its queue; the sink is linked to the writer.
    #
    write = Keyword.fetch!(opts, :write)
    {:ok, sink} = Task.start_link(fn -> sink_loop(write) end)

    {:ok,
     %{
       owner: Keyword.fetch!(opts, :owner),
       sink: sink,
       busy: false,
       queue: :queue.new(),
       queued: 0,
       max_queue: Keyword.fetch!(opts, :max_queue),
       waiters: [],
       stream_id: nil,
       pending: []
     }}
  end

  @impl true
  def handle_cast({:write, data}, state), do: emit(data, state)

  def handle_cast({:attach, stream_id}, state) do
    pending = Enum.reverse(state.pending)
    state = %{state | stream_id: stream_id, pending: []}

    Enum.reduce(pending, {:noreply, state}, fn
      message, {:noreply, state} -> handle_info(message, state)
      _message, stop -> stop
    end)
  end

  @impl true
  def handle_call(:flush, _from, %{busy: false, queued: 0} = state), do: {:reply, :ok, state}

  def handle_call(:flush, from, state),
    do: {:noreply, %{state | waiters: [from | state.waiters]}}

  # The writer accepts only the messages of the stream that the session
  # opened for it and drops the messages of other streams. A message
  # that comes before the attach cast waits for it; the wait does not
  # count for the queue bound (each message counts when the attach
  # replays it).
  #
  @impl true
  def handle_info({:oz_mcp_stream, _id, _payload} = message, %{stream_id: nil} = state),
    do: {:noreply, %{state | pending: [message | state.pending]}}

  def handle_info({:oz_mcp_stream, id, {:event, _event_id, data}}, %{stream_id: id} = state),
    do: emit(data, state)

  def handle_info({:oz_mcp_stream, id, :terminate}, %{stream_id: id} = state) do
    send(state.owner, {:stdio_session_ended, self()})
    {:noreply, state}
  end

  def handle_info({:oz_mcp_stream, _other_stream_id, _payload}, state), do: {:noreply, state}

  def handle_info({:written, :ok}, state) do
    case :queue.out(state.queue) do
      {{:value, line}, rest} ->
        send(state.sink, {:write, line, self()})
        {:noreply, %{state | queue: rest, queued: state.queued - 1}}

      {:empty, _queue} ->
        reply_waiters(%{state | busy: false})
    end
  end

  def handle_info({:written, {:error, reason}}, state),
    do: {:stop, {:shutdown, {:write_failed, reason}}, state}

  def handle_info(_other, state), do: {:noreply, state}

  defp emit(data, %{busy: false} = state) do
    send(state.sink, {:write, [data, "\n"], self()})
    {:noreply, %{state | busy: true}}
  end

  # One message sits in the sink, so the queue holds at most `max_queue`
  # messages.
  #
  defp emit(_data, %{queued: queued, max_queue: max_queue} = state) when queued >= max_queue do
    {:stop, {:shutdown, {:output_overflow, max_queue}}, state}
  end

  defp emit(data, state) do
    {:noreply, %{state | queue: :queue.in([data, "\n"], state.queue), queued: state.queued + 1}}
  end

  defp reply_waiters(%{waiters: []} = state), do: {:noreply, state}

  defp reply_waiters(%{waiters: waiters} = state) do
    for from <- Enum.reverse(waiters), do: GenServer.reply(from, :ok)
    {:noreply, %{state | waiters: []}}
  end

  defp sink_loop(write) do
    receive do
      {:write, iodata, reply_to} ->
        send(reply_to, {:written, do_write(write, iodata)})
        sink_loop(write)
    end
  end

  # The sink maps every other value of the write function to an error.
  #
  defp do_write(write, iodata) do
    case write.(iodata) do
      :ok -> :ok
      {:error, _reason} = error -> error
      other -> {:error, {:bad_return, other}}
    end
  rescue
    error -> {:error, Exception.normalize(:error, error, __STACKTRACE__)}
  end
end
