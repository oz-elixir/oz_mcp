#
# Tests for the `size/1` macro of the resource DSL.
# See: lib/oz_mcp/config/resource/dsl.ex
#
defmodule OzMcp.Config.Resource.DSLSizeTest do
  use ExUnit.Case, async: true

  import Support.Factories.Resource

  describe "size/1" do
    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when size is used multiple times" do
      module("Size") do
        resource("doc.md") do
          size(100)
          size(200)
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'size' multiple times")
    end

    test "raises when size is not an integer" do
      module("Size") do
        resource("doc.md", size: "big")
      end
      |> assert_compile_raise(ArgumentError, "'size' must be an integer, got: \"big\"")
    end

    test "raises when size is zero" do
      module("Size") do
        resource("doc.md", size: 0)
      end
      |> assert_compile_raise(ArgumentError, "'size' cannot be equals to zero")
    end

    test "raises when size is negative" do
      module("Size") do
        resource("doc.md", size: -1)
      end
      |> assert_compile_raise(ArgumentError, "'size' must be a positive integer")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when size is used at root level (only resource/2 is imported)" do
      module("Size") do
        size(100)
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Resource.Size",
        "undefined function size/1"
      )
    end

    test "raises when size is used inside annotations block" do
      module("Size") do
        resource("doc.md") do
          annotations(audience: ["user"]) do
            size(100)
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'size' here")
    end

    test "raises when size is used inside icon block" do
      module("Size") do
        resource("doc.md") do
          icon do
            size(100)
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'size' here")
    end
  end
end
