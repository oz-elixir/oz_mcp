defmodule OzMcp.Session.EffectsTest do
  use ExUnit.Case, async: true

  alias OzMcp.Session
  alias OzMcp.Session.{Core, Effects}

  defp shell(attrs \\ %{}) do
    struct!(%Session{core: %Core{opts: %{session_timeout_ms: 30_000}}}, attrs)
  end

  test "a monitor writes the tag and its ref and its demonitor removes both" do
    pid = spawn(fn -> :ok end)
    shell = shell()

    assert {:next_state, :ready, shell, []} =
             Effects.run([{:monitor, pid, :roots}], shell, nil, :ready)

    ref = shell.monitors[:roots]

    assert is_reference(ref)
    assert shell.refs == %{ref => :roots}

    assert {:next_state, :ready, shell, []} =
             Effects.run([{:demonitor, :roots}], shell, nil, :ready)

    assert shell.refs == %{}
    assert shell.monitors == %{}
  end

  test "a demonitor of a tag with no live monitor does nothing" do
    shell = shell()

    assert {:next_state, :ready, ^shell, []} =
             Effects.run([{:demonitor, :roots}], shell, nil, :ready)
  end

  test "an unknown effect raises" do
    assert_raise FunctionClauseError, fn ->
      Effects.run([{:unknown_effect}], shell(), nil, :ready)
    end
  end

  test "the calls and the internal events become actions in the order of the list" do
    from = {self(), make_ref()}

    effects = [
      {:reply, :ok},
      {:timeout, {:timeout, :init}, 100, :init},
      {:next_event, :internal, :close}
    ]

    assert {:next_state, :ready, _shell, actions} =
             Effects.run(effects, shell(), from, :ready)

    assert actions == [
             {:reply, from, :ok},
             {{:timeout, :init}, 100, :init},
             {:next_event, :internal, :close}
           ]
  end

  test "an idle check after a move to :ready arms the idle timer" do
    shell = shell(core: %Core{opts: %{session_timeout_ms: 10_000}})

    assert {:next_state, :ready, _shell, actions} =
             Effects.run([{:next_state, :ready}, :idle_check], shell, nil, :initializing)

    assert actions == [{{:timeout, :idle}, 10_000, :idle}]
  end

  test "an idle check in :initializing gives no action" do
    shell = shell()

    assert {:next_state, :initializing, _shell, []} =
             Effects.run([:idle_check], shell, nil, :initializing)
  end

  test "a stop with no action gives :stop" do
    assert {:stop, :normal, _shell} = Effects.run([{:stop, :normal}], shell(), nil, :ready)
  end

  test "a stop after a reply gives :stop_and_reply" do
    from = {self(), make_ref()}

    assert {:stop_and_reply, :normal, [{:reply, ^from, :ok}], _shell} =
             Effects.run([{:reply, :ok}, {:stop, :normal}], shell(), from, :ready)
  end

  test "a stop after a next_event and a timeout gives :stop" do
    effects = [
      {:next_event, :internal, :close},
      {:timeout, {:timeout, :idle}, 1_000, :idle},
      {:stop, :normal}
    ]

    assert {:stop, :normal, _shell} = Effects.run(effects, shell(), nil, :ready)
  end

  test "a stop keeps the replies and drops the other actions" do
    from = {self(), make_ref()}
    effects = [{:reply, :ok}, {:next_event, :internal, :close}, {:stop, :normal}]

    assert {:stop_and_reply, :normal, [{:reply, ^from, :ok}], _shell} =
             Effects.run(effects, shell(), from, :ready)
  end
end
