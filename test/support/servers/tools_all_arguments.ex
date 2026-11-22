defmodule Support.Servers.ToolsAllArguments do
  use OzMcp.Config.Server

  server_info do
    name "ts-with-all-tools-only-test"
    version "1.0.0"
  end

  tools do
    tool Support.Entities.Tools.WithInputSchemaTest
  end
end
