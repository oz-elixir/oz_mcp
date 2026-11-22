#
# Tests for the `annotations/1` macro of the tool DSL.
# See: lib/oz_mcp/config/tool/dsl.ex
#
defmodule OzMcp.Config.Tool.DSLAnnotationsTest do
  use ExUnit.Case, async: true

  import Support.Factories.Tool

  describe "annotations/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts an annotations block with at least one hint" do
      tool =
        module("Annotations") do
          tool("get_date") do
            title("T")
            description("D")
            annotations(read_only_hint: true)
          end
        end
        |> compile_one_tool()

      assert tool.annotations.readOnlyHint == true
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when annotations is used multiple times" do
      module("Annotations") do
        tool("get_date") do
          title("T")
          annotations(read_only_hint: true)
          annotations(destructive_hint: true)
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'annotations' multiple times")
    end

    test "raises when annotations block is empty" do
      module("Annotations") do
        tool("get_date") do
          title("T")
          annotations()
        end
      end
      |> assert_compile_raise(RuntimeError, "remove 'annotations', it's empty")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when annotations is used at root level (only tool/2 is imported)" do
      module("Annotations") do
        annotations(read_only_hint: true)
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Tool.Annotations",
        "undefined function annotations/1"
      )
    end

    test "raises when annotations is used inside icon block" do
      module("Annotations") do
        tool("get_date") do
          title("T")

          icon do
            annotations(read_only_hint: true)
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'annotations' here")
    end

    test "raises when annotations is used inside annotations block" do
      module("Annotations") do
        tool("get_date") do
          title("T")

          annotations(read_only_hint: true) do
            annotations(destructive_hint: true)
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'annotations' here")
    end

    test "raises when annotations is used inside execution block" do
      module("Annotations") do
        tool("get_date") do
          title("T")

          execution do
            annotations(read_only_hint: true)
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'annotations' here")
    end
  end
end
