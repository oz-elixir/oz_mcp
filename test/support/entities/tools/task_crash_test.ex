# Test support tool modules for the MCP Tasks runtime.
#

#
# Crashes the runner (A5).
#
defmodule Support.Entities.Tools.TaskCrashTest do
  use OzMcp.Config.Tool, dsl?: false

  alias OzMcp.Structs.{Tool, ToolExecution}

  def list do
    list = [
      %Tool{}
      |> Tool.name("task_crash")
      |> Tool.description("Raises inside call/2")
      |> Tool.execution(%ToolExecution{} |> ToolExecution.task_support(:optional))
    ]

    list
  end

  def call(_ctx, _params) do
    raise RuntimeError, "tool exploded"
  end
end
