#
# Tests for the `theme/1` macro of the resource DSL.
# See: lib/oz_mcp/config/resource/dsl.ex
#
defmodule OzMcp.Config.Resource.DSLThemeTest do
  use ExUnit.Case, async: true

  import Support.Factories.Resource

  describe "theme/1" do
    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when theme is used multiple times" do
      module("Theme") do
        resource("doc.md") do
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
        resource("doc.md") do
          icon(theme: 123)
        end
      end
      |> assert_compile_raise(ArgumentError, "'theme' must be a string, got: 123")
    end

    test "raises when theme is not 'light' or 'dark'" do
      module("Theme") do
        resource("doc.md") do
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

    test "raises when theme is used at root level (only resource/2 is imported)" do
      module("Theme") do
        theme("dark")
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Resource.Theme",
        "undefined function theme/1"
      )
    end

    test "raises when theme is used directly inside resource block" do
      module("Theme") do
        resource("doc.md") do
          theme("dark")
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'theme' here")
    end

    test "raises when theme is used inside annotations block" do
      module("Theme") do
        resource("doc.md") do
          annotations(audience: ["user"]) do
            theme("dark")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'theme' here")
    end
  end
end
