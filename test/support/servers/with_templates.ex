defmodule Support.Servers.WithTemplates do
  use OzMcp.Config.Server

  server_info do
    name "ts-with-templates"
    version "1.0.0"
  end

  resources do
    resource Support.Entities.Resources.WithTemplateTest
  end

  templates do
    template Support.Entities.Templates.FirstTest
  end

  capabilities do
    resources do
      subscribe true
    end
  end
end
