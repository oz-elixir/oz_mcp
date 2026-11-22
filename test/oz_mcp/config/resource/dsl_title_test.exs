#
# Tests for the `title/1` macro of the resource DSL.
# See: lib/oz_mcp/config/resource/dsl.ex
#
defmodule OzMcp.Config.Resource.DSLTitleTest do
  use ExUnit.Case, async: true

  import Support.Factories.Resource

  describe "title/1" do
    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when title is used multiple times" do
      module("Title") do
        resource("doc.md") do
          title("First")
          title("Second")
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'title' multiple times")
    end

    test "raises when title is not a string" do
      module("Title") do
        resource("doc.md", title: 123)
      end
      |> assert_compile_raise(ArgumentError, "'title' must be a string, got: 123")
    end

    test "raises when title is an empty string" do
      module("Title") do
        resource("doc.md", title: "")
      end
      |> assert_compile_raise(ArgumentError, "'title' cannot be an empty string")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when title is used at root level (only resource/2 is imported)" do
      module("Title") do
        title("Doc")
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Resource.Title",
        "undefined function title/1"
      )
    end

    test "raises when title is used inside annotations block" do
      module("Title") do
        resource("doc.md") do
          annotations(audience: ["user"]) do
            title("Other")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'title' here")
    end

    test "raises when title is used inside icon block" do
      module("Title") do
        resource("doc.md") do
          icon do
            title("Other")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'title' here")
    end
  end
end
