#
# Tests for the `icon/1` macro of the resource DSL.
# See: lib/oz_mcp/config/resource/dsl.ex
#
defmodule OzMcp.Config.Resource.DSLIconTest do
  use ExUnit.Case, async: true

  import Support.Factories.Resource

  describe "icon/1" do
    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when icon block has no src" do
      module("Icon") do
        resource("doc.md") do
          icon(mime_type: "image/png", src: :_none_)
        end
      end
      |> assert_compile_raise(RuntimeError, "icon 'src' is required")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when icon is used at root level (only resource/2 is imported)" do
      module("Icon") do
        icon()
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Resource.Icon",
        "undefined function icon/1"
      )
    end

    test "raises when icon is used inside annotations block" do
      module("Icon") do
        resource("doc.md") do
          annotations(audience: ["user"]) do
            icon()
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'icon' here")
    end

    test "raises when icon is used inside icon block" do
      module("Icon") do
        resource("doc.md") do
          icon do
            icon()
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'icon' here")
    end
  end
end
