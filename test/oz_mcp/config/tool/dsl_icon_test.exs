#
# Tests for the `icon/1` macro of the tool DSL.
# See: lib/oz_mcp/config/tool/dsl.ex
#
defmodule OzMcp.Config.Tool.DSLIconTest do
  use ExUnit.Case, async: true

  import Support.Factories.Tool

  describe "icon/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts an icon and appends it to tool.icons" do
      tool =
        module("Icon") do
          tool("get_date") do
            title("T")

            icon do
              mime_type("image/png")
            end
          end
        end
        |> compile_one_tool()

      [%OzMcp.Structs.Icon{src: "https://z.net/icon.png", mimeType: "image/png"}] = tool.icons
    end

    test "accepts multiple icon blocks that accumulate" do
      tool =
        module("Icon") do
          tool("get_date") do
            title("T")

            icon do
              mime_type("image/png")
            end

            icon do
              mime_type("image/jpeg")
            end
          end
        end
        |> compile_one_tool()

      assert length(tool.icons) == 2
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when icon block has no src" do
      module("Icon") do
        tool("get_date") do
          title("T")
          icon(mime_type: "image/png", src: :_none_)
        end
      end
      |> assert_compile_raise(RuntimeError, "icon 'src' is required")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when icon is used at root level (only tool/2 is imported)" do
      module("Icon") do
        icon()
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Tool.Icon",
        "undefined function icon/1"
      )
    end

    test "raises when icon is used inside annotations block" do
      module("Icon") do
        tool("get_date") do
          title("T")

          annotations(read_only_hint: true) do
            icon()
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'icon' here")
    end

    test "raises when icon is used inside icon block" do
      module("Icon") do
        tool("get_date") do
          title("T")

          icon do
            icon()
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'icon' here")
    end

    test "raises when icon is used inside execution block" do
      module("Icon") do
        tool("get_date") do
          title("T")

          execution do
            icon()
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'icon' here")
    end
  end
end
