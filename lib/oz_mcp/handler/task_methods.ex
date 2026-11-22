defmodule OzMcp.Handler.TaskMethods do
  @moduledoc false

  alias OzMcp.Context
  alias OzMcp.Handler.Reply
  alias OzMcp.Structs.Builder
  alias OzMcp.Tasks
  alias OzMcp.Tasks.{RelatedTask, Result}

  require Logger

  @spec get(Context.t(), stream) :: {OzMcp.Handler.response(), stream} when stream: term()
  def get(context, stream) do
    case Tasks.get(context.instance, Tasks.owner_key(context), context.task_id) do
      {:ok, task} ->
        Reply.success(context, OzMcp.Structs.Task.build(task), stream)

      {:error, reason} when reason in [:no_task, :expired] ->
        missing(context, "retrieve", reason, stream)

      other ->
        Logger.warning("tasks/get failed: #{inspect(other)}")
        Reply.internal(context, stream)
    end
  end

  @spec list(Context.t(), stream) :: {OzMcp.Handler.response(), stream} when stream: term()
  def list(context, stream) do
    #
    # NOTE: nil limit = task_page_size runtime opt, resolved by `OzMcp.Tasks`.
    #
    case Tasks.list(
           context.instance,
           Tasks.owner_key(context),
           context.tasks_cursor,
           nil,
           context.principal
         ) do
      {:ok, tasks, next_cursor} ->
        result = Builder.page(:tasks, OzMcp.Structs.Task, tasks, next_cursor)

        Reply.success(context, result, stream)

      {:error, :invalid_cursor} ->
        Reply.invalid_params(context, "Failed to list tasks: invalid cursor", stream)

      other ->
        Logger.warning("tasks/list failed: #{inspect(other)}")
        Reply.internal(context, stream)
    end
  end

  @spec cancel(Context.t(), stream) :: {OzMcp.Handler.response(), stream} when stream: term()
  def cancel(context, stream) do
    case Tasks.cancel(context.instance, Tasks.owner_key(context), context.task_id) do
      {:ok, task} ->
        Reply.success(context, OzMcp.Structs.Task.build(task), stream)

      {:error, {:terminal, status}} ->
        msg = "Cannot cancel task: already in terminal status '#{status}'"
        Reply.invalid_params(context, msg, stream)

      {:error, reason} when reason in [:no_task, :expired] ->
        missing(context, "cancel", reason, stream)

      other ->
        Logger.warning("tasks/cancel failed: #{inspect(other)}")
        Reply.internal(context, stream)
    end
  end

  @spec result(Context.t(), stream) :: {OzMcp.Handler.response(), stream} when stream: term()
  def result(context, stream) do
    #
    # Blocking call: the reply comes when the task reaches a terminal
    # status (MCP spec, "Result Retrieval": the receiver MUST block). The
    # wait stops at a terminal status, at the expiry of the task, at the
    # end of the session, or at a notifications/cancelled for this request
    # (-32800). The task itself does not change: only tasks/cancel cancels
    # a task. With keep_alive, an idle wait upgrades the response to an
    # event stream (see OzMcp.PostStream.heartbeat/2). The requests the
    # task sends to the client are written on the stream of this request
    # (see OzMcp.Tasks.Result).
    #
    {outcome, stream} = Result.wait(context, stream)

    case outcome do
      {:ok, %{outcome: :result, value: result}} ->
        result = RelatedTask.put(result, context.task_id, :_meta)
        Reply.success(context, result, stream)

      {:ok, %{outcome: :stored_error, error: err}} ->
        #
        # Replay of the stored underlying JSON-RPC error, as produced, with
        # the related-task metadata in its data.
        #
        data = related_error_data(err.data, context.task_id)
        Reply.error(context, err.code, err.message, data, stream)

      {:ok, %{outcome: :not_found}} ->
        missing(context, "retrieve", :no_task, stream)

      {:ok, %{outcome: :expired}} ->
        missing(context, "retrieve", :expired, stream)

      {:ok, %{outcome: :session_terminated}} ->
        Reply.error(context, -32000, "session terminated", stream)

      {:ok, %{outcome: :other, detail: other}} ->
        Logger.warning("tasks/result failed: #{other}")
        Reply.internal(context, stream)

      {:error, err} ->
        #
        # Cancelled (-32800), crashed (-32603) or duplicate request id.
        #
        Reply.error(context, err.code, err.message, err.data, stream)
    end
  end

  defp missing(context, verb, :no_task, stream),
    do: Reply.invalid_params(context, "Failed to #{verb} task: Task not found", stream)

  defp missing(context, verb, :expired, stream),
    do: Reply.invalid_params(context, "Failed to #{verb} task: Task has expired", stream)

  # The metadata of the task goes in the `_meta` of the data of a replayed
  # error. A data that is not a map stays as it is.
  #
  defp related_error_data(nil, task_id), do: RelatedTask.put(%{}, task_id)
  defp related_error_data(data, task_id) when is_map(data), do: RelatedTask.put(data, task_id)
  defp related_error_data(data, _task_id), do: data
end
