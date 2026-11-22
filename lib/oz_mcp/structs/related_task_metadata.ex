defmodule OzMcp.Structs.RelatedTaskMetadata do
  @moduledoc """
  Helper module used to build `RelatedTaskMetadata` structure.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %RelatedTaskMetadata{}
    |> RelatedTaskMetadata.task_id("task-123")
    |> RelatedTaskMetadata.build()
  ```

  Result:

  ```elixir
  %{taskId: "task-123"}
  ```

  Specification: [RelatedTaskMetadata](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/tasks)
  """

  use OzMcp.Structs.Wire,
    fields: [
      taskId: {:string, required: true}
    ]
end
