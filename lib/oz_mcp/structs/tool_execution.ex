defmodule OzMcp.Structs.ToolExecution do
  @moduledoc """
  Helper module used to build `ToolExecution` structure.

  _(MCP protocol: 2025-11-25)_

  ## Short example:

  ```elixir
  %ToolExecution{}
    |> ToolExecution.task_support(:optional)
    |> ToolExecution.build()
  ```

  Result:

  ```elixir
  %{taskSupport: :optional}
  ```

  Specification: [ToolExecution](https://modelcontextprotocol.io/specification/2025-11-25/schema#toolexecution)
  """

  use OzMcp.Structs.Wire,
    fields: [
      taskSupport: {:any, check: :validate_task_support, emit: :always},
      poll_interval: {:any, check: :validate_poll_interval, emit: :never, setter: false},
      immediate_response: {:any, check: :validate_immediate_response, emit: :never, setter: false}
    ]

  @type task_support() :: :forbidden | :optional | :required | String.t() | nil
  @type poll_interval() :: pos_integer() | nil
  @type immediate_response() :: String.t() | nil

  @doc """
  The preferred interval (ms) between two polls of `tasks/get` for the
  tasks of the tool. The value is never sent to the client: `build/1`
  does not emit it. The task records of the tool carry it as their
  `pollInterval`.
  """
  @spec poll_interval(t(), poll_interval()) :: t()
  def poll_interval(struct, value) do
    validate_poll_interval(value)

    Map.put(struct, :poll_interval, value)
  end

  @doc """
  The text that the client shows to the model while a task of the tool
  runs. The value is never sent to the client in `tools/list`: `build/1`
  does not emit it. The `CreateTaskResult` of a task-augmented call
  carries it as `io.modelcontextprotocol/model-immediate-response` in
  `_meta`.
  """
  @spec immediate_response(t(), immediate_response()) :: t()
  def immediate_response(struct, value) do
    validate_immediate_response(value)

    Map.put(struct, :immediate_response, value)
  end

  defp validate_poll_interval(value) do
    if value != nil and (not is_integer(value) or value < 1) do
      raise ArgumentError,
            "'poll_interval' must be a positive integer (ms) or nil, got: #{inspect(value)}"
    end
  end

  defp validate_immediate_response(value) do
    if value != nil and (not is_binary(value) or value == "") do
      raise ArgumentError,
            "'immediate_response' must be a non-empty string or nil, got: #{inspect(value)}"
    end
  end

  defp validate_task_support(value) do
    if is_nil(value) do
      raise ArgumentError, "All fields are 'nil', remove 'execution' declaration"
    end

    if value not in [
         :forbidden,
         :optional,
         :required,
         "forbidden",
         "optional",
         "required"
       ] do
      raise ArgumentError,
            "'task_support' allow only three values: 'forbidden', 'optional', 'required'"
    end
  end
end
