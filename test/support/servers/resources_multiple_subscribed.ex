defmodule Support.Servers.ResourcesMultipleSubscribed do
  use OzMcp.Config.Server

  server_info do
    name "ts-resources-only-test-2"
    version "1.0.1"
  end

  resources do
    resource Support.Entities.Resources.FirstTest
    resource Support.Entities.Resources.SecondTest
  end

  capabilities do
    resources do
      subscribe true
    end
  end
end
