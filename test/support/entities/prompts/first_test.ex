defmodule Support.Entities.Prompts.FirstTest do
  use OzMcp.Config.Prompt, dsl?: false

  alias OzMcp.Structs.{
    CompleteResult,
    Completion,
    GetPromptResult,
    Prompt,
    PromptArgument,
    PromptMessage,
    TextContent
  }

  def list do
    list = [
      %Prompt{}
      |> Prompt.name("code_review")
      |> Prompt.title("Code review")
      |> Prompt.description("Reviews code with a focus on safety")
      |> Prompt.arguments([
        %PromptArgument{}
        |> PromptArgument.name("language")
        |> PromptArgument.description("Programming language")
        |> PromptArgument.required(true)
      ])
    ]

    list
  end

  def get(_ctx, %{"name" => "code_review"} = _params) do
    result =
      %GetPromptResult{}
      |> GetPromptResult.description("Code review prompt")
      |> GetPromptResult.messages([
        %PromptMessage{
          role: :user,
          content:
            %TextContent{}
            |> TextContent.text("Review this code.")
        }
      ])
      |> GetPromptResult.build()

    {:ok, result}
  end

  def complete(_ctx, "code_review", %{"name" => "language"}, context) do
    values =
      case context do
        %{"focus" => "security"} -> ["elixir", "erlang"]
        _ -> ["elixir", "python"]
      end

    completion =
      %Completion{}
      |> Completion.values(values)
      |> Completion.total(length(values))
      |> Completion.has_more(false)

    {:ok,
     %CompleteResult{}
     |> CompleteResult.completion(completion)
     |> CompleteResult.build()}
  end

  def complete(_ctx, _name, _argument, _context) do
    completion = %Completion{} |> Completion.values([])

    {:ok,
     %CompleteResult{}
     |> CompleteResult.completion(completion)
     |> CompleteResult.build()}
  end
end
