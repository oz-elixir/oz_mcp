# Server with a task-capable tool (taskSupport "optional") but NO tasks
# capability. Pins the spec rule: an augmented call on a server that did
# not advertise tasks is executed normally, the task metadata is ignored.
#

defmodule Support.Servers.TasksNoCapability do
  use OzMcp.Config.Server

  server_info do
    name "ts-tasks-no-capability"
    version "1.0.0"
  end

  tools do
    tool Support.Entities.Tools.TaskImmediateTest
  end
end
