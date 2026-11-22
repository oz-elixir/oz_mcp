defmodule OzMcp.Structs.BooleanSchema do
  @moduledoc """
  Helper module used to build `BooleanSchema` structure: a yes/no field of
  an elicitation form.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %BooleanSchema{}
    |> BooleanSchema.title("Subscribe")
    |> BooleanSchema.default(true)
    |> BooleanSchema.build()
  ```

  Result:

  ```elixir
  %{type: "boolean", title: "Subscribe", default: true}
  ```

  Specification: [BooleanSchema](https://modelcontextprotocol.io/specification/2025-11-25/schema#booleanschema)
  """

  use OzMcp.Structs.Wire,
    const: %{type: "boolean"},
    fields: [
      title: :string,
      description: :string,
      default: :boolean
    ]
end
