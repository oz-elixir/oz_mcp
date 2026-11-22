#
# Tests for the `list/1` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLListTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  describe "list/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a non-empty map" do
      config =
        module("List") do
          capabilities do
            tasks(list: %{enabled: true})
          end
        end
        |> compile_config()

      assert config.capabilities.tasks.list == %{enabled: true}
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when list is not a map" do
      module("List") do
        capabilities do
          tasks(list: 123)
        end
      end
      |> assert_compile_raise(ArgumentError, "'list' must be a map, got: 123")
    end

    test "accepts an empty map" do
      config =
        module("List") do
          capabilities do
            tasks(list: %{})
          end
        end
        |> compile_config()

      assert config.capabilities.tasks.list == %{}
    end

    test "raises when list is declared multiple times" do
      module("List") do
        capabilities do
          tasks do
            list %{a: 1}
            list %{b: 2}
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'list' multiple times")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when list is used at root level" do
      module("List") do
        list %{enabled: true}
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Server.List",
        "undefined function list/1"
      )
    end

    test "raises when list is used directly inside capabilities block" do
      module("List") do
        capabilities do
          list %{enabled: true}
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'list' here")
    end
  end
end
