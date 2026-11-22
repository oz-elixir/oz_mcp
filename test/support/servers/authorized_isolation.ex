#
# Server with the full surface the session owner check must cover: tools,
# resources with subscribe and tasks. The task-capable tools capture
# their ctx, so the tests can pin the principal the callbacks receive.
#
defmodule Support.Servers.AuthorizedIsolation do
  use OzMcp.Config.Server

  server_info do
    name "ts-authorized-isolation"
    version "1.0.0"
  end

  tools do
    tool Support.Entities.Tools.SecondTest
    tool Support.Entities.Tools.TaskImmediateTest
    tool Support.Entities.Tools.TaskSlowTest
  end

  resources do
    resource Support.Entities.Resources.FirstTest
  end

  capabilities do
    resources do
      subscribe true
    end

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
