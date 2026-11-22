defmodule Support.Servers.RuntimeOther do
  use OzMcp.Config.Server

  server_info do
    name "runtime-test-other-server"
    version "1.0.0"
  end

  tools do
    tool Support.Entities.Tools.SecondTest
  end
end
