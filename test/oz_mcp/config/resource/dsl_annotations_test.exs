#
# Tests for the `annotations/1` macro of the resource DSL.
# See: lib/oz_mcp/config/resource/dsl.ex
#
defmodule OzMcp.Config.Resource.DSLAnnotationsTest do
  use ExUnit.Case, async: true

  import Support.Factories.Resource

  describe "annotations/1" do
    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when annotations is used multiple times" do
      module("Annotations") do
        resource("doc.md") do
          annotations(audience: ["user"])
          annotations(priority: 1)
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'annotations' multiple times")
    end

    test "raises when annotations block is empty" do
      module("Annotations") do
        resource("doc.md") do
          annotations()
        end
      end
      |> assert_compile_raise(RuntimeError, "remove 'annotations', it's empty")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when annotations is used at root level (only resource/2 is imported)" do
      module("Annotations") do
        annotations(audience: ["user"])
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Resource.Annotations",
        "undefined function annotations/1"
      )
    end

    test "raises when annotations is used inside icon block" do
      module("Annotations") do
        resource("doc.md") do
          icon do
            annotations(audience: ["user"])
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'annotations' here")
    end

    test "raises when annotations is used inside annotations block" do
      module("Annotations") do
        resource("doc.md") do
          annotations(audience: ["user"]) do
            annotations(priority: 1)
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'annotations' here")
    end
  end
end
