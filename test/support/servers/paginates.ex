defmodule Support.Servers.Paginates do
  use OzMcp.Config.Server

  server_info do
    name "ts-paginates"
    version "1.0.0"
  end

  tools do
    paginate 25
    tool Support.Entities.Tools.SecondTest
  end

  resources do
    paginate 50
    resource Support.Entities.Resources.FirstTest
  end

  templates do
    paginate 75
    template Support.Entities.Templates.FirstTest
  end

  prompts do
    paginate 100
    prompt Support.Entities.Prompts.FirstTest
  end
end
