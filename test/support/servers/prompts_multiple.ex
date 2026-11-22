defmodule Support.Servers.PromptsMultiple do
  use OzMcp.Config.Server

  server_info do
    name "ts-multiple-prompts"
    version "1.0.0"
  end

  prompts do
    prompt Support.Entities.Prompts.FirstTest
    prompt Support.Entities.Prompts.SecondTest
  end
end
