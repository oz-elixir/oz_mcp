#
# A server whose tools, resources, templates and prompts declare
# `required_scopes`. It uses the verifier `Support.Auth.Default` and the tasks,
# subscribe and completions capabilities, so the tests can cover every
# request that the scope check applies to.
#
defmodule Support.Servers.Scoped do
  use OzMcp.Config.Server

  server_info do
    name "ts-scoped"
    version "1.0.0"
  end

  tools do
    tool Support.Entities.Tools.ScopedTest
    tool Support.Entities.Tools.SecondTest
  end

  resources do
    resource Support.Entities.Resources.ScopedTest
  end

  templates do
    template Support.Entities.Templates.ScopedTest
  end

  prompts do
    prompt Support.Entities.Prompts.ScopedTest
  end

  capabilities do
    resources do
      subscribe true
    end

    completions %{}

    tasks do
      list %{}
      cancel %{}
      requests %{tools: %{call: %{}}}
    end
  end

  authorization do
    verifier(Support.Auth.Default)
    authorization_servers(["https://auth.example.com"])
    scopes_supported(["files:read", "files:write", "admin"])
    challenge_scopes(["files:read"])

    # The lists of this server show every entity: the tests of the switch
    # pin the old code path. A call without the scopes is still refused.
    #
    filter_by_scope(false)
  end
end
