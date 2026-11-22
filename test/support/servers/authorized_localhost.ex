defmodule Support.Servers.AuthorizedLocalhost do
  use OzMcp.Config.Server

  server_info do
    name "ts-authorized-localhost"
    version "1.0.0"
  end

  tools do
    tool Support.Entities.Tools.SecondTest
  end

  authorization do
    verifier(Support.Auth.Default)
    authorization_servers(["http://localhost:8080", "http://127.0.0.1", "http://[::1]"])
    audience_check(false)
  end
end
