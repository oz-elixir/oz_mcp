#
# Tests for the `tools/1` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLToolsTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  describe "tools/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a tools block with at least one tool" do
      config =
        module("Tools") do
          tools(tool: Support.Entities.Tools.SecondTest)
        end
        |> compile_config()

      assert config.tools.modules == [Support.Entities.Tools.SecondTest]
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when tools block is empty" do
      module("Tools") do
        tools(tool: :_none_)
      end
      |> assert_compile_raise(RuntimeError, "must declare at least one tool")
    end

    test "raises when tools is declared multiple times" do
      module("Tools") do
        tools(tool: Support.Entities.Tools.SecondTest)
        tools(tool: Support.Entities.Tools.FirstTest)
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'tools' multiple times")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when tools is used inside resources block" do
      module("Tools") do
        resources do
          tools(tool: Support.Entities.Tools.SecondTest)
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'tools' here")
    end
  end
end
