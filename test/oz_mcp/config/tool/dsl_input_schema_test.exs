#
# Tests for the `input_schema/1` macro of the tool DSL.
# See: lib/oz_mcp/config/tool/dsl.ex
#
defmodule OzMcp.Config.Tool.DSLInputSchemaTest do
  use ExUnit.Case, async: true

  import Support.Factories.Tool

  describe "input_schema/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a non-empty map stored at tool.inputSchema" do
      tool =
        module("InputSchema") do
          tool("get_date", title: "T", description: "D") do
            input_schema(%{type: "object", properties: %{}})
          end
        end
        |> compile_one_tool()

      assert tool.inputSchema == %{type: "object", properties: %{}}
    end

    test "accepts a string key at the root" do
      tool =
        module("InputSchema") do
          tool("get_date", title: "T", description: "D") do
            input_schema(%{"type" => "object", "properties" => %{}})
          end
        end
        |> compile_one_tool()

      assert tool.inputSchema == %{"type" => "object", "properties" => %{}}
    end

    test "accepts the atom :object at the root" do
      tool =
        module("InputSchema") do
          tool("get_date", title: "T", description: "D") do
            input_schema(%{type: :object, properties: %{}})
          end
        end
        |> compile_one_tool()

      assert tool.inputSchema == %{type: :object, properties: %{}}
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when the root type is not object" do
      module("InputSchema") do
        tool("get_date", title: "T") do
          input_schema(%{type: "string"})
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        ~s|'input_schema' the root must have type: "object", got: "string"|
      )
    end

    test "raises when the root has no type key" do
      module("InputSchema") do
        tool("get_date", title: "T") do
          input_schema(%{properties: %{}})
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        ~s|'input_schema' the root must have type: "object", got: nil|
      )
    end

    test "raises when the root has only a $ref" do
      module("InputSchema") do
        tool("get_date", title: "T") do
          input_schema(%{"$ref" => "#/components/schemas/pet"})
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        ~s|'input_schema' the root must have type: "object", got: nil|
      )
    end

    test "raises when input_schema is used multiple times" do
      module("InputSchema") do
        tool("get_date") do
          title("T")
          input_schema(%{type: "object", properties: %{a: 1}})
          input_schema(%{type: "object", properties: %{b: 2}})
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'input_schema' multiple times")
    end

    test "raises when input_schema is not a map" do
      module("InputSchema") do
        tool("get_date", title: "T") do
          input_schema(123)
        end
      end
      |> assert_compile_raise(ArgumentError, "'input_schema' must be a map, got: 123")
    end

    test "raises when input_schema is an empty map" do
      module("InputSchema") do
        tool("get_date", title: "T") do
          input_schema(%{})
        end
      end
      |> assert_compile_raise(ArgumentError, "'input_schema' cannot be an empty map")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when input_schema is used at root level (only tool/2 is imported)" do
      module("InputSchema") do
        input_schema(%{type: "object"})
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Tool.InputSchema",
        "undefined function input_schema/1"
      )
    end

    test "raises when input_schema is used inside icon block" do
      module("InputSchema") do
        tool("get_date") do
          title("T")

          icon do
            input_schema(%{type: "object"})
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'input_schema' here")
    end

    test "raises when input_schema is used inside annotations block" do
      module("InputSchema") do
        tool("get_date") do
          title("T")

          annotations(read_only_hint: true) do
            input_schema(%{type: "object"})
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'input_schema' here")
    end

    test "raises when input_schema is used inside execution block" do
      module("InputSchema") do
        tool("get_date") do
          title("T")

          execution do
            input_schema(%{type: "object"})
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'input_schema' here")
    end
  end
end
