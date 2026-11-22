#
# The runner of the effects of the core: the only impure step between
# the pure functions and the process. A monitor has a tag, not a ref:
# the shell keeps `monitors` (tag => ref) and `refs` (ref => tag).
# `{:start_roots, ctx}` is the only effect that goes back into the
# core: the effects of `Roots.started/2` (or `Roots.start_failed/2`)
# run in its place.
#
defmodule OzMcp.Session.Effects do
  @moduledoc false

  alias OzMcp.Handler.Invoke
  alias OzMcp.Instance
  alias OzMcp.Session.{Core, Effect, RestoreCache, Roots}
  alias OzMcp.Session.Snapshot.Writer
  alias OzMcp.Tasks
  alias OzMcp.Telemetry

  require Logger

  @type event_handler_result ::
          {:next_state, atom(), OzMcp.Session.t(), [term()]}
          | {:stop, term(), OzMcp.Session.t()}
          | {:stop_and_reply, term(), [term()], OzMcp.Session.t()}

  @spec run([Effect.t()], OzMcp.Session.t(), term(), atom()) :: event_handler_result()
  def run(effects, shell, from, state) do
    {shell, state, actions, stop} = exec(effects, shell, from, state, [], nil)
    result(shell, state, actions, stop)
  end

  # Runs the effects of `init/1` and gives the shell and the actions back.
  #
  @spec run_init([Effect.t()], OzMcp.Session.t()) :: {OzMcp.Session.t(), [term()]}
  def run_init(effects, shell) do
    {shell, _state, actions, _stop} = exec(effects, shell, nil, :initializing, [], nil)
    {shell, actions}
  end

  defp result(shell, _state, actions, stop) when stop != nil do
    stop_result(stop, shell, actions)
  end

  defp result(shell, state, actions, nil),
    do: {:next_state, state, shell, actions}

  defp stop_result(reason, shell, actions) do
    case for({:reply, _from, _term} = reply <- actions, do: reply) do
      [] -> {:stop, reason, shell}
      replies -> {:stop_and_reply, reason, replies, shell}
    end
  end

  defp exec([], shell, _from, state, actions, stop),
    do: {shell, state, Enum.reverse(actions), stop}

  defp exec([{:stop, reason} | _rest], shell, _from, state, actions, _stop),
    do: {shell, state, Enum.reverse(actions), reason}

  defp exec([{:start_roots, ctx} | rest], shell, from, state, actions, stop) do
    {core, more} = start_roots(shell.core, ctx)
    exec(more ++ rest, %{shell | core: core}, from, state, actions, stop)
  end

  defp exec([{:reply, term} | rest], shell, from, state, actions, stop) when from != nil,
    do: exec(rest, shell, from, state, [{:reply, from, term} | actions], stop)

  defp exec([{:reply, _term} | rest], shell, from, state, actions, stop),
    do: exec(rest, shell, from, state, actions, stop)

  defp exec([{:next_state, name} | rest], shell, from, _state, actions, stop),
    do: exec(rest, shell, from, name, actions, stop)

  defp exec([{:next_event, type, content} | rest], shell, from, state, actions, stop),
    do: exec(rest, shell, from, state, [{:next_event, type, content} | actions], stop)

  defp exec([{:send, pid, term} | rest], shell, from, state, actions, stop) do
    send(pid, term)
    exec(rest, shell, from, state, actions, stop)
  end

  defp exec([{:monitor, pid, tag} | rest], shell, from, state, actions, stop) do
    ref = Process.monitor(pid)

    shell = %{
      shell
      | refs: Map.put(shell.refs, ref, tag),
        monitors: Map.put(shell.monitors, tag, ref)
    }

    exec(rest, shell, from, state, actions, stop)
  end

  defp exec([{:demonitor, tag} | rest], shell, from, state, actions, stop) do
    case Map.pop(shell.monitors, tag) do
      {nil, _monitors} ->
        exec(rest, shell, from, state, actions, stop)

      {ref, monitors} ->
        Process.demonitor(ref, [:flush])
        shell = %{shell | monitors: monitors, refs: Map.delete(shell.refs, ref)}
        exec(rest, shell, from, state, actions, stop)
    end
  end

  defp exec([{:timeout, name, :cancel, _content} | rest], shell, from, state, actions, stop),
    do: exec(rest, shell, from, state, [{name, :cancel} | actions], stop)

  defp exec([{:timeout, name, ms, content} | rest], shell, from, state, actions, stop),
    do: exec(rest, shell, from, state, [{name, ms, content} | actions], stop)

  # A change that gives the same view returns no effect.
  #
  defp exec([{:view, view} | rest], shell, from, state, actions, stop) do
    {_new, _old} =
      Registry.update_value(
        Instance.names(shell.core.instance),
        {:session, shell.core.id},
        fn _ -> view end
      )

    exec(rest, shell, from, state, actions, stop)
  end

  defp exec([{:pubsub, :subscribe, topic} | rest], shell, from, state, actions, stop) do
    shell.core.opts.pubsub.subscribe(shell.core.instance, topic)
    exec(rest, shell, from, state, actions, stop)
  end

  defp exec([{:pubsub, :unsubscribe, topic} | rest], shell, from, state, actions, stop) do
    shell.core.opts.pubsub.unsubscribe(shell.core.instance, topic)
    exec(rest, shell, from, state, actions, stop)
  end

  # The session never waits for the store.
  #
  defp exec([{:snapshot, :save, snapshot} | rest], shell, from, state, actions, stop) do
    Writer.save(shell.core.instance, shell.core.id, snapshot)
    exec(rest, shell, from, state, actions, stop)
  end

  defp exec([{:snapshot, :delete} | rest], shell, from, state, actions, stop) do
    Writer.delete(shell.core.instance, shell.core.id)
    exec(rest, shell, from, state, actions, stop)
  end

  # The tombstone goes before the delete: a restore that comes after the
  # removal of the Registry entry cannot start the session again.
  #
  defp exec([{:tombstone, id} | rest], shell, from, state, actions, stop) do
    RestoreCache.put_deleted(shell.core.instance, id)
    exec(rest, shell, from, state, actions, stop)
  end

  defp exec([{:unregister, :principals} | rest], shell, from, state, actions, stop) do
    Registry.unregister(
      Instance.principals(shell.core.instance),
      shell.core.view.principal_key
    )

    exec(rest, shell, from, state, actions, stop)
  end

  defp exec([{:unregister, :names} | rest], shell, from, state, actions, stop) do
    Registry.unregister(Instance.names(shell.core.instance), {:session, shell.core.id})
    exec(rest, shell, from, state, actions, stop)
  end

  # The event names the limit and its value; no id of a session or of a
  # principal goes out.
  #
  defp exec([{:limit, name, value} | rest], shell, from, state, actions, stop) do
    Telemetry.limit(shell.telemetry, name, value, :session)
    exec(rest, shell, from, state, actions, stop)
  end

  # The same event as a refusal, with the outcome `:replaced`.
  #
  defp exec([{:limit, name, value, outcome} | rest], shell, from, state, actions, stop) do
    Telemetry.limit(shell.telemetry, name, value, :session, outcome)
    exec(rest, shell, from, state, actions, stop)
  end

  defp exec([{:telemetry, key, measurements, meta} | rest], shell, from, state, actions, stop) do
    Telemetry.event(shell.telemetry, key, measurements, meta)
    exec(rest, shell, from, state, actions, stop)
  end

  # The span of the life of the session ends with the session.
  #
  defp exec([{:span_stop, meta} | rest], shell, from, state, actions, stop) do
    Telemetry.stop(shell.span, meta)
    exec(rest, shell, from, state, actions, stop)
  end

  # A cast, so the end of the session never waits for a task process.
  #
  defp exec([{:end_tasks, tasks} | rest], shell, from, state, actions, stop) do
    _ = Tasks.terminate_session_async(shell.core.instance, shell.core.id, tasks)
    exec(rest, shell, from, state, actions, stop)
  end

  defp exec([{:send_after, ms, term} | rest], shell, from, state, actions, stop) do
    :erlang.send_after(ms, shell.core.pid, term)
    exec(rest, shell, from, state, actions, stop)
  end

  defp exec([{:kill_after, ms, pid} | rest], shell, from, state, actions, stop) do
    {:ok, _timer} = :timer.kill_after(ms, pid)
    exec(rest, shell, from, state, actions, stop)
  end

  defp exec([{:exit, pid, reason} | rest], shell, from, state, actions, stop) do
    Process.exit(pid, reason)
    exec(rest, shell, from, state, actions, stop)
  end

  defp exec([{:log, :warning, text} | rest], shell, from, state, actions, stop) do
    Logger.warning(text)
    exec(rest, shell, from, state, actions, stop)
  end

  defp exec([{:log, :debug, text} | rest], shell, from, state, actions, stop) do
    Logger.debug(text)
    exec(rest, shell, from, state, actions, stop)
  end

  # Arms or cancels the idle timer. Only the state `:ready` arms it.
  #
  defp exec([:idle_check | rest], shell, from, state, actions, stop) do
    actions =
      case state do
        :ready -> [Core.idle_timer(shell.core) | actions]
        _other -> actions
      end

    exec(rest, shell, from, state, actions, stop)
  end

  # An error of the start gives a warning and keeps the session alive.
  #
  defp start_roots(core, ctx) do
    with {:ok, supervisor} <- Instance.whereis(core.instance, :calls),
         {:ok, pid} <- start_roots_runner(supervisor, ctx) do
      Roots.started(core, pid)
    else
      :not_running -> Roots.start_failed(core, :not_running)
      {:error, reason} -> Roots.start_failed(core, {:error, reason})
    end
  end

  defp start_roots_runner(supervisor, %{server: server} = ctx) do
    Invoke.start(
      fn ->
        server.roots_list_changed(ctx)
        {:ok, %{}}
      end,
      supervisor: supervisor,
      on_exit: fn
        {:ok, _result} -> :ok
        {:error, _error} -> Logger.warning("roots_list_changed/1 of #{inspect(server)} failed")
      end
    )
  catch
    #
    # The start of the runner can exit when the invoke supervisor stops
    # while the session starts the run.
    #
    :exit, reason -> {:error, {:exit, reason}}
  end
end
