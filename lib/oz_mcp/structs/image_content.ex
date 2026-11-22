defmodule OzMcp.Structs.ImageContent do
  @moduledoc """
  Helper module used to build `ImageContent` structure.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %ImageContent{}
    |> ImageContent.data("iVBORw0KGgoAAAANSUhEUg==")
    |> ImageContent.mime_type("image/png")
    |> ImageContent.build()
  ```

  Result:

  ```elixir
  %{data: "iVBORw0KGgoAAAANSUhEUg==", type: "image", mimeType: "image/png"}
  ```

  Specification: [ImageContent](https://modelcontextprotocol.io/specification/2025-11-25/schema#imagecontent)
  """

  use OzMcp.Structs.Wire,
    const: %{type: "image"},
    fields: [
      data: {:string, required: true},
      mimeType: {:string, required: true},
      _meta: :meta,
      annotations: {:struct, OzMcp.Structs.Annotations}
    ]

  alias OzMcp.Structs.{Keys, Validate}

  @doc false
  @spec check_map(map()) :: :ok
  def check_map(block) do
    Validate.non_empty_string(:data, Keys.get(block, "data", :data, ""))
    Validate.non_empty_string(:mimeType, Keys.get(block, "mimeType", :mimeType, ""))
    Validate.meta(:_meta, Keys.get(block, "_meta", :_meta, nil))
    Validate.annotations(Keys.get(block, "annotations", :annotations, nil))
  end
end
