#
# Tests for the `description/1` macro of the prompt DSL.
# See: lib/oz_mcp/config/prompt/dsl.ex
#
defmodule OzMcp.Config.Prompt.DSLDescriptionTest do
  use ExUnit.Case, async: true

  import Support.Factories.Prompt

  describe "description/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a description at prompt level" do
      prompt =
        module("Description") do
          prompt("code_review", title: "T", description: "D")
        end
        |> compile_one_prompt()

      assert prompt.description == "D"
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when description is used multiple times at prompt level" do
      module("Description") do
        prompt("code_review") do
          description("First")
          description("Second")
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'description' multiple times")
    end

    test "raises when description is not a string" do
      module("Description") do
        prompt("code_review", description: 123)
      end
      |> assert_compile_raise(ArgumentError, "'description' must be a string, got: 123")
    end

    test "raises when description is an empty string" do
      module("Description") do
        prompt("code_review", description: "")
      end
      |> assert_compile_raise(ArgumentError, "'description' cannot be an empty string")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when description is used at root level (only prompt/2 is imported)" do
      module("Description") do
        description("Doc")
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Prompt.Description",
        "undefined function description/1"
      )
    end

    test "raises when description is used inside icon block" do
      module("Description") do
        prompt("code_review") do
          icon do
            description("Other")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'description' here")
    end
  end
end
