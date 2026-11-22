#
# Tests for the `completions/1` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLCompletionsTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  describe "completions/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts the canonical empty map" do
      config =
        module("Completions") do
          capabilities(completions: %{})
        end
        |> compile_config()

      assert config.capabilities.completions == %{}
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when completions is not a map" do
      module("Completions") do
        capabilities(completions: 123)
      end
      |> assert_compile_raise(ArgumentError, "'completions' must be a map, got: 123")
    end

    test "raises when completions is not an empty map" do
      module("Completions") do
        capabilities(completions: %{foo: 1})
      end
      |> assert_compile_raise(
        ArgumentError,
        "'completions' must be an empty map %{}, got: %{foo: 1}"
      )
    end

    test "raises when completions is declared multiple times" do
      module("Completions") do
        capabilities do
          completions %{}
          completions %{}
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'completions' multiple times")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when completions is used at root level" do
      module("Completions") do
        completions %{}
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Server.Completions",
        "undefined function completions/1"
      )
    end

    test "raises when completions is used inside tools block" do
      module("Completions") do
        tools do
          completions %{}
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'completions' here")
    end
  end
end
