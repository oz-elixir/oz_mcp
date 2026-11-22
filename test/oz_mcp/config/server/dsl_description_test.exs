#
# Tests for the `description/1` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLDescriptionTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  describe "description/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a non-empty string" do
      config =
        module("Description") do
          server_info(description: "A server exposing the marketing toolkit.")
        end
        |> compile_config()

      assert config.server_info.description == "A server exposing the marketing toolkit."
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when description is not a string" do
      module("Description") do
        server_info(description: 123)
      end
      |> assert_compile_raise(ArgumentError, "'description' must be a string, got: 123")
    end

    test "raises when description is an empty string" do
      module("Description") do
        server_info(description: "")
      end
      |> assert_compile_raise(ArgumentError, "'description' cannot be an empty string")
    end

    test "raises when description is used multiple times" do
      module("Description") do
        server_info do
          description "First"
          description "Second"
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'description' multiple times")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises description cannot be at root level" do
      module("Description") do
        description "The description"
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Server.Description",
        "undefined function description/1"
      )
    end

    test "raises when description is used inside tools block" do
      module("Description") do
        tools do
          description "inside"
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'description' here")
    end
  end
end
