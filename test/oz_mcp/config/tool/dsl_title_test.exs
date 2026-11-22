#
# Tests for the `title/1` macro of the tool DSL.
# See: lib/oz_mcp/config/tool/dsl.ex
#
defmodule OzMcp.Config.Tool.DSLTitleTest do
  use ExUnit.Case, async: true

  import Support.Factories.Tool

  describe "title/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a title at tool level" do
      tool =
        module("Title") do
          tool("get_date", title: "T", description: "D")
        end
        |> compile_one_tool()

      assert tool.title == "T"
    end

    test "accepts a title inside annotations (ToolAnnotations.title)" do
      tool =
        module("Title") do
          tool("get_date") do
            title "T"
            description "D"

            annotations do
              title "Annotations title"
            end
          end
        end
        |> compile_one_tool()

      assert tool.title == "T"
      assert tool.annotations.title == "Annotations title"
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when title is used multiple times at tool level" do
      module("Title") do
        tool("get_date") do
          title("First")
          title("Second")
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'title' multiple times")
    end

    test "raises when title is used multiple times inside annotations" do
      module("Title") do
        tool("get_date") do
          title "T"
          description "D"

          annotations do
            title("First")
            title("Second")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'title' multiple times")
    end

    test "raises when title is not a string" do
      module("Title") do
        tool("get_date", title: 123)
      end
      |> assert_compile_raise(ArgumentError, "'title' must be a string, got: 123")
    end

    test "raises when title is an empty string" do
      module("Title") do
        tool("get_date", title: "")
      end
      |> assert_compile_raise(ArgumentError, "'title' cannot be an empty string")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when title is used at root level (only tool/2 is imported)" do
      module("Title") do
        title("Doc")
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Tool.Title",
        "undefined function title/1"
      )
    end

    test "raises when title is used inside icon block" do
      module("Title") do
        tool("get_date") do
          icon do
            title("Other")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'title' here")
    end

    test "raises when title is used inside execution block" do
      module("Title") do
        tool("get_date") do
          execution do
            title("Other")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'title' here")
    end
  end
end
