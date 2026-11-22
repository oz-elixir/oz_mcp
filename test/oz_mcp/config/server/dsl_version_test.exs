#
# Tests for the `version/1` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLVersionTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  describe "version/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a non-empty string" do
      config =
        module("Version") do
          server_info(version: "1.2.3")
        end
        |> compile_config()

      assert config.server_info.version == "1.2.3"
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when version is not a string" do
      module("Version") do
        server_info(version: 123)
      end
      |> assert_compile_raise(ArgumentError, "'version' must be a string, got: 123")
    end

    test "raises when version is an empty string" do
      module("Version") do
        server_info(version: "")
      end
      |> assert_compile_raise(ArgumentError, "'version' cannot be an empty string")
    end

    test "raises when version is used multiple times" do
      module("Version") do
        server_info do
          version "1.0.0"
          version "2.0.0"
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'version' multiple times")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises version cannot be at root level" do
      module("Version") do
        version "1.0.0"
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Server.Version",
        "undefined function version/1"
      )
    end

    test "raises when version is used inside tools block" do
      module("Version") do
        tools do
          version "1.0.0"
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'version' here")
    end
  end
end
