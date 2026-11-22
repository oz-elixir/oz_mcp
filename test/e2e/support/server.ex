#
# The server of the end-to-end suite: tools (one that answers a plain
# JSON result, one task tool, one that reports progress, one that sends
# log messages, one that waits for a gate of the test and five paginated
# ones), five resources, six templates and six prompts. Every registry
# block paginates two items per page. It reuses the entity modules of the
# unit test support.
#
defmodule OzMcp.E2E.Server do
  use OzMcp.Config.Server

  server_info do
    name "e2e"
    version "1.0.0"
  end

  tools do
    paginate 2

    tool Support.Entities.Tools.FirstTest
    tool Support.Entities.Tools.TaskSlowTest
    tool Support.Entities.Tools.ProgressTest
    tool Support.Entities.Tools.LogTest
    tool Support.Entities.Tools.PaginatedGammaTest
    tool Support.Entities.Tools.GateTest
  end

  resources do
    paginate 2

    resource Support.Entities.Resources.FirstTest
    resource Support.Entities.Resources.PaginatedGammaTest
  end

  templates do
    paginate 2

    template Support.Entities.Templates.FirstTest
    template Support.Entities.Templates.PaginatedGammaTest
  end

  prompts do
    paginate 2

    prompt Support.Entities.Prompts.FirstTest
    prompt Support.Entities.Prompts.PaginatedGammaTest
  end

  capabilities do
    logging %{}

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
end
