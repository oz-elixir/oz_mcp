#
# One process for each client task that the server waits for. It is the
# only sender of `tasks/cancel`: the waiter never waits for the answer
# of the client, so the cancel does not extend the time limit.
#
defmodule OzMcp.Outbound.ClientTask.Guard do
  @moduledoc false

  alias OzMcp.{Instance, Outbound}

  require Logger

  @cancel_timeout 5_000

  @spec start(map(), String.t(), pid()) :: pid() | nil
  def start(ctx, task_id, waiter) do
    with {:ok, supervisor} <- Instance.whereis(ctx.instance, :calls),
         {:ok, pid} <-
           Task.Supervisor.start_child(supervisor, fn -> run(ctx, task_id, waiter) end) do
      pid
    else
      _no_guard -> nil
    end
  end

  # `:done`: the client task is terminal. `:cancel`: the waiter stops
  # waiting for a task that still runs.
  #
  @spec stop(pid() | nil, :done | :cancel) :: :ok
  def stop(nil, _message), do: :ok

  def stop(guard, message) do
    send(guard, {__MODULE__, message})
    :ok
  end

  defp run(ctx, task_id, waiter) do
    ref = Process.monitor(waiter)

    receive do
      {__MODULE__, :done} -> :ok
      {__MODULE__, :cancel} -> cancel(ctx, task_id)
      {:DOWN, ^ref, :process, _pid, _reason} -> cancel(ctx, task_id)
    end
  end

  # The task of the server is gone: try the route of the session.
  #
  defp cancel(ctx, task_id) do
    case send_cancel(ctx, task_id) do
      {:error, :no_task} -> log(send_cancel(%{ctx | task_id: nil}, task_id))
      result -> log(result)
    end
  end

  defp send_cancel(ctx, task_id),
    do: Outbound.request(ctx, "tasks/cancel", %{"taskId" => task_id}, timeout: @cancel_timeout)

  # The result tag only: the log holds no client data.
  #
  defp log({:ok, _result}), do: Logger.debug("client task cancel: ok")
  defp log({:error, {:rpc_error, _error}}), do: Logger.debug("client task cancel: rpc_error")

  defp log({:error, reason}) when is_atom(reason),
    do: Logger.debug("client task cancel: #{reason}")

  defp log({:error, _reason}), do: Logger.debug("client task cancel: error")
end
