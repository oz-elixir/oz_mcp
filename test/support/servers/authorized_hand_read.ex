#
# A server with an `authorization` block that uses the verifier
# `Support.Auth.HandRead`, which reads the credential without
# `OzMcp.Auth.bearer_token/2`.
#
defmodule Support.Servers.AuthorizedHandRead do
  use OzMcp.Config.Server

  server_info do
    name "ts-authorized-hand-read"
    version "1.0.0"
  end

  tools do
    tool Support.Entities.Tools.SecondTest
  end

  authorization do
    verifier(Support.Auth.HandRead)
    authorization_servers(["https://auth.example.com"])
    scopes_supported(["files:read", "files:write"])
    challenge_scopes(["files:read"])
    resource_name("Test MCP server")
    resource_documentation("https://docs.example.com/mcp")
  end
end
