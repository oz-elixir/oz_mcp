#
# Tests for the `description/1` macro of the template DSL.
# See: lib/oz_mcp/config/template/dsl.ex
#
defmodule OzMcp.Config.Template.DSLDescriptionTest do
  use ExUnit.Case, async: true

  import Support.Factories.Template

  describe "description/1" do
    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when description is used multiple times" do
      module("Description") do
        template("doc") do
          description("First")
          description("Second")
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'description' multiple times")
    end

    test "raises when description is not a string" do
      module("Description") do
        template("doc", description: 123)
      end
      |> assert_compile_raise(ArgumentError, "'description' must be a string, got: 123")
    end

    test "raises when description is an empty string" do
      module("Description") do
        template("doc", description: "")
      end
      |> assert_compile_raise(ArgumentError, "'description' cannot be an empty string")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when description is used at root level (only template/2 is imported)" do
      module("Description") do
        description("A doc")
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Template.Description",
        "undefined function description/1"
      )
    end

    test "raises when description is used inside annotations block" do
      module("Description") do
        template("doc") do
          annotations(audience: ["user"]) do
            description("Other")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'description' here")
    end

    test "raises when description is used inside icon block" do
      module("Description") do
        template("doc") do
          icon do
            description("Other")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'description' here")
    end
  end
end
