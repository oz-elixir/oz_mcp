#
# Test support tool that asks the client something while it runs: it sends
# one request with `OzMcp.Outbound.request/4` from inside the callback (so
# the real ctx, the runner process and the POST stream are used) and returns
# the outcome as text.
#
# Arguments: `method` (default `"ping"`), `timeout` (milliseconds, default
# `5000`) and `feature`, which uses `OzMcp.Client` with fixed inputs instead
# of a raw request: `"elicit_form"`, `"elicit_url"`, `"sample"`,
# `"sample_tools"` (a sampling request with a tool), `"sample_task"` and
# `"elicit_task"` (the request runs as a task of the client) and `"roots"`.
# The feature `"url_required"` returns the `-32042` error of
# `OzMcp.Client.url_elicitation_required/2`. The task features read
# `"task_required"` (boolean), `"ttl"` (milliseconds) and
# `"poll_interval"` (milliseconds). `delay` waits (milliseconds) before
# the request and `after_delay` waits after the outcome before the tool
# answers. `puts` prints one stray line with `IO.puts/1`, to check where
# the print of a callback goes. `text` asks nothing: it returns a text of
# its own, with a non-ASCII character and a newline, to check how the
# transport writes a text of the server.
#
defmodule Support.Entities.Tools.OutboundTest do
  use OzMcp.Config.Tool, dsl?: false

  alias OzMcp.{Client, Outbound}

  alias OzMcp.Structs.{
    CallToolResult,
    ElicitationSchema,
    NumberSchema,
    SamplingMessage,
    StringSchema,
    TextContent,
    Tool,
    ToolExecution
  }

  def list do
    list = [
      %Tool{}
      |> Tool.name("outbound")
      |> Tool.description("Sends a request to the client and reports the outcome")
      |> Tool.execution(%ToolExecution{} |> ToolExecution.task_support(:optional))
    ]

    list
  end

  def call(ctx, params) do
    arguments = Map.get(params, "arguments") || %{}

    case Map.get(arguments, "feature") do
      "url_required" -> {:error, url_required()}
      _feature -> ask(ctx, arguments)
    end
  end

  defp url_required do
    Client.url_elicitation_required([
      %{
        url: "https://example.com/connect",
        message: "Connect your account",
        elicitation_id: "elicit-1"
      }
    ])
  end

  defp ask(ctx, arguments) do
    method = Map.get(arguments, "method", "ping")
    timeout = Map.get(arguments, "timeout", 5_000)

    # `delay`: milliseconds to wait before the request (a task that asks late).
    #
    if delay = Map.get(arguments, "delay"), do: Process.sleep(delay)

    # `puts`: a stray print of the callback, to check where it goes.
    #
    if puts = Map.get(arguments, "puts"), do: IO.puts(puts)

    outcome = run(ctx, Map.get(arguments, "feature"), method, timeout, arguments)

    # `after_delay`: milliseconds to wait before the answer of the tool (a
    # client that needs the request to stay open after the outcome).
    #
    if after_delay = Map.get(arguments, "after_delay"), do: Process.sleep(after_delay)

    result =
      %CallToolResult{}
      |> CallToolResult.content([
        %TextContent{} |> TextContent.text(inspect(outcome, custom_options: [sort_maps: true]))
      ])
      |> CallToolResult.build()

    {:ok, result}
  end

  defp run(ctx, "elicit_form", _method, timeout, _arguments) do
    Client.elicit(ctx, form_schema(), message: "Who are you?", timeout: timeout)
  end

  defp run(ctx, "elicit_url", _method, timeout, _arguments) do
    Client.elicit(ctx, "https://example.com/authorize",
      message: "Authorize the access",
      elicitation_id: "elicit-1",
      timeout: timeout
    )
  end

  defp run(ctx, "sample", _method, timeout, _arguments) do
    Client.sample(ctx, [SamplingMessage.user("Hello")], max_tokens: 50, timeout: timeout)
  end

  defp run(ctx, "sample_tools", _method, timeout, _arguments) do
    tools = [%{name: "weather", inputSchema: %{type: "object"}}]

    Client.sample(ctx, [SamplingMessage.user("Weather?")],
      max_tokens: 50,
      tools: tools,
      tool_choice: :auto,
      timeout: timeout
    )
  end

  defp run(ctx, "sample_task", _method, timeout, arguments) do
    Client.sample(
      ctx,
      [SamplingMessage.user("Hello")],
      [max_tokens: 50, timeout: timeout] ++ task_opts(arguments)
    )
  end

  defp run(ctx, "elicit_task", _method, timeout, arguments) do
    Client.elicit(
      ctx,
      form_schema(),
      [message: "Who are you?", timeout: timeout] ++ task_opts(arguments)
    )
  end

  defp run(ctx, "roots", _method, timeout, _arguments),
    do: Client.list_roots(ctx, timeout: timeout)

  defp run(_ctx, "text", _method, _timeout, _arguments), do: "première\nligne"

  defp run(ctx, nil, method, timeout, _arguments),
    do: Outbound.request(ctx, method, nil, timeout: timeout)

  defp form_schema do
    %ElicitationSchema{}
    |> ElicitationSchema.property("name", %StringSchema{} |> StringSchema.title("Name"))
    |> ElicitationSchema.property(
      "age",
      %NumberSchema{} |> NumberSchema.type(:integer) |> NumberSchema.minimum(0)
    )
    |> ElicitationSchema.required(["name"])
  end

  defp task_opts(arguments) do
    task =
      case Map.get(arguments, "ttl") do
        ttl when is_integer(ttl) -> %{ttl: ttl}
        _other -> true
      end

    opts = [task: task, task_required: Map.get(arguments, "task_required", false)]

    case Map.get(arguments, "poll_interval") do
      ms when is_integer(ms) -> Keyword.put(opts, :poll_interval, ms)
      _other -> opts
    end
  end
end
