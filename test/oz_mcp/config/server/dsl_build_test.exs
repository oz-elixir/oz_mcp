#
# Integration / happy-path tests for the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLBuildTest do
  use ExUnit.Case, async: true

  alias OzMcp.Structs.{Implementation, ServerCapabilities}
  alias Support.Servers

  describe "build / integration" do
    # -----------------------------------------------------------------------
    # Build
    # -----------------------------------------------------------------------

    test "builds a server with tools only" do
      config = Servers.ToolsOnly.config()

      assert config == %{
               _meta: nil,
               protocol_version: "2025-11-25",
               instructions: nil,
               server_info: %Implementation{
                 icons: nil,
                 name: "ts-tools-only",
                 title: nil,
                 version: "1.0.0",
                 description: nil,
                 websiteUrl: nil
               },
               capabilities: %ServerCapabilities{
                 experimental: nil,
                 logging: nil,
                 completions: nil,
                 prompts: nil,
                 resources: nil,
                 tools: %{},
                 tasks: nil
               },
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

    test "builds a server with resources only" do
      config = Servers.ResourcesOnly.config()

      assert config == %{
               _meta: nil,
               protocol_version: "2025-11-25",
               instructions: nil,
               server_info: %Implementation{
                 icons: nil,
                 name: "ts-resources-only",
                 title: nil,
                 version: "1.0.0",
                 description: nil,
                 websiteUrl: nil
               },
               capabilities: %ServerCapabilities{
                 experimental: nil,
                 logging: nil,
                 completions: nil,
                 prompts: nil,
                 resources: %{subscribe: true},
                 tools: nil,
                 tasks: nil
               },
               tools: nil,
               resources: %{
                 paginate: nil,
                 list_result: nil,
                 modules: [Support.Entities.Resources.FirstTest]
               },
               templates: nil,
               prompts: nil,
               extras: nil,
               authorization: nil
             }
    end

    test "builds a server with both tools and resources" do
      config = Servers.ToolsAndResources.config()

      assert config == %{
               _meta: nil,
               protocol_version: "2025-11-25",
               instructions: nil,
               server_info: %Implementation{
                 icons: nil,
                 name: "ts-tools-and-resources",
                 title: nil,
                 version: "1.0.0",
                 description: nil,
                 websiteUrl: nil
               },
               capabilities: %ServerCapabilities{
                 experimental: nil,
                 logging: nil,
                 completions: nil,
                 prompts: nil,
                 resources: %{subscribe: true},
                 tools: %{},
                 tasks: nil
               },
               tools: %{
                 paginate: nil,
                 list_result: nil,
                 modules: [Support.Entities.Tools.SecondTest]
               },
               resources: %{
                 paginate: nil,
                 list_result: nil,
                 modules: [Support.Entities.Resources.FirstTest]
               },
               templates: nil,
               prompts: nil,
               extras: nil,
               authorization: nil
             }
    end

    test "builds a server with an explicit protocol_version" do
      assert Servers.ToolsWithProtocolVersion.config().protocol_version == "2025-11-25"
    end

    test "builds a server with a full server_info block" do
      config = Servers.ToolsWithFullServerInfo.config()

      assert config.server_info == %Implementation{
               icons: nil,
               name: "ts-full-server-info",
               title: "The title",
               version: "1.0.0",
               description: "The description",
               websiteUrl: "https://example.com"
             }
    end

    test "builds a server with multiple tools preserving order" do
      config = Servers.ToolsMultiple.config()

      assert config.tools.modules == [
               Support.Entities.Tools.SecondTest,
               Support.Entities.Tools.FirstTest
             ]
    end

    test "builds a server with multiple resources preserving order" do
      config = Servers.ResourcesMultiple.config()

      assert config.resources.modules == [
               Support.Entities.Resources.FirstTest,
               Support.Entities.Resources.SecondTest
             ]
    end

    test "auto-adds a default tools capability when omitted (tools only)" do
      config = Servers.ToolsOnly.config()

      assert config.capabilities == %ServerCapabilities{tools: %{}}

      assert config.tools == %{
               paginate: nil,
               list_result: nil,
               modules: [Support.Entities.Tools.SecondTest]
             }

      assert config.resources == nil
    end

    test "auto-adds a default resources capability when omitted (resources only)" do
      config = Servers.ResourcesMinimal.config()

      assert config.capabilities == %ServerCapabilities{resources: %{}}

      assert config.resources == %{
               paginate: nil,
               list_result: nil,
               modules: [Support.Entities.Resources.FirstTest]
             }

      assert config.tools == nil
    end
  end
end
