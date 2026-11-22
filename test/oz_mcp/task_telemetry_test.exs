#
# The `task` span: one `:start` when the process of the task starts and
# one `:stop` when it ends, with the final status of the task. A task
# that the host kills gives its `:stop` from the reaper, with no span
# context.
#
defmodule OzMcp.TaskTelemetryTest do
  use ExUnit.Case, async: true

  alias OzMcp.Instance
  alias OzMcp.Structs.Task
  alias OzMcp.Tasks
  alias OzMcp.Tasks.EtsStore
  alias Support.Helpers.SessionProbe
  alias Support.Helpers.TelemetryCapture
  alias Support.Helpers.Utils
  alias Support.Servers

  @server_module Servers.TasksTest

  setup context do
    ref = TelemetryCapture.attach()
    opts = Map.get(context, :task_opts) || %{}
    name = Module.concat(@server_module, "T#{System.unique_integer([:positive])}")

    Utils.start_instance(@server_module, [name: name] ++ Map.to_list(opts))
    Support.Entities.Tools.TaskSlowTest.use_instance(name)

    session_id = Utils.create_session(name, initialized: true)

    %{ref: ref, instance: name, session_id: session_id}
  end

  test "a completed task gives one start and one stop with status completed", %{
    ref: ref,
    instance: instance,
    session_id: session_id
  } do
    task = create_task(instance, session_id)

    assert {:ok, {:ok, _}} =
             Tasks.await(instance, Utils.owner(session_id), task.taskId, 5_000)

    events = collect_until(ref, instance, &stop_reached?(&1, 1))

    assert [start] = named(events, [:task, :start])
    assert [stop] = named(events, [:task, :stop])

    assert elem(start, 2).instance == instance
    assert is_reference(elem(start, 2).telemetry_span_context)
    assert is_integer(elem(start, 1).system_time)
    assert is_integer(elem(start, 1).monotonic_time)

    {_, %{duration: duration}, stop_meta} = stop
    assert stop_meta.status == :completed
    assert stop_meta.instance == instance
    assert stop_meta.telemetry_span_context == elem(start, 2).telemetry_span_context
    assert duration >= 0
  end

  test "a task of a tool that reports an error gives status failed", %{
    ref: ref,
    instance: instance,
    session_id: session_id
  } do
    task =
      create_task(instance, session_id,
        tool: {Support.Entities.Tools.TaskErrorTest, "task_error"},
        request: %{"name" => "task_error", "arguments" => %{}}
      )

    assert {:ok, {:error, _}} =
             Tasks.await(instance, Utils.owner(session_id), task.taskId, 5_000)

    events = collect_until(ref, instance, &stop_reached?(&1, 1))
    assert [stop] = named(events, [:task, :stop])
    assert elem(stop, 2).status == :failed
  end

  test "a cancel gives status cancelled", %{ref: ref, instance: instance, session_id: session_id} do
    task = create_slow_task(instance, session_id)

    assert {:ok, %Task{status: :cancelled}} =
             Tasks.cancel(instance, Utils.owner(session_id), task.taskId)

    events = collect_until(ref, instance, &stop_reached?(&1, 1))
    assert [stop] = named(events, [:task, :stop])
    assert elem(stop, 2).status == :cancelled
  end

  test "the end of the ttl gives status expired", %{
    ref: ref,
    instance: instance,
    session_id: session_id
  } do
    task = create_slow_task(instance, session_id, ttl: 100)

    wait_until(fn -> EtsStore.get(instance, task.taskId) == :not_found end)

    events = collect_until(ref, instance, &stop_reached?(&1, 1))
    assert [stop] = named(events, [:task, :stop])
    assert elem(stop, 2).status == :expired
  end

  @tag task_opts: %{tasks_follow_session: true}
  test "the end of the session gives status session_terminated", %{
    ref: ref,
    instance: instance,
    session_id: session_id
  } do
    task = create_slow_task(instance, session_id)

    assert :ok = SessionProbe.terminate_tasks(instance, session_id)

    wait_until(fn -> EtsStore.get(instance, task.taskId) == :not_found end)

    events = collect_until(ref, instance, &stop_reached?(&1, 1))
    assert [stop] = named(events, [:task, :stop])
    assert elem(stop, 2).status == :session_terminated
  end

  test "a stop of the child by the host gives status shutdown", %{
    ref: ref,
    instance: instance,
    session_id: session_id
  } do
    task = create_slow_task(instance, session_id)
    {:ok, pid} = Instance.whereis(instance, {:task, task.taskId})
    down_ref = Process.monitor(pid)

    assert :ok = DynamicSupervisor.terminate_child(Instance.via(instance, :tasks), pid)
    assert_receive {:DOWN, ^down_ref, :process, ^pid, _reason}

    events = collect_until(ref, instance, &stop_reached?(&1, 1))
    assert [stop] = named(events, [:task, :stop])
    assert elem(stop, 2).status == :shutdown
  end

  @tag :capture_log
  test "a crash of the process gives status failed and the reaper gives no stop", %{
    ref: ref,
    instance: instance,
    session_id: session_id
  } do
    task = create_slow_task(instance, session_id)
    {:ok, pid} = Instance.whereis(instance, {:task, task.taskId})
    down_ref = Process.monitor(pid)

    # A value that the next call reads: the cancel builds the params of
    # the cancellation notice from the record.
    #
    :sys.replace_state(pid, fn {state, data} -> {state, %{data | record: false}} end)
    Tasks.cancel(instance, Utils.owner(session_id), task.taskId)

    assert_receive {:DOWN, ^down_ref, :process, ^pid, _reason}
    wait_until(fn -> match?({:ok, %{status: :failed}}, EtsStore.get(instance, task.taskId)) end)

    events = collect_until(ref, instance, &stop_reached?(&1, 1))
    assert [_start] = named(events, [:task, :start])
    assert [stop] = named(events, [:task, :stop])
    assert elem(stop, 2).status == :failed
  end

  @tag :capture_log
  test "a killed task gives one stop from the reaper with no span context", %{
    ref: ref,
    instance: instance,
    session_id: session_id
  } do
    task = create_slow_task(instance, session_id)
    {:ok, pid} = Instance.whereis(instance, {:task, task.taskId})
    down_ref = Process.monitor(pid)

    # The duration of the event comes from the creation time of the
    # record: a wait before the kill makes it measurable. The tool is
    # still blocked, so the record is `working` at the kill.
    #
    Process.sleep(20)

    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^down_ref, :process, ^pid, :killed}
    wait_until(fn -> match?({:ok, %{status: :failed}}, EtsStore.get(instance, task.taskId)) end)

    events = collect_until(ref, instance, &stop_reached?(&1, 1))
    assert [start] = named(events, [:task, :start])
    assert [stop] = named(events, [:task, :stop])

    {_, %{duration: duration}, stop_meta} = stop
    assert stop_meta.status == :failed
    assert stop_meta.instance == instance
    assert duration >= System.convert_time_unit(20, :millisecond, :native)

    assert MapSet.new(Map.keys(stop_meta)) == MapSet.new([:instance, :server, :status])

    assert MapSet.new(Map.keys(elem(start, 2))) ==
             MapSet.new([:instance, :server, :telemetry_span_context])
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp create_task(instance, session_id, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          session_id: session_id,
          tool: {Support.Entities.Tools.TaskImmediateTest, "task_immediate"},
          request: %{"name" => "task_immediate", "arguments" => %{}},
          ttl: nil,
          progress_token: nil
        },
        Map.new(attrs)
      )

    assert {:ok, %Task{} = task} = Tasks.create(instance, attrs)
    task
  end

  defp create_slow_task(instance, session_id, extra_attrs \\ %{}) do
    create_task(
      instance,
      session_id,
      Map.merge(
        %{
          tool: {Support.Entities.Tools.TaskSlowTest, "task_slow"},
          request: %{"name" => "task_slow", "arguments" => %{}}
        },
        Map.new(extra_attrs)
      )
    )
  end

  # The events of the mailbox for one instance, until the condition holds
  # on the events of the `task` span. Each drain consumes the mailbox, so
  # the helper accumulates the events it took.
  #
  defp collect_until(ref, instance, fun, acc \\ [], tries \\ 300)

  defp collect_until(_ref, _instance, _fun, acc, 0), do: acc

  defp collect_until(ref, instance, fun, acc, tries) do
    if fun.(acc) do
      acc
    else
      case TelemetryCapture.drain_wait(ref, instance, 100) do
        [] -> collect_until(ref, instance, fun, acc, tries - 1)
        events -> collect_until(ref, instance, fun, acc ++ events, tries - 1)
      end
    end
  end

  defp stop_reached?(events, count), do: length(named(events, [:task, :stop])) >= count

  # The events of one name in the drained list.
  #
  defp named(events, tail) do
    event = [:oz_mcp | tail]
    Enum.filter(events, fn {name, _, _} -> name == event end)
  end

  defp wait_until(fun, retries \\ 1_500) do
    if Utils.eventually(fun, retries * 10) do
      :ok
    else
      flunk("condition was not met in time")
    end
  end
end
