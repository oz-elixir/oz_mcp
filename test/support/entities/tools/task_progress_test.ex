# Test support tool modules for the MCP Tasks runtime.
#

#
# Dual-mode progress tool: emits notifications/progress
# through OzMcp.Tasks.Context.progress/4 when running task-backed
# (ctx.task_id != nil) and through OzMcp.Notify.progress/5 when running
# plainly (token from the request _meta). Captures its ctx in
# :persistent_term so tests can pin the sync/task ctx contract.
#
defmodule Support.Entities.Tools.TaskProgressTest do
  use OzMcp.Config.Tool, dsl?: false

  alias OzMcp.Structs.{CallToolResult, TextContent, Tool, ToolExecution}

  def list do
    list = [
      %Tool{}
      |> Tool.name("task_progress")
      |> Tool.description("Emits task progress when task-backed")
      |> Tool.execution(%ToolExecution{} |> ToolExecution.task_support(:optional))
    ]

    list
  end

  def call(ctx, _params) do
    :persistent_term.put({__MODULE__, :ctx}, ctx)

    if ctx.task_id != nil do
      #
      # Task-backed execution: token owned by the task record.
      #
      OzMcp.Tasks.Context.progress(ctx, 1, 2, "step 1")
    else
      #
      # Plain execution: token comes from this request's _meta.
      #
      OzMcp.Notify.progress(ctx.instance, ctx.session_id, ctx.progress_token, 1,
        total: 2,
        message: "step 1"
      )
    end

    result =
      %CallToolResult{}
      |> CallToolResult.content([
        %TextContent{}
        |> TextContent.text("progress done")
      ])
      |> CallToolResult.build()

    {:ok, result}
  end

  def last_ctx, do: :persistent_term.get({__MODULE__, :ctx}, nil)
end
