defmodule Support.Servers.Completions do
  use OzMcp.Config.Server

  server_info do
    name "ts-completions"
    version "1.0.0"
  end

  prompts do
    prompt Support.Entities.Prompts.FirstTest
  end

  templates do
    template Support.Entities.Templates.FirstTest
  end

  capabilities do
    completions %{}
  end
end
