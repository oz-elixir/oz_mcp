#
# Test support prompt that echoes the `arguments` member it received,
# with the default form `Map.get(params, "arguments", %{})`, so a test
# can see whether a null member reached it.
#
defmodule Support.Entities.Prompts.NullArgsTest do
  use OzMcp.Config.Prompt, warn?: false

  alias OzMcp.Structs.{GetPromptResult, PromptMessage, TextContent}

  prompt "echo_arguments" do
    title "Echo arguments"
    description "Shows the arguments it received"
  end

  def get(_ctx, params) do
    arguments = Map.get(params, "arguments", %{})

    result =
      %GetPromptResult{}
      |> GetPromptResult.messages([
        %PromptMessage{
          role: :user,
          content:
            %TextContent{}
            |> TextContent.text(inspect(arguments, custom_options: [sort_maps: true]))
        }
      ])
      |> GetPromptResult.build()

    {:ok, result}
  end
end
