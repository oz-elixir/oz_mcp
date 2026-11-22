defmodule OzMcp.Structs.NumberSchema do
  @moduledoc """
  Helper module used to build `NumberSchema` structure: a numeric field of
  an elicitation form. The type is `number` by default; use `type/2` with
  `:integer` for a whole number.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %NumberSchema{}
    |> NumberSchema.type(:integer)
    |> NumberSchema.minimum(1)
    |> NumberSchema.maximum(10)
    |> NumberSchema.build()
  ```

  Result:

  ```elixir
  %{type: "integer", minimum: 1, maximum: 10}
  ```

  Specification: [NumberSchema](https://modelcontextprotocol.io/specification/2025-11-25/schema#numberschema)
  """

  use OzMcp.Structs.Wire,
    fields: [
      type:
        {{:one_of, [:number, :integer, "number", "integer"]},
         required: true, default: :number, to: :string},
      title: :string,
      description: :string,
      minimum: :number,
      maximum: :number,
      default: :number
    ]

  def build(struct) do
    result = super(struct)

    if struct.minimum && struct.maximum && struct.minimum > struct.maximum do
      raise ArgumentError, "The 'minimum' field cannot be greater than 'maximum'"
    end

    result
  end
end
