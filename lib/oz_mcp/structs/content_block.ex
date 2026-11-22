defmodule OzMcp.Structs.ContentBlock do
  @moduledoc """
  Helper module used to define the `ContentBlock` structure.

  _(MCP protocol: 2025-11-25)_

  `ContentBlock` is a union type. Build one of the specific content
  modules to use it as a `ContentBlock`.

  ## About specification

  Specification: [ContentBlock](https://modelcontextprotocol.io/specification/2025-11-25/schema#contentblock)

  ```
  ContentBlock:
    | TextContent
    | ImageContent
    | AudioContent
    | ResourceLink
    | EmbeddedResource
  ```
  """

  alias OzMcp.Structs.{
    AudioContent,
    EmbeddedResource,
    ImageContent,
    ResourceLink,
    TextContent
  }

  @type t() ::
          %TextContent{}
          | %ImageContent{}
          | %AudioContent{}
          | %ResourceLink{}
          | %EmbeddedResource{}
          | map()
end
