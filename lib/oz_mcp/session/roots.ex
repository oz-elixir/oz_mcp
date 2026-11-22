#
# The run of `roots_list_changed/1` of the server, one run at a time:
# a notification during a run marks one more run, so a burst is at
# most two runs. Owns the field `roots` of `OzMcp.Session.Core`.
# `changed/2` gets the short context of the callbacks when the client
# sends `notifications/roots/list_changed`.
#
defmodule OzMcp.Session.Roots do
  @moduledoc false

  alias OzMcp.Session.{Core, Effect}

  @deadline 300_000

  @spec changed(Core.t(), map()) :: {Core.t(), [Effect.t()]}
  def changed(%Core{roots: %{running: nil}} = core, ctx),
    do: {core, [{:start_roots, ctx}]}

  def changed(%Core{roots: roots} = core, ctx),
    do: {%{core | roots: %{roots | again: true, ctx: ctx}}, []}

  # The runner started. The shell gives the pid.
  #
  @spec started(Core.t(), pid()) :: {Core.t(), [Effect.t()]}
  def started(core, pid) do
    deadline = core.opts.request_timeout_ms || @deadline

    {%{core | roots: %{running: pid, again: false, ctx: nil}},
     [{:monitor, pid, :roots}, {:timeout, {:timeout, :roots}, deadline, pid}]}
  end

  # The start of the runner failed: the run does not happen.
  #
  @spec start_failed(Core.t(), :not_running | {:error, term()}) :: {Core.t(), [Effect.t()]}
  def start_failed(core, :not_running) do
    {idle(core),
     [
       {:log, :warning,
        "no invoke supervisor for #{inspect(core.instance)}, roots_list_changed/1 not called"}
     ]}
  end

  def start_failed(core, {:error, reason}) do
    {idle(core),
     [{:log, :warning, "roots_list_changed/1 not started: #{inspect(reason, limit: 5)}"}]}
  end

  # The runner ended. A burst during the run starts one more run.
  #
  @spec down(Core.t()) :: {Core.t(), [Effect.t()]}
  def down(%Core{roots: %{again: again, ctx: ctx}} = core) do
    core = idle(core)
    cancel = {:timeout, {:timeout, :roots}, :cancel, nil}
    if again, do: prepend(cancel, changed(core, ctx)), else: {core, [cancel]}
  end

  # The deadline of a run. A late timer of an ended run does nothing.
  #
  @spec deadline(Core.t(), pid()) :: {Core.t(), [Effect.t()]}
  def deadline(%Core{roots: %{running: pid}} = core, pid) do
    {core,
     [
       {:log, :warning, "roots_list_changed/1 did not end in time, stopping it"},
       {:exit, pid, :shutdown},
       {:send_after, core.opts.request_cancel_grace_ms, {:kill_callback, pid}}
     ]}
  end

  def deadline(core, _pid), do: {core, []}

  # The end of the session stops the runner, in the two steps of a cancel.
  #
  @spec stop(Core.t()) :: {Core.t(), [Effect.t()]}
  def stop(%Core{roots: %{running: pid}} = core) when is_pid(pid) do
    {core, [{:exit, pid, :shutdown}, {:kill_after, core.opts.request_cancel_grace_ms, pid}]}
  end

  def stop(core), do: {core, []}

  defp prepend(effect, {core, effects}), do: {core, [effect | effects]}
  defp idle(core), do: %{core | roots: %{running: nil, again: false, ctx: nil}}
end
