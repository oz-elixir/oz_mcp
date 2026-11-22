# Test support tool modules for the MCP Tasks runtime.
#

#
# Returns a successful CallToolResult with isError: true (A6).
#
defmodule Support.Entities.Tools.TaskIsErrorTest do
  use OzMcp.Config.Tool, dsl?: false

  alias OzMcp.Structs.{CallToolResult, TextContent, Tool, ToolExecution}

  def list do
    list = [
      %Tool{}
      |> Tool.name("task_is_error")
      |> Tool.description("Reports an error through isError")
      |> Tool.execution(%ToolExecution{} |> ToolExecution.task_support(:optional))
    ]

    list
  end

  def call(_ctx, _params) do
    result =
      %CallToolResult{}
      |> CallToolResult.content([
        %TextContent{}
        |> TextContent.text("tool failure")
      ])
      |> CallToolResult.is_error(true)
      |> CallToolResult.build()

    {:ok, result}
  end
end
