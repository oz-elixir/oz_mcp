defmodule OzMcp.Structs.ToolAnnotations do
  @moduledoc """
  Helper module used to build `ToolAnnotations` structure.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %ToolAnnotations{}
    |> ToolAnnotations.title("Search Tool")
    |> ToolAnnotations.read_only_hint(true)
    |> ToolAnnotations.build()
  ```

  Result:

  ```elixir
  %{title: "Search Tool", readOnlyHint: true}
  ```

  Specification: [ToolAnnotations](https://modelcontextprotocol.io/specification/2025-11-25/schema#toolannotations)
  """

  use OzMcp.Structs.Wire,
    fields: [
      title: :string,
      readOnlyHint: :boolean,
      destructiveHint: :boolean,
      idempotentHint: :boolean,
      openWorldHint: :boolean
    ]
end
