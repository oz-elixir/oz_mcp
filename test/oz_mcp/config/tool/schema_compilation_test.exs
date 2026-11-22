#
# Tests for the compile-time validation of `inputSchema` / `outputSchema`
# when a tool module is compiled. The compiler writes no cache: the catalog
# builds the root of a static tool at boot.
# See: lib/oz_mcp/config/tool.ex
#
defmodule OzMcp.Config.Tool.SchemaCompilationTest do
  use ExUnit.Case, async: true

  import Support.Factories.Tool

  describe "schema compilation" do
    test "validates the inputSchema of a DSL tool at compile time" do
      module("CompileOnly") do
        tool("get_weather", title: "T", description: "D") do
          input_schema(%{type: "object", properties: %{city: %{type: "string"}}})
        end
      end
      |> compile()
    end

    test "validates the outputSchema of a DSL tool at compile time" do
      module("CompileOutputOnly") do
        tool("get_weather", title: "T", description: "D") do
          output_schema(%{type: "object", properties: %{result: %{type: "string"}}})
        end
      end
      |> compile()
    end

    test "validates the schemas of every tool of a multi-tool module" do
      module("CompileMultiple") do
        tool("first", title: "T", description: "D") do
          input_schema(%{type: "object", properties: %{}})
        end

        tool("second", title: "T", description: "D") do
          input_schema(%{type: "object", properties: %{}})
        end
      end
      |> compile()
    end

    test "accepts a tool without schema" do
      module("CompileNone") do
        tool("get_date", title: "T", description: "D")
      end
      |> compile()
    end

    test "raises at compile time when the inputSchema is not a valid JSON Schema" do
      module("BadInputSchema") do
        tool("get_weather", title: "T", description: "D") do
          input_schema(%{type: "object", properties: %{price: %{type: "float"}}})
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        ~r"invalid schema for key \{Support.Generated.Tool\.BadInputSchema_\d+, \"get_weather\", :input\}"
      )
    end

    test "raises at compile time when the outputSchema is not a valid JSON Schema" do
      module("BadOutputSchema") do
        tool("get_weather", title: "T", description: "D") do
          output_schema(%{type: "object", properties: %{price: %{type: "float"}}})
        end
      end
      |> assert_compile_raise(
        ArgumentError,
        ~r"invalid schema for key \{Support.Generated.Tool\.BadOutputSchema_\d+, \"get_weather\", :output\}"
      )
    end
  end
end
