#
# Tests for the `open_world_hint/1` macro of the tool DSL (annotations property).
# See: lib/oz_mcp/config/tool/dsl.ex
#
defmodule OzMcp.Config.Tool.DSLOpenWorldHintTest do
  use ExUnit.Case, async: true

  import Support.Factories.Tool

  describe "open_world_hint/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts true" do
      tool =
        module("OpenWorldHint") do
          tool("get_date") do
            title("T")
            annotations(open_world_hint: true)
          end
        end
        |> compile_one_tool()

      assert tool.annotations.openWorldHint == true
    end

    test "accepts false" do
      tool =
        module("OpenWorldHint") do
          tool("get_date") do
            title("T")
            annotations(open_world_hint: false)
          end
        end
        |> compile_one_tool()

      assert tool.annotations.openWorldHint == false
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when open_world_hint is used multiple times" do
      module("OpenWorldHint") do
        tool("get_date") do
          title("T")

          annotations(open_world_hint: true) do
            open_world_hint(false)
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'open_world_hint' multiple times")
    end

    test "raises when open_world_hint is not a boolean" do
      module("OpenWorldHint") do
        tool("get_date") do
          title("T")
          annotations(open_world_hint: "yes")
        end
      end
      |> assert_compile_raise(ArgumentError, "'open_world_hint' must be a boolean, got: \"yes\"")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when open_world_hint is used at root level (only tool/2 is imported)" do
      module("OpenWorldHint") do
        open_world_hint(true)
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Tool.OpenWorldHint",
        "undefined function open_world_hint/1"
      )
    end

    test "raises when open_world_hint is used directly inside tool block" do
      module("OpenWorldHint") do
        tool("get_date") do
          title("T")
          open_world_hint(true)
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'open_world_hint' here")
    end

    test "raises when open_world_hint is used inside icon block" do
      module("OpenWorldHint") do
        tool("get_date") do
          title("T")

          icon do
            open_world_hint(true)
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'open_world_hint' here")
    end

    test "raises when open_world_hint is used inside execution block" do
      module("OpenWorldHint") do
        tool("get_date") do
          title("T")

          execution do
            open_world_hint(true)
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'open_world_hint' here")
    end
  end
end
