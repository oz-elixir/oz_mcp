#
# Tests for the `tool/1` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLToolTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  describe "tool/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a module atom inside tools block" do
      config =
        module("Tool") do
          tools(tool: Support.Entities.Tools.SecondTest)
        end
        |> compile_config()

      assert config.tools.modules == [Support.Entities.Tools.SecondTest]
    end

    test "accepts multiple tools accumulating in declaration order" do
      config =
        module("Tool") do
          tools do
            tool Support.Entities.Tools.SecondTest
            tool Support.Entities.Tools.FirstTest
          end
        end
        |> compile_config()

      assert config.tools.modules == [
               Support.Entities.Tools.SecondTest,
               Support.Entities.Tools.FirstTest
             ]
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when the same module is listed two times in tools" do
      module("Tool") do
        tools do
          tool Support.Entities.Tools.SecondTest
          tool Support.Entities.Tools.SecondTest
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        "module #{inspect(Support.Entities.Tools.SecondTest)} is listed two times in 'tools'"
      )
    end

    test "raises when tool is not a module" do
      module("Tool") do
        tools(tool: "not-a-module")
      end
      |> assert_compile_raise(
        ArgumentError,
        "'tool' must be a module (atom), got: \"not-a-module\""
      )
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises tool cannot be at root level" do
      module("Tool") do
        tool Support.Entities.Tools.SecondTest
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Server.Tool",
        "undefined function tool/1"
      )
    end

    test "raises when tool is used inside resources block" do
      module("Tool") do
        resources do
          tool Support.Entities.Tools.SecondTest
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'tool' here")
    end
  end
end
