#
# The wait of a `tasks/result` request. The request process attaches to
# the task process and waits in its own loop. The loop writes on the
# stream of the request the events that the session sends for it, keeps
# the response open (an idle wait becomes an event stream with a
# heartbeat comment) and ends at the outcome of the task, at the end
# of the session (`-32000`), or at a `notifications/cancelled` for the
# request (`-32800`).
#
# The task sends the messages of the wait through the session of the
# stream. A stream with no registration gets no message of the task.
#
defmodule OzMcp.Tasks.Result do
  @moduledoc false

  alias OzMcp.Handler.Invoke
  alias OzMcp.PostStream
  alias OzMcp.Tasks
  alias OzMcp.Utils.Error

  @cancel_tag :oz_mcp_cancel

  # The code is also the stored code of a cancelled task (`OzMcp.Task`).
  #
  @cancelled_code -32_800

  # The code -32000 stays for the documented server errors only. Every
  # internal error of the framework uses the standard -32603.
  #
  @session_code -32_000

  @type outcome ::
          {:ok, %{required(:outcome) => atom(), optional(atom()) => term()}}
          | {:error, Error.t()}

  # Waits for the outcome of the task of the request. Returns the outcome
  # and the stream as it is after the wait.
  #
  @spec wait(OzMcp.Context.t(), PostStream.t() | nil) :: {outcome(), PostStream.t() | nil}
  def wait(context, stream) do
    instance = context.instance
    request_id = context.rpc_id
    task_id = context.task_id

    Invoke.flush_stale(request_id)

    try do
      case Tasks.attach(
             instance,
             Tasks.owner_key(context),
             task_id,
             stream_id(stream),
             origin(context)
           ) do
        {:attached, pid} ->
          ref = Process.monitor(pid)
          heartbeat = OzMcp.Instance.opts(instance).sse_heartbeat_ms

          # The expiry of the principal, the poll close and the writes of
          # the stream are the rule of the connection loop. This wait only
          # relays the messages of the task.
          #
          loop(
            %{
              ref: ref,
              task_id: task_id,
              request_id: request_id,
              heartbeat: heartbeat,
              context: context
            },
            stream
          )

        {:done, answer} ->
          {outcome(answer), stream}
      end
    after
      Tasks.detach(instance, task_id)
      Invoke.flush_cancel(request_id)
      flush_task_messages(task_id)
    end
  end

  defp loop(wait, stream) do
    %{ref: ref, task_id: task_id, request_id: request_id, heartbeat: heartbeat} = wait

    receive do
      {:oz_mcp_task_result, ^task_id, answer} ->
        Process.demonitor(ref, [:flush])
        {outcome(answer), stream}

      {:DOWN, ^ref, :process, _pid, _reason} ->
        {outcome(after_exit(wait.context)), stream}

      {@cancel_tag, ^request_id, :session_terminated} ->
        {{:error, Error.new(@session_code, "session terminated")}, stream}

      {@cancel_tag, ^request_id, _reason} ->
        {{:error, Error.new(@cancelled_code, "request cancelled")}, stream}

      {:oz_mcp_stream, stream_id, _payload} = message
      when not is_nil(stream) and stream_id == stream.stream_id ->
        loop(wait, PostStream.relay(stream, message))

      # A message of another stream (or of no stream this process holds):
      # dropped.
      #
      {:oz_mcp_stream, _stream_id, _payload} ->
        loop(wait, stream)
    after
      heartbeat ->
        loop(wait, PostStream.heartbeat(stream, start: true))
    end
  end

  # The task process ended with no outcome message (it crashed): the
  # record tells how the task ended.
  #
  defp after_exit(context) do
    case Tasks.attach(
           context.instance,
           Tasks.owner_key(context),
           context.task_id,
           nil,
           origin(context)
         ) do
      {:done, answer} -> answer
      {:attached, _pid} -> {:error, :unavailable}
    end
  end

  # The outcome of the wait, in the shape the handler answers from.
  #
  defp outcome({:ok, {:ok, result}}), do: {:ok, %{outcome: :result, value: result}}

  defp outcome({:ok, {:error, err}}) do
    {:ok,
     %{
       outcome: :stored_error,
       error: %{code: err.code, message: err.message, data: Map.get(err, :data)}
     }}
  end

  defp outcome({:error, :no_task}), do: {:ok, %{outcome: :not_found}}

  defp outcome({:error, reason}) when reason in [:expired, :session_terminated],
    do: {:ok, %{outcome: reason}}

  # The task cannot answer (a restart, a stop): the wait ends as a server
  # error, as a crash of the runner would.
  #
  defp outcome({:error, reason}) when reason in [:unavailable, :timeout],
    do: {:error, Error.new(-32_603, "internal error")}

  defp outcome(other), do: {:ok, %{outcome: :other, detail: inspect(other, limit: 5)}}

  # The task sends the events through the session of the stream, so only
  # a stream that the session knows (a registration) can get them.
  #
  defp stream_id(%{registration: nil}), do: nil
  defp stream_id(%{stream_id: stream_id}), do: stream_id
  defp stream_id(nil), do: nil

  # The process of the task uses them to decide which held requests the
  # stream gets.
  #
  defp origin(%OzMcp.Context{session_id: session_id, client_capabilities: capabilities}) do
    %{session_id: session_id, client_capabilities: capabilities || %{}}
  end

  # What the task sent after the wait ended is of no use.
  #
  defp flush_task_messages(task_id) do
    receive do
      {:oz_mcp_task_result, ^task_id, _answer} -> flush_task_messages(task_id)
    after
      0 -> :ok
    end
  end
end
