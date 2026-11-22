defmodule Support.Servers.Default do
  use OzMcp.Config.Server

  server_info do
    name "ts-default-test"
    version "1.2.0"
  end

  tools do
    tool Support.Entities.Tools.SecondTest
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
