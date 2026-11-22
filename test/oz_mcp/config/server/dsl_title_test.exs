#
# Tests for the `title/1` macro of the server DSL.
# See: lib/oz_mcp/config/server/dsl.ex
#
defmodule OzMcp.Config.Server.DSLTitleTest do
  use ExUnit.Case, async: true
  import Support.Factories.Server

  describe "title/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a non-empty string" do
      config =
        module("Title") do
          server_info(title: "Marketing Server")
        end
        |> compile_config()

      assert config.server_info.title == "Marketing Server"
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when title is not a string" do
      module("Title") do
        server_info(title: 123)
      end
      |> assert_compile_raise(ArgumentError, "'title' must be a string, got: 123")
    end

    test "raises when title is an empty string" do
      module("Title") do
        server_info(title: "")
      end
      |> assert_compile_raise(ArgumentError, "'title' cannot be an empty string")
    end

    test "raises when title is used multiple times" do
      module("Title") do
        server_info do
          title "First"
          title "Second"
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'title' multiple times")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises title cannot be at root level" do
      module("Title") do
        title "The title"
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Server.Title",
        "undefined function title/1"
      )
    end

    test "raises when title is used inside tools block" do
      module("Title") do
        tools do
          title "inside"
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'title' here")
    end
  end
end
