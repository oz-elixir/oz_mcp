# Hand-crafted (non-DSL) server config whose prompt declaration uses string
# keys. Pins the tolerant prompt-argument lookup of the prompts/get validation:
# a non-DSL server config can return plain maps with string keys from
# list/0 instead of %PromptArgument{} structs.
#

defmodule Support.Servers.PromptsStringKeyConfig do
  def config do
    %{
      tools: nil,
      resources: nil,
      prompts: %{
        modules: [Support.Entities.Prompts.FirstTest, Support.Entities.Prompts.DslTest.PlainMap]
      },
      capabilities: %{}
    }
  end
end
