#
# Tests for the `immediate_response/1` macro of the tool DSL (execution
# property). See: lib/oz_mcp/config/tool/dsl.ex
#
defmodule OzMcp.Config.Tool.DSLImmediateResponseTest do
  use ExUnit.Case, async: true

  import Support.Factories.Tool

  alias OzMcp.Structs.Tool

  describe "immediate_response/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a non-empty string with task_support 'optional'" do
      tool =
        module("ImmediateResponse") do
          tool("get_date") do
            title("T")

            execution do
              task_support("optional")
              immediate_response("Export started. It can take a few minutes.")
            end
          end
        end
        |> compile_one_tool()

      assert tool.execution.immediate_response ==
               "Export started. It can take a few minutes."

      assert tool.execution.taskSupport == "optional"
    end

    test "accepts a non-empty string with task_support 'required'" do
      tool =
        module("ImmediateResponse") do
          tool("get_date") do
            title("T")

            execution do
              task_support("required")
              immediate_response("Working on it.")
            end
          end
        end
        |> compile_one_tool()

      assert tool.execution.immediate_response == "Working on it."
    end

    test "accepts an immediate_response declared before the task_support" do
      tool =
        module("ImmediateResponse") do
          tool("get_date") do
            title("T")

            execution do
              immediate_response("Working on it.")
              task_support("optional")
            end
          end
        end
        |> compile_one_tool()

      assert tool.execution.immediate_response == "Working on it."
    end

    test "does not emit the value in the tools/list output" do
      tool =
        module("ImmediateResponse") do
          tool("get_date") do
            title("T")

            execution do
              task_support("optional")
              immediate_response("Working on it.")
            end
          end
        end
        |> compile_one_tool()

      built = Tool.build(tool)

      assert built.execution == %{taskSupport: "optional"}
      refute Map.has_key?(built.execution, :immediate_response)
      refute Map.has_key?(built.execution, :immediateResponse)
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when immediate_response is an empty string" do
      module("ImmediateResponse") do
        tool("get_date") do
          title("T")

          execution do
            task_support("optional")
            immediate_response("")
          end
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        "'immediate_response' must be a non-empty string, got: \"\""
      )
    end

    test "raises when immediate_response is not a string" do
      module("ImmediateResponse") do
        tool("get_date") do
          title("T")

          execution do
            task_support("optional")
            immediate_response(123)
          end
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        "'immediate_response' must be a non-empty string, got: 123"
      )
    end

    test "raises when immediate_response is used multiple times" do
      module("ImmediateResponse") do
        tool("get_date") do
          title("T")

          execution do
            task_support("optional")
            immediate_response("One.")
            immediate_response("Two.")
          end
        end
      end
      |> assert_compile_raise(
        RuntimeError,
        "cannot declare 'immediate_response' multiple times"
      )
    end

    test "raises when the execution block has an immediate_response but no task_support" do
      module("ImmediateResponse") do
        tool("get_date") do
          title("T")

          execution do
            immediate_response("Working on it.")
          end
        end
      end
      |> assert_compile_raise(
        RuntimeError,
        "a tool with an 'immediate_response' needs a 'task_support' with the value 'optional' or 'required'"
      )
    end

    test "raises when the execution block has an immediate_response and a forbidden task_support" do
      module("ImmediateResponse") do
        tool("get_date") do
          title("T")

          execution do
            task_support("forbidden")
            immediate_response("Working on it.")
          end
        end
      end
      |> assert_compile_raise(
        RuntimeError,
        "a tool with an 'immediate_response' needs a 'task_support' with the value 'optional' or 'required'"
      )
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when immediate_response is used at root level (only tool/2 is imported)" do
      module("ImmediateResponse") do
        immediate_response("Working on it.")
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Tool.ImmediateResponse",
        "undefined function immediate_response/1"
      )
    end

    test "raises when immediate_response is used directly inside tool block" do
      module("ImmediateResponse") do
        tool("get_date") do
          title("T")
          immediate_response("Working on it.")
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'immediate_response' here")
    end

    test "raises when immediate_response is used inside icon block" do
      module("ImmediateResponse") do
        tool("get_date") do
          title("T")

          icon do
            immediate_response("Working on it.")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'immediate_response' here")
    end

    test "raises when immediate_response is used inside annotations block" do
      module("ImmediateResponse") do
        tool("get_date") do
          title("T")

          annotations(read_only_hint: true) do
            immediate_response("Working on it.")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'immediate_response' here")
    end
  end
end
