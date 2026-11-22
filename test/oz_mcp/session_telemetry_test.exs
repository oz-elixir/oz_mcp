#
# The `session` span: one `:start` when the process of the session
# starts and one `:stop` when it ends, with the reason of the end and
# the transport of the caller. A session that an exit signal stops
# gives a `:start` with no `:stop`.
#
defmodule OzMcp.SessionTelemetryTest do
  use ExUnit.Case, async: true

  alias OzMcp.Instance
  alias OzMcp.Session
  alias OzMcp.Session.View
  alias OzMcp.Sessions
  alias Support.Helpers.PersistentSnapshot
  alias Support.Helpers.SessionProbe
  alias Support.Helpers.TelemetryCapture
  alias Support.Helpers.Utils
  alias Support.Servers

  @server Servers.Default

  setup do
    %{ref: TelemetryCapture.attach()}
  end

  test "a new session gives a start with restored? false", %{ref: ref} do
    instance = start_instance()
    {_id, _pid} = start_session(instance)

    assert [start] = named(TelemetryCapture.drain(ref, instance), [:session, :start])
    {_, measurements, meta} = start

    assert meta.instance == instance
    assert meta.server == @server
    assert meta.restored? == false
    assert is_reference(meta.telemetry_span_context)
    assert is_integer(measurements.system_time)
    assert is_integer(measurements.monotonic_time)
  end

  test "the transport of the caller goes in the metadata", %{ref: ref} do
    instance = start_instance()
    {_id, _pid} = start_session(instance, transport: :stdio)

    assert [start] = named(TelemetryCapture.drain(ref, instance), [:session, :start])
    assert elem(start, 2).transport == :stdio
  end

  test "the metadata holds the fixed keys only", %{ref: ref} do
    instance = start_instance()
    {_id, _pid} = start_session(instance)

    assert [start] = named(TelemetryCapture.drain(ref, instance), [:session, :start])
    {_name, _measurements, meta} = start

    assert MapSet.new(Map.keys(meta)) ==
             MapSet.new([:instance, :server, :restored?, :telemetry_span_context])
  end

  test "a terminate gives a stop with the reason terminated", %{ref: ref} do
    instance = start_instance()
    {id, pid} = start_session(instance)
    down_ref = Process.monitor(pid)

    assert :ok = Sessions.terminate(instance, id)
    assert_receive {:DOWN, ^down_ref, :process, ^pid, {:shutdown, :terminated}}

    events = TelemetryCapture.drain(ref, instance)
    assert [start] = named(events, [:session, :start])
    assert [stop] = named(events, [:session, :stop])
    {_, %{duration: duration}, stop_meta} = stop

    assert stop_meta.reason == :terminated
    assert stop_meta.restored? == false
    assert stop_meta.instance == instance
    assert stop_meta.server == @server
    assert duration >= 0

    assert stop_meta.telemetry_span_context == elem(start, 2).telemetry_span_context
  end

  test "the idle timer gives the reason idle", %{ref: ref} do
    instance = start_instance(session_timeout_ms: 1_000)
    {id, pid} = start_session(instance)
    :ok = Sessions.set_initialized(instance, id)

    assert {:down, {:shutdown, :idle}} = wait_down(pid)

    assert [stop] = named(TelemetryCapture.drain(ref, instance), [:session, :stop])
    assert elem(stop, 2).reason == :idle
    assert elem(stop, 2).restored? == false
  end

  test "an evict gives the reason evicted", %{ref: ref} do
    instance = start_instance()
    {id, pid} = start_session(instance)
    :ok = Sessions.set_initialized(instance, id)

    down_ref = Process.monitor(pid)
    assert :ok = Session.evict(instance, id)
    assert_receive {:DOWN, ^down_ref, :process, ^pid, {:shutdown, :evicted}}

    assert [stop] = named(TelemetryCapture.drain(ref, instance), [:session, :stop])
    assert elem(stop, 2).reason == :evicted
  end

  test "the init timer gives the reason init_timeout", %{ref: ref} do
    instance = start_instance(session_init_timeout_ms: 50)
    {_id, pid} = start_session(instance)

    assert {:down, {:shutdown, :init_timeout}} = wait_down(pid)

    assert [stop] = named(TelemetryCapture.drain(ref, instance), [:session, :stop])
    assert elem(stop, 2).reason == :init_timeout
  end

  test "a start from a snapshot gives restored? true and the http transport", %{ref: ref} do
    instance = start_instance(session_snapshot: PersistentSnapshot)

    snapshot = %{
      principal_key: nil,
      protocol_version: nil,
      client_info: %{"name" => "session-telemetry", "version" => "1"},
      client_capabilities: %{},
      log_level: :warning,
      subscriptions: []
    }

    :ok = PersistentSnapshot.put(instance, "stored-id", snapshot)

    assert {:ok, %View{initialized: true}} =
             Sessions.start_restored(instance, "stored-id", snapshot)

    assert [start] = named(TelemetryCapture.drain(ref, instance), [:session, :start])
    meta = elem(start, 2)

    assert meta.restored? == true
    assert meta.transport == :http_streamable
    assert meta.instance == instance
    assert meta.server == @server
  end

  test "a failure inside the process gives the reason crash", %{ref: ref} do
    instance = start_instance()
    {id, pid} = start_session(instance)
    :ok = Sessions.set_initialized(instance, id)
    down_ref = Process.monitor(pid)

    # A value that the next message reads: the idle timer of a touch
    # reads the runtime options of the session.
    #
    SessionProbe.update_core(pid, &%{&1 | opts: false})
    :gen_statem.cast(pid, {:touch, nil})

    assert_receive {:DOWN, ^down_ref, :process, ^pid, _reason}

    assert [stop] = named(TelemetryCapture.drain(ref, instance), [:session, :stop])
    assert elem(stop, 2).reason == :crash
  end

  test "an exit signal gives a start with no stop", %{ref: ref} do
    instance = start_instance()
    {_id, pid} = start_session(instance)
    down_ref = Process.monitor(pid)

    Process.exit(pid, :boom)
    assert_receive {:DOWN, ^down_ref, :process, ^pid, :boom}

    events = TelemetryCapture.drain(ref, instance)
    assert [_start] = named(events, [:session, :start])
    assert [] = named(events, [:session, :stop])
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp start_instance(extra \\ []) do
    name = Module.concat(@server, "T#{System.unique_integer([:positive])}")

    Utils.start_instance(@server, [name: name, allowed_origins: []] ++ extra)

    name
  end

  defp start_session(instance, opts \\ []) do
    {:ok, id} = Sessions.start(instance, opts)
    {:ok, pid} = Instance.whereis(instance, {:session, id})
    {id, pid}
  end

  defp wait_down(pid, timeout \\ 5_000) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} -> {:down, reason}
    after
      timeout -> :alive
    end
  end

  # The events of one name in the drained list. The drain consumes the
  # mailbox, so the test drains one time and picks the events here.
  #
  defp named(events, tail) do
    event = [:oz_mcp | tail]
    Enum.filter(events, fn {name, _, _} -> name == event end)
  end
end
