#
# Test support server that serves the tools and the prompt with the nullable schemas.
#
defmodule Support.Servers.NullArgs do
  use OzMcp.Config.Server

  server_info do
    name "ts-null-args"
    version "1.0.0"
  end

  tools do
    tool Support.Entities.Tools.NullArgsTest
  end

  prompts do
    prompt Support.Entities.Prompts.NullArgsTest
  end
end
