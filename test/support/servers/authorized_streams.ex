#
# Server with the tools of the e2e tests of the close of a `POST` stream:
# the tool that asks the client for an elicitation while it runs and the
# task tool that blocks until the test tells it to finish. Other tests
# count the tools of `Authorized` and `AuthorizedIsolation`, so this
# server holds its own list.
#
defmodule Support.Servers.AuthorizedStreams do
  use OzMcp.Config.Server

  server_info do
    name "ts-authorized-streams"
    version "1.0.0"
  end

  tools do
    tool Support.Entities.Tools.OutboundTest
    tool Support.Entities.Tools.TaskSlowTest
  end

  capabilities do
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
