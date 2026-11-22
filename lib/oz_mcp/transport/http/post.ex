#
# The `POST` route of the endpoint: the body shape, the POST stages, the
# touch of the session, the stream target of a callback and the run of
# the message in OzMcp.Handler. The status codes are in the guide "HTTP
# transport".
#
# The request registers before the handler runs, so a cancel reaches this
# process before the callback starts.
#
defmodule OzMcp.Transport.Http.Post do
  @moduledoc false

  import Plug.Conn, only: [put_private: 3, put_resp_header: 3]

  alias OzMcp.Context
  alias OzMcp.Context.Error
  alias OzMcp.{Instance, PostStream, Protocol, Session, Sessions, Telemetry, Validate, Wire}
  alias OzMcp.Pipeline.Bound
  alias OzMcp.Stream.{Expiry, Loop, Timers}
  alias OzMcp.Transport.Http.{Cors, PostLoop, PostWorker, Response}
  alias OzMcp.Utils.JsonRpc

  require Logger

  # The `POST` route: the body shape first, then the POST stages and the
  # handler. The whole route runs inside the `request` span.
  #
  @spec call(Plug.Conn.t()) :: Plug.Conn.t()
  def call(conn) do
    rpc = conn.body_params

    Telemetry.span(
      conn.private[:oz_mcp_telemetry],
      :request,
      %{method: Protocol.bound_method(rpc), kind: JsonRpc.kind(rpc)},
      :http_streamable,
      fn ->
        conn = do_call(conn)
        {conn, stop_meta(conn)}
      end
    )
  end

  # The status, the code of a refusal and the result.
  #
  defp stop_meta(%Plug.Conn{status: status, private: private}) do
    code = private[:oz_mcp_error_code]

    %{
      status: status,
      error_code: code,
      result: if(code, do: :error, else: Map.get(private, :oz_mcp_result, :error))
    }
  end

  defp do_call(conn) do
    #
    # Plug.Parsers wraps non-map JSON under "_json".
    #
    case conn.body_params do
      %{"_json" => list} when is_list(list) ->
        Response.refuse_body(conn, :http_batch_not_supported)

      %{"_json" => _scalar} ->
        Response.refuse_body(conn, :http_invalid_message)

      rpc when is_map(rpc) ->
        handle(conn)

      _ ->
        Response.refuse_body(conn, :http_invalid_message)
    end
  end

  defp handle(conn) do
    remember_id(conn.body_params)

    context =
      Context.new(
        conn.private.instance,
        :http_streamable,
        :rpc,
        conn.private[:oz_mcp_config]
      )
      |> Context.put_http_conn(conn)
      |> Validate.http_post()
      |> Response.unwrap()

    if context.conn.halted do
      context.conn
    else
      case touch_session(context) do
        :ok ->
          serve(context)

        {:error, :no_session} ->
          Response.invalid_session(context.conn)

        {:error, _reason} ->
          Response.unavailable(context.conn, Response.reply_id(context))
      end
    end
  end

  # Only a method that runs a callback gets a stream target.
  #
  defp serve(%{session_id: nil} = context), do: context |> dispatch(nil) |> elem(0)

  defp serve(context) do
    if Context.request?(context) do
      case open_request(context) do
        {:stream, worker, ref, stream} ->
          stream_run(context, stream, worker, ref)

        {:plain, nil} ->
          run(context, nil)

        # The id of a request MUST NOT be reused while it runs.
        #
        {:error, :duplicate} ->
          duplicate_request_id(context.conn, context.rpc_id)

        {:error, :no_session} ->
          Response.invalid_session(context.conn)

        {:error, _reason} ->
          Response.unavailable(context.conn, Response.reply_id(context))
      end
    else
      context |> dispatch(nil) |> elem(0)
    end
  end

  # A streaming method with no task opens the stream and starts the
  # worker. A task-augmented tools/call only creates the task.
  #
  defp open_request(%{bound: %Bound{task: nil}} = context) do
    if PostStream.stream_method?(context.rpc_method) do
      stream_open(context)
    else
      plain_open(context)
    end
  end

  defp open_request(context), do: plain_open(context)

  defp stream_open(context) do
    with {:ok, worker} <- PostWorker.start(context.instance) do
      #
      # The monitor of the worker is the tag of its answer.
      #
      ref = Process.monitor(worker)

      case PostStream.begin(
             context.instance,
             context.session_id,
             context.rpc_id,
             context.conn,
             &Cors.put_cors_headers/1,
             request_owner: worker
           ) do
        {:ok, stream} ->
          go(worker, ref, context, stream)
          {:stream, worker, ref, stream}

        {:error, reason} ->
          send(worker, :oz_mcp_worker_stop)
          Process.demonitor(ref, [:flush])
          {:error, reason}
      end
    end
  end

  # The go message carries the headless stream and the log metadata.
  #
  defp go(worker, ref, context, stream) do
    headless = %{stream | conn: nil}

    send(
      worker,
      {:oz_mcp_worker_go, ref, %{context | conn: nil}, headless, Logger.metadata()}
    )
  end

  # The loop of the stream runs in this process, with `PostLoop`.
  #
  defp stream_run(context, stream, worker, ref) do
    opts = instance_opts(context)

    loop = %Loop{
      target: PostLoop,
      state: %PostLoop{
        stream: stream,
        rpc_id: Response.reply_id(context),
        keep_alive: context.rpc_method == "tasks/result"
      },
      stream_id: stream.stream_id,
      heartbeat_ms: opts.sse_heartbeat_ms,
      principal: context.principal,
      server_ref: nil,
      aux_ref: ref,
      expiry_timer: Expiry.arm(context.principal),
      poll_timer: Timers.arm_poll(opts.sse_max_stream_ms)
    }

    try do
      Loop.run(loop)
    catch
      kind, reason ->
        #
        # The worker owns the request: its stop makes the session stop
        # the callback. `PostStream.close/1` would leave it running.
        #
        Process.exit(worker, :shutdown)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp plain_open(context) do
    case Session.open_request(context.instance, context.session_id, context.rpc_id, self(), nil) do
      :ok -> {:plain, nil}
      {:error, _reason} = error -> error
    end
  end

  # A crash keeps the stream from before the answer and `close/1` frees
  # it.
  #
  defp run(context, stream) do
    {conn, stream} = dispatch(context, stream)
    _ = release(context, stream)
    conn
  catch
    kind, reason ->
      _ = release(context, stream)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp release(context, nil),
    do: Session.end_request(context.instance, context.session_id, context.rpc_id)

  defp release(_context, stream), do: PostStream.close(stream)

  defp dispatch(context, stream) do
    case OzMcp.Handler.handle_request(context, stream) do
      #
      # The session id of a new session goes into the response header.
      #
      {{:session_created, session_id, rpc_response}, _stream} ->
        conn = put_resp_header(context.conn, "mcp-session-id", session_id)
        answer(%{context | conn: conn}, rpc_response, nil, :ok)

      # A limit on the number of sessions refused the session.
      #
      {{:refused, :too_many_sessions}, _stream} ->
        conn =
          context
          |> Context.put_error(:http_too_many_sessions)
          |> Response.handle_context_error()
          |> Map.fetch!(:conn)

        {conn, stream}

      {{:rpc_success, rpc_response}, stream} ->
        answer(context, rpc_response, stream, :ok)

      {{:rpc_error, rpc_response}, stream} ->
        answer(context, rpc_response, stream, :rpc_error)

      # A store of the server failed: a server error.
      #
      {:internal_error, _stream} ->
        {Response.internal_error(context.conn, Response.reply_id(context)), stream}

      # A notification, or the answer of the client: nothing to send.
      #
      {:notified, _stream} ->
        {context.conn |> Response.empty(202) |> put_private(:oz_mcp_result, :ok), stream}
    end
  end

  # The refusal code goes on the conn, like the pipeline refusals.
  #
  defp duplicate_request_id(conn, rpc_id) do
    {status, body} = Error.build(Error.new(:rpc_duplicate_request_id), rpc_id)

    conn
    |> put_private(:oz_mcp_error_code, :rpc_duplicate_request_id)
    |> Response.json(status, body)
  end

  # The id is remembered before the validation: a raise there loses the
  # context and the last resort must echo the id.
  #
  defp remember_id(rpc) do
    if JsonRpc.kind(rpc) == :request, do: Response.remember_request_id(rpc["id"])
    :ok
  end

  defp touch_session(%{session_id: nil}), do: :ok

  defp touch_session(context) do
    granted = context.principal && context.principal.scopes
    Sessions.touch(context.instance, context.session_id, granted)
  end

  defp answer(context, rpc_response, stream, result) do
    encoded = Wire.encode_answer(rpc_response)

    {conn, stream} =
      case PostStream.answer(encoded, stream) do
        {{:streamed, conn}, stream} -> {conn, stream}
        {:not_streamed, stream} -> {Response.json(context.conn, 200, encoded), stream}
      end

    {put_private(conn, :oz_mcp_result, result), stream}
  end

  # The config that the request froze when it came in.
  #
  defp instance_opts(%Context{config: %Instance.Config{opts: opts}}), do: opts
  defp instance_opts(context), do: Instance.opts(context.instance)
end
