defmodule OzMcp.Sessions.ReclaimTest do
  use ExUnit.Case, async: true

  alias OzMcp.Instance
  alias OzMcp.Session
  alias OzMcp.Sessions
  alias OzMcp.Sessions.Reclaim
  alias Support.Helpers.Utils
  alias Support.Servers

  @server Servers.Default
  @alice {"https://issuer.test", "alice"}
  @bob {"https://issuer.test", "bob"}

  setup do
    name = Module.concat(@server, "RC#{System.unique_integer([:positive])}")
    Utils.start_instance(@server, name: name, max_sessions: 100)
    %{instance: name}
  end

  defp start_session(instance, opts \\ []) do
    {:ok, id} = Sessions.start(instance, opts)
    id
  end

  # The stamp of a new session comes from the clock. The test writes the
  # value in the process of the session, the owner of the Registry entry.
  #
  defp set_last_active(instance, id, at) do
    {:ok, pid} = Instance.whereis(instance, {:session, id})

    :sys.replace_state(pid, fn {name, state} ->
      view = %{state.core.view | last_active_ms: at}
      Registry.update_value(Instance.names(instance), {:session, id}, fn _ -> view end)
      {name, put_in(state.core.view, view)}
    end)
  end

  defp alive?(instance, id), do: match?({:ok, _view}, Sessions.lookup(instance, id))

  test "the oldest idle session goes first", %{instance: instance} do
    first = start_session(instance)
    oldest = start_session(instance)
    last = start_session(instance)

    set_last_active(instance, first, 300)
    set_last_active(instance, oldest, 100)
    set_last_active(instance, last, 200)

    assert :ok = Reclaim.run(instance, :instance, nil)

    refute alive?(instance, oldest)
    assert alive?(instance, first)
    assert alive?(instance, last)
  end

  test "a session that never sent notifications/initialized goes first", %{instance: instance} do
    initialized = start_session(instance)
    assert :ok = Sessions.set_initialized(instance, initialized)
    fresh = start_session(instance)

    set_last_active(instance, initialized, 100)
    set_last_active(instance, fresh, 500)

    assert :ok = Reclaim.run(instance, :instance, nil)

    refute alive?(instance, fresh)
    assert alive?(instance, initialized)
  end

  test "a session with a GET stream is not a candidate", %{instance: instance} do
    streamed = start_session(instance)
    idle = start_session(instance)

    assert {:ok, _} = Session.open_stream(instance, streamed, :get, self(), nil)
    set_last_active(instance, streamed, 100)
    set_last_active(instance, idle, 200)

    assert :ok = Reclaim.run(instance, :instance, nil)

    refute alive?(instance, idle)
    assert alive?(instance, streamed)
  end

  test "a session with a request in flight answers busy", %{instance: instance} do
    busy = start_session(instance)
    idle = start_session(instance)
    assert :ok = Session.open_request(instance, busy, 1, self(), nil)
    set_last_active(instance, busy, 100)
    set_last_active(instance, idle, 200)

    assert :ok = Reclaim.run(instance, :instance, nil)

    refute alive?(instance, idle)
    assert alive?(instance, busy)
  end

  test "the scan stops after five busy candidates", %{instance: instance} do
    busy =
      for n <- 1..5 do
        id = start_session(instance)
        assert :ok = Session.open_request(instance, id, n, self(), nil)
        set_last_active(instance, id, 100 + n)
        id
      end

    idle = start_session(instance)
    set_last_active(instance, idle, 200)

    assert :none = Reclaim.run(instance, :instance, nil)

    assert Enum.all?([idle | busy], &alive?(instance, &1))
  end

  test "the principal scope ends a session of that principal only", %{instance: instance} do
    alice_old = start_session(instance, principal_key: @alice)
    alice_new = start_session(instance, principal_key: @alice)
    bob = start_session(instance, principal_key: @bob)

    set_last_active(instance, alice_old, 100)
    set_last_active(instance, alice_new, 200)
    set_last_active(instance, bob, 50)

    assert :ok = Reclaim.run(instance, {:principal, @alice}, nil)

    refute alive?(instance, alice_old)
    assert alive?(instance, alice_new)
    assert alive?(instance, bob)
  end

  test "except_id is never ended", %{instance: instance} do
    only = start_session(instance)
    set_last_active(instance, only, 100)

    assert :none = Reclaim.run(instance, :instance, only)
    assert alive?(instance, only)
  end

  test "the match specification reads the real views", %{instance: instance} do
    streamed = start_session(instance)
    older = start_session(instance)
    newer = start_session(instance)

    assert {:ok, _} = Session.open_stream(instance, streamed, :get, self(), nil)
    set_last_active(instance, streamed, 100)
    set_last_active(instance, older, 200)
    set_last_active(instance, newer, 300)

    assert :ok = Reclaim.run(instance, :instance, nil)

    refute alive?(instance, older)
    assert alive?(instance, streamed)
    assert alive?(instance, newer)
  end
end
