#
# Declares an outputSchema and returns a result whose shape the request
# arguments select ("shape" argument of tools/call). Task-capable, so the
# same shapes run on the synchronous path and in a task runner.
#
defmodule Support.Entities.Tools.TaskStructuredTest do
  use OzMcp.Config.Tool, dsl?: false

  alias OzMcp.Structs.{CallToolResult, TextContent, Tool, ToolExecution}

  @schema %{
    type: "object",
    properties: %{result: %{type: "string"}},
    required: ["result"]
  }

  def schema, do: @schema

  def list do
    list = [
      %Tool{}
      |> Tool.name("task_structured")
      |> Tool.description("Returns a structuredContent shaped by the arguments")
      |> Tool.output_schema(@schema)
      |> Tool.execution(%ToolExecution{} |> ToolExecution.task_support(:optional))
    ]

    list
  end

  def call(_ctx, %{"arguments" => %{"shape" => "valid"}}) do
    {:ok, structured(%{"result" => "ok"})}
  end

  def call(_ctx, %{"arguments" => %{"shape" => "atom_keys"}}) do
    {:ok, structured(%{result: "ok"})}
  end

  def call(_ctx, %{"arguments" => %{"shape" => "wrong"}}) do
    {:ok, structured(%{"result" => 42})}
  end

  def call(_ctx, %{"arguments" => %{"shape" => "map_bad_both"}}) do
    #
    # A plain map whose content block has no `type` and whose
    # structuredContent does not agree with the schema: with both checks
    # off, it reaches the client as it is.
    #
    {:ok,
     %{
       "content" => [%{"text" => "no type"}],
       "structuredContent" => %{"result" => 42}
     }}
  end

  def call(_ctx, %{"arguments" => %{"shape" => "missing"}}) do
    {:ok,
     %CallToolResult{}
     |> CallToolResult.content([%TextContent{} |> TextContent.text("no structured content")])
     |> CallToolResult.build()}
  end

  def call(_ctx, %{"arguments" => %{"shape" => "is_error"}}) do
    {:ok,
     %CallToolResult{}
     |> CallToolResult.content([%TextContent{} |> TextContent.text("tool failure")])
     |> CallToolResult.is_error(true)
     |> CallToolResult.build()}
  end

  defp structured(data) do
    %CallToolResult{}
    |> CallToolResult.content([%TextContent{} |> TextContent.text("done")])
    |> CallToolResult.structured_content(data)
    |> CallToolResult.build()
  end
end
