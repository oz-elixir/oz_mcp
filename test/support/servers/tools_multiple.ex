defmodule Support.Servers.ToolsMultiple do
  use OzMcp.Config.Server

  server_info do
    name "ts-tools-only-test-2"
    version "1.0.0"
  end

  tools do
    tool Support.Entities.Tools.SecondTest
    tool Support.Entities.Tools.FirstTest
  end
end
