#
# A protected server whose only tool module has `dsl?: false` and returns
# structs with scopes (`Support.Entities.Tools.StructScopedTest`).
#
defmodule Support.Servers.StructScoped do
  use OzMcp.Config.Server

  server_info do
    name "ts-struct-scoped"
    version "1.0.0"
  end

  tools do
    tool Support.Entities.Tools.StructScopedTest
  end

  authorization do
    verifier(Support.Auth.Default)
    authorization_servers(["https://auth.example.com"])
  end
end
