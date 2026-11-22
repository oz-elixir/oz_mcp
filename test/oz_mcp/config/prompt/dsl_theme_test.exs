#
# Tests for the `theme/1` macro of the prompt DSL (icon property).
# See: lib/oz_mcp/config/prompt/dsl.ex
#
defmodule OzMcp.Config.Prompt.DSLThemeTest do
  use ExUnit.Case, async: true

  import Support.Factories.Prompt

  describe "theme/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts 'light'" do
      prompt =
        module("Theme") do
          prompt("code_review") do
            title("T")

            icon do
              theme("light")
            end
          end
        end
        |> compile_one_prompt()

      [icon] = prompt.icons
      assert icon.theme == "light"
    end

    test "accepts 'dark'" do
      prompt =
        module("Theme") do
          prompt("code_review") do
            title("T")

            icon do
              theme("dark")
            end
          end
        end
        |> compile_one_prompt()

      [icon] = prompt.icons
      assert icon.theme == "dark"
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when theme is used multiple times" do
      module("Theme") do
        prompt("code_review") do
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
        prompt("code_review") do
          title("T")
          icon(theme: 123)
        end
      end
      |> assert_compile_raise(ArgumentError, "'theme' must be a string, got: 123")
    end

    test "raises when theme is not 'light' or 'dark'" do
      module("Theme") do
        prompt("code_review") do
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

    test "raises when theme is used at root level (only prompt/2 is imported)" do
      module("Theme") do
        theme("dark")
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Prompt.Theme",
        "undefined function theme/1"
      )
    end

    test "raises when theme is used directly inside prompt block" do
      module("Theme") do
        prompt("code_review") do
          title("T")
          theme("dark")
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'theme' here")
    end
  end
end
