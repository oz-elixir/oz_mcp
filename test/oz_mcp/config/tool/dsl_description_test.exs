#
# Tests for the `description/1` macro of the tool DSL.
# See: lib/oz_mcp/config/tool/dsl.ex
#
defmodule OzMcp.Config.Tool.DSLDescriptionTest do
  use ExUnit.Case, async: true

  import Support.Factories.Tool

  describe "description/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a description at tool level" do
      tool =
        module("Description") do
          tool("get_date", title: "T", description: "A description")
        end
        |> compile_one_tool()

      assert tool.description == "A description"
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when description is used multiple times" do
      module("Description") do
        tool("get_date") do
          title("T")
          description("First")
          description("Second")
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'description' multiple times")
    end

    test "raises when description is not a string" do
      module("Description") do
        tool("get_date", title: "T", description: 123)
      end
      |> assert_compile_raise(ArgumentError, "'description' must be a string, got: 123")
    end

    test "raises when description is an empty string" do
      module("Description") do
        tool("get_date", title: "T", description: "")
      end
      |> assert_compile_raise(ArgumentError, "'description' cannot be an empty string")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    # NOTE: The tool DSL imports only `tool/2`; every other macro is an
    # undefined function at the module root -> CompileError.
    #
    test "raises when description is used at root level (only tool/2 is imported)" do
      module("Description") do
        description("A doc")
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Tool.Description",
        "undefined function description/1"
      )
    end

    test "raises when description is used inside icon block" do
      module("Description") do
        tool("get_date") do
          title("T")

          icon do
            description("Other")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'description' here")
    end

    test "raises when description is used inside annotations block" do
      module("Description") do
        tool("get_date") do
          title("T")

          annotations(read_only_hint: true) do
            description("Other")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'description' here")
    end

    test "raises when description is used inside execution block" do
      module("Description") do
        tool("get_date") do
          title("T")

          execution do
            description("Other")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'description' here")
    end
  end
end
