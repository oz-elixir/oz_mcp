defmodule Support.Servers.ResourcesSingle do
  use OzMcp.Config.Server

  server_info do
    name "ts-resources-only-test-1"
    version "1.0.1"
  end

  resources do
    resource Support.Entities.Resources.FirstTest
  end

  capabilities do
    resources do
      subscribe false
    end
  end
end
