defmodule OzMcp.Structs.TaskMetadata do
  @moduledoc """
  Helper module used to build `TaskMetadata` structure.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %TaskMetadata{}
    |> TaskMetadata.ttl(60_000)
    |> TaskMetadata.build()
  ```

  Result:

  ```elixir
  %{ttl: 60000}
  ```

  Specification: [TaskMetadata](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/tasks)
  """

  use OzMcp.Structs.Wire,
    fields: [
      ttl: :non_neg_integer
    ]
end
