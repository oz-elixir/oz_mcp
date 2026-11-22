#
# `OzMcp.Transport.Http.Post` starts one worker per streaming request
# and the loop of the response reads its answer.
#
# The process that runs the handler of one streaming `POST` request, so
# a slow callback cannot block the process of the web server. The worker
# is started suspended, it waits for the go message of the writer, it
# runs the handler and it asks the session to number the response
# before it sends the reply to the writer.
#
defmodule OzMcp.Transport.Http.PostWorker do
  @moduledoc false

  alias OzMcp.Handler
  alias OzMcp.Handler.Invoke
  alias OzMcp.PostStream
  alias OzMcp.Wire

  # Every message of the worker carries the reference of the writer:
  # late answers of an earlier request are dropped.
  #
  @go_tag :oz_mcp_worker_go
  @stop_tag :oz_mcp_worker_stop

  # Starts the worker of the request. The process that calls it becomes the
  # writer: the worker waits for its go message. The worker runs under the
  # invoke supervisor of the instance; an instance that does not run at all
  # (unit tests) runs the worker as a plain process and a restart window
  # refuses the start (`{:error, :unavailable}`).
  #
  @spec start(instance :: module()) :: {:ok, pid()} | {:error, term()}
  def start(instance) do
    #
    # The pid of the writer is bound before the spawn: inside the worker
    # `self()` is the worker.
    #
    writer = self()
    Invoke.start_worker(instance, fn -> wait_for_go(writer) end)
  end

  # The writer monitor is a safety net for a writer that dies early.
  #
  defp wait_for_go(writer) do
    monitor = Process.monitor(writer)

    receive do
      {tag, ref, context, stream, metadata} when tag == @go_tag and is_reference(ref) ->
        #
        # From here the session watches the writer.
        #
        Process.demonitor(monitor, [:flush])
        Logger.metadata(metadata)
        run(writer, ref, context, stream)

      @stop_tag ->
        :ok

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        :ok
    end
  end

  defp run(writer, ref, context, stream) do
    {result, stream} = Handler.handle_request(context, stream)

    case answer(result, stream) do
      :internal_error ->
        send(writer, {:oz_mcp_loop, ref, {:answer, :internal_error}})

      {kind, encoded, reply} ->
        send(writer, {:oz_mcp_loop, ref, {:answer, kind, encoded, reply}})
    end
  end

  # The session numbers the response; the writer writes it.
  #
  defp answer({kind, rpc_response}, stream) when kind in [:rpc_success, :rpc_error] do
    encoded = Wire.encode_answer(rpc_response)
    {kind, encoded, PostStream.close_in_session(stream, encoded)}
  end

  # A store failed: close the request in the session, tell the writer.
  #
  defp answer(:internal_error, stream) do
    :ok = PostStream.close(stream)
    :internal_error
  end
end
