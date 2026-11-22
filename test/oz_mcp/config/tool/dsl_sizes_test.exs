#
# Tests for the `sizes/1` macro of the tool DSL (icon property).
# See: lib/oz_mcp/config/tool/dsl.ex
#
defmodule OzMcp.Config.Tool.DSLSizesTest do
  use ExUnit.Case, async: true

  import Support.Factories.Tool

  describe "sizes/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a list of strings" do
      tool =
        module("Sizes") do
          tool("get_date") do
            title("T")

            icon do
              sizes(["16x16", "32x32"])
            end
          end
        end
        |> compile_one_tool()

      [icon] = tool.icons
      assert icon.sizes == ["16x16", "32x32"]
    end

    test "accepts sizes ['48x48', 'any']" do
      tool =
        module("Sizes") do
          tool("get_date") do
            title("T")

            icon do
              sizes(["48x48", "any"])
            end
          end
        end
        |> compile_one_tool()

      [icon] = tool.icons
      assert icon.sizes == ["48x48", "any"]
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises for sizes ['48']" do
      module("Sizes") do
        tool("get_date") do
          title("T")

          icon do
            sizes(["48"])
          end
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        ~s|'sizes' entry must be "any" or a "WxH" string such as "48x48", got: "48"|
      )
    end

    test "raises for sizes [48]" do
      module("Sizes") do
        tool("get_date") do
          title("T")

          icon do
            sizes([48])
          end
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        ~s|'sizes' entry must be "any" or a "WxH" string such as "48x48", got: 48|
      )
    end

    test "raises when sizes is used multiple times" do
      module("Sizes") do
        tool("get_date") do
          title("T")

          icon do
            sizes(["16x16"])
            sizes(["32x32"])
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'sizes' multiple times")
    end

    test "raises when sizes is not a list" do
      module("Sizes") do
        tool("get_date") do
          title("T")
          icon(sizes: "16x16")
        end
      end
      |> assert_compile_raise(ArgumentError, "'sizes' must be a list of string, got: \"16x16\"")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when sizes is used at root level (only tool/2 is imported)" do
      module("Sizes") do
        sizes(["16x16"])
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Tool.Sizes",
        "undefined function sizes/1"
      )
    end

    test "raises when sizes is used directly inside tool block" do
      module("Sizes") do
        tool("get_date") do
          title("T")
          sizes(["16x16"])
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'sizes' here")
    end

    test "raises when sizes is used inside annotations block" do
      module("Sizes") do
        tool("get_date") do
          title("T")

          annotations(read_only_hint: true) do
            sizes(["16x16"])
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'sizes' here")
    end

    test "raises when sizes is used inside execution block" do
      module("Sizes") do
        tool("get_date") do
          title("T")

          execution do
            sizes(["16x16"])
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'sizes' here")
    end
  end
end
