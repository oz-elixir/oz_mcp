#
# Deletes the expired terminal records and marks the record of a lost
# task process `failed`. At start the reaper lists the active records
# of the store: each record whose process is dead gets its `failed`
# record and each live process gets a monitor again (a store without
# `active/1` skips this step). After the start the reaper reads only
# the head of the expiry index.
#
defmodule OzMcp.Tasks.Reaper do
  @moduledoc false

  use GenServer

  alias OzMcp.Instance
  alias OzMcp.Notify
  alias OzMcp.Tasks
  alias OzMcp.Tasks.Notifier
  alias OzMcp.Tasks.Records
  alias OzMcp.Telemetry

  require Logger

  @batch 100
  @retry_ms 1_000
  @max_backoff_ms 30_000
  @reconcile_timeout 1_000
  @down_wait_ms 500

  def start_link(%{name: instance} = config),
    do: GenServer.start_link(__MODULE__, config, name: Instance.via(instance, :tasks_reaper))

  def child_spec(%{name: instance} = config) do
    %{id: {__MODULE__, instance}, start: {__MODULE__, :start_link, [config]}}
  end

  # Monitors a task process. An abnormal exit marks its record `failed`.
  #
  def watch(instance, pid, task_id),
    do: GenServer.cast(Instance.via(instance, :tasks_reaper), {:watch, pid, task_id})

  # Tells the reaper that the head of the expiry index can have changed.
  #
  def rearm(instance), do: GenServer.cast(Instance.via(instance, :tasks_reaper), :rearm)

  # Asks the reaper to look at one task: a record whose process is gone
  # gets its `failed` record before the answer. The caller reads the
  # record again either way. An `:error` says that the reaper could not
  # answer (a restart, a store that waits).
  #
  @spec reconcile(atom(), String.t()) :: :ok | :error
  def reconcile(instance, task_id) do
    GenServer.call(
      Instance.via(instance, :tasks_reaper),
      {:reconcile, task_id},
      @reconcile_timeout
    )
  catch
    :exit, _reason -> :error
  end

  @impl true
  def init(%{name: instance} = config) do
    state = %{
      instance: instance,
      store: config.opts.task_store,
      telemetry: config.telemetry,
      monitors: %{},
      watched: %{},
      timer: nil,
      backoff: nil
    }

    {:ok, state, {:continue, :sweep}}
  end

  @impl true
  def handle_continue(:sweep, state), do: {:noreply, state |> sweep() |> arm()}

  @impl true
  def handle_cast({:watch, pid, task_id}, state), do: {:noreply, track(state, pid, task_id)}

  def handle_cast(:rearm, state), do: {:noreply, arm(state)}

  @impl true
  def handle_call({:reconcile, task_id}, _from, state) do
    state =
      guarded(
        state,
        {:reconcile, task_id},
        fn ->
          case Records.get(state.store, state.instance, task_id) do
            {:ok, %{status: status} = record} when status in [:working, :input_required] ->
              if Tasks.pid_state(record.pid) == :dead,
                do: reconcile_dead(state, task_id),
                else: state

            {:ok, _terminal} ->
              state

            :not_found ->
              state

            # The caller reads the record again and answers
            # `{:error, :unavailable}`: the reply stays `:ok`.
            #
            _unknown ->
              failure(state, {:reconcile, task_id}, :error)
          end
        end,
        fn state -> state end
      )

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:reap, state) do
    state = %{state | timer: nil}

    state =
      guarded(
        state,
        :reap,
        fn ->
          expired = Records.expired(state.store, state.instance, now_ms(), @batch)

          case delete_all(state, expired) do
            :ok -> arm(%{state | backoff: nil})
            :error -> raise "store delete failed"
          end
        end,
        fn state -> %{state | timer: Process.send_after(self(), :reap, delay(state))} end
      )

    {:noreply, state}
  end

  def handle_info(:retry_sweep, state), do: {:noreply, sweep(state)}

  def handle_info({:retry_lost, task_id, reason}, state),
    do: {:noreply, fail_lost(state, task_id, reason)}

  def handle_info({:DOWN, ref, :process, _pid, reason}, state),
    do: {:noreply, down(state, ref, reason)}

  def handle_info(_message, state), do: {:noreply, state}

  # A store call can fail: the tables are not there while the owner
  # restarts, or the store itself is broken. The reaper survives both:
  # each step runs through `guarded/4` and retries with a backoff.
  #
  defp guarded(state, step, fun, on_error) do
    fun.()
  rescue
    exception -> on_error.(failure(state, step, exception.__struct__))
  catch
    kind, _reason -> on_error.(failure(state, step, kind))
  end

  # The message of the exception, the reason of the exit and the record
  # never go to the log: a store can put client data in them.
  #
  defp failure(state, step, what) do
    state = %{state | backoff: next_backoff(state.backoff)}

    Logger.warning(
      "task reaper: store failure in #{inspect(step)} (#{inspect(what)}), " <>
        "retry in #{delay(state)} ms"
    )

    state
  end

  defp next_backoff(nil), do: @retry_ms
  defp next_backoff(ms), do: min(ms * 2, @max_backoff_ms)

  defp delay(%{backoff: nil}), do: @retry_ms
  defp delay(%{backoff: ms}), do: ms

  defp now_ms, do: System.system_time(:millisecond)

  defp arm(state) do
    guarded(
      state,
      :arm,
      fn ->
        _ = if state.timer, do: Process.cancel_timer(state.timer)

        case Records.next_expiry(state.store, state.instance) do
          nil ->
            %{state | timer: nil}

          at ->
            %{state | timer: Process.send_after(self(), :reap, max(at - now_ms(), 0))}
        end
      end,
      fn state -> %{state | timer: Process.send_after(self(), :reap, delay(state))} end
    )
  end

  # The sweep at start: each active record gets a monitor again, or its
  # `failed` record when its process is gone. A record of another node
  # stays alone; so does a record with a watched task id.
  #
  defp sweep(state) do
    if Code.ensure_loaded?(state.store) and function_exported?(state.store, :active, 1) do
      guarded(
        state,
        :sweep,
        fn ->
          state = Enum.reduce(state.store.active(state.instance), state, &sweep_record/2)

          # A sweep that finds no lost task resets the backoff of an
          # earlier failure of another step.
          #
          %{state | backoff: nil}
        end,
        fn state ->
          Process.send_after(self(), :retry_sweep, delay(state))
          state
        end
      )
    else
      Logger.info("task store has no active/1: the reaper cannot recover records at start")
      state
    end
  end

  # A record whose task id the reaper watches stays alone in a sweep: a
  # `fail_lost/3` here would write the message of a lost task over the
  # true reason of the end.
  #
  defp sweep_record(%{task_id: task_id}, %{watched: watched} = state)
       when is_map_key(watched, task_id),
       do: state

  defp sweep_record(%{pid: pid, task_id: task_id}, state) do
    case Tasks.pid_state(pid) do
      :alive -> track(state, pid, task_id)
      :dead -> fail_lost(state, task_id, :lost)
      :remote -> state
    end
  end

  # The end of a watched process: every end reason but `:normal` goes to
  # `fail_lost/3`, which skips a terminal record.
  #
  defp down(state, ref, reason) do
    {task_id, monitors} = Map.pop(state.monitors, ref)
    {_ref, watched} = Map.pop(state.watched, task_id)
    state = %{state | monitors: monitors, watched: watched}

    if task_id && reason != :normal,
      do: fail_lost(state, task_id, reason),
      else: state
  end

  # A cast of `watch/3` that arrives after the sweep saw the record adds
  # no second monitor.
  #
  defp track(%{watched: watched} = state, _pid, task_id) when is_map_key(watched, task_id),
    do: state

  defp track(state, pid, task_id) do
    ref = Process.monitor(pid)

    %{
      state
      | monitors: Map.put(state.monitors, ref, task_id),
        watched: Map.put(state.watched, task_id, ref)
    }
  end

  # The process is dead and the reaper watches it: its `:DOWN` waits in
  # the mailbox or comes soon, with the real end reason. The `:DOWN` of
  # the ref is taken here.
  #
  defp reconcile_dead(%{watched: watched} = state, task_id) when is_map_key(watched, task_id) do
    ref = Map.fetch!(watched, task_id)

    receive do
      {:DOWN, ^ref, :process, _pid, reason} -> down(state, ref, reason)
    after
      @down_wait_ms -> fail_lost(state, task_id, :lost)
    end
  end

  defp reconcile_dead(state, task_id), do: fail_lost(state, task_id, :lost)

  # Only a terminal record or `:not_found` stops the retry: an unknown
  # answer of `get/2` is a store failure like a raise.
  #
  defp fail_lost(state, task_id, reason) do
    guarded(
      state,
      {:fail_lost, task_id},
      fn ->
        case Records.get(state.store, state.instance, task_id) do
          {:ok, %{status: status} = record} when status in [:working, :input_required] ->
            write_lost(state, record, task_id, reason)

          {:ok, _terminal} ->
            state

          :not_found ->
            state

          _unknown ->
            state
            |> failure({:fail_lost, task_id}, :error)
            |> retry_lost(task_id, reason)
        end
      end,
      fn state -> retry_lost(state, task_id, reason) end
    )
  end

  # A kill of the task process is the only end where the process itself
  # emits no `:stop` event. For a kill the reaper emits the event from
  # the record: it has no span token, so the duration comes from the
  # creation time of the record.
  #
  defp write_lost(state, record, task_id, reason) do
    record = Tasks.failed_record(record, Tasks.lost_message(reason))

    case Records.put(state.store, state.instance, record) do
      :ok ->
        if reason == :killed do
          Telemetry.stop_untracked(state.telemetry, :task, lost_duration(record), %{
            status: :failed
          })
        end

        # The reaper has no streams: the message goes to the topic of the
        # principal, or to the session of the task.
        #
        Notifier.deliver(
          state.instance,
          record,
          [],
          Notify.task_status_message(Tasks.to_task(record))
        )

        arm(%{state | backoff: nil})

      _other ->
        state = failure(state, {:fail_lost, task_id}, :error)
        retry_lost(state, task_id, reason)
    end
  end

  # The retry of `fail_lost/3` stops by itself when the record became
  # terminal or went away in the meantime: the case of `fail_lost/3`
  # matches none of these answers.
  #
  defp retry_lost(state, task_id, reason) do
    Process.send_after(self(), {:retry_lost, task_id, reason}, delay(state))
    state
  end

  defp delete_all(state, records) do
    Enum.reduce_while(records, :ok, fn record, :ok ->
      case Records.delete(state.store, state.instance, record) do
        :ok -> {:cont, :ok}
        _other -> {:halt, :error}
      end
    end)
  end

  defp lost_duration(record) do
    DateTime.utc_now()
    |> DateTime.diff(record.created_at, :microsecond)
    |> max(0)
    |> System.convert_time_unit(:microsecond, :native)
  end
end
