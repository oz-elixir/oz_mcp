defmodule Support.Servers.PaginatedTools do
  use OzMcp.Config.Server

  server_info do
    name "ts-paginated-tools"
    version "1.0.0"
  end

  tools do
    paginate 4
    tool Support.Entities.Tools.PaginatedAlphaTest
    tool Support.Entities.Tools.PaginatedBetaTest
    tool Support.Entities.Tools.PaginatedGammaTest
  end
end
