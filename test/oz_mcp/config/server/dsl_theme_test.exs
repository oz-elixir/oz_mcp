#
# Tests for the `theme/1` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLThemeTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  describe "theme/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts \"dark\"" do
      config =
        module("Theme") do
          server_info do
            icon(theme: "dark")
          end
        end
        |> compile_config()

      assert hd(config.server_info.icons).theme == "dark"
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when theme is not a string" do
      module("Theme") do
        server_info do
          icon(theme: 123)
        end
      end
      |> assert_compile_raise(ArgumentError, "'theme' must be a string, got: 123")
    end

    test "raises when theme is not 'light' or 'dark'" do
      module("Theme") do
        server_info do
          icon(theme: "invalid")
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        "'theme' can take only two values: 'light' or 'dark'"
      )
    end

    test "raises when theme is used multiple times" do
      module("Theme") do
        server_info do
          icon do
            theme "light"
            theme "dark"
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'theme' multiple times")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises theme cannot be at root level" do
      module("Theme") do
        theme "dark"
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Server.Theme",
        "undefined function theme/1"
      )
    end

    test "raises when theme is used directly inside server_info block" do
      module("Theme") do
        server_info do
          theme "dark"
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'theme' here")
    end

    test "raises when theme is used inside tools block" do
      module("Theme") do
        tools do
          theme "dark"
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'theme' here")
    end
  end
end
