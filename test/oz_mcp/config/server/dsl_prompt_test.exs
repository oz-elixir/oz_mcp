#
# Tests for the `prompt/1` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLPromptTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  describe "prompt/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a module atom inside prompts block" do
      config =
        module("Prompt") do
          prompts(prompt: Support.Entities.Prompts.FirstTest)
        end
        |> compile_config()

      assert config.prompts.modules == [Support.Entities.Prompts.FirstTest]
    end

    test "accepts multiple prompts accumulating in declaration order" do
      config =
        module("Prompt") do
          prompts do
            prompt Support.Entities.Prompts.FirstTest
            prompt Support.Entities.Prompts.SecondTest
          end
        end
        |> compile_config()

      assert config.prompts.modules == [
               Support.Entities.Prompts.FirstTest,
               Support.Entities.Prompts.SecondTest
             ]
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when the same module is listed two times in prompts" do
      module("Prompt") do
        prompts do
          prompt Support.Entities.Prompts.FirstTest
          prompt Support.Entities.Prompts.FirstTest
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        "module #{inspect(Support.Entities.Prompts.FirstTest)} is listed two times in 'prompts'"
      )
    end

    test "raises when prompt is not a module" do
      module("Prompt") do
        prompts(prompt: "not-a-module")
      end
      |> assert_compile_raise(
        ArgumentError,
        "'prompt' must be a module (atom), got: \"not-a-module\""
      )
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises prompt cannot be at root level" do
      module("Prompt") do
        prompt Support.Entities.Prompts.FirstTest
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Server.Prompt",
        "undefined function prompt/1"
      )
    end

    test "raises when prompt is used inside resources block" do
      module("Prompt") do
        resources do
          prompt Support.Entities.Prompts.FirstTest
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'prompt' here")
    end
  end
end
