#
# The target of `OzMcp.Stream.Loop` for a `POST` stream. The state is
# one `%PostLoop{}` struct: the headless stream (the writer owns the
# connection), the id of the request and the kind of wait
# (`tasks/result` asks for an idle upgrade). The answer of the worker
# ends the loop; the death of the worker with no answer is a crash (a
# plain `500` before any event, an end with no result after). There is
# no `session_down/1` rule: the end of the session reaches the worker
# as a cancel of the request.
#
defmodule OzMcp.Transport.Http.PostLoop do
  @moduledoc false

  @behaviour OzMcp.Stream.Loop

  alias OzMcp.PostStream
  alias OzMcp.Transport.Http.Response

  defstruct stream: nil,
            rpc_id: nil,
            keep_alive: false

  @type t :: %__MODULE__{}

  @impl true
  def stream(payload, %{stream: stream} = state) do
    #
    # The loop reads the stream id before it calls this callback: the
    # payload is wrapped again, as `PostStream.relay/2` asks for.
    #
    message = {:oz_mcp_stream, stream.stream_id, payload}
    {:cont, %{state | stream: PostStream.relay(stream, message)}}
  end

  @impl true
  def idle(%{stream: stream, keep_alive: keep_alive} = state) do
    {:cont, %{state | stream: PostStream.heartbeat(stream, start: keep_alive)}}
  end

  @impl true
  def timer(reason, %{stream: stream} = state) when reason in [:expired, :poll],
    do: close(state, PostStream.start_stream(stream))

  # Not reached: the end of the session reaches the worker as a cancel.
  #
  @impl true
  def session_down(state), do: {:cont, state}

  @impl true
  def message({:answer, :internal_error}, state), do: aux_down(:no_answer, state)

  def message({:answer, kind, encoded, reply}, %{stream: stream}) do
    result = if kind == :rpc_error, do: :rpc_error, else: :ok

    conn =
      case PostStream.write_answer(stream, reply, encoded) do
        {{:streamed, conn}, _stream} -> conn
        {:not_streamed, stream} -> Response.json(stream.conn, 200, encoded)
      end

    {:halt, Plug.Conn.put_private(conn, :oz_mcp_result, result)}
  end

  # The worker crashed before any event: a plain JSON-RPC error with
  # the id of the request answers the client.
  #
  @impl true
  def aux_down(_reason, %{stream: %{started: false} = stream} = state),
    do: {:halt, Response.internal_error(stream.conn, state.rpc_id)}

  # The chunked response ends with no result (a second response head
  # is not possible).
  #
  def aux_down(_reason, %{stream: stream}), do: {:halt, stream.conn}

  # The close of a POST stream for real: start it if needed, write the
  # `retry:` hint and hand it off.
  #
  defp close(state, %{started: false} = stream), do: {:cont, %{state | stream: stream}}

  defp close(state, stream) do
    stream = PostStream.write_retry(stream)

    case PostStream.hand_off(stream) do
      {:handed_off, stream} -> {:halt, Plug.Conn.put_private(stream.conn, :oz_mcp_result, :ok)}
      {:answered, stream} -> {:cont, %{state | stream: stream}}
    end
  end
end
