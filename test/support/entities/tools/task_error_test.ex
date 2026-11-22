# Test support tool modules for the MCP Tasks runtime.
#

#
# Returns an error tuple in either accepted shape: the %Error{} struct
# (default) or an equivalent plain map when the request arguments carry
# "shape": "plain_map".
#
defmodule Support.Entities.Tools.TaskErrorTest do
  use OzMcp.Config.Tool, dsl?: false

  alias OzMcp.Structs.{Tool, ToolExecution}
  alias OzMcp.Utils.Error

  def list do
    list = [
      %Tool{}
      |> Tool.name("task_error")
      |> Tool.description("Returns an error tuple")
      |> Tool.execution(%ToolExecution{} |> ToolExecution.task_support(:optional))
    ]

    list
  end

  def call(_ctx, %{"arguments" => %{"shape" => "plain_map"}}) do
    {:error, %{code: -32000, message: "boom", data: %{"detail" => "extra"}}}
  end

  def call(_ctx, _params) do
    {:error, Error.new(-32000, "boom")}
  end
end
