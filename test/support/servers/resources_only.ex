defmodule Support.Servers.ResourcesOnly do
  use OzMcp.Config.Server

  server_info do
    name "ts-resources-only"
    version "1.0.0"
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
