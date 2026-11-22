defmodule OzMcp.Structs.CallToolResult do
  @moduledoc """
  Helper module used to build `CallToolResult` structure.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %CallToolResult{}
    |> CallToolResult.content([
      %TextContent{}
      |> TextContent.text("Hello, world!")
    ])
    |> CallToolResult.build()
  ```

  Result:

  ```elixir
  %{content: [%{type: "text", text: "Hello, world!"}]}
  ```

  ## Long example:

  ```elixir
  %CallToolResult{}
    |> CallToolResult.content([
      %TextContent{}
      |> TextContent.text("Hello, world!"),
      %ImageContent{}
      |> ImageContent.data("iVBORw0KGgoAAAANSUhEUg==")
      |> ImageContent.mime_type("image/png")
    ])
    |> CallToolResult.structured_content(%{"result" => "ok"})
    |> CallToolResult.is_error(false)
    |> CallToolResult._meta(%{"key" => "value"})
    |> CallToolResult.extras(%{"durationMs" => 12, "cost" => 0.25})
    |> CallToolResult.build()
  ```

  Result:

  ```elixir
  %{
    :content => [
      %{type: "text", text: "Hello, world!"},
      %{
        data: "iVBORw0KGgoAAAANSUhEUg==",
        type: "image",
        mimeType: "image/png"
      }
    ],
    :_meta => %{"key" => "value"},
    :structuredContent => %{"result" => "ok"},
    :isError => false,
    "cost" => 0.25,
    "durationMs" => 12
  }
  ```

  Specification: [CallToolResult](https://modelcontextprotocol.io/specification/2025-11-25/schema#calltoolresult)
  """

  use OzMcp.Structs.Wire,
    fields: [
      content: {:content_list, type: quote(do: [content()])},
      _meta: :meta,
      structuredContent: :map,
      isError: :boolean,
      extras: :extras
    ]

  @type content :: OzMcp.Structs.ContentBlock.t()
end
