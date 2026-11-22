#
# The writer of the snapshot saves and deletes. The session hands a save
# or a delete to this process and goes on, so a slow store never stops
# the calls of the session. One worker at a time runs for one session id,
# under the `:calls` supervisor of the instance; each worker is linked
# to the writer, so a crash of the writer stops its workers. The limits
# of the design for the operator are in the moduledoc of
# `OzMcp.Session.Snapshot`.
#
defmodule OzMcp.Session.Snapshot.Writer do
  @moduledoc false

  use GenServer

  alias OzMcp.Instance
  alias OzMcp.Session.RestoreCache
  alias OzMcp.Session.Snapshot.Guard
  alias OzMcp.Telemetry

  require Logger

  defstruct [
    :instance,
    :module,
    :telemetry,
    pending: %{},
    workers: %{},
    timers: %{}
  ]

  # A save that blocks the delete of its id is stopped after this time.
  #
  @save_ms 3_000

  # A delete that the store does not answer in time is stopped; the
  # limit keeps the old limit of the end of a session.
  #
  @delete_ms 5_000

  # The wait before a job tries the `:calls` supervisor again.
  #
  @retry_ms 100

  def child_spec({name, opts}) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [{name, opts}]}}
  end

  def start_link({name, opts}),
    do: GenServer.start_link(__MODULE__, {name, opts}, name: Instance.via(name, :snapshot_writer))

  @doc false
  @spec save(Instance.t(), String.t(), map()) :: :ok
  def save(instance, id, snapshot),
    do: GenServer.cast(Instance.via(instance, :snapshot_writer), {:save, id, snapshot})

  # The pending save of the id is dropped and a running save ends or is
  # stopped first. An exit of the call hands the delete to a task of the
  # instance instead (`delete_unordered/3`): after `:noproc` no save of
  # the id can race such a delete and the delete may remove the
  # tombstone; any other exit leaves the job in the mailbox of the
  # writer, so the fallback never removes it.
  #
  @doc false
  @spec delete(Instance.t(), String.t()) :: :ok
  def delete(instance, id) do
    GenServer.call(Instance.via(instance, :snapshot_writer), {:delete, id}, 1_000)
  catch
    :exit, {:noproc, _} -> delete_unordered(instance, id, true)
    :exit, _reason -> delete_unordered(instance, id, false)
  end

  # Two deletes of one id (the fallback and the ordered one) give a
  # store that holds no snapshot at the end.
  #
  defp delete_unordered(instance, id, clear?) do
    _ =
      with {:ok, supervisor} <- Instance.whereis(instance, :calls) do
        _ =
          Task.Supervisor.start_child(supervisor, fn -> bounded_delete(instance, id, clear?) end)
      end

    :ok
  end

  defp bounded_delete(instance, id, clear?) do
    _ =
      with {:ok, %{opts: %{session_snapshot: module}}} <- Instance.config(instance) do
        telemetry = Telemetry.handle(instance)
        started = System.monotonic_time()
        task = Task.async(fn -> Guard.call("delete", fn -> module.delete(instance, id) end) end)

        result =
          case Task.yield(task, @delete_ms) do
            {:ok, :ok} ->
              if clear?, do: RestoreCache.clear_deleted(instance, id)

              :ok

            {:ok, _failed} ->
              :error

            {:exit, _reason} ->
              :error

            nil ->
              _ = Task.shutdown(task, :brutal_kill)
              Logger.warning("session snapshot delete stopped: the store did not answer in time")
              :stopped
          end

        write_event(telemetry, started, :delete, result)
      end

    :ok
  end

  @impl true
  def init({name, opts}) do
    #
    # The link ties the life of each worker to the life of the writer:
    # a crash of the writer stops its workers. The trap turns an exit of
    # a worker into a message that this module drops.
    #
    Process.flag(:trap_exit, true)

    # The registry of the instance is the first child: its meta holds the
    # config when this child starts.
    #
    {:ok,
     %__MODULE__{
       instance: name,
       module: Map.fetch!(opts, :session_snapshot),
       telemetry: Telemetry.handle(name)
     }}
  end

  @impl true
  def handle_cast({:save, id, snapshot}, state) do
    #
    # A save of an id whose delete is pending or runs is ignored: a save
    # behind a delete would write the snapshot again.
    #
    state =
      if deleted_job?(state, id), do: state, else: put_in(state.pending[id], {:save, snapshot})

    {:noreply, start_worker(state, id)}
  end

  @impl true
  def handle_call({:delete, id}, _from, state) do
    state = put_in(state.pending[id], :delete)

    state =
      case Map.fetch(state.workers, id) do
        {:ok, %{kind: :save} = worker} -> arm_timer(state, id, worker, @save_ms)
        {:ok, %{kind: :delete}} -> state
        :error -> start_worker(state, id)
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_worker(ref, state)}
  end

  # The worker went down without an answer: the writer goes on.
  #
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, finish_worker(ref, state)}

  # An exit of a linked worker: the `:DOWN` of the monitor frees the id,
  # this message holds nothing new.
  #
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # A write of the id did not end in time: the worker is stopped, a save
  # frees the id for the delete and a delete gives up (the tombstone
  # stays).
  #
  def handle_info({:worker_timeout, id, worker_ref}, state) do
    case Map.get(state.workers, id) do
      %{ref: ^worker_ref, kind: kind, pid: pid, started: started} ->
        write_event(state.telemetry, started, kind, :stopped)
        _ = stop_worker(state.instance, pid)
        Logger.warning("session snapshot #{kind} stopped: the store did not answer in time")
        {:noreply, state}

      _other ->
        #
        # A timer of an earlier write: the worker already ended.
        #
        {:noreply, state}
    end
  end

  # The `:calls` supervisor did not run when the job was ready: the job
  # stayed pending and the writer tries it again.
  #
  def handle_info({:retry_worker, id}, state), do: {:noreply, start_worker(state, id)}

  # The id is free: a newer pending job starts a worker again.
  #
  defp finish_worker(ref, state) do
    case Enum.find(state.workers, fn {_id, worker} -> worker.ref == ref end) do
      {id, _worker} ->
        {timer, timers} = Map.pop(state.timers, id)
        _ = if timer, do: Process.cancel_timer(timer)
        state = %{state | workers: Map.delete(state.workers, id), timers: timers}
        start_worker(state, id)

      nil ->
        state
    end
  end

  defp stop_worker(instance, pid) do
    case Instance.whereis(instance, :calls) do
      {:ok, supervisor} -> _ = terminate_worker(supervisor, pid)
      :not_running -> :ok
    end
  end

  # The supervisor can stop between the lookup and the stop of the
  # worker: the exit of the stop is not a reason to crash.
  #
  defp terminate_worker(supervisor, pid) do
    Task.Supervisor.terminate_child(supervisor, pid)
  catch
    :exit, _reason -> :ok
  end

  # One worker for one id at a time.
  #
  defp start_worker(%{workers: workers} = state, id) when is_map_key(workers, id), do: state

  defp start_worker(state, id) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        state

      {job, pending} ->
        %{instance: instance, module: module, telemetry: telemetry} = state

        case Instance.whereis(instance, :calls) do
          {:ok, supervisor} ->
            #
            # `async/2` links the worker to the writer: the death of the
            # writer stops the worker and a worker that dies sends the
            # exit to this process only.
            #
            started = System.monotonic_time()
            {kind, fun} = job_fun(job, telemetry, module, instance, id, started)

            case async_worker(supervisor, fun) do
              {:ok, task} ->
                workers =
                  Map.put(state.workers, id, %{
                    ref: task.ref,
                    pid: task.pid,
                    started: started,
                    kind: kind
                  })

                # A delete carries its own time limit. A save runs without
                # one: the delete behind a save arms the timer of the save.
                #
                if kind == :delete do
                  timer = Process.send_after(self(), {:worker_timeout, id, task.ref}, @delete_ms)

                  %{
                    state
                    | pending: pending,
                      workers: workers,
                      timers: Map.put(state.timers, id, timer)
                  }
                else
                  %{state | pending: pending, workers: workers}
                end

              :not_running ->
                defer_worker(state, id, job, pending)
            end

          :not_running ->
            defer_worker(state, id, job, pending)
        end
    end
  end

  # The supervisor can stop between the lookup and the start of the
  # worker: the exit of the start is the same as no supervisor.
  #
  defp async_worker(supervisor, fun) do
    {:ok, Task.Supervisor.async(supervisor, fun)}
  catch
    :exit, _reason -> :not_running
  end

  # An instance that does not run drops the job: the write goes with it.
  #
  defp defer_worker(%{instance: instance, telemetry: telemetry} = state, id, job, pending) do
    case Instance.config(instance) do
      {:ok, _config} ->
        _ = Process.send_after(self(), {:retry_worker, id}, @retry_ms)
        %{state | pending: Map.put(pending, id, job)}

      :not_running ->
        write_event(telemetry, nil, job_kind(job), :dropped)
        %{state | pending: pending}
    end
  end

  defp job_kind({:save, _snapshot}), do: :save
  defp job_kind(:delete), do: :delete

  defp deleted_job?(state, id) do
    state.pending[id] == :delete or match?(%{kind: :delete}, state.workers[id])
  end

  # Arms the timer that stops the running save of the id.
  #
  defp arm_timer(state, id, worker, limit_ms) do
    {old, timers} = Map.pop(state.timers, id)
    _ = if old, do: Process.cancel_timer(old)

    timer = Process.send_after(self(), {:worker_timeout, id, worker.ref}, limit_ms)
    %{state | timers: Map.put(timers, id, timer)}
  end

  defp job_fun({:save, snapshot}, telemetry, module, instance, id, started) do
    {:save, fn -> write(telemetry, module, instance, id, snapshot, started) end}
  end

  defp job_fun(:delete, telemetry, module, instance, id, started) do
    {:delete, fn -> run_delete(telemetry, module, instance, id, started) end}
  end

  # The guard turns each failure of the store into `{:error, :failed}`:
  # the event holds the outcome only.
  #
  defp write(telemetry, module, instance, id, snapshot, started) do
    result = Guard.call("save", fn -> module.save(instance, id, snapshot) end)
    write_event(telemetry, started, :save, if(result == :ok, do: :ok, else: :error))
  end

  # The tombstone of the id goes away when the store holds nothing. A
  # delete that failed leaves the tombstone.
  #
  defp run_delete(telemetry, module, instance, id, started) do
    result = Guard.call("delete", fn -> module.delete(instance, id) end)

    if result == :ok, do: RestoreCache.clear_deleted(instance, id)

    write_event(telemetry, started, :delete, if(result == :ok, do: :ok, else: :error))
  end

  # The event of a write. `nil` as the start time gives the duration 0:
  # the write never ran.
  #
  defp write_event(telemetry, nil, action, result) do
    Telemetry.event(telemetry, :snapshot_write, %{duration: 0}, %{
      action: action,
      result: result
    })
  end

  defp write_event(telemetry, started, action, result) do
    Telemetry.event(
      telemetry,
      :snapshot_write,
      %{duration: System.monotonic_time() - started},
      %{
        action: action,
        result: result
      }
    )
  end
end
