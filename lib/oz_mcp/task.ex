#
# The process of one task: a `gen_statem` with `:working` and
# `:input_required`. A terminal status stops the process and only the
# record stays. The rules that a user can see are in the tasks guide.
#
defmodule OzMcp.Task do
  @moduledoc false

  @behaviour :gen_statem

  alias OzMcp.Handler.Invoke
  alias OzMcp.Handler.Output
  alias OzMcp.Instance
  alias OzMcp.Notify
  alias OzMcp.Outbound
  alias OzMcp.ProgressRule
  alias OzMcp.Session
  alias OzMcp.Sessions
  alias OzMcp.Tasks
  alias OzMcp.Tasks.Notifier
  alias OzMcp.Tasks.Reaper
  alias OzMcp.Tasks.Records
  alias OzMcp.Tasks.RelatedTask
  alias OzMcp.Telemetry
  alias OzMcp.Utils.Error
  alias OzMcp.Utils.JsonRpc
  alias OzMcp.Wire

  require Logger

  defstruct [
    :instance,
    :record,
    :runner,
    :runner_ref,
    :store,
    :opts,
    :telemetry,
    :span,
    waiters: [],
    held: %{},
    waiter_refs: %{},
    streams: [],
    seq: 0,
    last_progress: nil
  ]

  @runner_start_message "The task runner cannot start."

  # The code of a cancelled request: -32800, as `notifications/cancelled`.
  #
  @cancelled_code -32_800

  # A poll is neutral only while an attached stream can carry it.
  #
  @neutral ~w(ping tasks/cancel)
  @polls ~w(tasks/get tasks/result)

  def child_spec({_instance, record, _runner} = arg) do
    %{
      id: {__MODULE__, record.task_id},
      start: {__MODULE__, :start_link, [arg]},
      restart: :temporary
    }
  end

  def start_link({instance, record, _runner} = arg) do
    :gen_statem.start_link(Instance.via(instance, {:task, record.task_id}), __MODULE__, arg, [])
  end

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init({instance, record, runner}) do
    #
    # The runner links itself here. The trap keeps an abnormal end of the
    # runner from killing the task: the `:DOWN` gives the reason.
    #
    Process.flag(:trap_exit, true)

    {:ok, config} = Instance.config(instance)
    store = config.opts.task_store
    record = %{record | pid: self()}
    :ok = Records.put(store, instance, record)
    Reaper.watch(instance, self(), record.task_id)

    span = Telemetry.start(config.telemetry, :task)

    data = %__MODULE__{
      instance: instance,
      record: record,
      store: store,
      opts: config.opts,
      telemetry: config.telemetry,
      span: span
    }

    track(data)

    case start_runner(instance, runner) do
      {:ok, pid} ->
        record = %{record | runner_pid: pid}
        :ok = Records.put(store, instance, record)
        data = %{data | record: record, runner: pid, runner_ref: Process.monitor(pid)}
        {:ok, :working, data, ttl_timer(record)}

      {:error, _reason} ->
        #
        # The runner did not start: the record is terminal in the store.
        # `terminate/3` does not run after `:ignore`, so this ends the span.
        #
        record = %{Tasks.failed_record(record, @runner_start_message) | result: crash_outcome()}
        :ok = Records.put(store, instance, record)
        if record.expires_at_ms, do: Reaper.rearm(instance)
        untrack(data)
        Telemetry.stop(span, %{status: :failed})
        :ignore
    end
  end

  # The task ends the wait itself, so no entry stays after it.
  #
  @impl true
  def handle_event({:call, {caller, _tag} = from}, {:await, timeout}, _state, data) do
    ref = Process.monitor(caller)
    data = %{data | waiters: [{from, ref} | data.waiters]}

    case timeout do
      :infinity -> {:keep_state, data}
      ms -> {:keep_state, data, [{{:timeout, {:await, ref}}, ms, :expired}]}
    end
  end

  def handle_event({:timeout, {:await, ref}}, :expired, _state, data) do
    case List.keytake(data.waiters, ref, 1) do
      {{from, ^ref}, waiters} ->
        Process.demonitor(ref, [:flush])
        {:keep_state, %{data | waiters: waiters}, [{:reply, from, {:error, :timeout}}]}

      nil ->
        :keep_state_and_data
    end
  end

  def handle_event({:call, from}, :cancel, _state, data) do
    data = drop_held(data, "task was cancelled", :no_task)

    finish(data, :cancelled, "The task was cancelled by request.", cancel_outcome(), from)
  end

  def handle_event(:info, {:runner_finished, outcome}, _state, data) do
    {status, message, result} = classify(outcome)
    finish(data, status, message, result, nil)
  end

  def handle_event(:info, {:DOWN, ref, :process, _pid, reason}, _state, %{runner_ref: ref} = data) do
    #
    # The reason can hold an exception: it goes to the log only.
    #
    Logger.error("task #{data.record.task_id} runner crashed: " <> reason_text(reason))

    data = drop_held(%{data | runner: nil, runner_ref: nil}, "the request ended", :no_task)
    finish(data, :failed, Tasks.runner_crash_message(), crash_outcome(), nil)
  end

  def handle_event(:info, {:EXIT, _pid, _reason}, _state, _data), do: :keep_state_and_data

  def handle_event(
        :info,
        {:DOWN, ref, :process, _pid, _reason},
        state,
        %{waiter_refs: refs} = data
      )
      when is_map_key(refs, ref) do
    {out_id, refs} = Map.pop!(refs, ref)
    entry = Map.fetch!(data.held, out_id)
    push_cancelled(data, out_id, entry, "the request ended")

    data = %{data | held: Map.delete(data.held, out_id), waiter_refs: refs}
    next_status(state, data, "the request ended")
  end

  def handle_event(:info, {:DOWN, ref, :process, _pid, _reason}, state, data) do
    case List.keytake(data.waiters, ref, 1) do
      {{_from, ^ref}, waiters} ->
        {:keep_state, %{data | waiters: waiters}, [{{:timeout, {:await, ref}}, :cancel}]}

      nil ->
        data = stream_lost(%{data | streams: Enum.reject(data.streams, &(&1.ref == ref))})
        next_status(state, data, "the stream of a poll ended")
    end
  end

  def handle_event({:call, from}, {:attach, pid, stream_id, origin}, _state, data) do
    stream = new_stream(pid, stream_id, origin)

    for entry <- Enum.sort_by(Map.values(data.held), & &1.seq),
        held_goes_to?(stream, entry) do
      _ = emit_stream(data, stream, entry.data)
    end

    {:keep_state, %{data | streams: [stream | data.streams]}, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, {:detach, pid}, state, data) do
    {gone, streams} = Enum.split_with(data.streams, &(&1.pid == pid))
    Enum.each(gone, &Process.demonitor(&1.ref, [:flush]))

    state
    |> next_status(stream_lost(%{data | streams: streams}), "the stream of a poll ended")
    |> with_reply(from, :ok)
  end

  def handle_event(:cast, {:answer, out_id, outcome}, state, data) do
    case Map.pop(data.held, out_id) do
      {nil, _held} ->
        :keep_state_and_data

      {entry, held} ->
        if entry.waiter_ref, do: Process.demonitor(entry.waiter_ref, [:flush])
        send(entry.waiter, {Outbound.answer_tag(), out_id, outcome})

        data = %{data | held: held, waiter_refs: Map.delete(data.waiter_refs, entry.waiter_ref)}
        next_status(state, data, "the client answered")
    end
  end

  # The task makes the id of the request, holds it and monitors the waiter.
  #
  def handle_event({:call, from}, {:request, waiter, method, params}, state, data)
      when is_pid(waiter) and is_binary(method) do
    seq = data.seq + 1
    out_id = "t." <> data.record.task_id <> "." <> Integer.to_string(seq)

    case Wire.encode_message(JsonRpc.request(out_id, method, params)) do
      {:ok, encoded} ->
        ref = if waiter == data.runner, do: nil, else: Process.monitor(waiter)

        entry = %{
          seq: seq,
          method: method,
          params: params,
          data: encoded,
          waiter: waiter,
          waiter_ref: ref
        }

        entry = Map.put(entry, :neutral?, neutral?(data.streams, entry))

        data = %{
          data
          | held: Map.put(data.held, out_id, entry),
            seq: seq,
            waiter_refs:
              if(ref, do: Map.put(data.waiter_refs, ref, out_id), else: data.waiter_refs)
        }

        push_request(data, entry)

        state
        |> next_status(data, "waiting for the client: #{method}")
        |> with_reply(from, {:ok, out_id})

      {:error, :not_encodable} = error ->
        {:keep_state_and_data, [{:reply, from, error}]}
    end
  end

  def handle_event({:call, from}, {:cancel_request, out_id}, state, data) do
    case Map.pop(data.held, out_id) do
      {nil, _held} ->
        {:keep_state_and_data, [{:reply, from, :ok}]}

      {entry, held} ->
        if entry.waiter_ref, do: Process.demonitor(entry.waiter_ref, [:flush])

        data = %{data | held: held, waiter_refs: Map.delete(data.waiter_refs, entry.waiter_ref)}
        push_cancelled(data, out_id, entry, "the request ended")

        state
        |> next_status(data, "the request ended")
        |> with_reply(from, :ok)
    end
  end

  def handle_event(:internal, {:finish, status, message, result}, _state, data),
    do: finish(data, status, message, result, nil)

  # The end of the session: each waiter gets the end of the session.
  #
  def handle_event(:cast, :drop, _state, data) do
    data = drop_held(data, "the session ended", :session_terminated)
    remove(data, :session_terminated)
  end

  def handle_event(:cast, :expire, _state, data), do: expire(data)

  def handle_event({:timeout, :ttl}, :expire, _state, data), do: expire(data)

  def handle_event(:cast, {:notify, rpc_notification, filter}, _state, data) do
    Notifier.deliver(data.instance, data.record, data.streams, rpc_notification, filter)
    :keep_state_and_data
  end

  def handle_event(:cast, {:progress, progress, total, message}, _state, data) do
    record = data.record

    with token when not is_nil(token) <- record.progress_token,
         {:ok, last} <- ProgressRule.check(data.last_progress, progress) do
      Notifier.deliver(
        data.instance,
        record,
        data.streams,
        Notify.task_progress_message(token, progress, total, message, record.task_id)
      )

      {:keep_state, %{data | last_progress: last}}
    else
      :drop ->
        Logger.debug("a task progress value that does not increase was dropped")
        :keep_state_and_data

      _no_token ->
        :keep_state_and_data
    end
  end

  def handle_event(:cast, {:status_message, message}, _state, data) do
    record = %{data.record | status_message: message}
    :ok = Records.put(data.store, data.instance, record)
    {:keep_state, %{data | record: record}}
  end

  # A call that no clause takes is a defect of the caller: an error at once.
  #
  def handle_event({:call, from}, message, state, _data) do
    Logger.warning("task call #{inspect(call_tag(message))} has no clause in #{inspect(state)}")
    {:keep_state_and_data, [{:reply, from, {:error, :badarg}}]}
  end

  def handle_event(_type, _event, _state, _data), do: :keep_state_and_data

  # Only the tag is logged: the rest can hold client data.
  #
  defp call_tag(message) when is_atom(message), do: message

  defp call_tag(message)
       when is_tuple(message) and tuple_size(message) > 0 and is_atom(elem(message, 0)),
       do: elem(message, 0)

  defp call_tag(_message), do: :unknown

  @impl true
  def terminate(reason, _state, data) do
    Telemetry.stop(data.span, %{status: end_status(reason)})
    if shutdown?(reason), do: write_stopped(data, reason)
    stop_runner(data)
  end

  defp end_status(:shutdown), do: :shutdown
  defp end_status({:shutdown, _}), do: :shutdown
  defp end_status(_crash), do: :failed

  defp shutdown?(:shutdown), do: true
  defp shutdown?({:shutdown, _}), do: true
  defp shutdown?(_other), do: false

  # A stop leaves a `failed` record, so no record stays active with a dead
  # pid. When the first write fails, the reaper writes the record.
  #
  defp write_stopped(%{record: %{status: status}} = data, reason)
       when status in [:working, :input_required] do
    data = safely(data, fn -> drop_held(data, "the task ended", :no_task) end)
    record = Tasks.failed_record(data.record, Tasks.lost_message(reason))

    if safely(:error, fn -> Records.put(data.store, data.instance, record) end) == :ok do
      _ =
        if record.expires_at_ms,
          do: safely(:ok, fn -> Reaper.rearm(data.instance) end)

      _ = safely(:ok, fn -> untrack(data) end)

      _ =
        safely(:ok, fn ->
          Notifier.deliver(
            data.instance,
            record,
            data.streams,
            Notify.task_status_message(Tasks.to_task(record))
          )
        end)

      # The order of `finish/5`: the status notification, then each stream.
      #
      _ = safely(:ok, fn -> notify_streams(data, {:ok, record.result}) end)

      Enum.each(data.waiters, fn {from, ref} ->
        safely(:ok, fn ->
          Process.demonitor(ref, [:flush])
          :gen_statem.reply(from, {:ok, record.result})
        end)
      end)
    end

    :ok
  end

  defp write_stopped(_data, _reason), do: :ok

  defp safely(fallback, fun) do
    fun.()
  rescue
    _exception -> fallback
  catch
    _kind, _reason -> fallback
  end

  defp new_stream(pid, stream_id, origin) do
    %{
      pid: pid,
      stream_id: stream_id,
      ref: Process.monitor(pid),
      session_id: origin.session_id,
      capabilities: origin.client_capabilities || %{}
    }
  end

  defp start_runner(instance, %{run: run, check: check, check_results: check_results}) do
    task = self()

    Invoke.start(
      fn ->
        #
        # A task that is already gone makes the link end the runner.
        #
        Process.link(task)
        run.()
      end,
      supervisor: Instance.via(instance, :calls),
      #
      # The runner always runs a tool: the shape of a `tools/call` result.
      #
      method: "tools/call",
      check: check,
      check_results: check_results,
      on_exit: fn result -> send(task, {:runner_finished, result}) end
    )
  catch
    :exit, reason -> {:error, reason}
  end

  defp ttl_timer(%{ttl: nil}), do: []
  defp ttl_timer(%{ttl: ttl}), do: [{{:timeout, :ttl}, ttl, :expire}]

  # The terminal transition: record, waiters, notification, end.
  #
  defp finish(data, status, message, result, from) do
    data = drop_held(data, "the task ended", :no_task)
    now = DateTime.utc_now()

    record = %{
      data.record
      | status: status,
        status_message: message,
        result: result,
        last_updated_at: now,
        expires_at_ms: nil,
        runner_pid: nil,
        pid: nil
    }

    record = %{record | expires_at_ms: Tasks.expires_at_ms(record)}

    :ok = Records.put(data.store, data.instance, record)
    if record.expires_at_ms, do: Reaper.rearm(data.instance)
    untrack(data)

    Enum.each(data.waiters, fn {from, ref} ->
      Process.demonitor(ref, [:flush])
      :gen_statem.reply(from, {:ok, result})
    end)

    # The terminal status first, then each attached `tasks/result`
    # request, so the last status is written before the response.
    #
    Notifier.deliver(
      data.instance,
      record,
      data.streams,
      Notify.task_status_message(Tasks.to_task(record))
    )

    notify_streams(data, {:ok, result})

    replies = if from, do: [{:reply, from, {:ok, Tasks.to_task(record)}}], else: []
    Telemetry.stop(data.span, %{status: status})

    {:stop_and_reply, :normal, replies, %{data | record: record, waiters: [], span: nil}}
  end

  defp change_status(data, status, message) do
    record = %{
      data.record
      | status: status,
        status_message: message,
        last_updated_at: DateTime.utc_now()
    }

    :ok = Records.put(data.store, data.instance, record)

    Notifier.deliver(
      data.instance,
      record,
      data.streams,
      Notify.task_status_message(Tasks.to_task(record))
    )

    %{data | record: record}
  end

  defp expire(data) do
    data = drop_held(data, "task expired", :no_task)
    remove(data, :expired)
  end

  defp remove(data, reason) do
    _ = Records.delete(data.store, data.instance, data.record)
    untrack(data)

    Enum.each(data.waiters, fn {from, ref} ->
      Process.demonitor(ref, [:flush])
      :gen_statem.reply(from, {:error, reason})
    end)

    notify_streams(data, {:error, reason})
    Telemetry.stop(data.span, %{status: reason})
    {:stop, :normal, %{data | waiters: [], span: nil}}
  end

  # A task that outlives its session is not tracked.
  #
  defp track(%{opts: %{tasks_follow_session: true}} = data),
    do: Session.track_task(data.instance, data.record.session_id, data.record.task_id)

  defp track(_data), do: :ok

  defp untrack(%{opts: %{tasks_follow_session: true}} = data),
    do: Session.untrack_task(data.instance, data.record.session_id, data.record.task_id)

  defp untrack(_data), do: :ok

  # Each attached `tasks/result` request gets the outcome.
  #
  defp notify_streams(data, outcome) do
    for %{pid: pid} <- data.streams,
        do: send(pid, {:oz_mcp_task_result, data.record.task_id, outcome})

    :ok
  end

  defp with_reply({:keep_state, data}, from, reply),
    do: {:keep_state, data, [{:reply, from, reply}]}

  defp with_reply({:next_state, state, data}, from, reply),
    do: {:next_state, state, data, [{:reply, from, reply}]}

  defp neutral?(_streams, %{method: method}) when method in @neutral, do: true

  defp neutral?(streams, %{method: method} = entry) when method in @polls,
    do: Enum.any?(streams, &held_goes_to?(&1, entry))

  defp neutral?(_streams, _entry), do: false

  # A held poll with no stream that can carry it is no longer neutral.
  #
  defp stream_lost(data) do
    held =
      Map.new(data.held, fn {id, entry} ->
        {id, %{entry | neutral?: neutral?(data.streams, entry)}}
      end)

    %{data | held: held}
  end

  # input_required <=> a held request that is not neutral.
  #
  defp next_status(state, data, message) do
    wanted =
      if Enum.any?(data.held, fn {_id, entry} -> not entry.neutral? end),
        do: :input_required,
        else: :working

    if wanted == state,
      do: {:keep_state, data},
      else: {:next_state, wanted, change_status(data, wanted, message)}
  end

  defp drop_held(data, reason, error) do
    for {out_id, entry} <- data.held do
      push_cancelled(data, out_id, entry, reason)

      if entry.waiter_ref, do: Process.demonitor(entry.waiter_ref, [:flush])

      send(entry.waiter, {Outbound.answer_tag(), out_id, {:error, error}})
    end

    %{data | held: %{}, waiter_refs: %{}}
  end

  # A held request goes only to a stream whose client accepts it.
  #
  defp held_goes_to?(stream, entry) do
    not is_nil(stream.stream_id) and not is_nil(stream.session_id) and
      Outbound.accepts?(stream.capabilities, entry.method, entry.params)
  end

  # A message for an attached stream goes through its session.
  #
  defp emit_stream(data, stream, encoded) do
    Sessions.emit(data.instance, stream.session_id, {:stream, stream.stream_id}, encoded)
  end

  defp push_request(data, entry) do
    for stream <- data.streams,
        held_goes_to?(stream, entry) do
      _ = emit_stream(data, stream, entry.data)
    end

    :ok
  end

  defp push_cancelled(data, out_id, entry, reason) do
    params = RelatedTask.put(%{"requestId" => out_id, "reason" => reason}, data.record.task_id)
    notice = JsonRpc.notification("notifications/cancelled", params)

    _ =
      with {:ok, encoded} <- Wire.encode_message(notice) do
        for stream <- data.streams,
            held_goes_to?(stream, entry) do
          _ = emit_stream(data, stream, encoded)
        end
      end

    :ok
  end

  # The runner gets `:shutdown`, then `:kill` after the grace time.
  #
  defp stop_runner(%{runner: nil}), do: :ok

  defp stop_runner(%{runner: runner, runner_ref: ref, opts: opts}) do
    Process.exit(runner, :shutdown)

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    after
      opts.request_cancel_grace_ms ->
        Process.exit(runner, :kill)
        :ok
    end
  end

  defp classify({:ok, result}) when is_map(result) and not is_struct(result) do
    if Output.error_result?(result),
      do: {:failed, "The tool execution reported an error.", {:ok, result}},
      else: {:completed, nil, {:ok, result}}
  end

  # The runner refuses any other result for `tools/call`; this clause must
  # not make a completed task.
  #
  defp classify({:ok, other}) do
    Logger.error(
      "the runner of a task gave a result that is not a map: #{inspect(other, limit: 5)}"
    )

    {:failed, "internal error", crash_outcome()}
  end

  defp classify({:error, %Error{} = err}) do
    {:failed, err.message, {:error, %{code: err.code, message: err.message, data: err.data}}}
  end

  defp classify({:error, %{code: code, message: message} = err})
       when is_integer(code) and is_binary(message) do
    {:failed, message, {:error, %{code: code, message: message, data: Map.get(err, :data)}}}
  end

  # The handler adds the related-task `_meta` to `data`.
  #
  defp cancel_outcome,
    do: {:error, %{code: @cancelled_code, message: "task was cancelled", data: nil}}

  defp crash_outcome, do: {:error, %{code: -32_603, message: "internal error", data: nil}}

  # `inspect/2` does not bound the total size of a nested term, so the
  # text is cut after it.
  #
  @max_reason_bytes 2_000

  defp reason_text(reason) do
    text = inspect(reason, limit: 20, printable_limit: @max_reason_bytes)

    if byte_size(text) > @max_reason_bytes,
      do: cut_text(text) <> "...",
      else: text
  end

  # The cut leaves valid UTF-8: 10xxxxxx bytes follow the first byte of a
  # multi-byte character.
  #
  defp cut_text(text) do
    cut = binary_part(text, 0, @max_reason_bytes)
    drop_broken(cut, byte_size(cut))
  end

  defp drop_broken(cut, size) when size > 0 do
    case :binary.at(cut, size - 1) do
      byte when byte in 0b10000000..0b10111111 ->
        drop_broken(binary_part(cut, 0, size - 1), size - 1)

      _first_byte_or_ascii ->
        cut
    end
  end
end
