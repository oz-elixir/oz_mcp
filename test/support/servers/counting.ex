#
# A protected server with no scoped entity, a `dsl?: false` tool module
# that counts its list calls (`Support.Entities.Tools.CountingTest`), a `dsl?: false` template
# module that counts its list calls too (`Support.Entities.Templates.CountingTest`) and two
# tools per page.
#
defmodule Support.Servers.Counting do
  use OzMcp.Config.Server

  server_info do
    name "ts-counting"
    version "1.0.0"
  end

  tools do
    tool Support.Entities.Tools.CountingTest
    paginate 2
  end

  templates do
    template Support.Entities.Templates.CountingTest
  end

  authorization do
    verifier(Support.Auth.Default)
    authorization_servers(["https://auth.example.com"])
  end
end
