defmodule OzMcp.Test.SessionProbeTest do
  use ExUnit.Case, async: true

  alias OzMcp.Instance
  alias OzMcp.Session.EventLog
  alias OzMcp.Sessions
  alias Support.Helpers.SessionProbe
  alias Support.Helpers.Utils
  alias Support.Servers

  @server Servers.Default

  defp start_instance do
    name = Module.concat(@server, "T#{System.unique_integer([:positive])}")
    Utils.start_instance(@server, name: name, allowed_origins: [])
    name
  end

  defp start_session(instance) do
    {:ok, id} = Sessions.start(instance, [])
    {:ok, pid} = Instance.whereis(instance, {:session, id})
    {id, pid}
  end

  test "core/1 gives the state name and a plain map with every field" do
    instance = start_instance()
    {id, pid} = start_session(instance)

    assert {:initializing, core} = SessionProbe.core(pid)
    assert core.instance == instance
    assert core.id == id
    assert core.retired == false
    assert core.requests == %{}
    assert core.streams == %{}
    assert core.refs == %{}
    assert %EventLog{} = core.log
  end

  test "update_core/2 writes one field and core/1 reads it" do
    instance = start_instance()
    {_id, pid} = start_session(instance)

    SessionProbe.update_core(pid, &%{&1 | retired: true})

    assert {:initializing, %{retired: true}} = SessionProbe.core(pid)
  end

  test "Support.Helpers.Utils.session_data/2 gives the same map as core/1" do
    instance = start_instance()
    {id, pid} = start_session(instance)

    {_state, core} = SessionProbe.core(pid)

    assert Utils.session_data(instance, id) == core
  end

  test "a write of the log through the probe reaches events_after/3" do
    instance = start_instance()
    {id, pid} = start_session(instance)

    SessionProbe.update_core(pid, fn core ->
      %{core | log: EventLog.append(core.log, "st", {"st:1", "x"})}
    end)

    assert {:ok, [{"st:1", "x"}]} = SessionProbe.events_after(instance, id, nil)
  end
end
