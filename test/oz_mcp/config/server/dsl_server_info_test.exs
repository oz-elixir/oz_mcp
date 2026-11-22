#
# Tests for the `server_info/1` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLServerInfoTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  alias OzMcp.Structs.Implementation

  describe "server_info/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a server_info block with name and version" do
      config =
        module("ServerInfo") do
          server_info(name: "my-server", version: "1.0.0")
        end
        |> compile_config()

      assert config.server_info == %Implementation{
               icons: nil,
               name: "my-server",
               title: nil,
               version: "1.0.0",
               description: nil,
               websiteUrl: nil
             }
    end

    test "accepts a server_info block with all optional fields" do
      config =
        module("ServerInfo") do
          server_info do
            name "my-server"
            version "1.0.0"
            title "The title"
            description "The description"
            website_url "https://example.com"
          end
        end
        |> compile_config()

      assert config.server_info == %Implementation{
               icons: nil,
               name: "my-server",
               title: "The title",
               version: "1.0.0",
               description: "The description",
               websiteUrl: "https://example.com"
             }
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when server_info is declared multiple times" do
      module("ServerInfo") do
        server_info(name: "first", version: "1.0.0")
        server_info(name: "second", version: "2.0.0")
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'server_info' multiple times")
    end

    test "raises when name is not present" do
      module("ServerInfo") do
        server_info(name: :_none_)
      end
      |> assert_compile_raise(RuntimeError, "'name' is required")
    end

    test "raises when version is not present" do
      module("ServerInfo") do
        server_info(version: :_none_)
      end
      |> assert_compile_raise(RuntimeError, "'version' is required")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when server_info is used inside tools block" do
      module("ServerInfo") do
        tools do
          server_info(name: "inside", version: "2.0.0")
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'server_info' here")
    end
  end
end
