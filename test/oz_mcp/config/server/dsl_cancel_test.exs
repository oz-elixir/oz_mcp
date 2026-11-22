#
# Tests for the `cancel/1` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLCancelTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  describe "cancel/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a non-empty map" do
      config =
        module("Cancel") do
          capabilities do
            tasks(cancel: %{timeout: 30})
          end
        end
        |> compile_config()

      assert config.capabilities.tasks.cancel == %{timeout: 30}
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when cancel is not a map" do
      module("Cancel") do
        capabilities do
          tasks(cancel: 123)
        end
      end
      |> assert_compile_raise(ArgumentError, "'cancel' must be a map, got: 123")
    end

    test "accepts an empty map" do
      config =
        module("Cancel") do
          capabilities do
            tasks(cancel: %{})
          end
        end
        |> compile_config()

      assert config.capabilities.tasks.cancel == %{}
    end

    test "raises when cancel is declared multiple times" do
      module("Cancel") do
        capabilities do
          tasks do
            cancel %{a: 1}
            cancel %{b: 2}
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'cancel' multiple times")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when cancel is used at root level" do
      module("Cancel") do
        cancel %{timeout: 30}
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Server.Cancel",
        "undefined function cancel/1"
      )
    end

    test "raises when cancel is used directly inside capabilities block" do
      module("Cancel") do
        capabilities do
          cancel %{timeout: 30}
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'cancel' here")
    end
  end
end
