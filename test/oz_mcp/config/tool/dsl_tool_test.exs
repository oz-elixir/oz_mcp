#
# Tests for the `tool/2` macro of the tool DSL.
# See: lib/oz_mcp/config/tool/dsl.ex
#
defmodule OzMcp.Config.Tool.DSLToolTest do
  use ExUnit.Case, async: true
  import Support.Factories.Tool

  describe "tool/2" do
    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when tool name is not a string" do
      module("Tool") do
        tool(123)
      end
      |> assert_compile_raise(ArgumentError, "name must be a string, got: 123")
    end

    test "raises when tool name is an empty string" do
      module("Tool") do
        tool("")
      end
      |> assert_compile_raise(ArgumentError, "'name' cannot be an empty string")
    end

    test "raises when two tools have the same name" do
      module("Tool") do
        tool("get_date", title: "First")
        tool("get_date", title: "Second")
      end
      |> assert_compile_raise(
        ArgumentError,
        "duplicate tool name: \"get_date\" is declared two times"
      )
    end

    test "accepts two tools with different names" do
      mod =
        module("Tool") do
          tool("first", title: "First")
          tool("second", title: "Second")
        end
        |> compile()

      assert Enum.map(mod.list(), & &1.name) == ["first", "second"]
    end

    # -----------------------------------------------------------------------
    # Warnings
    # -----------------------------------------------------------------------

    test "warn?: true emits warning when title is missing in tool" do
      module("Tool", _warn_: true) do
        tool("get_date", description: "D")
      end
      |> assert_compile_warning("The tool get_date does not have a title configuration")
    end

    test "warn?: true emits warning when description is missing in tool" do
      module("Tool", _warn_: true) do
        tool("get_date", title: "T")
      end
      |> assert_compile_warning("The tool get_date does not have a description configuration")
    end

    test "warn?: true emits both warnings when title and description are missing in tool" do
      module("Tool", _warn_: true) do
        tool("get_date")
      end
      |> assert_compile_warning("The tool get_date does not have a title configuration")

      module("Tool", _warn_: true) do
        tool("get_date")
      end
      |> assert_compile_warning("The tool get_date does not have a description configuration")
    end

    test "warn?: false suppresses tool warnings when title and description are missing" do
      module("Tool") do
        tool("get_date")
      end
      |> refute_compile_warning([
        "does not have a title configuration",
        "does not have a description configuration"
      ])
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when tool block is nested inside another tool block" do
      module("Tool") do
        tool("outer") do
          tool("inner")
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'tool' here")
    end

    test "raises when tool block is used inside icon block" do
      module("Tool") do
        tool("outer") do
          icon do
            tool("inner")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'tool' here")
    end

    test "raises when tool block is used inside annotations block" do
      module("Tool") do
        tool("outer") do
          annotations(read_only_hint: true) do
            tool("inner")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'tool' here")
    end

    test "raises when tool block is used inside execution block" do
      module("Tool") do
        tool("outer") do
          execution do
            tool("inner")
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'tool' here")
    end

    # -----------------------------------------------------------------------
    # Name rule (SEP-986)
    # -----------------------------------------------------------------------

    test "warns for a name with a space" do
      module("Tool", _warn_: true) do
        tool("get date", title: "T", description: "D")
      end
      |> assert_compile_warning("SEP-986")
    end

    test "warning shows the rule and the two options" do
      module("Tool", _warn_: true) do
        tool("get date", title: "T", description: "D")
      end
      |> assert_compile_warning(
        "must be 1 to 128 characters of A-Z, a-z, 0-9, _, - and ., got: \"get date\""
      )

      module("Tool", _warn_: true) do
        tool("get date", title: "T", description: "D")
      end
      |> assert_compile_warning("use OzMcp.Config.Tool, strict_names?: true")
    end

    test "does not warn for a valid name with . - _ and digits" do
      module("Tool", _warn_: true) do
        tool("get_date.v2-final", title: "T", description: "D")
      end
      |> refute_compile_warning(["SEP-986"])
    end

    test "does not warn when warn?: false" do
      module("Tool", _warn_: false) do
        tool("get date", title: "T", description: "D")
      end
      |> refute_compile_warning(["SEP-986"])
    end

    test "does not warn by default" do
      module("Tool") do
        tool("get date", title: "T", description: "D")
      end
      |> refute_compile_warning(["SEP-986"])
    end

    test "raises with strict_names?: true for a name with a space" do
      module("Tool", _strict_names_: true, _warn_: true) do
        tool("get date", title: "T", description: "D")
      end
      |> assert_compile_raise(
        ArgumentError,
        "tool name must be 1 to 128 characters of A-Z, a-z, 0-9, _, - and ., got: \"get date\""
      )
    end

    test "raises with strict_names?: true for 129 characters" do
      module("Tool", _strict_names_: true) do
        tool(String.duplicate("a", 129), title: "T", description: "D")
      end
      |> assert_compile_raise(ArgumentError, ~r/tool name must be 1 to 128 characters/)
    end

    test "accepts 128 characters with strict_names?: true" do
      mod =
        module("Tool", _strict_names_: true) do
          tool(String.duplicate("a", 128), title: "T", description: "D")
        end
        |> compile()

      assert [%{name: name}] = mod.list()
      assert String.length(name) == 128
    end

    test "accepts the edge characters . - _ with strict_names?: true" do
      mod =
        module("Tool", _strict_names_: true) do
          tool("a.b-c_d9", title: "T", description: "D")
        end
        |> compile()

      assert [%{name: "a.b-c_d9"}] = mod.list()
    end
  end
end
