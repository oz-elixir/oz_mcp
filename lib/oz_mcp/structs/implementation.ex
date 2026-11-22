defmodule OzMcp.Structs.Implementation do
  @moduledoc """
  Helper module used to build `Implementation` structure.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %Implementation{}
    |> Implementation.name("my-server")
    |> Implementation.title("My MCP Server")
    |> Implementation.version("1.0.0")
    |> Implementation.build()
  ```

  Result:

  ```elixir
  %{name: "my-server", version: "1.0.0", title: "My MCP Server"}
  ```

  Specification: [Implementation](https://modelcontextprotocol.io/specification/2025-11-25/schema#implementation)
  """

  use OzMcp.Structs.Wire,
    fields: [
      icons: {:list_of, OzMcp.Structs.Icon},
      name: {:string, required: true},
      title: :string,
      version: {:string, required: true},
      description: :string,
      websiteUrl: :string
    ]
end
