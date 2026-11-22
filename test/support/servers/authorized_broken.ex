defmodule Support.Servers.AuthorizedBroken do
  use OzMcp.Config.Server

  server_info do
    name "ts-authorized-broken"
    version "1.0.0"
  end

  tools do
    tool Support.Entities.Tools.SecondTest
  end

  authorization do
    verifier(Support.Auth.Broken)
    authorization_servers(["https://auth.example.com"])
    challenge_scopes(["files:read"])
  end
end
