#
# Tests for the `idempotent_hint/1` macro of the tool DSL (annotations property).
# See: lib/oz_mcp/config/tool/dsl.ex
#
defmodule OzMcp.Config.Tool.DSLIdempotentHintTest do
  use ExUnit.Case, async: true

  import Support.Factories.Tool

  describe "idempotent_hint/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts true" do
      tool =
        module("IdempotentHint") do
          tool("get_date") do
            title("T")
            annotations(idempotent_hint: true)
          end
        end
        |> compile_one_tool()

      assert tool.annotations.idempotentHint == true
    end

    test "accepts false" do
      tool =
        module("IdempotentHint") do
          tool("get_date") do
            title("T")
            annotations(idempotent_hint: false)
          end
        end
        |> compile_one_tool()

      assert tool.annotations.idempotentHint == false
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when idempotent_hint is used multiple times" do
      module("IdempotentHint") do
        tool("get_date") do
          title("T")

          annotations(idempotent_hint: true) do
            idempotent_hint(false)
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'idempotent_hint' multiple times")
    end

    test "raises when idempotent_hint is not a boolean" do
      module("IdempotentHint") do
        tool("get_date") do
          title("T")
          annotations(idempotent_hint: "yes")
        end
      end
      |> assert_compile_raise(ArgumentError, "'idempotent_hint' must be a boolean, got: \"yes\"")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when idempotent_hint is used at root level (only tool/2 is imported)" do
      module("IdempotentHint") do
        idempotent_hint(true)
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Tool.IdempotentHint",
        "undefined function idempotent_hint/1"
      )
    end

    test "raises when idempotent_hint is used directly inside tool block" do
      module("IdempotentHint") do
        tool("get_date") do
          title("T")
          idempotent_hint(true)
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'idempotent_hint' here")
    end

    test "raises when idempotent_hint is used inside icon block" do
      module("IdempotentHint") do
        tool("get_date") do
          title("T")

          icon do
            idempotent_hint(true)
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'idempotent_hint' here")
    end

    test "raises when idempotent_hint is used inside execution block" do
      module("IdempotentHint") do
        tool("get_date") do
          title("T")

          execution do
            idempotent_hint(true)
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'idempotent_hint' here")
    end
  end
end
