#
# Tests for the `logging/1` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLLoggingTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  describe "logging/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts an empty map" do
      config =
        module("Logging") do
          capabilities(logging: %{})
        end
        |> compile_config()

      assert config.capabilities.logging == %{}
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when logging is not a map" do
      module("Logging") do
        capabilities(logging: 123)
      end
      |> assert_compile_raise(ArgumentError, "'logging' must be a map, got: 123")
    end

    test "raises when logging is not an empty map" do
      module("Logging") do
        capabilities(logging: %{enabled: true})
      end
      |> assert_compile_raise(
        ArgumentError,
        "'logging' must be an empty map %{}, got: %{enabled: true}"
      )
    end

    test "raises when logging is declared multiple times" do
      module("Logging") do
        capabilities do
          logging %{}
          logging %{}
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'logging' multiple times")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when logging is used at root level" do
      module("Logging") do
        logging %{}
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Server.Logging",
        "undefined function logging/1"
      )
    end

    test "raises when logging is used inside tools block" do
      module("Logging") do
        tools do
          logging %{}
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'logging' here")
    end
  end
end
