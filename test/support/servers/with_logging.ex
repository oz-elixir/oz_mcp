defmodule Support.Servers.WithLogging do
  use OzMcp.Config.Server

  server_info do
    name "ts-with-logging"
    version "1.0.0"
  end

  tools do
    tool Support.Entities.Tools.SecondTest
  end

  capabilities do
    logging %{}
  end
end
