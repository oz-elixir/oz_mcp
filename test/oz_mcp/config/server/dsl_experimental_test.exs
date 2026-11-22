#
# Tests for the `experimental/1` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLExperimentalTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  describe "experimental/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a non-empty map with string keys" do
      config =
        module("Experimental") do
          capabilities(experimental: %{"feature" => %{}})
        end
        |> compile_config()

      assert config.capabilities.experimental == %{"feature" => %{}}
    end

    test "accepts a non-empty map with atom keys" do
      config =
        module("Experimental") do
          capabilities(experimental: %{feature: %{}})
        end
        |> compile_config()

      assert config.capabilities.experimental == %{feature: %{}}
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when experimental is not a map" do
      module("Experimental") do
        capabilities(experimental: 123)
      end
      |> assert_compile_raise(ArgumentError, "'experimental' must be a map, got: 123")
    end

    test "raises when experimental is an empty map" do
      module("Experimental") do
        capabilities(experimental: %{})
      end
      |> assert_compile_raise(ArgumentError, "'experimental' cannot be an empty map")
    end

    test "raises when experimental has non-string/atom keys" do
      module("Experimental") do
        capabilities(experimental: %{1 => "value"})
      end
      |> assert_compile_raise(
        ArgumentError,
        "all keys of 'experimental' map must be a string or atom"
      )
    end

    test "raises when experimental is declared multiple times" do
      module("Experimental") do
        capabilities do
          experimental %{a: 1}
          experimental %{b: 2}
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'experimental' multiple times")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when experimental is used at root level" do
      module("Experimental") do
        experimental %{feature: %{}}
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Server.Experimental",
        "undefined function experimental/1"
      )
    end

    test "raises when experimental is used inside tools block" do
      module("Experimental") do
        tools do
          experimental %{feature: %{}}
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'experimental' here")
    end
  end
end
