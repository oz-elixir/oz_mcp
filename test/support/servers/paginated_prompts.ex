defmodule Support.Servers.PaginatedPrompts do
  use OzMcp.Config.Server

  server_info do
    name "ts-paginated-prompts"
    version "1.0.0"
  end

  prompts do
    paginate 4
    prompt Support.Entities.Prompts.PaginatedAlphaTest
    prompt Support.Entities.Prompts.PaginatedBetaTest
    prompt Support.Entities.Prompts.PaginatedGammaTest
  end
end
