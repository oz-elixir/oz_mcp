defmodule OzMcp.Config.ServerTest do
  use ExUnit.Case, async: true
  alias OzMcp.Catalog
  alias OzMcp.Structs.{Prompt, Resource, ResourceTemplate, Tool}
  alias Support.Servers

  # -----------------------------------------------------------------------
  # __using__/1
  # -----------------------------------------------------------------------

  describe "__using__/1 macro" do
    test "use with no option is accepted" do
      code = """
      defmodule Support.Generated.Server.NoOption do
        use OzMcp.Config.Server

        server_info do
          name "no-option"
          version "1.0.0"
        end

        tools do
          tool Support.Entities.Tools.SecondTest
        end
      end
      """

      [{mod, _}] = Code.compile_string(code)
      assert function_exported?(mod, :initialize_result, 0)
    end
  end

  # -----------------------------------------------------------------------
  # __before_compile__/1
  # -----------------------------------------------------------------------

  describe "auto-generated initialize_result/0" do
    test "is exported when module uses the server DSL" do
      Code.ensure_loaded(Servers.ToolsAndResources)
      assert function_exported?(Servers.ToolsAndResources, :initialize_result, 0)
    end

    test "returns the initialize result with tools capability (no subscribe key)" do
      init = Servers.ToolsOnly.initialize_result()

      assert init == %{
               protocolVersion: "2025-11-25",
               capabilities: %{tools: %{}},
               serverInfo: %{name: "ts-tools-only", version: "1.0.0"}
             }

      refute Map.has_key?(init.capabilities, :resources)
    end

    test "returns the initialize result with resources capability (subscribe)" do
      init = Servers.ResourcesOnly.initialize_result()

      assert init == %{
               protocolVersion: "2025-11-25",
               capabilities: %{resources: %{subscribe: true}},
               serverInfo: %{name: "ts-resources-only", version: "1.0.0"}
             }

      refute Map.has_key?(init.capabilities, :tools)
    end

    test "returns the initialize result with both tools and resources capabilities" do
      init = Servers.ToolsAndResources.initialize_result()

      assert init == %{
               protocolVersion: "2025-11-25",
               capabilities: %{
                 tools: %{},
                 resources: %{subscribe: true}
               },
               serverInfo: %{name: "ts-tools-and-resources", version: "1.0.0"}
             }
    end

    test "uses the declared protocol_version in initialize result" do
      init = Servers.ToolsWithProtocolVersion.initialize_result()
      assert init.protocolVersion == "2025-11-25"
    end

    test "auto-adds a default tools capability when tools are defined but no capability is declared" do
      init = Servers.ToolsOnly.initialize_result()

      assert init.capabilities == %{tools: %{}}
    end

    test "auto-adds a default resources capability when resources are defined but no capability is declared" do
      init = Servers.ResourcesMinimal.initialize_result()

      assert init.capabilities == %{resources: %{}}
    end
  end

  # -----------------------------------------------------------------------
  # __before_compile__/1 - tools
  # -----------------------------------------------------------------------

  describe "Catalog.find_tool/2" do
    test "is not exported" do
      Code.ensure_loaded(Servers.ToolsOnly)

      refute function_exported?(Servers.ToolsOnly, :find_tool, 1)
    end

    test "returns {module, tool} when found" do
      {module, tool} = find_tool(Servers.ToolsOnly, "get_date")

      assert module == Support.Entities.Tools.SecondTest
      assert %Tool{} = tool
      assert tool.name == "get_date"
    end

    test "finds the right tool among many registered modules" do
      {module, tool} = find_tool(Servers.ToolsMultiple, "get_temperature")

      assert module == Support.Entities.Tools.FirstTest
      assert %Tool{} = tool
      assert tool.name == "get_temperature"
    end

    test "returns nil when name does not match any tool" do
      assert find_tool(Servers.ToolsOnly, "does-not-exist") == nil
      assert find_tool(Servers.ToolsMultiple, "does-not-exist") == nil
    end

    test "returns nil when the module has no tools" do
      assert find_tool(Servers.ResourcesOnly, "get_date") == nil
    end
  end

  # -----------------------------------------------------------------------
  # __before_compile__/1 - resources
  # -----------------------------------------------------------------------

  describe "Catalog.find_resource/2" do
    test "is not exported" do
      Code.ensure_loaded(Servers.ResourcesOnly)

      refute function_exported?(Servers.ResourcesOnly, :find_resource, 1)
    end

    test "returns {module, resource} when found" do
      {module, resource} = find_resource(Servers.ResourcesOnly, "file:///marketing.md")

      assert module == Support.Entities.Resources.FirstTest
      assert %Resource{} = resource
      assert resource.uri == "file:///marketing.md"
    end

    test "finds the right resource among many registered modules" do
      {module, resource} =
        find_resource(Servers.ResourcesMultiple, "file:///api_call.md")

      assert module == Support.Entities.Resources.SecondTest
      assert %Resource{} = resource
      assert resource.uri == "file:///api_call.md"
    end

    test "returns nil when uri does not match any resource" do
      assert find_resource(Servers.ResourcesOnly, "file:///unknown.md") == nil
      assert find_resource(Servers.ResourcesMultiple, "file:///unknown.md") == nil
    end

    test "returns nil when the module has no resources" do
      assert find_resource(Servers.ToolsOnly, "file:///marketing.md") == nil
    end
  end

  describe "Catalog.find_template/2" do
    test "is not exported" do
      Code.ensure_loaded(Servers.WithTemplates)

      refute function_exported?(Servers.WithTemplates, :find_template, 1)
    end

    test "returns {module, template, params} when found" do
      {module, template, params} =
        find_template(Servers.WithTemplates, "file://docs/intro.md")

      assert module == Support.Entities.Templates.FirstTest
      assert %ResourceTemplate{} = template
      assert template.uriTemplate == "file://docs/{path}"
      assert params == %{"path" => "intro.md"}
    end

    test "returns nil when uri does not match any template" do
      assert find_template(Servers.WithTemplates, "unknown://nothing") == nil
    end

    test "returns nil when the module has no templates" do
      assert find_template(Servers.ToolsOnly, "file://docs/intro.md") == nil
    end
  end

  describe "Catalog.find_template_by_ref/2" do
    test "is not exported" do
      Code.ensure_loaded(Servers.WithTemplates)

      refute function_exported?(Servers.WithTemplates, :find_template_by_ref, 1)
    end

    test "returns {module, template, params} for a known template string" do
      {module, template, params} =
        find_template_by_ref(Servers.WithTemplates, "file://docs/{path}")

      assert module == Support.Entities.Templates.FirstTest
      assert %ResourceTemplate{} = template
      assert template.uriTemplate == "file://docs/{path}"
      assert params == %{}
    end

    test "reads the list of the module" do
      {module, template, _params} =
        find_template_by_ref(Servers.WithTemplates, "file://docs/{path}")

      assert module == Support.Entities.Templates.FirstTest
      assert template.uriTemplate == "file://docs/{path}"
    end

    test "returns nil for an unknown template string" do
      assert find_template_by_ref(Servers.WithTemplates, "file://docs/{unknown}") == nil
    end

    test "returns nil for a concrete uri" do
      assert find_template_by_ref(Servers.WithTemplates, "file://docs/intro.md") == nil
    end

    test "returns nil when the module has no templates" do
      assert find_template_by_ref(Servers.ToolsOnly, "file://docs/{path}") == nil
    end
  end

  # -----------------------------------------------------------------------
  # __before_compile__/1 - prompts
  # -----------------------------------------------------------------------

  describe "Catalog.find_prompt/2" do
    test "is not exported" do
      Code.ensure_loaded(Servers.PromptsOnly)

      refute function_exported?(Servers.PromptsOnly, :find_prompt, 1)
    end

    test "returns {module, prompt} when found" do
      {module, prompt} = find_prompt(Servers.PromptsOnly, "code_review")

      assert module == Support.Entities.Prompts.FirstTest
      assert %Prompt{} = prompt
      assert prompt.name == "code_review"
    end

    test "finds the right prompt among many registered modules" do
      {module, prompt} = find_prompt(Servers.PromptsMultiple, "farewell")

      assert module == Support.Entities.Prompts.SecondTest
      assert %Prompt{} = prompt
      assert prompt.name == "farewell"
    end

    test "returns nil when name does not match any prompt" do
      assert find_prompt(Servers.PromptsOnly, "does-not-exist") == nil
      assert find_prompt(Servers.PromptsMultiple, "does-not-exist") == nil
    end

    test "returns nil when the module has no prompts" do
      assert find_prompt(Servers.ToolsOnly, "code_review") == nil
    end
  end

  # -----------------------------------------------------------------------
  # __before_compile__/1 - paginate_tools
  # -----------------------------------------------------------------------

  describe "auto-generated paginate_tools/0" do
    test "is not exported" do
      Code.ensure_loaded(Servers.ToolsOnly)

      assert function_exported?(Servers.ToolsOnly, :paginate_tools, 0)
    end

    test "returns the declared integer when paginate_tools is set" do
      Code.ensure_loaded(Servers.Paginates)
      assert Servers.Paginates.paginate_tools() == 25
    end

    test "returns nil when paginate_tools is omitted" do
      Code.ensure_loaded(Servers.ToolsOnly)
      assert Servers.ToolsOnly.paginate_tools() == nil
    end

    test "returns nil when the module has no tools" do
      Code.ensure_loaded(Servers.ResourcesOnly)
      assert Servers.ResourcesOnly.paginate_tools() == nil
    end
  end

  # -----------------------------------------------------------------------
  # __before_compile__/1 - paginate_resources
  # -----------------------------------------------------------------------

  describe "auto-generated paginate_resources/0" do
    test "is not exported" do
      Code.ensure_loaded(Servers.ResourcesOnly)

      assert function_exported?(Servers.ResourcesOnly, :paginate_resources, 0)
    end

    test "returns the declared integer when paginate_resources is set" do
      Code.ensure_loaded(Servers.Paginates)
      assert Servers.Paginates.paginate_resources() == 50
    end

    test "returns nil when paginate_resources is omitted" do
      Code.ensure_loaded(Servers.ResourcesOnly)
      assert Servers.ResourcesOnly.paginate_resources() == nil
    end

    test "returns nil when the module has no resources" do
      Code.ensure_loaded(Servers.ToolsOnly)
      assert Servers.ToolsOnly.paginate_resources() == nil
    end
  end

  # -----------------------------------------------------------------------
  # __before_compile__/1 - paginate_templates
  # -----------------------------------------------------------------------

  describe "auto-generated paginate_templates/0" do
    test "is not exported" do
      Code.ensure_loaded(Servers.WithTemplates)

      assert function_exported?(Servers.WithTemplates, :paginate_templates, 0)
    end

    test "returns the declared integer when paginate_templates is set" do
      Code.ensure_loaded(Servers.Paginates)
      assert Servers.Paginates.paginate_templates() == 75
    end

    test "returns nil when paginate_templates is omitted" do
      Code.ensure_loaded(Servers.WithTemplates)
      assert Servers.WithTemplates.paginate_templates() == nil
    end

    test "returns nil when the module has no templates" do
      Code.ensure_loaded(Servers.ToolsOnly)
      assert Servers.ToolsOnly.paginate_templates() == nil
    end
  end

  # -----------------------------------------------------------------------
  # __before_compile__/1 - paginate_prompts
  # -----------------------------------------------------------------------

  describe "auto-generated paginate_prompts/0" do
    test "is not exported" do
      Code.ensure_loaded(Servers.PromptsOnly)

      assert function_exported?(Servers.PromptsOnly, :paginate_prompts, 0)
    end

    test "returns the declared integer when paginate_prompts is set" do
      Code.ensure_loaded(Servers.Paginates)
      assert Servers.Paginates.paginate_prompts() == 100
    end

    test "returns nil when paginate_prompts is omitted" do
      Code.ensure_loaded(Servers.PromptsOnly)
      assert Servers.PromptsOnly.paginate_prompts() == nil
    end

    test "returns nil when the module has no prompts" do
      Code.ensure_loaded(Servers.ToolsOnly)
      assert Servers.ToolsOnly.paginate_prompts() == nil
    end
  end

  # -----------------------------------------------------------------------
  # __before_compile__/1 - list_*_result meta/extras
  # -----------------------------------------------------------------------

  describe "auto-generated list_tools_result_meta/0" do
    test "is not exported" do
      Code.ensure_loaded(Servers.ToolsOnly)
    end

    test "returns the _meta map when list_tools_result meta is set" do
      Code.ensure_loaded(Servers.OnlyMeta)

      assert Servers.OnlyMeta.list_tools_result_meta() == %{
               "tls_meta1" => "tls_meta1_value",
               "tls_meta2" => "tls_meta2_value"
             }
    end

    test "returns the _meta map when both meta and extras are set" do
      Code.ensure_loaded(Servers.MetaAndExtra)

      assert Servers.MetaAndExtra.list_tools_result_meta() == %{
               "tls_meta1" => "tls_meta1_value",
               "tls_meta2" => "tls_meta2_value"
             }
    end

    test "returns nil when list_tools_result declares only extras" do
      Code.ensure_loaded(Servers.OnlyExtra)
      assert Servers.OnlyExtra.list_tools_result_meta() == nil
    end

    test "returns nil when list_tools_result is omitted" do
      Code.ensure_loaded(Servers.ToolsOnly)
      assert Servers.ToolsOnly.list_tools_result_meta() == nil
    end

    test "returns nil when the module has no tools" do
      Code.ensure_loaded(Servers.ResourcesOnly)
      assert Servers.ResourcesOnly.list_tools_result_meta() == nil
    end
  end

  describe "auto-generated list_tools_result_extras/0" do
    test "is not exported" do
      Code.ensure_loaded(Servers.ToolsOnly)
    end

    test "returns the extras map when list_tools_result extra is set" do
      Code.ensure_loaded(Servers.OnlyExtra)

      assert Servers.OnlyExtra.list_tools_result_extras() == %{
               "tls_extra1" => "tls_extra1_value",
               "tls_extra2" => "tls_extra2_value"
             }
    end

    test "returns the extras map when both meta and extras are set" do
      Code.ensure_loaded(Servers.MetaAndExtra)

      assert Servers.MetaAndExtra.list_tools_result_extras() == %{
               "tls_extra1" => "tls_extra1_value",
               "tls_extra2" => "tls_extra2_value"
             }
    end

    test "returns nil when list_tools_result declares only meta" do
      Code.ensure_loaded(Servers.OnlyMeta)
      assert Servers.OnlyMeta.list_tools_result_extras() == nil
    end

    test "returns nil when list_tools_result is omitted" do
      Code.ensure_loaded(Servers.ToolsOnly)
      assert Servers.ToolsOnly.list_tools_result_extras() == nil
    end

    test "returns nil when the module has no tools" do
      Code.ensure_loaded(Servers.ResourcesOnly)
      assert Servers.ResourcesOnly.list_tools_result_extras() == nil
    end
  end

  describe "auto-generated list_resources_result_meta/0" do
    test "is not exported" do
      Code.ensure_loaded(Servers.ResourcesOnly)
    end

    test "returns the _meta map when list_resources_result meta is set" do
      Code.ensure_loaded(Servers.OnlyMeta)

      assert Servers.OnlyMeta.list_resources_result_meta() == %{
               "rsc_meta1" => "rsc_meta1_value",
               "rsc_meta2" => "rsc_meta2_value"
             }
    end

    test "returns the _meta map when both meta and extras are set" do
      Code.ensure_loaded(Servers.MetaAndExtra)

      assert Servers.MetaAndExtra.list_resources_result_meta() == %{
               "rsc_meta1" => "rsc_meta1_value",
               "rsc_meta2" => "rsc_meta2_value"
             }
    end

    test "returns nil when list_resources_result declares only extras" do
      Code.ensure_loaded(Servers.OnlyExtra)
      assert Servers.OnlyExtra.list_resources_result_meta() == nil
    end

    test "returns nil when list_resources_result is omitted" do
      Code.ensure_loaded(Servers.ResourcesOnly)
      assert Servers.ResourcesOnly.list_resources_result_meta() == nil
    end

    test "returns nil when the module has no resources" do
      Code.ensure_loaded(Servers.ToolsOnly)
      assert Servers.ToolsOnly.list_resources_result_meta() == nil
    end
  end

  describe "auto-generated list_resources_result_extras/0" do
    test "is not exported" do
      Code.ensure_loaded(Servers.ResourcesOnly)
    end

    test "returns the extras map when list_resources_result extra is set" do
      Code.ensure_loaded(Servers.OnlyExtra)

      assert Servers.OnlyExtra.list_resources_result_extras() == %{
               "rsc_extra1" => "rsc_extra1_value",
               "rsc_extra2" => "rsc_extra2_value"
             }
    end

    test "returns the extras map when both meta and extras are set" do
      Code.ensure_loaded(Servers.MetaAndExtra)

      assert Servers.MetaAndExtra.list_resources_result_extras() == %{
               "rsc_extra1" => "rsc_extra1_value",
               "rsc_extra2" => "rsc_extra2_value"
             }
    end

    test "returns nil when list_resources_result declares only meta" do
      Code.ensure_loaded(Servers.OnlyMeta)
      assert Servers.OnlyMeta.list_resources_result_extras() == nil
    end

    test "returns nil when list_resources_result is omitted" do
      Code.ensure_loaded(Servers.ResourcesOnly)
      assert Servers.ResourcesOnly.list_resources_result_extras() == nil
    end

    test "returns nil when the module has no resources" do
      Code.ensure_loaded(Servers.ToolsOnly)
      assert Servers.ToolsOnly.list_resources_result_extras() == nil
    end
  end

  describe "auto-generated list_resource_templates_result_meta/0" do
    test "is not exported" do
      Code.ensure_loaded(Servers.WithTemplates)

      assert function_exported?(
               Servers.WithTemplates,
               :list_resource_templates_result_meta,
               0
             )
    end

    test "returns the _meta map when list_resource_templates_result meta is set" do
      Code.ensure_loaded(Servers.OnlyMeta)

      assert Servers.OnlyMeta.list_resource_templates_result_meta() == %{
               "tpl_meta1" => "tpl_meta1_value",
               "tpl_meta2" => "tpl_meta2_value2"
             }
    end

    test "returns the _meta map when both meta and extras are set" do
      Code.ensure_loaded(Servers.MetaAndExtra)

      assert Servers.MetaAndExtra.list_resource_templates_result_meta() == %{
               "tpl_meta1" => "tpl_meta1_value",
               "tpl_meta2" => "tpl_meta2_value2"
             }
    end

    test "returns nil when list_resource_templates_result declares only extras" do
      Code.ensure_loaded(Servers.OnlyExtra)
      assert Servers.OnlyExtra.list_resource_templates_result_meta() == nil
    end

    test "returns nil when list_resource_templates_result is omitted" do
      Code.ensure_loaded(Servers.ResourcesOnly)
      assert Servers.ResourcesOnly.list_resource_templates_result_meta() == nil
    end

    test "returns nil when the module has no resources" do
      Code.ensure_loaded(Servers.ToolsOnly)
      assert Servers.ToolsOnly.list_resource_templates_result_meta() == nil
    end
  end

  describe "auto-generated list_resource_templates_result_extras/0" do
    test "is not exported" do
      Code.ensure_loaded(Servers.WithTemplates)

      assert function_exported?(
               Servers.WithTemplates,
               :list_resource_templates_result_extras,
               0
             )
    end

    test "returns the extras map when list_resource_templates_result extra is set" do
      Code.ensure_loaded(Servers.OnlyExtra)

      assert Servers.OnlyExtra.list_resource_templates_result_extras() == %{
               "tpl_extra1" => "tpl_extra1_value",
               "tpl_extra2" => "tpl_extra2_value2"
             }
    end

    test "returns the extras map when both meta and extras are set" do
      Code.ensure_loaded(Servers.MetaAndExtra)

      assert Servers.MetaAndExtra.list_resource_templates_result_extras() == %{
               "tpl_extra1" => "tpl_extra1_value",
               "tpl_extra2" => "tpl_extra2_value2"
             }
    end

    test "returns nil when list_resource_templates_result declares only meta" do
      Code.ensure_loaded(Servers.OnlyMeta)
      assert Servers.OnlyMeta.list_resource_templates_result_extras() == nil
    end

    test "returns nil when list_resource_templates_result is omitted" do
      Code.ensure_loaded(Servers.ResourcesOnly)
      assert Servers.ResourcesOnly.list_resource_templates_result_extras() == nil
    end

    test "returns nil when the module has no resources" do
      Code.ensure_loaded(Servers.ToolsOnly)
      assert Servers.ToolsOnly.list_resource_templates_result_extras() == nil
    end
  end

  describe "auto-generated list_prompts_result_meta/0" do
    test "is not exported" do
      Code.ensure_loaded(Servers.PromptsOnly)
    end

    test "returns the _meta map when list_prompts_result meta is set" do
      Code.ensure_loaded(Servers.OnlyMeta)

      assert Servers.OnlyMeta.list_prompts_result_meta() == %{
               "prm_meta1" => "prm_meta1_value",
               "prm_meta2" => "prm_meta2_value"
             }
    end

    test "returns the _meta map when both meta and extras are set" do
      Code.ensure_loaded(Servers.MetaAndExtra)

      assert Servers.MetaAndExtra.list_prompts_result_meta() == %{
               "prm_meta1" => "prm_meta1_value",
               "prm_meta2" => "prm_meta2_value"
             }
    end

    test "returns nil when list_prompts_result declares only extras" do
      Code.ensure_loaded(Servers.OnlyExtra)
      assert Servers.OnlyExtra.list_prompts_result_meta() == nil
    end

    test "returns nil when list_prompts_result is omitted" do
      Code.ensure_loaded(Servers.PromptsOnly)
      assert Servers.PromptsOnly.list_prompts_result_meta() == nil
    end

    test "returns nil when the module has no prompts" do
      Code.ensure_loaded(Servers.ToolsOnly)
      assert Servers.ToolsOnly.list_prompts_result_meta() == nil
    end
  end

  describe "auto-generated list_prompts_result_extras/0" do
    test "is not exported" do
      Code.ensure_loaded(Servers.PromptsOnly)
    end

    test "returns the extras map when list_prompts_result extra is set" do
      Code.ensure_loaded(Servers.OnlyExtra)

      assert Servers.OnlyExtra.list_prompts_result_extras() == %{
               "prm_extra1" => "prm_extra1_value",
               "prm_extra2" => "prm_extra2_value"
             }
    end

    test "returns the extras map when both meta and extras are set" do
      Code.ensure_loaded(Servers.MetaAndExtra)

      assert Servers.MetaAndExtra.list_prompts_result_extras() == %{
               "prm_extra1" => "prm_extra1_value",
               "prm_extra2" => "prm_extra2_value"
             }
    end

    test "returns nil when list_prompts_result declares only meta" do
      Code.ensure_loaded(Servers.OnlyMeta)
      assert Servers.OnlyMeta.list_prompts_result_extras() == nil
    end

    test "returns nil when list_prompts_result is omitted" do
      Code.ensure_loaded(Servers.PromptsOnly)
      assert Servers.PromptsOnly.list_prompts_result_extras() == nil
    end

    test "returns nil when the module has no prompts" do
      Code.ensure_loaded(Servers.ToolsOnly)
      assert Servers.ToolsOnly.list_prompts_result_extras() == nil
    end
  end

  # -----------------------------------------------------------------------
  # Behaviour conformance
  # -----------------------------------------------------------------------

  describe "behaviour callbacks" do
    test "declares the expected callbacks" do
      callbacks = OzMcp.Config.Server.behaviour_info(:callbacks)

      assert MapSet.new(callbacks) ==
               MapSet.new([
                 {:initialize_result, 0},
                 {:paginate_tools, 0},
                 {:paginate_resources, 0},
                 {:paginate_templates, 0},
                 {:paginate_prompts, 0},
                 {:roots_list_changed, 1},
                 {:authorization, 0}
               ])

      # The only optional callbacks have a default in every DSL module.
      #
      assert OzMcp.Config.Server.behaviour_info(:optional_callbacks) == [
               roots_list_changed: 1,
               authorization: 0
             ]
    end

    test "a server module exports no list function and no max page function" do
      Code.ensure_loaded(Servers.PaginatedTools)

      refute function_exported?(Servers.PaginatedTools, :list_tools, 1)
      refute function_exported?(Servers.PaginatedTools, :tools_max_page, 0)
      assert function_exported?(Servers.PaginatedTools, :paginate_tools, 0)
    end

    test "roots_list_changed/1 does nothing by default and can be overridden" do
      ctx = %{
        instance: Servers.Default,
        server: Servers.Default,
        session_id: "s"
      }

      Code.ensure_loaded(Servers.Default)
      Code.ensure_loaded(Servers.Outbound)

      assert Servers.Default.roots_list_changed(ctx) == :ok
      assert function_exported?(Servers.Outbound, :roots_list_changed, 1)

      # The probe of the test is the test process under `{:roots_probe,
      # session_id}` in the Names Registry of a throwaway instance name:
      # the callback finds the probe of its ctx and a test that runs at
      # the same time gets no collision of a global process name.
      #
      instance =
        Module.concat(Servers.Outbound, "Probe#{System.unique_integer([:positive])}")

      names = OzMcp.Instance.names(instance)
      start_supervised!({Registry, keys: :unique, name: names})
      Registry.register(names, {:roots_probe, "s"}, nil)

      ctx = %{ctx | instance: instance, server: Servers.Outbound}
      assert Servers.Outbound.roots_list_changed(ctx) == :ok
      assert_received {:roots_list_changed, ^ctx}
    end

    # ----- DSL modules conform to the behaviour

    test "DSL modules implement all required callbacks" do
      Code.ensure_loaded(Servers.ToolsAndResources)
      Code.ensure_loaded(Servers.WithTemplates)
      Code.ensure_loaded(Servers.PromptsOnly)
      assert function_exported?(Servers.ToolsAndResources, :paginate_tools, 0)

      assert function_exported?(
               Servers.ToolsAndResources,
               :list_resources_result_meta,
               0
             )

      assert function_exported?(
               Servers.ToolsAndResources,
               :list_resources_result_extras,
               0
             )

      assert function_exported?(Servers.ToolsAndResources, :paginate_resources, 0)

      assert function_exported?(
               Servers.WithTemplates,
               :list_resource_templates_result_meta,
               0
             )

      assert function_exported?(
               Servers.WithTemplates,
               :list_resource_templates_result_extras,
               0
             )

      assert function_exported?(Servers.WithTemplates, :paginate_templates, 0)
      refute function_exported?(Servers.WithTemplates, :find_template, 1)
      refute function_exported?(Servers.WithTemplates, :find_template_by_ref, 1)
      assert function_exported?(Servers.PromptsOnly, :paginate_prompts, 0)
      refute function_exported?(Servers.PromptsOnly, :find_prompt, 1)
    end

    test "DSL modules with no tools still satisfy the tools callbacks" do
      Code.ensure_loaded(Servers.ResourcesOnly)
    end

    test "DSL modules with no prompts still satisfy the prompts callbacks" do
      Code.ensure_loaded(Servers.ToolsOnly)
    end
  end

  defp find_tool(server, name), do: Catalog.find_tool(Catalog.fetch(server), name)

  defp find_resource(server, uri), do: Catalog.find_resource(Catalog.fetch(server), uri)

  defp find_prompt(server, name), do: Catalog.find_prompt(Catalog.fetch(server), name)

  defp find_template(server, uri), do: Catalog.find_template(Catalog.fetch(server), uri)

  defp find_template_by_ref(server, ref),
    do: Catalog.find_template_by_ref(Catalog.fetch(server), ref)
end
