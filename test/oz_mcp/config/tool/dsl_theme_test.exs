#
# Tests for the `theme/1` macro of the tool DSL (icon property).
# See: lib/oz_mcp/config/tool/dsl.ex
#
defmodule OzMcp.Config.Tool.DSLThemeTest do
  use ExUnit.Case, async: true

  import Support.Factories.Tool

  describe "theme/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts 'light'" do
      tool =
        module("Theme") do
          tool("get_date") do
            title("T")

            icon do
              theme("light")
            end
          end
        end
        |> compile_one_tool()

      [icon] = tool.icons
      assert icon.theme == "light"
    end

    test "accepts 'dark'" do
      tool =
        module("Theme") do
          tool("get_date") do
            title("T")

            icon do
              theme("dark")
            end
          end
        end
        |> compile_one_tool()

      [icon] = tool.icons
      assert icon.theme == "dark"
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when theme is used multiple times" do
      module("Theme") do
        tool("get_date") do
          title("T")

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
        tool("get_date") do
          title("T")
          icon(theme: 123)
        end
      end
      |> assert_compile_raise(ArgumentError, "'theme' must be a string, got: 123")
    end

    test "raises when theme is not 'light' or 'dark'" do
      module("Theme") do
        tool("get_date") do
          title("T")
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

    test "raises when theme is used at root level (only tool/2 is imported)" do
      module("Theme") do
        theme("dark")
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Tool.Theme",
        "undefined function theme/1"
      )
    end

    test "raises when theme is used directly inside tool block" do
      module("Theme") do
        tool("get_date") do
          title("T")
          theme("dark")
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'theme' here")
    end

    test "raises when theme is used inside annotations block" do
      module("Theme") do
        tool("get_date") do
          title("T")

          annotations(read_only_hint: true) do
            theme("dark")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'theme' here")
    end

    test "raises when theme is used inside execution block" do
      module("Theme") do
        tool("get_date") do
          title("T")

          execution do
            theme("dark")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'theme' here")
    end
  end
end
