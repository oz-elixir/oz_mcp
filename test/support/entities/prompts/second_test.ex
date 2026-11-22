defmodule Support.Entities.Prompts.SecondTest do
  use OzMcp.Config.Prompt, dsl?: false

  alias OzMcp.Structs.{GetPromptResult, Prompt, PromptMessage, TextContent}

  def list do
    list = [
      %Prompt{}
      |> Prompt.name("greeting")
      |> Prompt.title("Greeting")
      |> Prompt.description("A greeting prompt"),
      %Prompt{}
      |> Prompt.name("farewell")
      |> Prompt.title("Farewell")
      |> Prompt.description("A farewell prompt")
    ]

    list
  end

  def get(_ctx, %{"name" => "greeting"} = _params) do
    result =
      %GetPromptResult{}
      |> GetPromptResult.messages([
        %PromptMessage{
          role: :user,
          content:
            %TextContent{}
            |> TextContent.text("Hello!")
        }
      ])
      |> GetPromptResult.build()

    {:ok, result}
  end

  def get(_ctx, %{"name" => "farewell"} = _params) do
    result =
      %GetPromptResult{}
      |> GetPromptResult.messages([
        %PromptMessage{
          role: :user,
          content:
            %TextContent{}
            |> TextContent.text("Goodbye!")
        }
      ])
      |> GetPromptResult.build()

    {:ok, result}
  end
end
