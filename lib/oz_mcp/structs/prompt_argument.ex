defmodule OzMcp.Structs.PromptArgument do
  @moduledoc """
  Helper module used to build `PromptArgument` structure.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %PromptArgument{}
    |> PromptArgument.name("city")
    |> PromptArgument.description("The city name")
    |> PromptArgument.required(true)
    |> PromptArgument.build()
  ```

  Result:

  ```elixir
  %{name: "city", description: "The city name", required: true}
  ```

  Specification: [PromptArgument](https://modelcontextprotocol.io/specification/2025-11-25/schema#promptargument)
  """

  use OzMcp.Structs.Wire,
    fields: [
      name: {:string, required: true},
      title: :string,
      description: :string,
      required: {:boolean, emit: :true_only}
    ]
end
