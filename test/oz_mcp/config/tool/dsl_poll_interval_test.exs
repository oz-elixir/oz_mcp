#
# Tests for the `poll_interval/1` macro of the tool DSL (execution
# property). See: lib/oz_mcp/config/tool/dsl.ex
#
defmodule OzMcp.Config.Tool.DSLPollIntervalTest do
  use ExUnit.Case, async: true

  import Support.Factories.Tool

  describe "poll_interval/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a positive integer with task_support 'optional'" do
      tool =
        module("PollInterval") do
          tool("get_date") do
            title("T")

            execution do
              task_support("optional")
              poll_interval(5_000)
            end
          end
        end
        |> compile_one_tool()

      assert tool.execution.poll_interval == 5_000
      assert tool.execution.taskSupport == "optional"
    end

    test "accepts a positive integer with task_support 'required'" do
      tool =
        module("PollInterval") do
          tool("get_date") do
            title("T")

            execution do
              task_support("required")
              poll_interval(1_000)
            end
          end
        end
        |> compile_one_tool()

      assert tool.execution.poll_interval == 1_000
    end

    test "accepts a poll_interval declared before the task_support" do
      tool =
        module("PollInterval") do
          tool("get_date") do
            title("T")

            execution do
              poll_interval(2_500)
              task_support("optional")
            end
          end
        end
        |> compile_one_tool()

      assert tool.execution.poll_interval == 2_500
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when poll_interval is zero" do
      module("PollInterval") do
        tool("get_date") do
          title("T")

          execution do
            task_support("optional")
            poll_interval(0)
          end
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        "'poll_interval' must be a positive integer (ms), got: 0"
      )
    end

    test "raises when poll_interval is negative" do
      module("PollInterval") do
        tool("get_date") do
          title("T")

          execution do
            task_support("optional")
            poll_interval(-1)
          end
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        "'poll_interval' must be a positive integer (ms), got: -1"
      )
    end

    test "raises when poll_interval is a string" do
      module("PollInterval") do
        tool("get_date") do
          title("T")

          execution do
            task_support("optional")
            poll_interval("5")
          end
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        "'poll_interval' must be a positive integer (ms), got: \"5\""
      )
    end

    test "raises when poll_interval is used multiple times" do
      module("PollInterval") do
        tool("get_date") do
          title("T")

          execution do
            task_support("optional")
            poll_interval(5_000)
            poll_interval(1_000)
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'poll_interval' multiple times")
    end

    test "raises when the execution block has a poll_interval but no task_support" do
      module("PollInterval") do
        tool("get_date") do
          title("T")

          execution do
            poll_interval(5_000)
          end
        end
      end
      |> assert_compile_raise(
        RuntimeError,
        "a tool with a 'poll_interval' needs a 'task_support' with the value 'optional' or 'required'"
      )
    end

    test "raises when the execution block has a poll_interval and a forbidden task_support" do
      module("PollInterval") do
        tool("get_date") do
          title("T")

          execution do
            task_support("forbidden")
            poll_interval(5_000)
          end
        end
      end
      |> assert_compile_raise(
        RuntimeError,
        "a tool with a 'poll_interval' needs a 'task_support' with the value 'optional' or 'required'"
      )
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when poll_interval is used at root level (only tool/2 is imported)" do
      module("PollInterval") do
        poll_interval(5_000)
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Tool.PollInterval",
        "undefined function poll_interval/1"
      )
    end

    test "raises when poll_interval is used directly inside tool block" do
      module("PollInterval") do
        tool("get_date") do
          title("T")
          poll_interval(5_000)
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'poll_interval' here")
    end

    test "raises when poll_interval is used inside icon block" do
      module("PollInterval") do
        tool("get_date") do
          title("T")

          icon do
            poll_interval(5_000)
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'poll_interval' here")
    end

    test "raises when poll_interval is used inside annotations block" do
      module("PollInterval") do
        tool("get_date") do
          title("T")

          annotations(read_only_hint: true) do
            poll_interval(5_000)
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'poll_interval' here")
    end
  end
end
