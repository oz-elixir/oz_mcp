defmodule OzMcp.RootsChangedTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias OzMcp.{Context, Instance, RootsChanged, Sessions}
  alias Support.Helpers.Utils
  alias Support.Servers

  @server_module Servers.Outbound

  @server Module.concat(@server_module, __MODULE__)

  setup context do
    Utils.start_instance(
      @server_module,
      [name: @server] ++ Map.to_list(Map.get(context, :server_opts, %{}))
    )

    session_id = Utils.create_session(@server, initialized: true)

    # The probe of the test is the test process under `{:roots_probe,
    # session_id}` in the Names Registry of the instance: the callback
    # finds the probe of its ctx and a test that runs at the same time
    # gets no collision of a global process name. The value of the entry
    # is the mode of the callback (see `gate/1`).
    #
    Registry.register(Instance.names(@server), {:roots_probe, session_id}, nil)

    %{ctx: ctx(session_id), session_id: session_id}
  end

  # The callback of the session holds each run: it reports its pid to the
  # probe and waits for `:release`.
  #
  defp gate(session_id) do
    {:gate, nil} =
      Registry.update_value(Instance.names(@server), {:roots_probe, session_id}, fn _ ->
        :gate
      end)

    :ok
  end

  defp ctx(session_id),
    do: %{
      instance: @server,
      server: @server_module,
      session_id: session_id,
      request_id: nil,
      progress_token: nil,
      task_id: nil,
      client_capabilities: %{"roots" => %{}}
    }

  defp running?(session_id),
    do: Utils.session_data(@server, session_id).roots.running != nil

  defp wait_until(fun, tries \\ 1_500) do
    if Utils.eventually(fun, tries * 10) do
      :ok
    else
      flunk("condition was not met in time")
    end
  end

  # The invoke supervisor of the instance runs the callback. A test can
  # take it out of the supervision tree and put a fake process under its
  # name, to give the start of a run an error or an exit. The child id of
  # the supervisor is the name it registers under.
  #
  @calls_child_id {Instance.names(@server), :calls}

  defp stop_calls_child do
    supervisor = Support.Helpers.TreeProbe.workers(@server)
    assert is_pid(supervisor)
    assert :ok = Supervisor.terminate_child(supervisor, @calls_child_id)
    wait_until(fn -> Instance.whereis(@server, :calls) == :not_running end)
    supervisor
  end

  defp restart_calls_child(supervisor) do
    wait_until(fn -> Instance.whereis(@server, :calls) == :not_running end)
    assert {:ok, _pid} = Supervisor.restart_child(supervisor, @calls_child_id)
    :ok
  end

  # A fake invoke supervisor. It answers each start of a runner with
  # `reply`, or exits while it answers when `reply` is `:exit`.
  #
  defp start_fake_calls(reply) do
    names = Instance.names(@server)
    parent = self()

    pid =
      spawn(fn ->
        assert {:ok, _owner} = Registry.register(names, :calls, nil)
        send(parent, {:fake_calls_ready, self()})
        fake_calls(reply)
      end)

    assert_receive {:fake_calls_ready, ^pid}, 1_000
    pid
  end

  defp fake_calls(reply) do
    receive do
      {:"$gen_call", from, _request} ->
        case reply do
          :exit ->
            exit(:calls_fake_stopped)

          value ->
            GenServer.reply(from, value)
            fake_calls(reply)
        end

      :stop ->
        :ok
    end
  end

  defp stop_fake(fake) do
    Process.exit(fake, :kill)
    wait_until(fn -> Instance.whereis(@server, :calls) == :not_running end)
    :ok
  end

  defp assert_one_log_line(log, text) do
    count = log |> String.split("\n") |> Enum.count(&String.contains?(&1, text))
    assert count == 1, "expected one log line with #{inspect(text)}, got #{count}"
  end

  test "an error of the start of the runner keeps the session alive", %{
    ctx: ctx,
    session_id: session_id
  } do
    supervisor = stop_calls_child()
    fake = start_fake_calls({:error, :max_children})

    log =
      capture_log(fn ->
        assert RootsChanged.trigger(ctx) == :ok
        Utils.sync_server(@server, session_id)
      end)

    assert log =~ "roots_list_changed/1 not started: :max_children"
    assert_one_log_line(log, "roots_list_changed/1 not started")
    assert Utils.session_data(@server, session_id) != nil
    refute running?(session_id)

    # The roots state is idle again: with the supervisor back, a later
    # notification starts a run.
    #
    stop_fake(fake)
    restart_calls_child(supervisor)

    assert RootsChanged.trigger(ctx) == :ok
    assert_receive {:roots_list_changed, _}, 5_000
  end

  test "a stop of the invoke supervisor while the session starts a run keeps the session alive",
       %{
         ctx: ctx,
         session_id: session_id
       } do
    supervisor = stop_calls_child()
    fake = start_fake_calls(:exit)

    log =
      capture_log(fn ->
        assert RootsChanged.trigger(ctx) == :ok
        Utils.sync_server(@server, session_id)
      end)

    assert log =~ ":calls_fake_stopped"
    assert_one_log_line(log, "roots_list_changed/1 not started")
    assert Utils.session_data(@server, session_id) != nil
    refute running?(session_id)

    stop_fake(fake)
    restart_calls_child(supervisor)

    assert RootsChanged.trigger(ctx) == :ok
    assert_receive {:roots_list_changed, _}, 5_000
  end

  test "the end of the session stops a run of the callback that waits", %{ctx: ctx} do
    gate(ctx.session_id)

    assert RootsChanged.trigger(ctx) == :ok
    assert_receive {:roots_blocked, callback}, 5_000
    ref = Process.monitor(callback)

    assert :ok = Sessions.terminate(@server, ctx.session_id)

    # The callback never finishes: the session stops it in the two steps
    # of a cancel.
    #
    assert_receive {:DOWN, ^ref, :process, ^callback, :shutdown}, 5_000
  end

  @tag server_opts: %{request_timeout_ms: 200}
  test "a run that does not end in time is stopped and the session stays alive", %{
    ctx: ctx,
    session_id: session_id
  } do
    gate(ctx.session_id)

    log =
      capture_log(fn ->
        assert RootsChanged.trigger(ctx) == :ok
        assert_receive {:roots_blocked, callback}, 5_000

        ref = Process.monitor(callback)
        assert_receive {:DOWN, ^ref, :process, ^callback, _reason}, 5_000
      end)

    assert_one_log_line(log, "roots_list_changed/1 did not end in time")
    assert Utils.session_data(@server, session_id) != nil
    wait_until(fn -> not running?(session_id) end)
  end

  test "the first notification starts a run, the callback gets the ctx", %{ctx: ctx} do
    assert RootsChanged.trigger(ctx) == :ok
    assert_receive {:roots_list_changed, ^ctx}, 5_000
  end

  test "the session is free when the runs are done", %{
    ctx: ctx,
    session_id: session_id
  } do
    RootsChanged.trigger(ctx)
    assert_receive {:roots_list_changed, _}, 5_000
    wait_until(fn -> not running?(session_id) end)
  end

  test "a notification during a run is coalesced and gives one more run", %{
    ctx: ctx,
    session_id: session_id
  } do
    gate(ctx.session_id)

    assert RootsChanged.trigger(ctx) == :ok
    assert_receive {:roots_blocked, first}, 5_000

    assert RootsChanged.trigger(ctx) == :ok
    assert RootsChanged.trigger(ctx) == :ok
    assert running?(session_id)

    send(first, :release)
    assert_receive {:roots_blocked, second}, 5_000
    send(second, :release)

    refute_receive {:roots_blocked, _}, 200
    wait_until(fn -> not running?(session_id) end)
  end

  test "a notification without a running session starts a new run after the end of the last",
       %{ctx: ctx, session_id: session_id} do
    RootsChanged.trigger(ctx)
    assert_receive {:roots_list_changed, _}, 5_000
    wait_until(fn -> not running?(session_id) end)

    assert RootsChanged.trigger(ctx) == :ok
    assert_receive {:roots_list_changed, _}, 5_000
  end

  test "concurrent first notifications run the callback at most twice", %{ctx: ctx} do
    gate(ctx.session_id)

    tasks = for _ <- 1..40, do: Task.async(fn -> RootsChanged.trigger(ctx) end)
    results = Task.await_many(tasks)

    assert Enum.all?(results, &(&1 == :ok))
    assert_receive {:roots_blocked, first}, 5_000
    #
    # The notifications that came during the run fold into one more run.
    #
    refute_receive {:roots_blocked, _}, 200

    send(first, :release)
    assert_receive {:roots_blocked, second}, 5_000
    send(second, :release)
    refute_receive {:roots_blocked, _}, 300
  end

  test "a burst of 10 notifications runs the callback at most twice", %{ctx: ctx} do
    gate(ctx.session_id)

    for _ <- 1..10, do: assert(RootsChanged.trigger(ctx) == :ok)
    assert_receive {:roots_blocked, first}, 5_000
    refute_receive {:roots_blocked, _}, 200

    send(first, :release)
    assert_receive {:roots_blocked, second}, 5_000
    send(second, :release)
    refute_receive {:roots_blocked, _}, 300
  end

  test "works with the ctx built from a request context", %{session_id: session_id} do
    context = %Context{instance: @server, server: @server_module, session_id: session_id}
    assert RootsChanged.trigger(Context.to_ctx(context)) == :ok
    assert_receive {:roots_list_changed, ctx}, 5_000
    assert ctx.session_id == session_id
  end
end
