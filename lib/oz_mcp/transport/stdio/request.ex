defmodule OzMcp.Transport.Stdio.Request do
  @moduledoc false

  alias OzMcp.{Handler, PostStream, Session, Telemetry, Validate, Wire}
  alias OzMcp.Transport.Stdio.{Outcome, Writer}
  alias OzMcp.Utils.Log

  require Logger

  # Runs one validated request in a child process.
  #
  @spec child(map(), pid(), Telemetry.token() | nil) :: :ok
  def child(context, writer, token) do
    _outcome =
      with_registration(:child, context, writer, token, fn stream ->
        case Validate.stdio_bind(context) do
          {:cont, bound} ->
            {result, stream} = Handler.handle_request(bound, stream)
            {Outcome.from_handler(result, bound.rpc_id), stream}

          {:halt, refused} ->
            {Outcome.validation(refused), stream}
        end
      end)

    :ok
  end

  # Runs one validated message in the transport process. `adopt` takes the
  # id of a new session and gives the new state or a stop tuple.
  #
  @spec inline(map(), pid(), Telemetry.token() | nil, (String.t() -> term())) :: Outcome.t()
  def inline(context, writer, token, adopt) do
    with_registration(:inline, context, writer, token, fn handle ->
      result = Handler.handle_request(context)

      if result == :internal_error and is_nil(context.rpc_id),
        do: Logger.warning("stdio notification failed")

      {result |> Outcome.from_handler(context.rpc_id) |> adopted(adopt), handle}
    end)
  end

  # Answers a message that the validation refused and ends its span.
  #
  # The span ends, then the answer goes out. A notification and an
  # answer of the client get no line (JSON-RPC 2.0): the refusal is a
  # warning log only.
  #
  @spec refuse(map(), pid(), Telemetry.token() | nil) :: Outcome.t()
  def refuse(context, writer, token) do
    outcome = Outcome.validation(context)
    end_span(token, outcome.span)

    if outcome.line do
      write_line(writer, outcome.line)
    else
      Logger.warning(refused_text(context) <> inspect(context.error.code))
    end

    outcome
  end

  defp refused_text(%{rpc_kind: :response}), do: "stdio response of the client refused: "

  defp refused_text(_context), do: "stdio notification refused: "

  # Ends the span of a message that raised before its run and writes the
  # crash line.
  #
  # The span ends one time, with the id of the raw message, so the
  # answer of a client keeps its id.
  #
  @spec crashed(term(), pid(), Telemetry.token() | nil, {atom(), term(), list()}) :: :ok
  def crashed(id, writer, token, {kind, reason, stacktrace} = caught) do
    outcome = Outcome.crashed(:inline, id, caught)
    Logger.error("stdio message failed: " <> Log.describe(kind, reason, stacktrace))
    end_span(token, outcome.span)
    write_line(writer, outcome.line)
    :ok
  end

  # The id of the request, as the raw message holds it: the answer of a
  # client carries an id that the context does not hold in `rpc_id` and
  # a crash line for it must still name the id.
  #
  @spec request_id(map()) :: String.t() | integer() | nil
  def request_id(%{"id" => id}) when is_binary(id) or is_integer(id), do: id
  def request_id(_rpc), do: nil

  # One place for the three refusals of the registration and for the
  # cleanup of a request. The span ends one time, in each branch,
  # before the final line goes out.
  #
  defp with_registration(mode, context, writer, token, fun) do
    case register(mode, context, writer) do
      {:ok, handle} ->
        {outcome, handle} = guarded(mode, context, handle, fun)
        end_span(token, outcome.span)
        safe_release(mode, handle, context, outcome, writer)
        outcome

      {:error, _reason} = error ->
        outcome = Outcome.refusal(error, context.rpc_id)
        end_span(token, outcome.span)
        write_line(writer, outcome.line)
        outcome
    end
  end

  # The registration makes this process the owner of the messages of the
  # request, in the same call that opens the stream: a
  # `notifications/cancelled` finds the request while the handler runs.
  #
  defp register(:child, context, writer) do
    PostStream.begin_sink(context.instance, context.session_id, context.rpc_id, fn data ->
      Writer.write(writer, data)
    end)
  end

  # The transport process: no stream, the owner is self(). Never
  # `PostStream.begin_sink/4` here: a `ping` would pay two session
  # calls. A notification, an answer of the client, or a message before
  # the session has nothing to register.
  #
  defp register(:inline, context, _writer) do
    if registrable?(context) do
      case Session.open_request(context.instance, context.session_id, context.rpc_id, self(), nil) do
        :ok -> {:ok, :inline}
        {:error, _reason} = error -> error
      end
    else
      {:ok, :inline}
    end
  end

  defp registrable?(%{session_id: sid, rpc_id: id}),
    do: is_binary(sid) and (is_binary(id) or is_integer(id))

  # A raise in the run gives the crash outcome.
  #
  defp guarded(:child, context, handle, fun) do
    fun.(handle)
  catch
    kind, reason ->
      Logger.error("stdio request failed: " <> Log.describe(kind, reason, __STACKTRACE__))
      {Outcome.crashed(:child, context.rpc_id, {kind, reason, __STACKTRACE__}), handle}
  end

  # The log names a message, not a request.
  #
  defp guarded(:inline, context, handle, fun) do
    fun.(handle)
  catch
    kind, reason ->
      Logger.error("stdio message failed: " <> Log.describe(kind, reason, __STACKTRACE__))
      {Outcome.crashed(:inline, request_id(context.rpc), {kind, reason, __STACKTRACE__}), handle}
  end

  # The adoption runs before the span end: the writer is the stream of
  # the session before the response line.
  #
  defp adopted(%Outcome{adopt: nil} = outcome, _adopt), do: outcome

  defp adopted(%Outcome{adopt: session_id} = outcome, adopt) do
    case adopt.(session_id) do
      {:stop, _reason, _state} = stop -> %{outcome | line: nil, next: stop}
      state -> %{outcome | next: state}
    end
  end

  # A raise here must not take the answer away: the request still gets
  # one line.
  #
  @doc false
  def safe_release(mode, handle, context, outcome, writer) do
    release(handle, context, outcome, writer)
  catch
    kind, reason ->
      Logger.error("stdio release failed: " <> Log.describe(kind, reason, __STACKTRACE__))

      if outcome.line do
        caught = {kind, reason, __STACKTRACE__}
        write_line(writer, Outcome.crashed(mode, request_id(context.rpc), caught).line)
      end

      :ok
  end

  # `finish/2` drains the queued messages first, so the response stays
  # the last line.
  #
  defp release(%PostStream{} = stream, _context, outcome, _writer) do
    if outcome.line == nil do
      PostStream.close(stream)
    else
      PostStream.finish(outcome.line, stream)
    end

    :ok
  end

  # The line goes out first, then the release of the registration.
  #
  defp release(:inline, context, outcome, writer) do
    write_line(writer, outcome.line)

    _ =
      if registrable?(context) do
        Session.end_request(context.instance, context.session_id, context.rpc_id)
      end

    :ok
  end

  # stdio has no HTTP status (`status: nil`); a `nil` token is accepted.
  #
  defp end_span(token, {:stop, extra}), do: Telemetry.stop(token, extra)

  defp end_span(token, {:exception, kind, reason, stacktrace}),
    do: Telemetry.exception(token, kind, reason, stacktrace)

  # Writes the final line of a message on stdout. A `nil` line writes
  # nothing; a line that cannot be encoded becomes the -32603 error with
  # the id of the message, so a request always gets one line.
  #
  @spec write_line(pid(), map() | nil) :: :ok
  def write_line(_writer, nil), do: :ok

  def write_line(writer, line) do
    Writer.write(writer, Wire.encode_answer(line))
    :ok
  end
end
