defmodule Support.Servers.ResourcesMinimal do
  use OzMcp.Config.Server

  server_info do
    name "ts-resources-minimal"
    version "1.0.0"
  end

  resources do
    resource Support.Entities.Resources.FirstTest
  end
end
