defmodule Support.Servers.RuntimeTest do
  use OzMcp.Config.Server

  server_info do
    name "runtime-test-server"
    version "1.0.0"
  end

  tools do
    tool Support.Entities.Tools.SecondTest
  end
end
