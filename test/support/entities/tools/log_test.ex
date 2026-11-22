#
# Test support tool that sends log messages with `OzMcp.Notify.log/4`
# (the ctx form, written on the stream of the request): one at `:debug`,
# one at `:warning`. The argument `delay` (milliseconds) waits before the
# first message. The argument `count` (a number) adds `count` messages at
# `:info` after the two: a flood, for a test of the rate limit.
#
defmodule Support.Entities.Tools.LogTest do
  use OzMcp.Config.Tool, dsl?: false

  alias OzMcp.Structs.{CallToolResult, TextContent, Tool, ToolExecution}

  def list do
    list = [
      %Tool{}
      |> Tool.name("log")
      |> Tool.description("Sends log messages through the stream of the request")
      |> Tool.execution(%ToolExecution{} |> ToolExecution.task_support(:optional))
    ]

    list
  end

  def call(ctx, params) do
    #
    # `delay`: milliseconds to wait before the first message, so a test can
    # open the stream that receives the messages while the tool runs.
    #
    if delay = get_in(params, ["arguments", "delay"]), do: Process.sleep(delay)

    OzMcp.Notify.log(ctx, :debug, "step 1")
    OzMcp.Notify.log(ctx, :warning, %{"disk" => "92%"}, logger: "tool")

    count = get_in(params, ["arguments", "count"]) || 0

    if is_integer(count) and count > 0 do
      for n <- 1..count, do: OzMcp.Notify.log(ctx, :info, %{"step" => n})
    end

    result =
      %CallToolResult{}
      |> CallToolResult.content([%TextContent{} |> TextContent.text("log done")])
      |> CallToolResult.build()

    {:ok, result}
  end
end
