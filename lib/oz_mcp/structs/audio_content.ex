defmodule OzMcp.Structs.AudioContent do
  @moduledoc """
  Helper module used to build `AudioContent` structure.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %AudioContent{}
    |> AudioContent.data("UklGRiQAAA==")
    |> AudioContent.mime_type("audio/wav")
    |> AudioContent.build()
  ```

  Result:

  ```elixir
  %{data: "UklGRiQAAA==", type: "audio", mimeType: "audio/wav"}
  ```

  Specification: [AudioContent](https://modelcontextprotocol.io/specification/2025-11-25/schema#audiocontent)
  """

  use OzMcp.Structs.Wire,
    const: %{type: "audio"},
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
