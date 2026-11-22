#
# Tests for the `name/1` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLNameTest do
  use ExUnit.Case, async: true

  import Support.Factories.Server

  describe "name/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a non-empty string" do
      config =
        module("Name") do
          server_info(name: "my-server")
        end
        |> compile_config()

      assert config.server_info.name == "my-server"
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when name is not a string" do
      module("Name") do
        server_info(name: 123)
      end
      |> assert_compile_raise(ArgumentError, "'name' must be a string, got: 123")
    end

    test "raises when name is an empty string" do
      module("Name") do
        server_info(name: "")
      end
      |> assert_compile_raise(ArgumentError, "'name' cannot be an empty string")
    end

    test "raises when name is used multiple times" do
      module("Name") do
        server_info do
          name "first"
          name "second"
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'name' multiple times")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises name cannot be at root level" do
      module("Name") do
        name "my-server"
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Server.Name",
        "undefined function name/1"
      )
    end

    test "raises when name is used inside tools block" do
      module("Name") do
        tools do
          name "inside"
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'name' here")
    end
  end
end
