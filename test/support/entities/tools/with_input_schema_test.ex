defmodule Support.Entities.Tools.WithInputSchemaTest do
  use OzMcp.Config.Tool, dsl?: false

  alias OzMcp.Structs.Tool

  @input_schema %{
    type: "object",
    required: ["string_1", "integer_1"],
    properties: %{
      #
      # All types
      #
      string_1: %{type: "string", description: "string_1"},
      integer_1: %{type: "integer", description: "integer_1"},
      float_1: %{type: "number", description: "float_1"},
      number_1: %{type: "number", description: "number_1"},
      boolean_1: %{type: "boolean", description: "boolean_1"},
      array_1: %{type: "array", description: "array_1"},
      object_1: %{type: "object", description: "object_1"},
      #
      # With defaults
      #
      string_2: %{type: "string", default: "default_2"},
      integer_2: %{type: "integer", default: 2},
      float_2: %{type: "number", default: 1.5},
      number_2: %{type: "number", default: 42},
      boolean_2: %{type: "boolean", default: false},
      array_2: %{type: "array", default: [1, 2]},
      #
      # All constraints
      #
      string_3: %{type: "string", minLength: 3, maxLength: 20},
      integer_3: %{type: "integer", minimum: 0, maximum: 150},
      float_3: %{type: "number", exclusiveMinimum: 0.0, exclusiveMaximum: 1.0},
      number_3: %{type: "number", minimum: 5, maximum: 42},
      email_3: %{type: "string", format: "email"},
      uri_3: %{type: "string", format: "uri"}
    }
  }

  def list do
    list = [
      %Tool{}
      |> Tool.name("input_schema_tool")
      |> Tool.title("Tool with input schema")
      |> Tool.description("A tool with all properties in input schema")
      |> Tool.input_schema(@input_schema)
    ]

    list
  end

  def call(_ctx, _params), do: {:ik, :fake_result}
end
