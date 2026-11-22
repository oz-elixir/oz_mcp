defmodule OzMcp.Structs.ToolResultContent do
  @moduledoc """
  Helper module used to build `ToolResultContent` structure: the result of a
  tool call, inside a sampling message.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %ToolResultContent{}
    |> ToolResultContent.tool_use_id("call_1")
    |> ToolResultContent.content([%TextContent{} |> TextContent.text("18 C")])
    |> ToolResultContent.build()
  ```

  Result:

  ```elixir
  %{type: "tool_result", toolUseId: "call_1", content: [%{type: "text", text: "18 C"}]}
  ```

  Specification: [ToolResultContent](https://modelcontextprotocol.io/specification/2025-11-25/schema#toolresultcontent)
  """

  use OzMcp.Structs.Wire,
    const: %{type: "tool_result"},
    fields: [
      toolUseId: {:string, required: true},
      content: {:content_list, type: quote(do: list())},
      structuredContent: :map,
      isError: :boolean,
      _meta: :meta
    ]
end
