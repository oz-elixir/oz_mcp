defmodule Support.Servers.ResourcesMultiple do
  use OzMcp.Config.Server

  server_info do
    name "ts-multiple-resources"
    version "1.0.0"
  end

  resources do
    resource Support.Entities.Resources.FirstTest
    resource Support.Entities.Resources.SecondTest
  end

  capabilities do
    resources do
      subscribe false
    end
  end
end
