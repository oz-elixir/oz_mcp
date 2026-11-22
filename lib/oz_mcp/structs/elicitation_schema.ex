defmodule OzMcp.Structs.ElicitationSchema do
  @moduledoc """
  Helper module used to build the `requestedSchema` of a form elicitation:
  a flat object whose properties are primitive fields.

  _(MCP protocol: 2025-11-25)_

  A property is one of `OzMcp.Structs.StringSchema`,
  `OzMcp.Structs.NumberSchema`, `OzMcp.Structs.BooleanSchema`,
  `OzMcp.Structs.EnumSchema`, `OzMcp.Structs.MultiSelectEnumSchema`, or a
  map that is already a primitive schema. The form is flat: `build/1` raises
  `ArgumentError` for a map whose `type` is not `string`, `number`,
  `integer`, `boolean` or an `array` of strings (a nested `object`, or an
  `array` of objects).

  ## Short example:

  ```elixir
  %ElicitationSchema{}
    |> ElicitationSchema.property("name", %StringSchema{} |> StringSchema.title("Name"))
    |> ElicitationSchema.property("age", %NumberSchema{} |> NumberSchema.type(:integer))
    |> ElicitationSchema.required(["name"])
    |> ElicitationSchema.build()
  ```

  Result:

  ```elixir
  %{
    type: "object",
    properties: %{
      "name" => %{type: "string", title: "Name"},
      "age" => %{type: "integer"}
    },
    required: ["name"]
  }
  ```

  Specification: [ElicitRequestFormParams](https://modelcontextprotocol.io/specification/2025-11-25/schema#elicitrequestformparams)
  """

  use OzMcp.Structs.Wire,
    build: false,
    fields: [
      properties: {:map, required: true, type: quote(do: %{optional(String.t()) => primitive()})},
      required: {:list, type: quote(do: list(String.t()) | nil)}
    ]

  alias OzMcp.Structs.{
    BooleanSchema,
    EnumSchema,
    MultiSelectEnumSchema,
    NumberSchema,
    StringSchema,
    Validate
  }

  @type primitive ::
          %StringSchema{}
          | %NumberSchema{}
          | %BooleanSchema{}
          | %EnumSchema{}
          | %MultiSelectEnumSchema{}
          | map()

  @spec property(%__MODULE__{}, String.t(), primitive()) :: %__MODULE__{}
  def property(struct, name, schema) do
    Map.put(struct, :properties, Map.put(struct.properties, name, schema))
  end

  @spec build(t()) :: map()
  def build(struct) do
    Validate.list_or_nil(:required, struct.required)

    if not is_map(struct.properties) or map_size(struct.properties) == 0 do
      raise ArgumentError, "The 'properties' field is required and must be a non-empty map"
    end

    Enum.each(struct.properties, fn {name, _schema} ->
      if not is_binary(name) or name == "" do
        raise ArgumentError,
              "property names must be non-empty strings, got: #{inspect(name)}"
      end
    end)

    names = Map.keys(struct.properties)

    Enum.each(struct.required || [], fn name ->
      if name not in names do
        raise ArgumentError, "required property #{inspect(name)} is not a property of the schema"
      end
    end)

    %{type: "object", properties: Map.new(struct.properties, fn {k, v} -> {k, primitive(v)} end)}
    |> put_required(struct.required)
  end

  defp put_required(result, nil), do: result
  defp put_required(result, []), do: result
  defp put_required(result, required), do: Map.put(result, :required, required)

  defp primitive(%StringSchema{} = s), do: StringSchema.build(s)
  defp primitive(%NumberSchema{} = s), do: NumberSchema.build(s)
  defp primitive(%BooleanSchema{} = s), do: BooleanSchema.build(s)
  defp primitive(%EnumSchema{} = s), do: EnumSchema.build(s)
  defp primitive(%MultiSelectEnumSchema{} = s), do: MultiSelectEnumSchema.build(s)
  defp primitive(%{} = s) when not is_struct(s), do: validate_flat(s)

  defp primitive(other) do
    raise ArgumentError,
          "a property must be a StringSchema, NumberSchema, BooleanSchema, EnumSchema, " <>
            "MultiSelectEnumSchema struct or a map, got: #{inspect(other)}"
  end

  # A map must be a primitive schema: the form is flat.
  #
  defp validate_flat(schema) do
    case get(schema, :type) do
      type when type in ["string", "number", "integer", "boolean"] ->
        schema

      "array" ->
        validate_items(schema, get(schema, :items))

      other ->
        raise ArgumentError,
              "a property map must be a primitive schema (string, number, integer, " <>
                "boolean or an array of strings), got type: #{inspect(other)}"
    end
  end

  # The items of a multi-select are strings (`enum`, or `anyOf` with `const`).
  #
  defp validate_items(schema, %{} = items) when not is_struct(items) do
    if get(items, :type) in [nil, "string"] and is_nil(get(items, :properties)) do
      schema
    else
      invalid_items(items)
    end
  end

  defp validate_items(_schema, items), do: invalid_items(items)

  defp invalid_items(items) do
    raise ArgumentError,
          "an array property must have string items (a multi-select), got items: " <>
            inspect(items)
  end

  defp get(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
