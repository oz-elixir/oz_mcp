#
# The tools that the TypeScript SDK run calls.
#
defmodule OzMcp.E2E.SdkServer.Tools do
  use OzMcp.Config.Tool

  alias OzMcp.{Client, Notify}

  tool "sdk_echo" do
    title "Echo"
    description "Answers with the text it gets"

    input_schema %{
      type: "object",
      properties: %{text: %{type: "string"}},
      required: ["text"]
    }
  end

  tool "sdk_elicit" do
    title "Elicit"
    description "Asks the client for a name and answers with the name"
  end

  tool "sdk_task" do
    title "Task"
    description "Runs as a task. With hold: true, it stays working until a cancel"

    input_schema %{
      type: "object",
      properties: %{hold: %{type: "boolean"}}
    }

    execution do
      task_support "optional"
    end
  end

  tool "sdk_notify" do
    title "Notify"
    description "Sends a log message on the GET stream, then answers"
  end

  @impl true
  def call(_ctx, %{"name" => "sdk_echo", "arguments" => %{"text" => text}}),
    do: {:ok, %{content: [%{type: "text", text: text}]}}

  def call(ctx, %{"name" => "sdk_elicit"}) do
    schema = %{
      type: "object",
      properties: %{name: %{type: "string", description: "Your name"}},
      required: ["name"]
    }

    case Client.elicit(ctx, schema, message: "Who are you?") do
      #
      # The action is an atom, the content has string keys.
      #
      {:ok, %{action: :accept, content: %{"name" => name}}} ->
        {:ok, %{content: [%{type: "text", text: "hello #{name}"}]}}

      {:ok, %{action: action}} ->
        {:ok, %{content: [%{type: "text", text: "action: #{action}"}]}}

      {:error, reason} ->
        {:error, OzMcp.Utils.Error.new(-32603, "elicitation failed: #{inspect(reason)}")}
    end
  end

  def call(_ctx, %{"name" => "sdk_task"} = params) do
    #
    # With `hold: true` the task stays `working` until the cancel ends the
    # runner. The hold has no timer, so no test depends on the clock.
    #
    if get_in(params, ["arguments", "hold"]) == true, do: Process.sleep(:infinity)
    {:ok, %{content: [%{type: "text", text: "task done"}]}}
  end

  def call(ctx, %{"name" => "sdk_notify"}) do
    #
    # No request context: the message goes to the GET stream of the session
    # (or to the ring of its closed GET stream), not to this POST response.
    #
    :ok = Notify.broadcast_log(ctx.instance, :info, "from-get-stream")
    {:ok, %{content: [%{type: "text", text: "sent"}]}}
  end
end

#
# The server that the TypeScript SDK run calls. It is apart from
# `OzMcp.E2E.ConformanceServer`, because the tool list of that server is
# the contract of the conformance scenarios.
#
defmodule OzMcp.E2E.SdkServer do
  use OzMcp.Config.Server

  server_info do
    name "sdk-server"
    version "1.0.0"
  end

  tools do
    tool OzMcp.E2E.SdkServer.Tools
  end

  capabilities do
    logging %{}

    tasks do
      list %{}
      cancel %{}
      requests %{tools: %{call: %{}}}
    end
  end
end
