defmodule OzMcp.Structs.StringSchema do
  @moduledoc """
  Helper module used to build `StringSchema` structure: a text field of an
  elicitation form.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %StringSchema{}
    |> StringSchema.title("Email")
    |> StringSchema.format("email")
    |> StringSchema.build()
  ```

  Result:

  ```elixir
  %{type: "string", title: "Email", format: "email"}
  ```

  Specification: [StringSchema](https://modelcontextprotocol.io/specification/2025-11-25/schema#stringschema)
  """

  use OzMcp.Structs.Wire,
    const: %{type: "string"},
    fields: [
      title: :string,
      description: :string,
      minLength: :non_neg_integer,
      maxLength: :non_neg_integer,
      format: {:one_of, ["email", "uri", "date", "date-time"]},
      default: :any_string
    ]

  def build(struct) do
    result = super(struct)

    if struct.minLength && struct.maxLength && struct.minLength > struct.maxLength do
      raise ArgumentError, "The 'minLength' field cannot be greater than 'maxLength'"
    end

    result
  end
end
