#
# Tests for the `argument/2` macro of the prompt DSL.
# See: lib/oz_mcp/config/prompt/dsl.ex
#
defmodule OzMcp.Config.Prompt.DSLArgumentTest do
  use ExUnit.Case, async: true

  import Support.Factories.Prompt

  alias OzMcp.Structs.PromptArgument

  describe "argument/2" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts an argument without options" do
      prompt =
        module("Argument") do
          prompt("code_review") do
            title("T")
            description("D")

            argument("language")
          end
        end
        |> compile_one_prompt()

      assert prompt.arguments == [%PromptArgument{name: "language"}]
    end

    test "accepts an argument with all options" do
      prompt =
        module("Argument") do
          prompt("code_review") do
            title("T")
            description("D")

            argument("language",
              required: true,
              title: "Language",
              description: "Programming language"
            )
          end
        end
        |> compile_one_prompt()

      assert prompt.arguments == [
               %PromptArgument{
                 name: "language",
                 title: "Language",
                 description: "Programming language",
                 required: true
               }
             ]
    end

    test "accepts an argument with required: false" do
      prompt =
        module("Argument") do
          prompt("code_review") do
            title("T")

            argument("focus", required: false)
          end
        end
        |> compile_one_prompt()

      assert prompt.arguments == [%PromptArgument{name: "focus", required: false}]
    end

    test "accepts multiple arguments that accumulate in declaration order" do
      prompt =
        module("Argument") do
          prompt("code_review") do
            title("T")

            argument("language", required: true)
            argument("focus")
          end
        end
        |> compile_one_prompt()

      assert Enum.map(prompt.arguments, & &1.name) == ["language", "focus"]
    end

    test "leaves arguments nil when no argument is declared" do
      prompt =
        module("Argument") do
          prompt("code_review", title: "T", description: "D")
        end
        |> compile_one_prompt()

      assert prompt.arguments == nil
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when argument name is not a string" do
      module("Argument") do
        prompt("code_review") do
          title("T")
          argument(123)
        end
      end
      |> assert_compile_raise(ArgumentError, "name must be a string, got: 123")
    end

    test "raises when argument name is an empty string" do
      module("Argument") do
        prompt("code_review") do
          title("T")
          argument("")
        end
      end
      |> assert_compile_raise(ArgumentError, "'name' cannot be an empty string")
    end

    test "raises when opts is not a keyword list" do
      module("Argument") do
        prompt("code_review") do
          title("T")
          argument("language", "not-keyword")
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        "'opts' must be a keyword list, got: \"not-keyword\""
      )
    end

    test "raises when an unknown option is given" do
      module("Argument") do
        prompt("code_review") do
          title("T")
          argument("language", requird: true)
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        "unknown argument option(s): [:requird], allowed options are :title, :description and :required"
      )
    end

    test "raises when argument title is not a string" do
      module("Argument") do
        prompt("code_review") do
          title("T")
          argument("language", title: 123)
        end
      end
      |> assert_compile_raise(ArgumentError, "'title' must be a non-empty string, got: 123")
    end

    test "raises when argument title is an empty string" do
      module("Argument") do
        prompt("code_review") do
          title("T")
          argument("language", title: "")
        end
      end
      |> assert_compile_raise(ArgumentError, "'title' must be a non-empty string, got: \"\"")
    end

    test "raises when argument description is not a string" do
      module("Argument") do
        prompt("code_review") do
          title("T")
          argument("language", description: 123)
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        "'description' must be a non-empty string, got: 123"
      )
    end

    test "raises when argument description is an empty string" do
      module("Argument") do
        prompt("code_review") do
          title("T")
          argument("language", description: "")
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        "'description' must be a non-empty string, got: \"\""
      )
    end

    test "raises when required is not a boolean" do
      module("Argument") do
        prompt("code_review") do
          title("T")
          argument("language", required: "yes")
        end
      end
      |> assert_compile_raise(ArgumentError, "'required' must be a boolean, got: \"yes\"")
    end

    test "raises when argument name is declared multiple times" do
      module("Argument") do
        prompt("code_review") do
          title("T")
          argument("language", required: true)
          argument("language", required: false)
        end
      end
      |> assert_compile_raise(RuntimeError, "argument 'language' already exists")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when argument is used at root level (only prompt/2 is imported)" do
      module("Argument") do
        argument("language")
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Prompt.Argument",
        "undefined function argument/2"
      )
    end

    test "raises when argument is used inside icon block" do
      module("Argument") do
        prompt("code_review") do
          title("T")

          icon do
            argument("language")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'argument' here")
    end
  end
end
