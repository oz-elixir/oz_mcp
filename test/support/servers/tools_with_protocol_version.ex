defmodule Support.Servers.ToolsWithProtocolVersion do
  use OzMcp.Config.Server

  protocol_version "2025-11-25"

  server_info do
    name "ts-with-protocol-version"
    version "1.0.0"
  end

  tools do
    tool Support.Entities.Tools.SecondTest
  end
end
