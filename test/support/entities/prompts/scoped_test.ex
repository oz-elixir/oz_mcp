defmodule Support.Entities.Prompts.ScopedTest do
  use OzMcp.Config.Prompt, warn?: false

  alias OzMcp.Structs.{
    CompleteResult,
    Completion,
    GetPromptResult,
    PromptMessage,
    TextContent
  }

  prompt "summarize" do
    title "Summarize"
    description "Summarize a text"
  end

  prompt "audit" do
    title "Audit"
    description "Audit a project"
    required_scopes(["files:write"])
  end

  def get(_ctx, %{"name" => name} = _params) do
    result =
      %GetPromptResult{}
      |> GetPromptResult.description("#{name} prompt")
      |> GetPromptResult.messages([
        %PromptMessage{
          role: :user,
          content:
            %TextContent{}
            |> TextContent.text("#{name} message")
        }
      ])
      |> GetPromptResult.build()

    {:ok, result}
  end

  def complete(_ctx, "summarize", _argument, _context) do
    {:ok, empty_completion()}
  end

  def complete(_ctx, "audit", _argument, _context) do
    {:ok, empty_completion()}
  end

  defp empty_completion do
    completion = %Completion{} |> Completion.values([])

    %CompleteResult{}
    |> CompleteResult.completion(completion)
    |> CompleteResult.build()
  end
end
