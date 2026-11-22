#
# Tests for the `task_support/1` macro of the tool DSL (execution property).
# See: lib/oz_mcp/config/tool/dsl.ex
#
defmodule OzMcp.Config.Tool.DSLTaskSupportTest do
  use ExUnit.Case, async: true

  import Support.Factories.Tool

  describe "task_support/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts 'forbidden'" do
      tool =
        module("TaskSupport") do
          tool("get_date") do
            title("T")

            execution do
              task_support("forbidden")
            end
          end
        end
        |> compile_one_tool()

      assert tool.execution.taskSupport == "forbidden"
    end

    test "accepts 'optional'" do
      tool =
        module("TaskSupport") do
          tool("get_date") do
            title("T")

            execution do
              task_support("optional")
            end
          end
        end
        |> compile_one_tool()

      assert tool.execution.taskSupport == "optional"
    end

    test "accepts 'required'" do
      tool =
        module("TaskSupport") do
          tool("get_date") do
            title("T")

            execution do
              task_support("required")
            end
          end
        end
        |> compile_one_tool()

      assert tool.execution.taskSupport == "required"
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when task_support is used multiple times" do
      module("TaskSupport") do
        tool("get_date") do
          title("T")

          execution do
            task_support("optional")
            task_support("required")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'task_support' multiple times")
    end

    test "raises when task_support is declared twice with the same value" do
      #
      # NOTE: The ToolExecution struct defaults taskSupport to the atom
      # `:forbidden`, but the DSL stores the string value. So even
      # `task_support "forbidden"` twice is detected as a duplicate
      # (the stored string "forbidden" differs from the atom default).
      #
      module("TaskSupport") do
        tool("get_date") do
          title("T")

          execution do
            task_support("forbidden")
            task_support("forbidden")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'task_support' multiple times")
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when task_support is not a string" do
      module("TaskSupport") do
        tool("get_date") do
          title("T")

          execution do
            task_support(123)
          end
        end
      end
      |> assert_compile_raise(ArgumentError, "'task_support' must be a string, got: 123")
    end

    test "raises when task_support is an invalid value" do
      module("TaskSupport") do
        tool("get_date") do
          title("T")

          execution do
            task_support("invalid")
          end
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        "'task_support' can take only three values: 'forbidden', 'optional' or 'required'"
      )
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when task_support is used at root level (only tool/2 is imported)" do
      module("TaskSupport") do
        task_support("optional")
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Tool.TaskSupport",
        "undefined function task_support/1"
      )
    end

    test "raises when task_support is used directly inside tool block" do
      module("TaskSupport") do
        tool("get_date") do
          title("T")
          task_support("optional")
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'task_support' here")
    end

    test "raises when task_support is used inside icon block" do
      module("TaskSupport") do
        tool("get_date") do
          title("T")

          icon do
            task_support("optional")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'task_support' here")
    end

    test "raises when task_support is used inside annotations block" do
      module("TaskSupport") do
        tool("get_date") do
          title("T")

          annotations(read_only_hint: true) do
            task_support("optional")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'task_support' here")
    end
  end
end
