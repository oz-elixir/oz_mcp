defmodule Support.Servers.TemplatesMultiple do
  use OzMcp.Config.Server

  server_info do
    name "ts-multiple-templates"
    version "1.0.0"
  end

  resources do
    resource Support.Entities.Resources.WithTemplateTest
  end

  templates do
    template Support.Entities.Templates.FirstTest
    template Support.Entities.Templates.SecondTest
  end

  capabilities do
    resources do
      subscribe true
    end
  end
end
