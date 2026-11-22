defmodule OzMcp.Structs.TextContent do
  @moduledoc """
  Helper module used to build `TextContent` structure.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %TextContent{}
    |> TextContent.text("Hello, world!")
    |> TextContent.build()
  ```

  Result:

  ```elixir
  %{type: "text", text: "Hello, world!"}
  ```

  Specification: [TextContent](https://modelcontextprotocol.io/specification/2025-11-25/schema#textcontent)
  """

  use OzMcp.Structs.Wire,
    const: %{type: "text"},
    fields: [
      text: {:string, required: true},
      _meta: :meta,
      annotations: {:struct, OzMcp.Structs.Annotations}
    ]

  alias OzMcp.Structs.{Keys, Validate}

  @doc false
  @spec check_map(map()) :: :ok
  def check_map(block) do
    Validate.non_empty_string(:text, Keys.get(block, "text", :text, ""))
    Validate.meta(:_meta, Keys.get(block, "_meta", :_meta, nil))
    Validate.annotations(Keys.get(block, "annotations", :annotations, nil))
  end
end
