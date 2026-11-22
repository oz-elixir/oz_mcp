# Test support tool modules for the MCP Tasks runtime.
#

#
# Returns an unbuilt %CallToolResult{} struct with isError: true. The
# framework must build the struct exactly as if the tool had called
# build/1 itself.
#
defmodule Support.Entities.Tools.TaskUnbuiltStructTest do
  use OzMcp.Config.Tool, dsl?: false

  alias OzMcp.Structs.{CallToolResult, TextContent, Tool, ToolExecution}

  def list do
    list = [
      %Tool{}
      |> Tool.name("task_unbuilt")
      |> Tool.description("Returns an unbuilt struct")
      |> Tool.execution(%ToolExecution{} |> ToolExecution.task_support(:optional))
    ]

    list
  end

  def call(_ctx, _params) do
    {:ok,
     %CallToolResult{}
     |> CallToolResult.content([
       %TextContent{}
       |> TextContent.text("tool failure")
     ])
     |> CallToolResult.is_error(true)}
  end
end
