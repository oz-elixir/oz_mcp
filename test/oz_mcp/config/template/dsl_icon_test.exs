#
# Tests for the `icon/1` macro of the template DSL.
# See: lib/oz_mcp/config/template/dsl.ex
#
defmodule OzMcp.Config.Template.DSLIconTest do
  use ExUnit.Case, async: true

  import Support.Factories.Template

  describe "icon/1" do
    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when icon block has no src" do
      module("Icon") do
        template("doc") do
          icon(mime_type: "image/png", src: :_none_)
        end
      end
      |> assert_compile_raise(RuntimeError, "icon 'src' is required")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when icon is used at root level (only template/2 is imported)" do
      module("Icon") do
        icon()
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Template.Icon",
        "undefined function icon/1"
      )
    end

    test "raises when icon is used inside annotations block" do
      module("Icon") do
        template("doc") do
          annotations(audience: ["user"]) do
            icon()
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'icon' here")
    end

    test "raises when icon is used inside icon block" do
      module("Icon") do
        template("doc") do
          icon do
            icon()
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'icon' here")
    end
  end
end
