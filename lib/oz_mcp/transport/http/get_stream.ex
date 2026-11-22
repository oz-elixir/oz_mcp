#
# The `GET` stream of the Streamable HTTP transport: it validates the
# request, attaches the stream to the session, writes the head and the
# replay and waits in OzMcp.Stream.Loop.
#
# The rules of the stream live in the guide "HTTP transport". A warning
# holds no text of the `Last-Event-ID` and no data of an event.
#
defmodule OzMcp.Transport.Http.GetStream do
  @moduledoc false

  import Plug.Conn

  alias OzMcp.Context
  alias OzMcp.Session
  alias OzMcp.Sessions
  alias OzMcp.Stream.Expiry
  alias OzMcp.Stream.Loop
  alias OzMcp.Stream.Sse
  alias OzMcp.Stream.Timers
  alias OzMcp.Transport.Http.{Cors, GetLoop, Response}
  alias OzMcp.Utils.Log
  alias OzMcp.Validate

  require Logger

  # Every chunk write returns the conn.
  #
  defstruct [
    :conn,
    :instance,
    :session_id,
    :stream_id,
    :mode,
    :heartbeat_ms,
    :retry_ms,
    :max_stream_ms,
    :server_ref,
    :principal,
    poll_timer: nil,
    expiry_timer: nil
  ]

  @type t :: %__MODULE__{}

  # The `GET` route of the endpoint: the GET stages validate the request
  # and a request that passes serves its stream until it ends.
  #
  @spec call(Plug.Conn.t()) :: Plug.Conn.t()
  def call(conn) do
    context =
      Context.new(
        conn.private.instance,
        :http_streamable,
        :http,
        conn.private[:oz_mcp_config]
      )
      |> Context.put_http_conn(conn)
      |> Validate.http_get()
      |> Response.unwrap()

    if context.conn.halted do
      context.conn
    else
      check_subscriptions(context)
      serve(context)
    end
  end

  # The touch runs before the attach, so the subscription check lands
  # first.
  #
  defp check_subscriptions(context) do
    granted = context.principal && context.principal.scopes
    _ = Sessions.touch(context.instance, context.session_id, granted)
    :ok
  end

  @doc false
  @spec serve(Context.t()) :: Plug.Conn.t()
  def serve(%Context{} = context) do
    Logger.debug("Get SSE stream")

    case OzMcp.Instance.config(context.instance, context) do
      :not_running ->
        Response.unavailable(context.conn)

      {:ok, %{opts: opts}} ->
        #
        # The attach is one step before the head is committed, so a
        # deleted session still gets a clean 404 and the chunk order
        # stays old-to-new.
        #
        case Session.open_stream(
               context.instance,
               context.session_id,
               :get,
               self(),
               last_event_id(context.conn)
             ) do
          {:ok, %{mode: :resume} = payload} ->
            resume_stream(context, opts, payload)

          {:ok, %{mode: :get} = payload} ->
            open_stream(context, opts, payload)

          {:error, :too_many_streams} ->
            context
            |> Context.put_error(:http_too_many_streams)
            |> Response.handle_context_error()
            |> Map.fetch!(:conn)

          {:error, reason} when reason in [:unavailable, :timeout] ->
            Response.unavailable(context.conn)

          # Nothing to resume; `204` stops the reconnect loop.
          #
          {:error, :no_stream} ->
            Response.empty(context.conn, 204)

          _ ->
            Response.invalid_session(context.conn)
        end
    end
  end

  # The retry hint, the priming event or the replay, then the live events.
  #
  defp open_stream(context, opts, %{
         stream_id: stream_id,
         replay: events,
         priming_id: priming_id,
         session_pid: session_pid
       }) do
    stream = %__MODULE__{
      mode: :get,
      stream_id: stream_id,
      conn: open_response(context.conn),
      instance: context.instance,
      session_id: context.session_id,
      heartbeat_ms: opts.sse_heartbeat_ms,
      retry_ms: opts.sse_retry_ms,
      max_stream_ms: opts.sse_max_stream_ms,
      principal: context.principal
    }

    with {:ok, conn} <- write_retry(stream),
         {:ok, conn} <- prime(conn, priming_id),
         {:ok, conn} <- write_replay(conn, events) do
      #
      # The timers are armed after the replay: a stream that ends before
      # the loop leaves nothing to remove.
      #
      loop(%{
        stream
        | conn: conn,
          expiry_timer: Expiry.arm(stream.principal),
          poll_timer: Timers.arm_poll(stream.max_stream_ms),
          server_ref: Process.monitor(session_pid)
      })
    else
      _write_failed ->
        cleanup_stream(stream)
        stream.conn
    end
  end

  # A GET that resumes a POST stream: the replay, then the live events.
  # No priming event: the Last-Event-ID of the client is its position.
  #
  defp resume_stream(context, opts, %{
         replay: events,
         ended: ended,
         stream_id: stream_id,
         session_pid: session_pid
       }) do
    stream = %__MODULE__{
      mode: :resume,
      stream_id: stream_id,
      conn: open_response(context.conn),
      instance: context.instance,
      session_id: context.session_id,
      heartbeat_ms: opts.sse_heartbeat_ms,
      retry_ms: opts.sse_retry_ms,
      max_stream_ms: opts.sse_max_stream_ms,
      principal: context.principal
    }

    with {:ok, conn} <- first_chunks(stream, ended),
         {:ok, conn} <- write_replay(conn, events) do
      if ended do
        conn
      else
        #
        # The monitor is armed after the replay is written.
        #
        loop(%{
          stream
          | conn: conn,
            expiry_timer: Expiry.arm(stream.principal),
            poll_timer: Timers.arm_poll(stream.max_stream_ms),
            server_ref: Process.monitor(session_pid)
        })
      end
    else
      _write_failed ->
        cleanup_stream(stream)
        stream.conn
    end
  end

  # A live stream opens with the retry hint; a stream that is over opens
  # with its replay.
  #
  defp first_chunks(%__MODULE__{conn: conn}, true), do: {:ok, conn}

  defp first_chunks(%__MODULE__{} = stream, false), do: write_retry(stream)

  defp open_response(conn) do
    conn
    |> Cors.put_cors_headers()
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> send_chunked(200)
  end

  defp last_event_id(conn) do
    case get_req_header(conn, "last-event-id") do
      [last_event_id | _] -> last_event_id
      [] -> nil
    end
  end

  # The head of a fresh stream and the last chunk of a self-closing one.
  #
  @doc false
  @spec write_retry(t()) :: {:ok, Plug.Conn.t()} | {:error, term()}
  def write_retry(%__MODULE__{conn: conn, retry_ms: retry_ms}),
    do: Plug.Conn.chunk(conn, Sse.encode(%Sse{retry: retry_ms}))

  # The client can resume from this id at once.
  #
  @doc false
  @spec prime(Plug.Conn.t(), String.t() | nil) ::
          {:ok, Plug.Conn.t()} | {:error, term()}
  def prime(conn, nil), do: {:ok, conn}
  def prime(conn, id), do: Plug.Conn.chunk(conn, Sse.priming(id))

  # The stored id is reused byte-for-byte: a fresh id would break the
  # Last-Event-ID chain of the client.
  #
  @doc false
  @spec write_replay(Plug.Conn.t(), [{String.t(), binary()}]) ::
          {:ok, Plug.Conn.t()} | {:error, Plug.Conn.t()}
  def write_replay(conn, []), do: {:ok, conn}

  def write_replay(conn, [{event_id, encoded} | rest]) do
    event = Sse.encode(Sse.make(event_id, "message", encoded))

    case Plug.Conn.chunk(conn, event) do
      {:ok, conn} -> write_replay(conn, rest)
      {:error, _reason} -> {:error, conn}
    end
  end

  @doc false
  @spec loop(t()) :: Plug.Conn.t()
  def loop(%__MODULE__{} = stream) do
    %Loop{
      target: GetLoop,
      state: stream,
      stream_id: stream.stream_id,
      heartbeat_ms: stream.heartbeat_ms,
      principal: stream.principal,
      server_ref: stream.server_ref,
      poll_timer: stream.poll_timer,
      expiry_timer: stream.expiry_timer
    }
    |> Loop.run()
  end

  # A GET stream unregisters; a resumer detaches, so another GET can
  # resume it. Best effort: an exit must not stop this process.
  #
  @doc false
  @spec cleanup_stream(t()) :: :ok
  def cleanup_stream(%__MODULE__{mode: :resume} = stream) do
    best_effort(fn ->
      Session.detach_resume(stream.instance, stream.session_id, stream.stream_id, self())
    end)
  end

  def cleanup_stream(%__MODULE__{} = stream) do
    best_effort(fn -> Session.close_stream(stream.instance, stream.session_id, self()) end)
  end

  defp best_effort(fun) do
    _ = fun.()
    :ok
  catch
    :exit, reason ->
      Logger.debug(fn ->
        "stream cleanup skipped: " <> Log.describe(:exit, reason, __STACKTRACE__)
      end)

      :ok
  end
end
