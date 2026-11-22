defmodule OzMcp.Structs.ResourceContents do
  @moduledoc """
  Helper module used to define the `ResourceContents` structure.

  _(MCP protocol: 2025-11-25)_

  `ResourceContents` is a union type. Build one of the specific
  resource contents modules to use it as a `ResourceContents`.

  ## About specification

  Specification: [TextResourceContents](https://modelcontextprotocol.io/specification/2025-11-25/schema#textresourcecontents), [BlobResourceContents](https://modelcontextprotocol.io/specification/2025-11-25/schema#blobresourcecontents)

  ```
  ResourceContents:
    | TextResourceContents
    | BlobResourceContents
  ```
  """

  alias OzMcp.Structs.{BlobResourceContents, TextResourceContents}

  @type t() :: %TextResourceContents{} | %BlobResourceContents{}
end
