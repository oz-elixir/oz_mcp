#
# Tests for the `requests/1` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLRequestsTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  describe "requests/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a non-empty map" do
      config =
        module("Requests") do
          capabilities do
            tasks(requests: %{tools: %{call: %{}}})
          end
        end
        |> compile_config()

      assert config.capabilities.tasks.requests == %{tools: %{call: %{}}}
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when requests is not a map" do
      module("Requests") do
        capabilities do
          tasks(requests: 123)
        end
      end
      |> assert_compile_raise(ArgumentError, "'requests' must be a map, got: 123")
    end

    test "accepts an empty map" do
      config =
        module("Requests") do
          capabilities do
            tasks(requests: %{})
          end
        end
        |> compile_config()

      assert config.capabilities.tasks.requests == %{}
    end

    test "raises when requests is declared multiple times" do
      module("Requests") do
        capabilities do
          tasks do
            requests %{a: 1}
            requests %{b: 2}
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'requests' multiple times")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when requests is used at root level" do
      module("Requests") do
        requests %{tools: %{call: %{}}}
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Server.Requests",
        "undefined function requests/1"
      )
    end

    test "raises when requests is used directly inside capabilities block" do
      module("Requests") do
        capabilities do
          requests %{tools: %{call: %{}}}
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'requests' here")
    end
  end
end
