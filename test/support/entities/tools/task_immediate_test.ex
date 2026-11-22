# Test support tool modules for the MCP Tasks runtime.
#

#
# Completes immediately with a successful CallToolResult. Captures the
# runner ctx in :persistent_term so tests can pin the exact ctx contract.
# The module is quiet: one server of the tests declares it without the
# tasks capability on purpose (the plain path of an augmented call).
#
defmodule Support.Entities.Tools.TaskImmediateTest do
  use OzMcp.Config.Tool, dsl?: false, warn?: false

  alias OzMcp.Structs.{CallToolResult, TextContent, Tool, ToolExecution}

  def list do
    list = [
      %Tool{}
      |> Tool.name("task_immediate")
      |> Tool.description("Completes immediately")
      |> Tool.execution(%ToolExecution{} |> ToolExecution.task_support(:optional))
    ]

    list
  end

  def call(ctx, _params) do
    :persistent_term.put({__MODULE__, :ctx}, ctx)

    result =
      %CallToolResult{}
      |> CallToolResult.content([
        %TextContent{}
        |> TextContent.text("done")
      ])
      |> CallToolResult.build()

    {:ok, result}
  end

  def last_ctx, do: :persistent_term.get({__MODULE__, :ctx}, nil)
end
