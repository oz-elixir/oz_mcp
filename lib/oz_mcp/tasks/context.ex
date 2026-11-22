# Specifications:
# https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/tasks
#

defmodule OzMcp.Tasks.Context do
  @moduledoc """
  Task helpers for tool authors.

  Helper module over the standard tool ctx map (`OzMcp.Context.ctx()`).
  There is no struct: the tool's single `ctx` argument IS the channel —
  a tool has exactly one mandatory callback, `call(ctx, params)`. A
  task-backed execution carries a non-nil `ctx.task_id`; a plain
  synchronous call carries `task_id: nil` and every helper here returns
  `{:error, :not_a_task}` without sending anything.

  A task can also send a log message to its client with
  `OzMcp.Notify.log(ctx, level, data)`: the message carries the
  `io.modelcontextprotocol/related-task` `_meta` and goes to the owner
  of the task — each open `tasks/result` stream of the task, else every
  session of the owner. Each receiving session applies its own level.

  ## The dual-mode pattern

  One tool handles BOTH execution modes through the same callback:

    * **task-backed** — progress/status helpers route through the task
      record; the progress token is owned by the task (captured at
      creation from the request `_meta.progressToken`), tools never
      pass it.
    * **plain synchronous** — `ctx.task_id` is nil; progress with a
      client-requested token goes through `ctx.progress_token` and
      `OzMcp.Notify.progress/5`.

      ```elixir
      def call(ctx, params) do
        total = 10

        for i <- 1..total do
          run_step(i)
          report(ctx, i, total)
        end

        {:ok, %CallToolResult{} |> CallToolResult.build()}
      end

      defp report(ctx, i, total) do
        cond do
          ctx.task_id != nil ->
            OzMcp.Tasks.Context.progress(ctx, i, total, "step \#{i}")

          ctx.progress_token != nil ->
            OzMcp.Notify.progress(ctx.instance, ctx.session_id, ctx.progress_token, i,
              total: total, message: "step \#{i}"
            )

          true ->
            :ok
        end
      end
      ```
  """

  @type ctx :: OzMcp.Context.ctx()

  @doc """
  Emits notifications/progress for the task. The progress token is owned
  by the task record (captured at creation); tools never pass it here.
  This call and `OzMcp.Notify.progress/3` with the ctx of a task are the
  same: both call OzMcp.Tasks.progress/5.

  The `progress` value must increase with each call for the same token;
  a value that does not is dropped (`:ok`, the client gets nothing, a
  debug line is written). The first value can be any number; a value
  that is not a number is not checked.

  Returns `{:error, :not_a_task}` when `ctx.task_id` is nil,
  `{:error, :not_encodable}` when a value holds a term that JSON cannot
  encode and `{:error, :unavailable}` when the instance does not run.
  """
  @spec progress(ctx(), number(), number() | nil, term()) ::
          :ok | {:error, :not_a_task | :not_encodable | :unavailable}
  def progress(%{task_id: nil}, _progress, _total, _message), do: {:error, :not_a_task}

  def progress(%{task_id: task_id, instance: instance}, progress, total, message)
      when not is_nil(task_id) do
    OzMcp.Tasks.progress(instance, task_id, progress, total, message)
  end

  @doc """
  Sets/updates the statusMessage without changing the status.

  Returns `{:error, :not_a_task}` when `ctx.task_id` is nil and
  `{:error, :not_encodable}` when the message is a text that JSON cannot
  encode (a string that is not valid UTF-8, or a term that is not a
  string): the task keeps its old message. `{:error, :unavailable}` means
  that the instance does not run.
  """
  @spec status_message(ctx(), String.t()) ::
          :ok | {:error, :not_a_task | :not_encodable | :unavailable}
  def status_message(%{task_id: nil}, _message), do: {:error, :not_a_task}

  def status_message(%{task_id: task_id, instance: instance}, message)
      when not is_nil(task_id) do
    OzMcp.Tasks.status_message(instance, task_id, message)
  end
end
