defmodule Support.Servers.ToolsWithFullServerInfo do
  use OzMcp.Config.Server

  server_info do
    name "ts-full-server-info"
    version "1.0.0"
    title "The title"
    description "The description"
    website_url "https://example.com"
  end

  tools do
    tool Support.Entities.Tools.SecondTest
  end
end
