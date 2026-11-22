defmodule OzMcp.Structs.CreateTaskResult do
  @moduledoc """
  Helper module used to build `CreateTaskResult` structure.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %CreateTaskResult{}
    |> CreateTaskResult.task(
      %Task{}
      |> Task.task_id("task-123")
      |> Task.status(:working)
      |> Task.created_at("2025-01-12T15:00:58Z")
      |> Task.last_updated_at("2025-01-12T15:01:12Z")
      |> Task.ttl(60_000)
    )
    |> CreateTaskResult.build()
  ```

  Result:

  ```elixir
  %{
    task: %{
      status: "working",
      ttl: 60000,
      taskId: "task-123",
      createdAt: "2025-01-12T15:00:58Z",
      lastUpdatedAt: "2025-01-12T15:01:12Z"
    }
  }
  ```

  ## Long example:

  ```elixir
  %CreateTaskResult{}
    |> CreateTaskResult.task(
      %Task{}
      |> Task.task_id("task-123")
      |> Task.status(:working)
      |> Task.created_at("2025-01-12T15:00:58Z")
      |> Task.last_updated_at("2025-01-12T15:01:12Z")
      |> Task.ttl(60_000)
    )
    |> CreateTaskResult._meta(%{"key" => "value"})
    |> CreateTaskResult.extras(%{"queuePosition" => 3, "estimatedWaitMs" => 1500})
    |> CreateTaskResult.build()
  ```

  Result:

  ```elixir
  %{
    :task => %{
      status: "working",
      ttl: 60000,
      taskId: "task-123",
      createdAt: "2025-01-12T15:00:58Z",
      lastUpdatedAt: "2025-01-12T15:01:12Z"
    },
    :_meta => %{"key" => "value"},
    "estimatedWaitMs" => 1500,
    "queuePosition" => 3
  }
  ```

  Specification: [CreateTaskResult](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/tasks)
  """

  use OzMcp.Structs.Wire,
    fields: [
      task: {:task, default: %OzMcp.Structs.Task{}},
      _meta: :meta,
      extras: :extras
    ]
end
