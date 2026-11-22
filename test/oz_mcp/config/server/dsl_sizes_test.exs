#
# Tests for the `sizes/1` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLSizesTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  describe "sizes/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a list of strings" do
      config =
        module("Sizes") do
          server_info do
            icon(sizes: ["16x16", "32x32"])
          end
        end
        |> compile_config()

      assert hd(config.server_info.icons).sizes == ["16x16", "32x32"]
    end

    test "accepts sizes ['48x48', 'any']" do
      config =
        module("Sizes") do
          server_info do
            icon(sizes: ["48x48", "any"])
          end
        end
        |> compile_config()

      assert hd(config.server_info.icons).sizes == ["48x48", "any"]
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when sizes is not a list" do
      module("Sizes") do
        server_info do
          icon(sizes: "16x16")
        end
      end
      |> assert_compile_raise(ArgumentError, "'sizes' must be a list of string, got: \"16x16\"")
    end

    test "raises for sizes ['48']" do
      module("Sizes") do
        server_info do
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
        server_info do
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
        server_info do
          icon do
            sizes ["16x16"]
            sizes ["32x32"]
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'sizes' multiple times")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises sizes cannot be at root level" do
      module("Sizes") do
        sizes ["16x16"]
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Server.Sizes",
        "undefined function sizes/1"
      )
    end

    test "raises when sizes is used directly inside server_info block" do
      module("Sizes") do
        server_info do
          sizes ["16x16"]
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'sizes' here")
    end

    test "raises when sizes is used inside tools block" do
      module("Sizes") do
        tools do
          sizes ["16x16"]
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'sizes' here")
    end
  end
end
