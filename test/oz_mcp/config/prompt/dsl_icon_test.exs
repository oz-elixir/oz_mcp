#
# Tests for the `icon/1` macro of the prompt DSL.
# See: lib/oz_mcp/config/prompt/dsl.ex
#
defmodule OzMcp.Config.Prompt.DSLIconTest do
  use ExUnit.Case, async: true

  import Support.Factories.Prompt

  describe "icon/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts an icon and appends it to prompt.icons" do
      prompt =
        module("Icon") do
          prompt("code_review") do
            title("T")

            icon do
              mime_type("image/png")
            end
          end
        end
        |> compile_one_prompt()

      [%OzMcp.Structs.Icon{src: "https://z.net/icon.png", mimeType: "image/png"}] = prompt.icons
    end

    test "accepts multiple icon blocks that accumulate" do
      prompt =
        module("Icon") do
          prompt("code_review") do
            title("T")

            icon do
              mime_type("image/png")
            end

            icon do
              mime_type("image/jpeg")
            end
          end
        end
        |> compile_one_prompt()

      assert length(prompt.icons) == 2
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when icon block has no src" do
      module("Icon") do
        prompt("code_review") do
          title("T")
          icon(mime_type: "image/png", src: :_none_)
        end
      end
      |> assert_compile_raise(RuntimeError, "icon 'src' is required")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when icon is used at root level (only prompt/2 is imported)" do
      module("Icon") do
        icon()
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Prompt.Icon",
        "undefined function icon/1"
      )
    end

    test "raises when icon is used inside icon block" do
      module("Icon") do
        prompt("code_review") do
          title("T")

          icon do
            icon()
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'icon' here")
    end
  end
end
