#
# Tests for the `prompt/2` macro of the prompt DSL.
# See: lib/oz_mcp/config/prompt/dsl.ex
#
defmodule OzMcp.Config.Prompt.DSLPromptTest do
  use ExUnit.Case, async: true
  import Support.Factories.Prompt

  describe "prompt/2" do
    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when prompt name is not a string" do
      module("Prompt") do
        prompt(123)
      end
      |> assert_compile_raise(ArgumentError, "name must be a string, got: 123")
    end

    test "raises when prompt name is an empty string" do
      module("Prompt") do
        prompt("")
      end
      |> assert_compile_raise(ArgumentError, "'name' cannot be an empty string")
    end

    test "raises when two prompts have the same name" do
      module("Prompt") do
        prompt("code_review", title: "First")
        prompt("code_review", title: "Second")
      end
      |> assert_compile_raise(
        ArgumentError,
        "duplicate prompt name: \"code_review\" is declared two times"
      )
    end

    test "accepts two prompts with different names" do
      mod =
        module("Prompt") do
          prompt("first", title: "First")
          prompt("second", title: "Second")
        end
        |> compile()

      assert Enum.map(mod.list(), & &1.name) == ["first", "second"]
    end

    # -----------------------------------------------------------------------
    # Warnings
    # -----------------------------------------------------------------------

    test "warn?: true emits warning when title is missing in prompt" do
      module("Prompt", _warn_: true) do
        prompt("code_review", description: "D")
      end
      |> assert_compile_warning("The prompt code_review does not have a title configuration")
    end

    test "warn?: true emits warning when description is missing in prompt" do
      module("Prompt", _warn_: true) do
        prompt("code_review", title: "T")
      end
      |> assert_compile_warning(
        "The prompt code_review does not have a description configuration"
      )
    end

    test "warn?: true emits both warnings when title and description are missing in prompt" do
      module("Prompt", _warn_: true) do
        prompt("code_review")
      end
      |> assert_compile_warning("The prompt code_review does not have a title configuration")

      module("Prompt", _warn_: true) do
        prompt("code_review")
      end
      |> assert_compile_warning(
        "The prompt code_review does not have a description configuration"
      )
    end

    test "warn?: false suppresses prompt warnings when title and description are missing" do
      module("Prompt") do
        prompt("code_review")
      end
      |> refute_compile_warning([
        "does not have a title configuration",
        "does not have a description configuration"
      ])
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when prompt block is nested inside another prompt block" do
      module("Prompt") do
        prompt("outer") do
          prompt("inner")
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'prompt' here")
    end

    test "raises when prompt block is used inside icon block" do
      module("Prompt") do
        prompt("outer") do
          icon do
            prompt("inner")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'prompt' here")
    end
  end
end
