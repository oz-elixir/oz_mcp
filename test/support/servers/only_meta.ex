defmodule Support.Servers.OnlyMeta do
  use OzMcp.Config.Server

  server_info do
    name "ts-only-meta"
    version "1.0.0"
  end

  tools do
    paginate 25
    tool Support.Entities.Tools.SecondTest

    list_result do
      meta "tls_meta1", "tls_meta1_value"
      meta "tls_meta2", "tls_meta2_value"
    end
  end

  resources do
    paginate 50
    resource Support.Entities.Resources.FirstTest

    list_result do
      meta "rsc_meta1", "rsc_meta1_value"
      meta "rsc_meta2", "rsc_meta2_value"
    end
  end

  templates do
    template Support.Entities.Templates.FirstTest

    list_result do
      meta "tpl_meta1", "tpl_meta1_value"
      meta "tpl_meta2", "tpl_meta2_value2"
    end
  end

  prompts do
    prompt Support.Entities.Prompts.FirstTest

    list_result do
      meta "prm_meta1", "prm_meta1_value"
      meta "prm_meta2", "prm_meta2_value"
    end
  end
end
