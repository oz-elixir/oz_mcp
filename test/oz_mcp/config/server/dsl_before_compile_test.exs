#
# Tests for the `__before_compile__/1` macro of the server DSL.
# See: lib/oz_mcp/config/server.ex and lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLBeforeCompileTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  alias OzMcp.Structs.{Implementation, ServerCapabilities}

  describe "__before_compile__/1" do
    # -----------------------------------------------------------------------
    # Build
    # -----------------------------------------------------------------------

    test "generates a config/0 function returning the built config" do
      mod =
        module("BeforeCompile") do
          server_info(name: "before-compile-generates-config", version: "2.3.4")
          tools(tool: Support.Entities.Tools.SecondTest)
        end
        |> compile()

      assert function_exported?(mod, :config, 0)

      assert mod.config() == %{
               _meta: nil,
               protocol_version: "2025-11-25",
               instructions: nil,
               server_info: %Implementation{
                 icons: nil,
                 name: "before-compile-generates-config",
                 title: nil,
                 version: "2.3.4",
                 description: nil,
                 websiteUrl: nil
               },
               capabilities: %ServerCapabilities{tools: %{}},
               tools: %{
                 paginate: nil,
                 list_result: nil,
                 modules: [Support.Entities.Tools.SecondTest]
               },
               resources: nil,
               templates: nil,
               prompts: nil,
               extras: nil,
               authorization: nil
             }
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when server_info is not declared" do
      module("BeforeCompile", _server_info_: :_none_) do
        tools(tool: Support.Entities.Tools.SecondTest)
      end
      |> assert_compile_raise(RuntimeError, "'server_info' is required")
    end

    test "raises when neither tools nor resources are defined" do
      module("BeforeCompile", _tools_: :_none_) do
        server_info(name: "before-compile-no-tools-nor-resources", version: "1.0.0")
      end
      |> assert_compile_raise(
        RuntimeError,
        "at least one tool, resource, template or prompt must be defined"
      )
    end

    # -----------------------------------------------------------------------
    # Special
    # -----------------------------------------------------------------------

    test "defaults protocol_version to 2025-11-25 when not declared" do
      config =
        module("BeforeCompile") do
          server_info(name: "before-compile-default-protocol-version", version: "1.0.0")
        end
        |> compile_config()

      assert config.protocol_version == "2025-11-25"
    end

    test "uses the declared protocol_version when provided" do
      config =
        module("BeforeCompile") do
          protocol_version "2025-11-25"
          server_info(name: "before-compile-declared-protocol-version", version: "1.0.0")
        end
        |> compile_config()

      assert config.protocol_version == "2025-11-25"
    end

    # -----------------------------------------------------------------------
    # tool capability <-> tools block relationship
    # -----------------------------------------------------------------------

    test "auto-adds a default tools capability when a tool is defined without a tool capability" do
      config =
        module("BeforeCompile") do
          tools(tool: Support.Entities.Tools.SecondTest)
        end
        |> compile_config()

      assert config.capabilities == %ServerCapabilities{tools: %{}}
    end

    test "auto-adds a default tools capability when the capabilities block omits the tools sub-block" do
      config =
        module("BeforeCompile") do
          capabilities(experimental: %{a: 1})
          tools(tool: Support.Entities.Tools.SecondTest)
        end
        |> compile_config()

      assert config.capabilities == %ServerCapabilities{experimental: %{a: 1}, tools: %{}}
    end

    # -----------------------------------------------------------------------
    # resource capability <-> resources/templates relationship
    # -----------------------------------------------------------------------

    test "auto-adds a default resources capability when a resource is defined without a resource capability" do
      config =
        module("BeforeCompile") do
          resources(resource: Support.Entities.Resources.FirstTest)
        end
        |> compile_config()

      assert config.capabilities == %ServerCapabilities{resources: %{}}
    end

    test "auto-adds a default resources capability when a template is defined without a resource capability" do
      config =
        module("BeforeCompile") do
          templates(template: Support.Entities.Templates.FirstTest)
        end
        |> compile_config()

      assert config.capabilities == %ServerCapabilities{resources: %{}}
    end

    test "auto-adds a default resources capability when the capabilities block omits the resources sub-block" do
      config =
        module("BeforeCompile") do
          capabilities(experimental: %{a: 1})
          resources(resource: Support.Entities.Resources.FirstTest)
        end
        |> compile_config()

      assert config.capabilities == %ServerCapabilities{experimental: %{a: 1}, resources: %{}}
    end

    test "keeps the declared resources capability when both a resource and a resource capability are defined" do
      config =
        module("BeforeCompile") do
          resources(resource: Support.Entities.Resources.FirstTest)

          capabilities do
            cap_resources(subscribe: true)
          end
        end
        |> compile_config()

      assert config.capabilities == %ServerCapabilities{resources: %{subscribe: true}}
    end

    test "raises when a resource capability is declared but neither a resource nor a template is defined" do
      module("BeforeCompile") do
        tools(tool: Support.Entities.Tools.SecondTest)

        capabilities do
          cap_resources(subscribe: true)
        end
      end
      |> assert_compile_raise(
        RuntimeError,
        "if you declare resource capability then you must at least define one resource or one template"
      )
    end

    # -----------------------------------------------------------------------
    # prompt capability <-> prompts block relationship
    # -----------------------------------------------------------------------

    test "auto-adds a default prompts capability when a prompt is defined without a prompt capability" do
      config =
        module("BeforeCompile") do
          prompts(prompt: Support.Entities.Prompts.FirstTest)
        end
        |> compile_config()

      assert config.capabilities == %ServerCapabilities{prompts: %{}}
    end

    test "auto-adds a default prompts capability when the capabilities block omits the prompts sub-block" do
      config =
        module("BeforeCompile") do
          capabilities(experimental: %{a: 1})
          prompts(prompt: Support.Entities.Prompts.FirstTest)
        end
        |> compile_config()

      assert config.capabilities == %ServerCapabilities{experimental: %{a: 1}, prompts: %{}}
    end

    test "accepts a prompts-only server (no tools, resources or templates)" do
      config =
        module("BeforeCompile", _tools_: :_none_) do
          server_info(name: "before-compile-prompts-only", version: "1.0.0")

          prompts(prompt: Support.Entities.Prompts.FirstTest)
        end
        |> compile_config()

      assert config.prompts == %{
               paginate: nil,
               list_result: nil,
               modules: [Support.Entities.Prompts.FirstTest]
             }

      assert config.capabilities == %ServerCapabilities{prompts: %{}}
      assert config.tools == nil
    end
  end
end
