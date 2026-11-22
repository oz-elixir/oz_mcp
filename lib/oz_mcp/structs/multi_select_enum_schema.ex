defmodule OzMcp.Structs.MultiSelectEnumSchema do
  @moduledoc """
  Helper module used to build a multi-select enum field of an elicitation
  form (`UntitledMultiSelectEnumSchema` or `TitledMultiSelectEnumSchema`).

  _(MCP protocol: 2025-11-25)_

  The options are the same as for `OzMcp.Structs.EnumSchema`. Without
  titles the items use `enum`; with at least one title they use `anyOf`.

  ## Short example:

  ```elixir
  %MultiSelectEnumSchema{}
    |> MultiSelectEnumSchema.options(["a", "b", "c"])
    |> MultiSelectEnumSchema.min_items(1)
    |> MultiSelectEnumSchema.default(["a"])
    |> MultiSelectEnumSchema.build()
  ```

  Result:

  ```elixir
  %{type: "array", items: %{type: "string", enum: ["a", "b", "c"]}, minItems: 1, default: ["a"]}
  ```

  Specification: [EnumSchema](https://modelcontextprotocol.io/specification/2025-11-25/schema#enumschema)
  """

  use OzMcp.Structs.Wire,
    build: false,
    fields: [
      title: :string,
      description: :string,
      options: {:list, default: [], type: quote(do: list(OzMcp.Structs.EnumOptions.option()))},
      minItems: :non_neg_integer,
      maxItems: :non_neg_integer,
      default: {:list, type: quote(do: list(String.t()) | nil)}
    ]

  alias OzMcp.Structs.{Builder, EnumOptions, Validate}

  @spec build(t()) :: map()
  def build(struct) do
    Validate.non_empty_string_or_nil(:title, struct.title)
    Validate.non_empty_string_or_nil(:description, struct.description)
    Validate.non_neg_integer_or_nil(:minItems, struct.minItems)
    Validate.non_neg_integer_or_nil(:maxItems, struct.maxItems)
    Validate.list_or_nil(:default, struct.default)

    if struct.minItems && struct.maxItems && struct.minItems > struct.maxItems do
      raise ArgumentError, "The 'minItems' field cannot be greater than 'maxItems'"
    end

    options = EnumOptions.normalize(struct.options)
    validate_default(struct.default, EnumOptions.values(options))

    %{type: "array"}
    |> Builder.maybe_put(struct, :title)
    |> Builder.maybe_put(struct, :description)
    |> Builder.maybe_put(struct, :minItems)
    |> Builder.maybe_put(struct, :maxItems)
    |> Map.put(:items, items(EnumOptions.render(options)))
    |> Builder.maybe_put(struct, :default)
  end

  defp items({:enum, values}), do: %{type: "string", enum: values}
  defp items({:titled, pairs}), do: %{anyOf: pairs}

  defp validate_default(nil, _values), do: :ok

  defp validate_default(default, values) do
    if Enum.all?(default, &(&1 in values)) do
      :ok
    else
      raise ArgumentError, "The 'default' field must contain only values of the options"
    end
  end
end
