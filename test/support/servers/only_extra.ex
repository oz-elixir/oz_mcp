defmodule Support.Servers.OnlyExtra do
  use OzMcp.Config.Server

  server_info do
    name "ts-only-extra"
    version "1.0.0"
  end

  tools do
    paginate 25
    tool Support.Entities.Tools.SecondTest

    list_result do
      extra "tls_extra1", "tls_extra1_value"
      extra "tls_extra2", "tls_extra2_value"
    end
  end

  resources do
    paginate 50
    resource Support.Entities.Resources.FirstTest

    list_result do
      extra "rsc_extra1", "rsc_extra1_value"
      extra "rsc_extra2", "rsc_extra2_value"
    end
  end

  templates do
    template Support.Entities.Templates.FirstTest

    list_result do
      extra "tpl_extra1", "tpl_extra1_value"
      extra "tpl_extra2", "tpl_extra2_value2"
    end
  end

  prompts do
    prompt Support.Entities.Prompts.FirstTest

    list_result do
      extra "prm_extra1", "prm_extra1_value"
      extra "prm_extra2", "prm_extra2_value"
    end
  end
end
