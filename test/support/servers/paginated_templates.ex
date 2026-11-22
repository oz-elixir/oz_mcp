defmodule Support.Servers.PaginatedTemplates do
  use OzMcp.Config.Server

  server_info do
    name "ts-paginated-templates"
    version "1.0.0"
  end

  templates do
    paginate 4
    template Support.Entities.Templates.PaginatedAlphaTest
    template Support.Entities.Templates.PaginatedBetaTest
    template Support.Entities.Templates.PaginatedGammaTest
  end
end
