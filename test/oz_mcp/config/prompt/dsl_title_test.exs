#
# Tests for the `title/1` macro of the prompt DSL.
# See: lib/oz_mcp/config/prompt/dsl.ex
#
defmodule OzMcp.Config.Prompt.DSLTitleTest do
  use ExUnit.Case, async: true

  import Support.Factories.Prompt

  describe "title/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a title at prompt level" do
      prompt =
        module("Title") do
          prompt("code_review", title: "T", description: "D")
        end
        |> compile_one_prompt()

      assert prompt.title == "T"
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when title is used multiple times at prompt level" do
      module("Title") do
        prompt("code_review") do
          title("First")
          title("Second")
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'title' multiple times")
    end

    test "raises when title is not a string" do
      module("Title") do
        prompt("code_review", title: 123)
      end
      |> assert_compile_raise(ArgumentError, "'title' must be a string, got: 123")
    end

    test "raises when title is an empty string" do
      module("Title") do
        prompt("code_review", title: "")
      end
      |> assert_compile_raise(ArgumentError, "'title' cannot be an empty string")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when title is used at root level (only prompt/2 is imported)" do
      module("Title") do
        title("Doc")
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Prompt.Title",
        "undefined function title/1"
      )
    end

    test "raises when title is used inside icon block" do
      module("Title") do
        prompt("code_review") do
          icon do
            title("Other")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'title' here")
    end
  end
end
