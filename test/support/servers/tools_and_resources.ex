defmodule Support.Servers.ToolsAndResources do
  use OzMcp.Config.Server

  server_info do
    name "ts-tools-and-resources"
    version "1.0.0"
  end

  tools do
    tool Support.Entities.Tools.SecondTest
  end

  resources do
    resource Support.Entities.Resources.FirstTest
  end

  capabilities do
    resources do
      subscribe true
    end
  end
end
