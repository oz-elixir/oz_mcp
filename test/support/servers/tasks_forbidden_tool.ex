defmodule Support.Servers.TasksForbiddenTool do
  use OzMcp.Config.Server

  server_info do
    name "ts-tasks-forbidden-tool"
    version "1.0.0"
  end

  tools do
    tool Support.Entities.Tools.SecondTest
  end

  capabilities do
    tasks do
      list %{}
      cancel %{}
      requests %{tools: %{call: %{}}}
    end
  end
end
