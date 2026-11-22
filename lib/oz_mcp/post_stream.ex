#
# Server-Sent Events stream of a `POST` request.
#
# When the callback of a `POST` request sends messages to the client,
# the response is upgraded to `text/event-stream`: the messages travel
# as events with ids `<stream id>:<n>`, the stream starts with a
# priming event (`<stream id>:0`, empty data) and the response of the
# request is the last event of the stream. The full rules — the resume
# with a `GET` and `Last-Event-ID`, the lazy upgrade, the close at the
# expiry of the principal or at `sse_max_stream_ms`, the hand-off on a
# disconnect — live in the guide "HTTP transport", section "The stream
# of a POST request".
#
# The process that handles the `POST` owns the stream: it carries the
# `%OzMcp.PostStream{}` struct through its wait and hands it back with
# the result of the request (see OzMcp.Stream). `begin/5` registers
# the request; a transport with no HTTP response (stdio) uses
# `begin_sink/4` and `finish/2` with a function in place of the
# connection.
#
defmodule OzMcp.PostStream do
  @moduledoc false

  @behaviour OzMcp.Stream

  import Plug.Conn, except: [push: 2]

  alias OzMcp.{Method, Session, Sessions, Wire}
  alias OzMcp.Method.Table
  alias OzMcp.Stream.Sse
  alias OzMcp.Utils.Generator

  @enforce_keys [:instance, :stream_id]
  defstruct [
    :conn,
    :prepare,
    :sink,
    :instance,
    :session_id,
    :request_id,
    :registration,
    :stream_id,
    seq: 0,
    started: false,
    failed: false,
    detached: false,
    ended: false
  ]

  @type t :: %__MODULE__{}

  # True for a method whose callback can send messages to the client while
  # the request runs, so a request that needs a stream target (`begin/5`).
  #
  @spec stream_method?(term()) :: boolean()
  def stream_method?(method) do
    case Table.fetch(method) do
      {:ok, %Method{streaming: streaming}} -> streaming
      :error -> false
    end
  end

  # The process that owns the stream of a request, when there is one. A
  # `nil` owner means the stream lost its live owner: the events go to the
  # log.
  #
  @spec owner(module(), String.t() | nil, String.t() | integer() | nil) ::
          {:ok, {pid() | nil, String.t()}} | :none
  def owner(instance, session_id, request_id)
      when is_binary(session_id) and
             (is_binary(request_id) or is_integer(request_id)),
      do: Session.stream_owner(instance, session_id, request_id)

  def owner(_instance, _session_id, _request_id), do: :none

  # Sends a message that belongs to a request of the client: to the owner
  # of its stream, or to the `GET` stream of the session.
  # `{:error, :not_encodable}` when the message holds a term that JSON
  # cannot encode.
  #
  @spec route(module(), String.t() | nil, String.t() | integer() | nil, map()) ::
          :ok | {:error, :not_encodable}
  def route(instance, session_id, request_id, message) do
    case Sessions.emit(instance, session_id, {:request_or_session, request_id}, message) do
      {:error, :not_encodable} = error -> error
      _ -> :ok
    end
  end

  # Like `route/4` for a progress notification: the session drops a value
  # that does not increase.
  #
  @spec route_progress(
          module(),
          String.t() | nil,
          String.t() | integer() | nil,
          term(),
          term(),
          map()
        ) ::
          :ok | {:error, :not_encodable}
  def route_progress(instance, session_id, request_id, token, progress, message) do
    case Sessions.emit_progress(
           instance,
           session_id,
           {:request_or_session, request_id},
           token,
           progress,
           message
         ) do
      {:error, :not_encodable} = error -> error
      _ -> :ok
    end
  end

  # Like `route/4` for a `notifications/message`; the session checks the
  # log rate before it emits.
  #
  @spec route_log(module(), String.t() | nil, String.t() | integer() | nil, map()) ::
          :ok | {:error, :not_encodable}
  def route_log(instance, session_id, request_id, message) do
    case Sessions.emit_log(instance, session_id, {:request_or_session, request_id}, message) do
      {:error, :not_encodable} = error -> error
      _ -> :ok
    end
  end

  # Registers the request in its session and makes the calling process the
  # owner of its stream. `prepare` adds the headers (CORS) of the router.
  # `{:error, :duplicate}` when the request id already has a stream.
  #
  @spec begin(
          module(),
          String.t() | nil,
          String.t() | integer() | nil,
          Plug.Conn.t(),
          (Plug.Conn.t() -> Plug.Conn.t())
        ) ::
          {:ok, t()}
          | {:error, :duplicate | :no_session | :unavailable | :timeout | :badarg}
  def begin(instance, session_id, request_id, conn, prepare),
    do: begin(instance, session_id, request_id, conn, prepare, [])

  # Like `begin/5` with `request_owner: pid`: that process owns the request
  # in the session, while the calling process owns the stream.
  #
  @spec begin(
          module(),
          String.t() | nil,
          String.t() | integer() | nil,
          Plug.Conn.t(),
          (Plug.Conn.t() -> Plug.Conn.t()),
          keyword()
        ) ::
          {:ok, t()}
          | {:error, :duplicate | :no_session | :unavailable | :timeout | :badarg}
  def begin(instance, session_id, request_id, conn, prepare, opts) do
    flush()

    stream_id = Generator.stream_id()
    request_owner = Keyword.get(opts, :request_owner, self())

    with {:ok, registration} <-
           open(instance, session_id, request_id, {stream_id, :sse}, request_owner) do
      {:ok,
       %__MODULE__{
         conn: conn,
         prepare: prepare,
         instance: instance,
         session_id: session_id,
         request_id: request_id,
         registration: registration,
         stream_id: stream_id
       }}
    end
  end

  # Like `begin/5` with a function in place of a connection (stdio): `sink`
  # takes one message as JSON text, must not block and gets the messages
  # and the response (`finish/2`) in order.
  #
  @spec begin_sink(
          module(),
          String.t() | nil,
          String.t() | integer() | nil,
          (map() -> any())
        ) ::
          {:ok, t()}
          | {:error, :duplicate | :no_session | :unavailable | :timeout | :badarg}
  def begin_sink(instance, session_id, request_id, sink) when is_function(sink, 1) do
    flush()

    stream_id = Generator.stream_id()

    with {:ok, registration} <- open(instance, session_id, request_id, {stream_id, :sink}, self()) do
      {:ok,
       %__MODULE__{
         sink: sink,
         instance: instance,
         session_id: session_id,
         request_id: request_id,
         registration: registration,
         stream_id: stream_id
       }}
    end
  end

  # Ends a request that has a sink: writes the queued messages, then the
  # response. Without a sink it only forgets the stream.
  #
  @spec finish(map() | binary(), t() | nil) :: :ok
  def finish(_response, nil), do: :ok
  def finish(_response, %__MODULE__{ended: true}), do: :ok

  def finish(response, %__MODULE__{} = stream) do
    case detach(stream) do
      :gone ->
        :ok

      :ok ->
        stream = drain(stream)

        case stream.sink do
          sink when is_function(sink) -> sink.(encode_response(response))
          _ -> :ok
        end

        :ok
    end
  end

  # Writes a message on the stream (OzMcp.Stream callback); the first
  # message starts it. A message of another stream id is dropped.
  #
  @spec relay(t(), {:oz_mcp_stream, String.t() | nil, term()}) :: t()
  def relay(%__MODULE__{ended: true} = stream, _message), do: stream

  def relay(%__MODULE__{stream_id: stream_id} = stream, {:oz_mcp_stream, stream_id, payload}),
    do: handle(stream, payload)

  def relay(%__MODULE__{} = stream, {:oz_mcp_stream, _other_stream_id, _payload}), do: stream

  defp handle(%__MODULE__{sink: sink} = stream, :taken_over) when is_function(sink),
    do: stream

  defp handle(%__MODULE__{} = stream, :taken_over), do: %{stream | failed: true}

  defp handle(%__MODULE__{sink: sink} = stream, {:event, _event_id, data})
       when is_function(sink) do
    sink.(IO.iodata_to_binary(data))
    stream
  end

  defp handle(%__MODULE__{failed: true} = stream, {:event, _event_id, _data}), do: stream

  defp handle(stream, {:event, event_id, data}) do
    stream = start(stream)
    write_event(stream, event_id, data)
  end

  defp handle(stream, :terminate), do: stream
  defp handle(stream, :end), do: stream

  # Ends the stream with the response of the request, as its final event.
  #
  # Returns `{{:streamed, conn}, stream}` when the stream was started, or
  # `{:not_streamed, stream}` when the caller must send the plain response.
  # The returned stream has `ended: true`: give it to `close/1`, which then
  # sends nothing.
  #
  @spec answer(map() | binary(), t() | nil) ::
          {{:streamed, Plug.Conn.t()} | :not_streamed, t() | nil}
  def answer(_response, nil), do: {:not_streamed, nil}

  def answer(response, %__MODULE__{} = stream) do
    encoded = encode_response(response)
    write_answer(stream, close_in_session(stream, encoded), encoded)
  end

  # Asks the session to number and log the response, without a write. The
  # reply is `{:sse, event_id}`, `:plain`, `:gone` or `{:error, reason}`.
  #
  @spec close_in_session(t(), binary()) ::
          {:sse, String.t()} | :plain | :gone | {:error, term()}
  def close_in_session(%__MODULE__{} = stream, encoded), do: close_request(stream, encoded)

  # Writes the end of the stream from the reply of `close_in_session/2`.
  #
  @spec write_answer(t(), {:sse, String.t()} | :plain | :gone | {:error, term()}, binary()) ::
          {{:streamed, Plug.Conn.t()} | :not_streamed, t()}
  def write_answer(stream, {:sse, event_id}, encoded) do
    #
    # The drain writes the earlier events in the order of their ids, then
    # the response. A stream that a resumer took over writes nothing.
    #
    stream = stream |> drain() |> write_final(event_id, encoded)
    stream = %{stream | ended: true}

    if stream.started,
      do: {{:streamed, stream.conn}, stream},
      else: {:not_streamed, stream}
  end

  def write_answer(stream, :plain, encoded) do
    stream = %{stream | ended: true}

    if stream.started,
      do: {{:streamed, write_final(stream, nil, encoded).conn}, stream},
      else: {:not_streamed, stream}
  end

  def write_answer(stream, {:error, _reason}, encoded) do
    #
    # The chunked response cannot go back to plain JSON, so a started
    # stream writes the response with no id. The flag `ended` is the only
    # guard against a second write: with no session there is no entry.
    #
    stream = %{drain(stream) | ended: true}

    if stream.started,
      do: {{:streamed, write_final(stream, nil, encoded).conn}, stream},
      else: {:not_streamed, stream}
  end

  def write_answer(stream, :gone, _encoded) do
    {:not_streamed, %{stream | ended: true}}
  end

  # Writes a comment (`: heartbeat`) so that a proxy does not close an idle
  # connection. `start: true` upgrades a plain response to an event stream
  # first. Does nothing on a sink or a gone connection.
  #
  @spec heartbeat(t() | nil, keyword()) :: t() | nil
  def heartbeat(nil, _opts), do: nil

  def heartbeat(%__MODULE__{conn: nil} = stream, _opts), do: stream

  def heartbeat(%__MODULE__{detached: true} = stream, _opts), do: stream

  def heartbeat(%__MODULE__{failed: false} = stream, opts) do
    stream
    |> maybe_start(Keyword.get(opts, :start, false))
    |> write_heartbeat()
  end

  def heartbeat(%__MODULE__{} = stream, _opts), do: stream

  # Starts a stream that did not start: the head, the priming event and the
  # flag `started`. `:gone` starts nothing.
  #
  @spec start_stream(t()) :: t()
  def start_stream(%__MODULE__{started: true} = stream), do: stream

  def start_stream(%__MODULE__{registration: {instance, session_id, request_id}} = stream) do
    case Session.promote_stream(instance, session_id, request_id, stream.stream_id) do
      :ok -> start(stream)
      _gone_or_error -> stream
    end
  end

  def start_stream(%__MODULE__{} = stream), do: start(stream)

  # Gives the stream no live owner: the connection ends, the callback goes
  # on and the later events go to the log. `{:handed_off, stream}` or
  # `{:answered, stream}`.
  #
  @spec hand_off(t()) :: {:handed_off, t()} | {:answered, t()}
  def hand_off(%__MODULE__{registration: {instance, session_id, request_id}} = stream) do
    case Session.hand_off_stream(instance, session_id, request_id, stream.stream_id) do
      :ok -> {:handed_off, %{stream | failed: true, detached: true}}
      _gone_or_error -> {:answered, stream}
    end
  end

  def hand_off(%__MODULE__{} = stream), do: {:answered, stream}

  # Writes the `retry:` hint of `:sse_retry_ms`; a failed write marks the
  # stream as failed.
  #
  @spec write_retry(t()) :: t()
  def write_retry(%__MODULE__{conn: nil} = stream), do: stream
  def write_retry(%__MODULE__{registration: nil} = stream), do: stream
  def write_retry(%__MODULE__{failed: true} = stream), do: stream

  def write_retry(%__MODULE__{} = stream) do
    retry_ms = OzMcp.Instance.opts(stream.instance).sse_retry_ms

    case Plug.Conn.chunk(stream.conn, Sse.encode(%Sse{retry: retry_ms})) do
      {:ok, conn} -> %{stream | conn: conn}
      {:error, _reason} -> %{stream | failed: true}
    end
  end

  # Forgets the stream. An answered or detached stream sends nothing; any
  # other sends one `end_request`.
  #
  @spec close(t() | nil) :: :ok
  def close(nil), do: :ok
  def close(%__MODULE__{ended: true}), do: :ok
  def close(%__MODULE__{detached: true}), do: :ok
  def close(%__MODULE__{registration: nil}), do: :ok

  def close(%__MODULE__{registration: {instance, session_id, request_id}}) do
    _ = Session.end_request(instance, session_id, request_id)
    :ok
  end

  # One call registers the request and makes the process the target of
  # its messages.
  #
  defp open(instance, session_id, request_id, stream, request_owner)
       when is_binary(session_id) and (is_binary(request_id) or is_integer(request_id)) do
    case Session.open_request(instance, session_id, request_id, request_owner, stream,
           stream_owner: self()
         ) do
      :ok -> {:ok, {instance, session_id, request_id}}
      {:error, _reason} = error -> error
    end
  end

  defp open(_instance, _session_id, _request_id, _stream, _request_owner), do: {:ok, nil}

  # `:gone` when a previous answer/finish/close on a copy of the struct
  # dropped the entry: a caller that reuses the old struct writes nothing.
  #
  defp detach(%__MODULE__{registration: nil}), do: :ok

  defp detach(%__MODULE__{registration: {instance, session_id, request_id}} = stream) do
    case Session.close_request(instance, session_id, request_id, stream.stream_id, :detach) do
      :gone -> :gone
      _ok_or_error -> :ok
    end
  end

  # The events of this stream that arrived after the last relay; the
  # messages of another stream stay (they are for the GET stream).
  #
  defp drain(%__MODULE__{stream_id: stream_id} = stream) do
    receive do
      {:oz_mcp_stream, ^stream_id, payload} ->
        drain(handle(stream, payload))
    after
      0 -> stream
    end
  end

  # Messages left by a previous request of the same process (the GET
  # stream messages stay).
  #
  defp flush do
    receive do
      {:oz_mcp_stream, stream_id, _payload} when stream_id != nil -> flush()
      {:oz_mcp_loop, _ref, _payload} -> flush()
    after
      0 -> :ok
    end
  end

  defp encode_response(response) when is_binary(response), do: response
  defp encode_response(response), do: Wire.encode_answer(response)

  # The id of the session, or `nil` for a stream that no session numbered
  # (no `id:` line).
  #
  defp write_final(%__MODULE__{registration: nil, started: true} = stream, nil, encoded) do
    seq = stream.seq + 1
    write_event(%{stream | seq: seq}, "#{stream.stream_id}:#{seq}", encoded)
  end

  defp write_final(stream, event_id, encoded), do: write_event(stream, event_id, encoded)

  defp write_event(%__MODULE__{failed: true} = stream, _event_id, _data), do: stream

  defp write_event(stream, event_id, data) do
    encoded = Sse.encode(Sse.make(event_id, "message", IO.iodata_to_binary(data)))

    case Plug.Conn.chunk(stream.conn, encoded) do
      {:ok, conn} -> %{stream | conn: conn}
      {:error, _reason} -> %{stream | failed: true}
    end
  end

  defp maybe_start(%__MODULE__{started: true} = stream, _start), do: stream
  defp maybe_start(stream, true), do: start_stream(stream)
  defp maybe_start(stream, false), do: stream

  defp write_heartbeat(%__MODULE__{started: true, failed: false} = stream) do
    case Plug.Conn.chunk(stream.conn, ": heartbeat\n\n") do
      {:ok, conn} -> %{stream | conn: conn}
      {:error, _reason} -> %{stream | failed: true}
    end
  end

  defp write_heartbeat(stream), do: stream

  defp start(%__MODULE__{started: true} = stream), do: stream

  defp start(stream) do
    conn =
      stream.conn
      |> stream.prepare.()
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)

    case Plug.Conn.chunk(conn, Sse.priming("#{stream.stream_id}:0")) do
      {:ok, conn} -> %{stream | conn: conn, started: true}
      {:error, _reason} -> %{stream | conn: conn, started: true, failed: true}
    end
  end

  # The session numbers, logs and hands on the response and frees the
  # request.
  #
  defp close_request(%{ended: true}, _encoded), do: :gone
  defp close_request(%{registration: nil}, _encoded), do: :plain

  defp close_request(
         %{
           registration: {instance, session_id, request_id},
           stream_id: stream_id,
           started: started?
         },
         encoded
       ) do
    Session.close_request(
      instance,
      session_id,
      request_id,
      stream_id,
      {:response, encoded, started?}
    )
  end

  # Splits an event id of the form `<stream>:<n>`; `:invalid` for any other
  # text. The id of a `GET` stream starts with `g.`.
  #
  @spec parse_event_id(term()) :: {String.t(), non_neg_integer()} | :invalid
  defdelegate parse_event_id(event_id), to: OzMcp.Session.Replay
end
