defmodule OzMcp.Structs.EnumSchema do
  @moduledoc """
  Helper module used to build a single-select enum field of an elicitation
  form (`UntitledSingleSelectEnumSchema` or `TitledSingleSelectEnumSchema`).

  _(MCP protocol: 2025-11-25)_

  The options are strings, `{value, title}` tuples, or maps with `const` and
  `title` (see `OzMcp.Structs.EnumOptions`). Without titles the schema uses
  `enum`; with at least one title it uses `oneOf`.

  ## Short example:

  ```elixir
  %EnumSchema{}
    |> EnumSchema.options(["low", "high"])
    |> EnumSchema.default("low")
    |> EnumSchema.build()
  ```

  Result:

  ```elixir
  %{type: "string", enum: ["low", "high"], default: "low"}
  ```

  With titles:

  ```elixir
  %EnumSchema{}
    |> EnumSchema.options([{"#ff0000", "Red"}, {"#00ff00", "Green"}])
    |> EnumSchema.build()
  ```

  Result:

  ```elixir
  %{
    type: "string",
    oneOf: [%{const: "#ff0000", title: "Red"}, %{const: "#00ff00", title: "Green"}]
  }
  ```

  Specification: [EnumSchema](https://modelcontextprotocol.io/specification/2025-11-25/schema#enumschema)
  """

  use OzMcp.Structs.Wire,
    build: false,
    fields: [
      title: :string,
      description: :string,
      options: {:list, default: [], type: quote(do: list(OzMcp.Structs.EnumOptions.option()))},
      default: :string
    ]

  alias OzMcp.Structs.{Builder, EnumOptions, Validate}

  @spec build(t()) :: map()
  def build(struct) do
    Validate.non_empty_string_or_nil(:title, struct.title)
    Validate.non_empty_string_or_nil(:description, struct.description)

    options = EnumOptions.normalize(struct.options)
    validate_default(struct.default, EnumOptions.values(options))

    %{type: "string"}
    |> Builder.maybe_put(struct, :title)
    |> Builder.maybe_put(struct, :description)
    |> put_options(EnumOptions.render(options))
    |> Builder.maybe_put(struct, :default)
  end

  defp put_options(result, {:enum, values}), do: Map.put(result, :enum, values)
  defp put_options(result, {:titled, pairs}), do: Map.put(result, :oneOf, pairs)

  defp validate_default(nil, _values), do: :ok

  defp validate_default(default, values) do
    if default in values do
      :ok
    else
      raise ArgumentError, "The 'default' field must be one of the options"
    end
  end
end
