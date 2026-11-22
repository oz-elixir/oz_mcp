defmodule Support.Servers.ToolsOnly do
  use OzMcp.Config.Server

  server_info do
    name "ts-tools-only"
    version "1.0.0"
  end

  tools do
    tool Support.Entities.Tools.SecondTest
  end
end
