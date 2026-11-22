defmodule Support.Servers.PromptsOnly do
  use OzMcp.Config.Server

  server_info do
    name "ts-prompts-only"
    version "1.0.0"
  end

  prompts do
    prompt Support.Entities.Prompts.FirstTest
  end
end
