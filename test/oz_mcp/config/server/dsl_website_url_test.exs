#
# Tests for the `website_url/1` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLWebsiteUrlTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  describe "website_url/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a non-empty string" do
      config =
        module("WebsiteUrl") do
          server_info(website_url: "https://example.com/docs")
        end
        |> compile_config()

      assert config.server_info.websiteUrl == "https://example.com/docs"
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when website_url is not a string" do
      module("WebsiteUrl") do
        server_info(website_url: 123)
      end
      |> assert_compile_raise(ArgumentError, "'website_url' must be a string, got: 123")
    end

    test "raises when website_url is an empty string" do
      module("WebsiteUrl") do
        server_info(website_url: "")
      end
      |> assert_compile_raise(ArgumentError, "'website_url' cannot be an empty string")
    end

    test "raises when website_url is used multiple times" do
      module("WebsiteUrl") do
        server_info do
          website_url "https://first.example.com"
          website_url "https://second.example.com"
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'website_url' multiple times")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises website_url cannot be at root level" do
      module("WebsiteUrl") do
        website_url "https://example.com"
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Server.WebsiteUrl",
        "undefined function website_url/1"
      )
    end

    test "raises when website_url is used inside tools block" do
      module("WebsiteUrl") do
        tools do
          website_url "https://inside.example.com"
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'website_url' here")
    end
  end
end
