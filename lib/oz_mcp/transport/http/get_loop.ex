#
# The target of `OzMcp.Stream.Loop` for a `GET` stream, in its two
# modes (`:get` and `:resume`). The mode rules live here: an `:end` of
# the own stream halts in `:resume` and is dropped in `:get`; a poll
# close touches the session before the close; the stop of the session
# is a warning and a close.
#
defmodule OzMcp.Transport.Http.GetLoop do
  @moduledoc false

  @behaviour OzMcp.Stream.Loop

  alias OzMcp.Sessions
  alias OzMcp.Stream.Sse
  alias OzMcp.Transport.Http.GetStream

  require Logger

  @impl true
  def stream({:event, event_id, data}, %GetStream{conn: conn} = stream) do
    event = Sse.encode(Sse.make(event_id, "message", IO.iodata_to_binary(data)))

    case Plug.Conn.chunk(conn, event) do
      {:ok, conn} ->
        {:cont, %{stream | conn: conn}}

      {:error, _reason} ->
        {:halt, leave(stream)}
    end
  end

  # The session ended or dropped the stream, or a resume took it over;
  # no unregister here.
  #
  def stream(:terminate, %GetStream{} = stream) do
    {:halt, write_last_retry(stream)}
  end

  # The resumed POST stream is complete, or its request stopped.
  #
  def stream(:end, %GetStream{mode: :resume} = stream) do
    {:halt, leave(stream)}
  end

  # In the `:get` mode the `:end` of the own stream id is dropped.
  #
  def stream(:end, %GetStream{} = stream), do: {:cont, stream}

  @impl true
  def idle(%GetStream{conn: conn} = stream) do
    case Plug.Conn.chunk(conn, ": heartbeat\n\n") do
      {:ok, conn} ->
        {:cont, %{stream | conn: conn}}

      {:error, _reason} ->
        {:halt, leave(stream)}
    end
  end

  @impl true
  def timer(:poll, %GetStream{} = stream) do
    #
    # A touch starts the idle timer of the session again.
    #
    _ = Sessions.touch(stream.instance, stream.session_id)
    {:halt, close_stream(stream)}
  end

  def timer(:expired, %GetStream{} = stream), do: {:halt, close_stream(stream)}

  @impl true
  def session_down(%GetStream{} = stream) do
    Logger.warning("the session of a GET stream stopped: the stream closes with a retry hint")
    {:halt, close_stream(stream)}
  end

  @impl true
  def message(_payload, %GetStream{} = stream), do: {:cont, stream}

  @impl true
  def aux_down(_reason, %GetStream{} = stream), do: {:cont, stream}

  # The stream leaves the session, the session stays; the retry event
  # tells the client when to connect again.
  #
  defp close_stream(%GetStream{} = stream) do
    GetStream.cleanup_stream(stream)
    write_last_retry(stream)
  end

  defp write_last_retry(%GetStream{} = stream) do
    case GetStream.write_retry(stream) do
      {:ok, conn} -> conn
      _error -> stream.conn
    end
  end

  # A write failed, or a resumed stream is over: leave the session.
  #
  defp leave(%GetStream{} = stream) do
    GetStream.cleanup_stream(stream)
    stream.conn
  end
end
