defmodule Support.Servers.Authorized do
  use OzMcp.Config.Server

  server_info do
    name "ts-authorized"
    version "1.0.0"
  end

  tools do
    tool Support.Entities.Tools.SecondTest
  end

  authorization do
    verifier(Support.Auth.Default)
    authorization_servers(["https://auth.example.com"])
    scopes_supported(["files:read", "files:write"])
    challenge_scopes(["files:read"])
    resource_name("Test MCP server")
    resource_documentation("https://docs.example.com/mcp")
  end
end
