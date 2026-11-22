#
# The plain tool of the benchmark: it echoes the `text` argument and
# sends nothing while it runs, so the answer is a plain JSON response.
#
defmodule Bench.EchoTool do
  use OzMcp.Config.Tool, dsl?: false

  alias OzMcp.Structs.{CallToolResult, TextContent, Tool}

  def list do
    [
      %Tool{}
      |> Tool.name("echo")
      |> Tool.description("Echoes the text of the arguments")
    ]
  end

  def call(_ctx, params) do
    text = get_in(params, ["arguments", "text"]) || ""

    result =
      %CallToolResult{}
      |> CallToolResult.content([%TextContent{} |> TextContent.text(text)])
      |> CallToolResult.build()

    {:ok, result}
  end
end

#
# The streamed tool of the benchmark: it echoes the `text` argument and
# reports progress three times on the stream of the request. A request
# with a `progressToken` in `_meta` gets an event stream; a request
# without one gets the plain JSON response, because the reports are
# dropped when the request carries no token.
#
defmodule Bench.SlowEchoTool do
  use OzMcp.Config.Tool, dsl?: false

  alias OzMcp.Structs.{CallToolResult, TextContent, Tool}

  @steps 3

  def list do
    [
      %Tool{}
      |> Tool.name("slow_echo")
      |> Tool.description("Echoes the text and reports progress three times")
    ]
  end

  def call(ctx, params) do
    text = get_in(params, ["arguments", "text"]) || ""

    for n <- 1..@steps do
      OzMcp.Notify.progress(ctx, n, total: @steps, message: "bench")
    end

    result =
      %CallToolResult{}
      |> CallToolResult.content([%TextContent{} |> TextContent.text(text)])
      |> CallToolResult.build()

    {:ok, result}
  end
end

#
# The server of the benchmark: one plain tool (`echo`) and one streamed
# tool (`slow_echo`). The instance runs with the options of
# `Bench.Runner.instance_opts/0`.
#
defmodule Bench.Server do
  use OzMcp.Config.Server

  server_info do
    name "bench-server"
    version "1.0.0"
  end

  tools do
    tool Bench.EchoTool
    tool Bench.SlowEchoTool
  end
end
