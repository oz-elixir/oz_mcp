defmodule Support.Entities.Tools.SecondTest do
  use OzMcp.Config.Tool, dsl?: false

  alias OzMcp.Structs.{CallToolResult, TextContent, Tool, ToolExecution}

  def list do
    list = [
      %Tool{}
      |> Tool.name("get_date")
      |> Tool.title("Get the current date (new)")
      |> Tool.description("Get the current date formatted as %d/%m/%Y")
      |> Tool.execution(
        %ToolExecution{}
        |> ToolExecution.task_support(:forbidden)
      ),
      %Tool{}
      |> Tool.name("get_time")
      |> Tool.title("Get the current time (new)")
      |> Tool.description("Get the current time formatted as %H:%M:%S")
    ]

    list
  end

  def call(_ctx, %{"name" => "get_date"} = _params) do
    result =
      %CallToolResult{}
      |> CallToolResult.content([
        %TextContent{}
        |> TextContent.text("22/11/2025")
      ])
      |> CallToolResult.build()

    {:ok, result}
  end

  def call(_ctx, %{"name" => "get_time"} = _params) do
    result =
      %CallToolResult{}
      |> CallToolResult.content([
        %TextContent{}
        |> TextContent.text("14:45:20")
      ])
      |> CallToolResult.build()

    {:ok, result}
  end
end
