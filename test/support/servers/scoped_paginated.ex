#
# A protected server whose lists are filtered by scope (the default of
# `filter_by_scope`). The tools are paginated, two per page, so the tests
# can pin that a page counts only the visible items. The resources come
# from two modules: one with `required_scopes` and one with `dsl?: false`
# that returns plain maps.
#
defmodule Support.Servers.ScopedPaginated do
  use OzMcp.Config.Server

  server_info do
    name "ts-scoped-pages"
    version "1.0.0"
  end

  tools do
    tool Support.Entities.Tools.ScopedPaginatedTest
    paginate 2
  end

  resources do
    resource Support.Entities.Resources.ScopedTest
    resource Support.Entities.Resources.PlainMapTest
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
  end

  authorization do
    verifier(Support.Auth.Default)
    authorization_servers(["https://auth.example.com"])
    scopes_supported(["files:read", "files:write", "admin"])
    challenge_scopes(["files:read"])
  end
end
