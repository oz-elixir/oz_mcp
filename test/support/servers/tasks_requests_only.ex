defmodule Support.Servers.TasksRequestsOnly do
  use OzMcp.Config.Server

  server_info do
    name "ts-tasks-requests-only"
    version "1.0.0"
  end

  tools do
    tool Support.Entities.Tools.TaskImmediateTest
  end

  capabilities do
    tasks do
      requests %{tools: %{call: %{}}}
    end
  end
end
