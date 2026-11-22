#
# Test support server with authorization and the tools that ask the client
# while they run. The tests of a task that acts through the sessions of its
# owner use it: a session of the principal creates the task, another one
# reads it and answers its requests.
#
defmodule Support.Servers.AuthorizedOutbound do
  use OzMcp.Config.Server

  server_info do
    name "ts-authorized-outbound"
    version "1.0.0"
  end

  tools do
    tool Support.Entities.Tools.OutboundTest
    tool Support.Entities.Tools.ProgressTest
    tool Support.Entities.Tools.LogTest
  end

  capabilities do
    logging %{}

    tasks do
      list %{}
      cancel %{}
      requests %{tools: %{call: %{}}}
    end
  end

  authorization do
    verifier(Support.Auth.Default)
    authorization_servers(["https://auth.example.com"])
    scopes_supported(["files:read", "files:write"])
    challenge_scopes(["files:read"])
  end
end
