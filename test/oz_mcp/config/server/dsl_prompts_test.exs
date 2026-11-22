#
# Tests for the `prompts/1` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLPromptsTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  describe "prompts/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a prompts block with at least one prompt" do
      config =
        module("Prompts") do
          prompts(prompt: Support.Entities.Prompts.FirstTest)
        end
        |> compile_config()

      assert config.prompts.modules == [Support.Entities.Prompts.FirstTest]
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when prompts block is empty" do
      module("Prompts") do
        prompts(prompt: :_none_)
      end
      |> assert_compile_raise(RuntimeError, "must declare at least one prompt")
    end

    test "raises when prompts is declared multiple times" do
      module("Prompts") do
        prompts(prompt: Support.Entities.Prompts.FirstTest)
        prompts(prompt: Support.Entities.Prompts.SecondTest)
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'prompts' multiple times")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when prompts is used inside resources block" do
      module("Prompts") do
        resources do
          prompts(prompt: Support.Entities.Prompts.FirstTest)
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'prompts' here")
    end
  end
end
