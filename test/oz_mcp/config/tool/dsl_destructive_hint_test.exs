#
# Tests for the `destructive_hint/1` macro of the tool DSL (annotations property).
# See: lib/oz_mcp/config/tool/dsl.ex
#
defmodule OzMcp.Config.Tool.DSLDestructiveHintTest do
  use ExUnit.Case, async: true

  import Support.Factories.Tool

  describe "destructive_hint/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts true" do
      tool =
        module("DestructiveHint") do
          tool("get_date") do
            title("T")
            annotations(destructive_hint: true)
          end
        end
        |> compile_one_tool()

      assert tool.annotations.destructiveHint == true
    end

    test "accepts false" do
      tool =
        module("DestructiveHint") do
          tool("get_date") do
            title("T")
            annotations(destructive_hint: false)
          end
        end
        |> compile_one_tool()

      assert tool.annotations.destructiveHint == false
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when destructive_hint is used multiple times" do
      module("DestructiveHint") do
        tool("get_date") do
          title("T")

          annotations(destructive_hint: true) do
            destructive_hint(false)
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'destructive_hint' multiple times")
    end

    test "raises when destructive_hint is not a boolean" do
      module("DestructiveHint") do
        tool("get_date") do
          title("T")
          annotations(destructive_hint: "yes")
        end
      end
      |> assert_compile_raise(ArgumentError, "'destructive_hint' must be a boolean, got: \"yes\"")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when destructive_hint is used at root level (only tool/2 is imported)" do
      module("DestructiveHint") do
        destructive_hint(true)
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Tool.DestructiveHint",
        "undefined function destructive_hint/1"
      )
    end

    test "raises when destructive_hint is used directly inside tool block" do
      module("DestructiveHint") do
        tool("get_date") do
          title("T")
          destructive_hint(true)
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'destructive_hint' here")
    end

    test "raises when destructive_hint is used inside icon block" do
      module("DestructiveHint") do
        tool("get_date") do
          title("T")

          icon do
            destructive_hint(true)
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'destructive_hint' here")
    end

    test "raises when destructive_hint is used inside execution block" do
      module("DestructiveHint") do
        tool("get_date") do
          title("T")

          execution do
            destructive_hint(true)
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'destructive_hint' here")
    end
  end
end
