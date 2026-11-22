#
# Test support tool that reports progress with `OzMcp.Notify.progress/3`
# (the ctx form, written on the stream of the request): two steps, the
# second one is slow so that the first one is delivered during the call.
#
# With the argument `"bad"` the second step holds a term that JSON cannot
# encode and the text of the result is the outcome of that call. The
# argument `delay` (milliseconds) waits before the first report. The
# argument `"repeat"` reports the second step one time more: its value does
# not increase, so the session drops it.
#
defmodule Support.Entities.Tools.ProgressTest do
  use OzMcp.Config.Tool, dsl?: false

  alias OzMcp.Structs.{CallToolResult, TextContent, Tool, ToolExecution}

  def list do
    list = [
      %Tool{}
      |> Tool.name("progress")
      |> Tool.description("Reports progress through the stream of the request")
      |> Tool.execution(%ToolExecution{} |> ToolExecution.task_support(:optional))
    ]

    list
  end

  def call(ctx, params) do
    #
    # `delay`: milliseconds to wait before the first report, so a test can
    # open the stream that receives the reports while the tool runs.
    #
    if delay = get_in(params, ["arguments", "delay"]), do: Process.sleep(delay)

    OzMcp.Notify.progress(ctx, 1, total: 2, message: "step 1")

    text =
      if get_in(params, ["arguments", "bad"]) do
        inspect(OzMcp.Notify.progress(ctx, 2, total: 2, message: self()))
      else
        OzMcp.Notify.progress(ctx, 2, total: 2)

        if get_in(params, ["arguments", "repeat"]),
          do: OzMcp.Notify.progress(ctx, 2, total: 2)

        "progress done"
      end

    result =
      %CallToolResult{}
      |> CallToolResult.content([%TextContent{} |> TextContent.text(text)])
      |> CallToolResult.build()

    {:ok, result}
  end
end
