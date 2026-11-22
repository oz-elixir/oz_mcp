defmodule OzMcp.Structs.Task do
  @moduledoc """
  Helper module used to build `Task` structure.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %Task{}
    |> Task.task_id("task-123")
    |> Task.status(:working)
    |> Task.created_at("2025-01-12T15:00:58Z")
    |> Task.last_updated_at("2025-01-12T15:01:12Z")
    |> Task.ttl(60_000)
    |> Task.build()
  ```

  Result:

  ```elixir
  %{
    status: "working",
    ttl: 60000,
    taskId: "task-123",
    createdAt: "2025-01-12T15:00:58Z",
    lastUpdatedAt: "2025-01-12T15:01:12Z"
  }
  ```

  Specification: [Task](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/tasks)
  """

  use OzMcp.Structs.Wire,
    fields: [
      taskId: {:string, required: true},
      status:
        {{:one_of, [:working, :input_required, :completed, :failed, :cancelled]},
         required: true, default: :working, to: :string, type: quote(do: status())},
      statusMessage: :string,
      createdAt: {:string, required: true},
      lastUpdatedAt: {:string, required: true},
      ttl: {:non_neg_integer, emit: :always},
      pollInterval: :non_neg_integer
    ]

  @type status :: :working | :input_required | :completed | :failed | :cancelled
end
