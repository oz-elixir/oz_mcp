defmodule Support.Servers.TasksTest do
  use OzMcp.Config.Server

  server_info do
    name "ts-tasks-test"
    version "1.0.0"
  end

  tools do
    tool Support.Entities.Tools.TaskImmediateTest
    tool Support.Entities.Tools.TaskIsErrorTest
    tool Support.Entities.Tools.TaskUnbuiltStructTest
    tool Support.Entities.Tools.TaskErrorTest
    tool Support.Entities.Tools.TaskCrashTest
    tool Support.Entities.Tools.TaskSlowTest
    tool Support.Entities.Tools.TaskProgressTest
    tool Support.Entities.Tools.TaskStructuredTest
  end

  capabilities do
    tasks do
      list %{}
      cancel %{}
      requests %{tools: %{call: %{}}}
    end
  end
end
