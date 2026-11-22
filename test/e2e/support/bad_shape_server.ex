#
# A server for the checks of the result shape of a task tool over a real
# connection. It serves the tool `Support.Entities.Tools.TaskBadShapeTest` and the `tasks`
# capability, as `OzMcp.E2E.Server` does. It does not reuse the main e2e
# server so that the list of its tools stays untouched.
#
defmodule OzMcp.E2E.BadShapeServer do
  use OzMcp.Config.Server

  server_info do
    name "e2e-bad-shape"
    version "1.0.0"
  end

  tools do
    tool Support.Entities.Tools.TaskBadShapeTest
  end

  capabilities do
    tasks do
      list %{}
      cancel %{}
      requests %{tools: %{call: %{}}}
    end
  end
end
