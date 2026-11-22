defmodule OzMcp.Structs.ToolUseContent do
  @moduledoc """
  Helper module used to build `ToolUseContent` structure: a request of the
  model to call a tool, inside a sampling message.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %ToolUseContent{}
    |> ToolUseContent.id("call_1")
    |> ToolUseContent.name("get_weather")
    |> ToolUseContent.input(%{"city" => "Paris"})
    |> ToolUseContent.build()
  ```

  Result:

  ```elixir
  %{type: "tool_use", id: "call_1", name: "get_weather", input: %{"city" => "Paris"}}
  ```

  Specification: [ToolUseContent](https://modelcontextprotocol.io/specification/2025-11-25/schema#tooluse)
  """

  use OzMcp.Structs.Wire,
    const: %{type: "tool_use"},
    fields: [
      id: {:string, required: true},
      name: {:string, required: true},
      _meta: :meta,
      input: {:map, required: true}
    ]
end
