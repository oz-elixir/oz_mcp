#
# Tests for the `priority/1` macro of the resource DSL.
# See: lib/oz_mcp/config/resource/dsl.ex
#
defmodule OzMcp.Config.Resource.DSLPriorityTest do
  use ExUnit.Case, async: true

  import Support.Factories.Resource

  describe "priority/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts priority 0" do
      resource =
        module("Priority") do
          resource("doc.md") do
            annotations(priority: 0)
          end
        end
        |> compile_one_resource()

      assert resource.annotations.priority == 0
    end

    test "accepts priority 1" do
      resource =
        module("Priority") do
          resource("doc.md") do
            annotations(priority: 1)
          end
        end
        |> compile_one_resource()

      assert resource.annotations.priority == 1
    end

    test "accepts a fractional priority" do
      resource =
        module("Priority") do
          resource("doc.md") do
            annotations(priority: 0.5)
          end
        end
        |> compile_one_resource()

      assert resource.annotations.priority == 0.5
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when priority is used multiple times" do
      module("Priority") do
        resource("doc.md") do
          annotations(priority: 1) do
            priority(0)
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'priority' multiple times")
    end

    test "raises when priority is not a number" do
      module("Priority") do
        resource("doc.md") do
          annotations(priority: "high")
        end
      end
      |> assert_compile_raise(ArgumentError, "'priority' must be a number, got: \"high\"")
    end

    test "raises when priority is negative" do
      module("Priority") do
        resource("doc.md") do
          annotations(priority: -1)
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        "'priority' must be a number between 0 and 1, got: -1"
      )
    end

    test "raises when priority is greater than 1" do
      module("Priority") do
        resource("doc.md") do
          annotations(priority: 2)
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        "'priority' must be a number between 0 and 1, got: 2"
      )
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when priority is used at root level (only resource/2 is imported)" do
      module("Priority") do
        priority(1)
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Resource.Priority",
        "undefined function priority/1"
      )
    end

    test "raises when priority is used directly inside resource block" do
      module("Priority") do
        resource("doc.md") do
          priority(1)
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'priority' here")
    end

    test "raises when priority is used inside icon block" do
      module("Priority") do
        resource("doc.md") do
          icon do
            priority(1)
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'priority' here")
    end
  end
end
