#
# Tests for the `instructions/1` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLInstructionsTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  describe "instructions/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a non-empty string" do
      config =
        module("Instructions") do
          instructions "Use this server to manage marketing assets."
        end
        |> compile_config()

      assert config.instructions == "Use this server to manage marketing assets."
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when instructions is not a string" do
      module("Instructions") do
        instructions 123
      end
      |> assert_compile_raise(ArgumentError, "'instructions' must be a string, got: 123")
    end

    test "raises when instructions is an empty string" do
      module("Instructions") do
        instructions ""
      end
      |> assert_compile_raise(ArgumentError, "'instructions' cannot be an empty string")
    end

    test "raises when instructions is used multiple times" do
      module("Instructions") do
        instructions "first"
        instructions "second"
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'instructions' multiple times")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when instructions is used inside tools block" do
      module("Instructions") do
        tools do
          instructions "inside"
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'instructions' here")
    end
  end
end
