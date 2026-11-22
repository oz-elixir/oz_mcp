defmodule OzMcp.Session.RootsTest do
  use ExUnit.Case, async: true

  alias OzMcp.Session.{Core, Roots}

  @deadline 300_000

  defp core(opts \\ [], roots \\ %{running: nil, again: false, ctx: nil}) do
    %Core{
      instance: OzMcp.Session.RootsTest,
      opts: Map.new([request_timeout_ms: 5_000, request_cancel_grace_ms: 10] ++ opts),
      roots: roots
    }
  end

  test "a notification with no run starts one" do
    ctx = %{server: TestServer, session_id: "s"}

    assert {_core, [{:start_roots, ^ctx}]} = Roots.changed(core(), ctx)
  end

  test "a notification during a run marks one more run" do
    pid = self()
    core = core([], %{running: pid, again: false, ctx: nil})
    ctx = %{server: TestServer, session_id: "s"}

    assert {%Core{roots: %{running: ^pid, again: true, ctx: ^ctx}}, []} =
             Roots.changed(core, ctx)
  end

  test "a burst during a run keeps the last ctx and one mark" do
    pid = self()
    first = %{server: TestServer, session_id: "one"}
    second = %{server: TestServer, session_id: "two"}
    core = core([], %{running: pid, again: false, ctx: nil})

    {core, []} = Roots.changed(core, first)
    {core, []} = Roots.changed(core, second)

    assert core.roots == %{running: pid, again: true, ctx: second}
  end

  test "the start of the runner arms its monitor and its deadline" do
    pid = self()
    core = core(request_timeout_ms: 1_000)

    assert {%Core{roots: %{running: ^pid, again: false, ctx: nil}}, effects} =
             Roots.started(core, pid)

    assert effects == [
             {:monitor, pid, :roots},
             {:timeout, {:timeout, :roots}, 1_000, pid}
           ]
  end

  test "the deadline of a run is the default when the server has no request timeout" do
    pid = self()
    core = core(request_timeout_ms: nil)

    assert {_core, effects} = Roots.started(core, pid)

    assert effects == [
             {:monitor, pid, :roots},
             {:timeout, {:timeout, :roots}, @deadline, pid}
           ]
  end

  test "the end of a run cancels its timer" do
    pid = self()
    core = core([], %{running: pid, again: false, ctx: nil})

    assert {%Core{roots: %{running: nil, again: false, ctx: nil}},
            [{:timeout, {:timeout, :roots}, :cancel, nil}]} = Roots.down(core)
  end

  test "the end of a run with a burst cancels the timer and starts the next run" do
    pid = self()
    ctx = %{server: TestServer, session_id: "s"}
    core = core([], %{running: pid, again: true, ctx: ctx})

    assert {%Core{roots: %{running: nil, again: false, ctx: nil}}, effects} = Roots.down(core)

    assert effects == [
             {:timeout, {:timeout, :roots}, :cancel, nil},
             {:start_roots, ctx}
           ]
  end

  test "a failed start with no supervisor gives the warning of today" do
    core = core()

    assert {%Core{roots: %{running: nil, again: false, ctx: nil}}, [effect]} =
             Roots.start_failed(core, :not_running)

    assert {:log, :warning, text} = effect

    assert text ==
             "no invoke supervisor for OzMcp.Session.RootsTest, roots_list_changed/1 not called"
  end

  test "a failed start with an error gives the warning of today" do
    core = core()

    assert {%Core{roots: %{running: nil, again: false, ctx: nil}}, [effect]} =
             Roots.start_failed(core, {:error, :max_children})

    assert {:log, :warning, text} = effect
    assert text == "roots_list_changed/1 not started: :max_children"
  end

  test "the deadline of a run stops it in two steps" do
    pid = self()
    core = core([], %{running: pid, again: false, ctx: nil})

    assert {_core, effects} = Roots.deadline(core, pid)

    assert effects == [
             {:log, :warning, "roots_list_changed/1 did not end in time, stopping it"},
             {:exit, pid, :shutdown},
             {:send_after, 10, {:kill_callback, pid}}
           ]
  end

  test "a late deadline of an ended run does nothing" do
    pid = self()
    core = core([], %{running: nil, again: false, ctx: nil})

    assert {^core, []} = Roots.deadline(core, pid)
  end

  test "the end of the session stops a live run" do
    pid = self()
    core = core([], %{running: pid, again: false, ctx: nil})

    assert {_core, effects} = Roots.stop(core)

    assert effects == [{:exit, pid, :shutdown}, {:kill_after, 10, pid}]
  end

  test "the end of the session with no live run does nothing" do
    core = core()

    assert {^core, []} = Roots.stop(core)
  end
end
