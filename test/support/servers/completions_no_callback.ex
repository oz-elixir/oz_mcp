defmodule Support.Servers.CompletionsNoCallback do
  use OzMcp.Config.Server

  server_info do
    name "ts-completions-no-callback"
    version "1.0.0"
  end

  prompts do
    #
    # `Support.Entities.Prompts.FirstTest` defines `complete/4`: the boot check of the
    # completions capability passes. `Support.Entities.Prompts.NoCompleteTest` has no
    # `complete/4`, so the request for `no_complete` still gives `-32601`.
    #
    prompt Support.Entities.Prompts.NoCompleteTest
    prompt Support.Entities.Prompts.FirstTest
  end

  capabilities do
    completions %{}
  end
end
