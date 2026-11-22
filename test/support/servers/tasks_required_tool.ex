defmodule Support.Servers.TasksRequiredTool do
  use OzMcp.Config.Server

  server_info do
    name "ts-tasks-required-tool"
    version "1.0.0"
  end

  tools do
    tool Support.Entities.Tools.DslTest.Full
  end

  capabilities do
    tasks do
      list %{}
      cancel %{}
      requests %{tools: %{call: %{}}}
    end
  end
end
