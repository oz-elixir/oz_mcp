#
# Tests for the `output_schema/1` macro of the tool DSL.
# See: lib/oz_mcp/config/tool/dsl.ex
#
defmodule OzMcp.Config.Tool.DSLOutputSchemaTest do
  use ExUnit.Case, async: true

  import Support.Factories.Tool

  describe "output_schema/1" do
    # -----------------------------------------------------------------------
    # Accepts
    # -----------------------------------------------------------------------

    test "accepts a non-empty map stored at tool.outputSchema" do
      tool =
        module("OutputSchema") do
          tool("get_date", title: "T", description: "D") do
            output_schema(%{type: "object", properties: %{}})
          end
        end
        |> compile_one_tool()

      assert tool.outputSchema == %{type: "object", properties: %{}}
    end

    test "accepts a string key at the root" do
      tool =
        module("OutputSchema") do
          tool("get_date", title: "T", description: "D") do
            output_schema(%{"type" => "object", "properties" => %{}})
          end
        end
        |> compile_one_tool()

      assert tool.outputSchema == %{"type" => "object", "properties" => %{}}
    end

    test "accepts the atom :object at the root" do
      tool =
        module("OutputSchema") do
          tool("get_date", title: "T", description: "D") do
            output_schema(%{type: :object, properties: %{}})
          end
        end
        |> compile_one_tool()

      assert tool.outputSchema == %{type: :object, properties: %{}}
    end

    # -----------------------------------------------------------------------
    # Raises
    # -----------------------------------------------------------------------

    test "raises when the root type is not object" do
      module("OutputSchema") do
        tool("get_date", title: "T") do
          output_schema(%{type: "string"})
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        ~s|'output_schema' the root must have type: "object", got: "string"|
      )
    end

    test "raises when the root has no type key" do
      module("OutputSchema") do
        tool("get_date", title: "T") do
          output_schema(%{properties: %{}})
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        ~s|'output_schema' the root must have type: "object", got: nil|
      )
    end

    test "raises when the root has only a $ref" do
      module("OutputSchema") do
        tool("get_date", title: "T") do
          output_schema(%{"$ref" => "#/components/schemas/pet"})
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        ~s|'output_schema' the root must have type: "object", got: nil|
      )
    end

    test "raises when output_schema is used multiple times" do
      module("OutputSchema") do
        tool("get_date") do
          title("T")
          output_schema(%{type: "object", properties: %{a: 1}})
          output_schema(%{type: "object", properties: %{b: 2}})
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot declare 'output_schema' multiple times")
    end

    test "raises when output_schema is not a map" do
      module("OutputSchema") do
        tool("get_date", title: "T") do
          output_schema(123)
        end
      end
      |> assert_compile_raise(ArgumentError, "'output_schema' must be a map, got: 123")
    end

    test "raises when output_schema is an empty map" do
      module("OutputSchema") do
        tool("get_date", title: "T") do
          output_schema(%{})
        end
      end
      |> assert_compile_raise(ArgumentError, "'output_schema' cannot be an empty map")
    end

    # -----------------------------------------------------------------------
    # Position
    # -----------------------------------------------------------------------

    test "raises when output_schema is used at root level (only tool/2 is imported)" do
      module("OutputSchema") do
        output_schema(%{type: "object"})
      end
      |> assert_compile_raise(
        CompileError,
        ~r"nofile: cannot compile module Support.Generated.Tool.OutputSchema",
        "undefined function output_schema/1"
      )
    end

    test "raises when output_schema is used inside icon block" do
      module("OutputSchema") do
        tool("get_date") do
          title("T")

          icon do
            output_schema(%{type: "object"})
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'output_schema' here")
    end

    test "raises when output_schema is used inside annotations block" do
      module("OutputSchema") do
        tool("get_date") do
          title("T")

          annotations(read_only_hint: true) do
            output_schema(%{type: "object"})
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'output_schema' here")
    end

    test "raises when output_schema is used inside execution block" do
      module("OutputSchema") do
        tool("get_date") do
          title("T")

          execution do
            output_schema(%{type: "object"})
          end
        end
      end
      |> assert_compile_raise(RuntimeError, "cannot use 'output_schema' here")
    end
  end
end
