# Hand-crafted (non-DSL) server config whose tasks capability members use
# string keys. Pins the tolerant capability lookup of the tasks validation:
# a non-DSL server config could store capabilities with
# string keys instead of atoms.
#

defmodule Support.Servers.TasksStringKeyCaps do
  def config do
    %{
      tools: %{modules: [Support.Entities.Tools.TaskImmediateTest]},
      resources: nil,
      prompts: nil,
      capabilities: %{
        "tasks" => %{
          "list" => %{},
          "cancel" => %{},
          "requests" => %{"tools" => %{"call" => %{}}}
        }
      }
    }
  end
end
