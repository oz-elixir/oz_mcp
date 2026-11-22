defmodule OzMcp.Structs.Root do
  @moduledoc """
  Helper module used to build `Root` structure: a directory or file the
  client lets the server work in.

  _(MCP protocol: 2025-11-25)_

  The client sends the roots; the server reads them with
  `OzMcp.Client.list_roots/2`. This module builds the same map, for example
  for a test double of a client. `uri` must be a `file://` URI.

  ## Short example:

  ```elixir
  %Root{}
    |> Root.uri("file:///home/user/project")
    |> Root.name("Project")
    |> Root.build()
  ```

  Result:

  ```elixir
  %{uri: "file:///home/user/project", name: "Project"}
  ```

  Specification: [Root](https://modelcontextprotocol.io/specification/2025-11-25/schema#root)
  """

  use OzMcp.Structs.Wire,
    fields: [
      uri: {:string, required: true},
      name: :string,
      _meta: :meta
    ]

  def build(struct) do
    result = super(struct)

    if not String.starts_with?(struct.uri, "file://") do
      raise ArgumentError, "The 'uri' field must be a file:// URI, got: #{inspect(struct.uri)}"
    end

    result
  end
end
