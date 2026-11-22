defmodule Support.Servers.PaginatedResources do
  use OzMcp.Config.Server

  server_info do
    name "ts-paginated-resources"
    version "1.0.0"
  end

  resources do
    paginate 4
    resource Support.Entities.Resources.PaginatedAlphaTest
    resource Support.Entities.Resources.PaginatedBetaTest
    resource Support.Entities.Resources.PaginatedGammaTest
  end
end
