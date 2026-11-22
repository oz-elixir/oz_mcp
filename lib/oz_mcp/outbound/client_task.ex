#
# The flow of a request that the client runs as a task: create, poll
# and read the final result. A guard sends `tasks/cancel` when the flow
# ends with the client task still running.
#
defmodule OzMcp.Outbound.ClientTask do
  @moduledoc false

  alias OzMcp.{Context, Instance, Outbound, Tasks}
  alias OzMcp.Outbound.ClientTask.Guard
  alias OzMcp.Structs.TaskMetadata

  @min_poll 100
  @max_poll 300_000
  @statuses ~w(working input_required completed failed cancelled)

  # A poll that fails with one of these goes on at the next interval.
  #
  @transient [:no_stream, :session_not_initialized]

  @spec run(map(), String.t(), map(), keyword()) :: Outbound.outcome()
  def run(ctx, method, params, opts) do
    timeout = Outbound.timeout(ctx.instance, method, opts)
    deadline = deadline(timeout)
    task_params = Map.put_new_lazy(params, :task, fn -> task_meta(opts, timeout) end)

    with {:ok, created} <- Outbound.request(ctx, method, task_params, opts),
         {:ok, task} <- parse_created(created) do
      task_id = task["taskId"]
      guard = Guard.start(ctx, task_id, self())
      register(ctx, task_id)
      {tag, outcome} = poll(ctx, task, deadline, opts)
      Guard.stop(guard, if(tag == :terminal, do: :done, else: :cancel))
      unregister(ctx, task_id)
      flush_hints(task_id)
      outcome
    end
  end

  # Wakes the waiters of `task_id` for the owner of `ctx`.
  #
  # This is a hint of the client, not a result: the waiter always calls
  # `tasks/get` after it.
  #
  # The waiter registers the client task id under the owner key.
  # `Registry` removes the entry when the process dies.
  #
  @spec hint(Context.t() | Context.ctx(), String.t()) :: :ok
  def hint(ctx, task_id) do
    Registry.dispatch(Instance.topics(ctx.instance), hint_key(ctx, task_id), fn entries ->
      for {pid, _} <- entries, do: send(pid, {:oz_mcp_client_task_hint, task_id})
    end)
  end

  defp register(ctx, task_id) do
    _ = Registry.register(Instance.topics(ctx.instance), hint_key(ctx, task_id), nil)
    :ok
  end

  defp unregister(ctx, task_id) do
    Registry.unregister(Instance.topics(ctx.instance), hint_key(ctx, task_id))
  end

  defp hint_key(ctx, task_id), do: {:client_task, Tasks.owner_key(ctx), task_id}

  defp flush_hints(task_id) do
    receive do
      {:oz_mcp_client_task_hint, ^task_id} -> flush_hints(task_id)
    after
      0 -> :ok
    end
  end

  defp poll(ctx, %{"status" => status} = task, deadline, opts)
       when status in ["completed", "failed"] do
    case read_result(ctx, task, deadline) do
      {:error, reason} when reason in @transient -> next(ctx, task, deadline, opts)
      outcome -> {:terminal, outcome}
    end
  end

  defp poll(_ctx, %{"status" => "cancelled", "taskId" => id}, _deadline, _opts),
    do: {:terminal, {:error, {:client_task_cancelled, id}}}

  # `tasks/result` blocks until a terminal status.
  #
  defp poll(ctx, %{"status" => "input_required"} = task, deadline, opts) do
    case read_result(ctx, task, deadline) do
      {:ok, _result} = outcome ->
        {:terminal, outcome}

      {:error, {:rpc_error, _}} = outcome ->
        {:terminal, outcome}

      {:error, reason} when reason == :timeout or reason in @transient ->
        next(ctx, task, deadline, opts)

      {:error, _reason} = outcome ->
        {:open, outcome}
    end
  end

  defp poll(ctx, task, deadline, opts), do: next(ctx, task, deadline, opts)

  defp next(ctx, task, deadline, opts) do
    wait(task, max(min(interval(ctx, task, opts), remaining(deadline)), 0))

    with left when left > 0 <- remaining(deadline),
         {:ok, answer} <- get(ctx, task, left),
         {:ok, fresh} <- parse_task(answer) do
      poll(ctx, Map.merge(task, fresh), deadline, opts)
    else
      {:error, reason} when reason in @transient -> next(ctx, task, deadline, opts)
      {:error, _reason} = outcome -> {:open, outcome}
      _no_time_left -> {:open, {:error, :timeout}}
    end
  end

  defp read_result(ctx, %{"taskId" => id}, deadline) do
    case remaining(deadline) do
      left when left > 0 ->
        Outbound.request(ctx, "tasks/result", %{"taskId" => id}, timeout: inner(ctx, left))

      _none ->
        {:error, :timeout}
    end
  end

  defp get(ctx, %{"taskId" => id}, left),
    do: Outbound.request(ctx, "tasks/get", %{"taskId" => id}, timeout: inner(ctx, left))

  defp parse_created(%{"task" => task}), do: parse_task(task)
  defp parse_created(result), do: {:error, {:invalid_response, result}}

  defp parse_task(%{"taskId" => id, "status" => status} = task)
       when is_binary(id) and id != "" and status in @statuses,
       do: {:ok, task}

  defp parse_task(result), do: {:error, {:invalid_response, result}}

  defp task_meta(opts, timeout) do
    ttl =
      case Keyword.get(opts, :ttl) do
        nil -> if is_integer(timeout), do: timeout
        ttl -> ttl
      end

    %TaskMetadata{}
    |> TaskMetadata.ttl(ttl)
    |> TaskMetadata.build()
  end

  defp interval(ctx, task, opts) do
    value =
      case task["pollInterval"] do
        ms when is_integer(ms) and ms > 0 -> ms
        _ -> call_interval(ctx, opts)
      end

    value |> max(@min_poll) |> min(@max_poll)
  end

  defp call_interval(ctx, opts) do
    case Keyword.get(opts, :poll_interval) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> Instance.opts(ctx.instance).client_task_poll_interval_ms
    end
  end

  defp inner(ctx, left), do: min(left, Instance.opts(ctx.instance).client_request_timeout_ms)

  defp deadline(:infinity), do: :infinity
  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: deadline - System.monotonic_time(:millisecond)

  defp wait(%{"taskId" => task_id}, ms) do
    receive do
      {:oz_mcp_client_task_hint, ^task_id} -> :ok
    after
      ms -> :ok
    end
  end
end
