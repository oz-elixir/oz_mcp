#
# Probes of the state of a session for the tests of the framework. A
# read of the view goes through the Registry. A read or a write of the
# event log goes through `:sys.get_state/1` and `:sys.replace_state/2`:
# both are messages in the mailbox of the session, so they run after
# every cast that the test sent before.
#
defmodule Support.Helpers.SessionProbe do
  alias OzMcp.Instance
  alias OzMcp.PostStream
  alias OzMcp.Session.{EventLog, View}
  alias OzMcp.Tasks
  alias OzMcp.Tasks.EtsStore
  alias Support.Helpers.{EventLogProbe, TaskScan}

  # The state name and the plain map of the state of a session process.
  #
  # The map has every field of the state, so a test reads a session field
  # through this function and not through `:sys.get_state/1`.
  #
  @spec core(pid()) :: {atom(), map()}
  def core(pid) do
    {state, data} = :sys.get_state(pid)

    core =
      data.core
      |> Map.from_struct()
      |> Map.put(:refs, data.refs)

    {state, core}
  end

  # Changes the state of a session process with `fun`, which takes and
  # returns the plain map of `core/1`.
  #
  @spec update_core(pid(), (map() -> map())) :: term()
  def update_core(pid, fun) do
    :sys.replace_state(pid, fn {state, data} ->
      core =
        data.core
        |> Map.from_struct()
        |> Map.put(:refs, data.refs)
        |> fun.()

      {refs, core} = Map.pop(core, :refs)
      {state, %{data | core: struct!(OzMcp.Session.Core, core), refs: refs}}
    end)
  end

  # The `View` of a session, or `:error`.
  #
  @spec view(Instance.t(), String.t()) :: {:ok, View.t()} | :error
  def view(instance, id) do
    case Registry.lookup(Instance.names(instance), {:session, id}) do
      [{_pid, %View{} = view}] -> {:ok, view}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  # True when the session exists and the client sent
  # `notifications/initialized`, else `{:error, :no_session}`.
  #
  @spec initialized?(Instance.t(), String.t()) :: boolean() | {:error, :no_session}
  def initialized?(instance, id) do
    case view(instance, id) do
      {:ok, %View{initialized: flag}} -> flag
      :error -> {:error, :no_session}
    end
  end

  # The events of every stream after `last_id`, in the order of the writes.
  # An id that is not in the log gives the whole log.
  #
  @spec events_after(Instance.t(), String.t(), String.t() | nil) ::
          {:ok, [EventLog.event()]} | {:error, :no_session}
  def events_after(instance, id, last_id) do
    with {:ok, pid} <- pid(instance, id) do
      case read_core(pid) do
        {:ok, {_state, core}} -> {:ok, after_id(EventLogProbe.all(core.log), last_id)}
        :error -> {:error, :no_session}
      end
    end
  end

  # Appends an event to the log of a stream, as the session does on a cast.
  #
  @spec append_event(Instance.t(), String.t(), EventLog.stream(), EventLog.event()) ::
          :ok | {:error, :no_session}
  def append_event(instance, id, stream_id, event) do
    with {:ok, pid} <- pid(instance, id) do
      replace_log(pid, &EventLog.append(&1, stream_id, event))
    end
  end

  # Appends an event to the log, under the stream that `event_id` names.
  # An id that names no stream is refused.
  #
  @spec log_event(Instance.t(), String.t(), String.t(), binary()) ::
          :ok | {:error, :invalid} | {:error, :no_session}
  def log_event(instance, id, event_id, encoded) do
    case PostStream.parse_event_id(event_id) do
      {stream_id, _n} -> append_event(instance, id, stream_id, {event_id, encoded})
      :invalid -> {:error, :invalid}
    end
  end

  # The ids of the requests to the client of a session that wait for an answer.
  #
  @spec pending_outbound_ids(Instance.t(), String.t()) :: [String.t()] | {:error, :no_session}
  def pending_outbound_ids(instance, id) do
    with {:ok, pid} <- pid(instance, id) do
      case read_core(pid) do
        {:ok, {_state, core}} -> Map.keys(core.outbound)
        :error -> {:error, :no_session}
      end
    end
  end

  # Ends the tasks of a session: the call returns when each task process
  # of the session has ended.
  #
  @spec terminate_tasks(Instance.t(), String.t(), Enumerable.t()) :: :ok | {:error, :unavailable}
  def terminate_tasks(instance, session_id, task_ids \\ []) do
    case task_pids(instance, session_id, task_ids) do
      {:ok, pids} ->
        refs = Enum.map(pids, &Process.monitor/1)

        case Tasks.terminate_session_async(instance, session_id, task_ids) do
          :ok ->
            Enum.each(refs, &await_down/1)

          error ->
            Enum.each(refs, &Process.demonitor(&1, [:flush]))
            error
        end

      error ->
        error
    end
  end

  defp pid(instance, id) do
    case Registry.lookup(Instance.names(instance), {:session, id}) do
      [{pid, _value}] -> {:ok, pid}
      _ -> {:error, :no_session}
    end
  rescue
    ArgumentError -> {:error, :no_session}
  end

  defp replace_log(pid, fun) do
    update_core(pid, fn core -> %{core | log: fun.(core.log)} end)
    :ok
  catch
    :exit, _reason -> {:error, :no_session}
  end

  # The session can die between the Registry lookup and the system
  # message: the exit of the sys call is then the same outcome as an
  # empty lookup and the probe gives `{:error, :no_session}` instead of
  # a crash of the test.
  #
  @spec read_core(pid()) :: {:ok, {atom(), map()}} | :error
  defp read_core(pid) do
    {:ok, core(pid)}
  catch
    :exit, _reason -> :error
  end

  # The events after `last_id`: the entries after the first one that
  # matches, or the whole log when no entry matches.
  #
  defp after_id(events, last_id) do
    case Enum.split_while(events, fn {id, _data} -> id != last_id end) do
      {_before, [_match | later]} -> later
      {all, []} -> all
    end
  end

  # The pids of the tasks that the end of a session stops: the records
  # that the session owns and the records of `task_ids` of this session,
  # each one once, only the records that hold a live pid.
  #
  defp task_pids(instance, session_id, task_ids) do
    owned = TaskScan.all_by_owner(instance, {:session, session_id})

    tracked =
      Enum.flat_map(task_ids, fn task_id ->
        case EtsStore.get(instance, task_id) do
          {:ok, %{session_id: ^session_id, pid: pid} = record} when is_pid(pid) -> [record]
          _other -> []
        end
      end)

    pids =
      (owned ++ tracked)
      |> Enum.uniq_by(& &1.task_id)
      |> Enum.flat_map(fn
        %{session_id: ^session_id, pid: pid} when is_pid(pid) -> [pid]
        _record -> []
      end)

    {:ok, pids}
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  # The same bound as the end of a session in the library. A task
  # process that does not end is a failure of the test: the raise names
  # this probe, not the timeout of the test runner.
  #
  @down_timeout 5_000

  defp await_down(ref) do
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    after
      @down_timeout ->
        Process.demonitor(ref, [:flush])
        raise "SessionProbe.terminate_tasks/3: a task process did not end in #{@down_timeout} ms"
    end
  end
end
