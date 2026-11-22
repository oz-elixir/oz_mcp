#
# Tests for the `sizes/1` macro of the template DSL.
# See: lib/oz_mcp/config/template/dsl.ex
#
defmodule OzMcp.Config.Template.DSLSizesTest do
  use ExUnit.Case, async: true

  import Support.Factories.Template

  describe "sizes/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts sizes ['48x48', 'any']" do
      template =
        module("Sizes") do
          template("doc") do
            icon do
              sizes(["48x48", "any"])
            end
          end
        end
        |> compile_one_template()

      [icon] = template.icons
      assert icon.sizes == ["48x48", "any"]
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when sizes is used multiple times" do
      module("Sizes") do
        template("doc") do
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
        template("doc") do
          icon(sizes: "16x16")
        end
      end
      |> assert_compile_raise(ArgumentError, "'sizes' must be a list of string, got: \"16x16\"")
    end

    test "raises for sizes ['48']" do
      module("Sizes") do
        template("doc") do
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
        template("doc") do
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

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when sizes is used at root level (only template/2 is imported)" do
      module("Sizes") do
        sizes(["16x16"])
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Template.Sizes",
        "undefined function sizes/1"
      )
    end

    test "raises when sizes is used directly inside template block" do
      module("Sizes") do
        template("doc") do
          sizes(["16x16"])
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'sizes' here")
    end

    test "raises when sizes is used inside annotations block" do
      module("Sizes") do
        template("doc") do
          annotations(audience: ["user"]) do
            sizes(["16x16"])
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'sizes' here")
    end
  end
end
