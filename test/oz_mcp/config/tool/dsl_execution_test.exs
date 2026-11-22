#
# Tests for the `execution/1` macro of the tool DSL.
# See: lib/oz_mcp/config/tool/dsl.ex
#
defmodule OzMcp.Config.Tool.DSLExecutionTest do
  use ExUnit.Case, async: true

  import Support.Factories.Tool

  alias OzMcp.Structs.ToolExecution

  describe "execution/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts an empty execution block (default taskSupport)" do
      #
      # NOTE: An empty execution block is valid. The resulting ToolExecution
      # keeps the struct's default `taskSupport: :forbidden`.
      #
      tool =
        module("Execution") do
          tool("get_date") do
            title("T")
            description("D")

            execution do
            end
          end
        end
        |> compile_one_tool()

      assert tool.execution == %ToolExecution{taskSupport: nil}
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when execution is used multiple times" do
      module("Execution") do
        tool("get_date") do
          title("T")

          execution do
            task_support("optional")
          end

          execution do
            task_support("required")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'execution' multiple times")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when execution is used at root level (only tool/2 is imported)" do
      module("Execution") do
        execution do
        end
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Tool.Execution",
        "undefined function execution/1"
      )
    end

    test "raises when execution is used inside icon block" do
      module("Execution") do
        tool("get_date") do
          title("T")

          icon do
            execution do
            end
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'execution' here")
    end

    test "raises when execution is used inside annotations block" do
      module("Execution") do
        tool("get_date") do
          title("T")

          annotations(read_only_hint: true) do
            execution do
            end
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'execution' here")
    end

    test "raises when execution is used inside execution block" do
      module("Execution") do
        tool("get_date") do
          title("T")

          execution do
            execution do
            end
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'execution' here")
    end
  end
end
