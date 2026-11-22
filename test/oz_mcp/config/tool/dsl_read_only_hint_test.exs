#
# Tests for the `read_only_hint/1` macro of the tool DSL (annotations property).
# See: lib/oz_mcp/config/tool/dsl.ex
#
defmodule OzMcp.Config.Tool.DSLReadOnlyHintTest do
  use ExUnit.Case, async: true

  import Support.Factories.Tool

  describe "read_only_hint/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts true" do
      tool =
        module("ReadOnlyHint") do
          tool("get_date") do
            title("T")
            annotations(read_only_hint: true)
          end
        end
        |> compile_one_tool()

      assert tool.annotations.readOnlyHint == true
    end

    test "accepts false" do
      tool =
        module("ReadOnlyHint") do
          tool("get_date") do
            title("T")
            annotations(read_only_hint: false)
          end
        end
        |> compile_one_tool()

      assert tool.annotations.readOnlyHint == false
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when read_only_hint is used multiple times" do
      module("ReadOnlyHint") do
        tool("get_date") do
          title("T")

          annotations(read_only_hint: true) do
            read_only_hint(false)
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'read_only_hint' multiple times")
    end

    test "raises when read_only_hint is not a boolean" do
      module("ReadOnlyHint") do
        tool("get_date") do
          title("T")
          annotations(read_only_hint: "yes")
        end
      end
      |> assert_compile_raise(ArgumentError, "'read_only_hint' must be a boolean, got: \"yes\"")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when read_only_hint is used at root level (only tool/2 is imported)" do
      module("ReadOnlyHint") do
        read_only_hint(true)
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Tool.ReadOnlyHint",
        "undefined function read_only_hint/1"
      )
    end

    test "raises when read_only_hint is used directly inside tool block" do
      module("ReadOnlyHint") do
        tool("get_date") do
          title("T")
          read_only_hint(true)
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'read_only_hint' here")
    end

    test "raises when read_only_hint is used inside icon block" do
      module("ReadOnlyHint") do
        tool("get_date") do
          title("T")

          icon do
            read_only_hint(true)
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'read_only_hint' here")
    end

    test "raises when read_only_hint is used inside execution block" do
      module("ReadOnlyHint") do
        tool("get_date") do
          title("T")

          execution do
            read_only_hint(true)
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'read_only_hint' here")
    end
  end
end
