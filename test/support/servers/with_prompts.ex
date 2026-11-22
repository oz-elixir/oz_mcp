defmodule Support.Servers.WithPrompts do
  use OzMcp.Config.Server

  server_info do
    name "ts-with-prompts"
    version "1.0.0"
  end

  tools do
    tool Support.Entities.Tools.SecondTest
  end

  prompts do
    prompt Support.Entities.Prompts.FirstTest
  end
end
