#
# Tests for the `theme/1` macro of the template DSL.
# See: lib/oz_mcp/config/template/dsl.ex
#
defmodule OzMcp.Config.Template.DSLThemeTest do
  use ExUnit.Case, async: true

  import Support.Factories.Template

  describe "theme/1" do
    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when theme is used multiple times" do
      module("Theme") do
        template("doc") do
          icon do
            theme("light")
            theme("dark")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'theme' multiple times")
    end

    test "raises when theme is not a string" do
      module("Theme") do
        template("doc") do
          icon(theme: 123)
        end
      end
      |> assert_compile_raise(ArgumentError, "'theme' must be a string, got: 123")
    end

    test "raises when theme is not 'light' or 'dark'" do
      module("Theme") do
        template("doc") do
          icon(theme: "invalid")
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        "'theme' can take only two values: 'light' or 'dark'"
      )
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when theme is used at root level (only template/2 is imported)" do
      module("Theme") do
        theme("dark")
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Template.Theme",
        "undefined function theme/1"
      )
    end

    test "raises when theme is used directly inside template block" do
      module("Theme") do
        template("doc") do
          theme("dark")
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'theme' here")
    end

    test "raises when theme is used inside annotations block" do
      module("Theme") do
        template("doc") do
          annotations(audience: ["user"]) do
            theme("dark")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'theme' here")
    end
  end
end
