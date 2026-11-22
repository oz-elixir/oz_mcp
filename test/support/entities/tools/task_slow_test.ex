# Test support tool modules for the MCP Tasks runtime.
#

#
# Blocks until it receives :finish (or a 10s safety timeout). Stores its
# runner pid and its ctx in :persistent_term so tests can coordinate and
# assert the ctx the runner received (principal, task id). Its execution
# declares a poll interval, so the tests can pin the per-tool hint.
#
defmodule Support.Entities.Tools.TaskSlowTest do
  use OzMcp.Config.Tool, dsl?: false

  alias OzMcp.Structs.{CallToolResult, TextContent, Tool, ToolExecution}
  alias Support.Helpers.Utils

  def list do
    list = [
      %Tool{}
      |> Tool.name("task_slow")
      |> Tool.description("Blocks until told to finish")
      |> Tool.execution(
        %ToolExecution{}
        |> ToolExecution.task_support(:optional)
        |> ToolExecution.poll_interval(2_500)
      )
    ]

    list
  end

  def call(ctx, _params) do
    instance = Map.get(ctx, :instance)

    for scope <- [:any, instance] do
      :persistent_term.put({__MODULE__, scope, :pid}, self())
      :persistent_term.put({__MODULE__, scope, :ctx}, ctx)
    end

    receive do
      :finish ->
        result =
          %CallToolResult{}
          |> CallToolResult.content([
            %TextContent{}
            |> TextContent.text("slow done")
          ])
          |> CallToolResult.build()

        {:ok, result}
    after
      10_000 ->
        {:error, OzMcp.Utils.Error.new(-32603, "slow tool safety timeout")}
    end
  end

  # A test that runs at the same time as other tests names the instance that
  # it uses: the functions below then read the runner of that instance only.
  #
  def use_instance(instance) do
    Process.put(:slow_tool_instance, instance)
    :ok
  end

  def reset, do: :persistent_term.put({__MODULE__, scope(), :pid}, nil)

  defp scope, do: Process.get(:slow_tool_instance, :any)

  def finish do
    case :persistent_term.get({__MODULE__, scope(), :pid}, nil) do
      nil -> :ok
      pid -> send(pid, :finish)
    end
  end

  def last_runner_pid, do: :persistent_term.get({__MODULE__, scope(), :pid}, nil)

  # The pid of the runner is one value for the whole test run: the pid of
  # another test can still be there. The wait accepts a new, alive pid only,
  # so a test reads `last_runner_pid/0` before it starts the task and gives
  # that value as `previous`.
  #
  def await_runner(previous) do
    true =
      Utils.eventually(fn ->
        case last_runner_pid() do
          pid when is_pid(pid) and pid != previous -> Process.alive?(pid)
          _other -> false
        end
      end)

    last_runner_pid()
  end

  def last_ctx, do: :persistent_term.get({__MODULE__, scope(), :ctx}, nil)
end
