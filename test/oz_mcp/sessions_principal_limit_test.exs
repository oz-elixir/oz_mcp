defmodule OzMcp.SessionsPrincipalLimitTest do
  #
  # Sync: the test of the scan reads the trace counters of the VM, which are
  # global.
  #
  use ExUnit.Case, async: false

  alias OzMcp.Instance
  alias OzMcp.Session
  alias OzMcp.Sessions
  alias Support.Helpers.Utils
  alias Support.Servers

  @server Servers.Default
  @alice {"https://issuer.test", "alice"}

  setup do
    name = Module.concat(@server, "PL#{System.unique_integer([:positive])}")
    Utils.start_instance(@server, name: name, max_sessions_per_principal: 1)
    %{instance: name}
  end

  describe "max_sessions_per_principal" do
    test "the limit refuses the session after the maximum when no session is idle", %{
      instance: instance
    } do
      assert {:ok, id} = Sessions.start(instance, principal_key: @alice)
      assert {:ok, _} = Session.open_stream(instance, id, :get, self(), nil)
      assert {:error, :too_many_sessions} = Sessions.start(instance, principal_key: @alice)
    end

    test "the oldest idle session of the principal is reclaimed", %{instance: instance} do
      assert {:ok, oldest} = Sessions.start(instance, principal_key: @alice)
      assert {:ok, newer} = Sessions.start(instance, principal_key: @alice)

      assert {:error, :no_session} = Sessions.lookup(instance, oldest)
      assert {:ok, _} = Sessions.lookup(instance, newer)
    end

    test "a restore with reclaim false does not end a session", %{instance: instance} do
      assert {:ok, id} = Sessions.start(instance, principal_key: @alice)

      snapshot = %{
        principal_key: @alice,
        protocol_version: nil,
        client_info: %{"name" => "principal-limit", "version" => "1"},
        client_capabilities: %{},
        log_level: :warning,
        subscriptions: []
      }

      assert {:error, :too_many_sessions} =
               Sessions.start_restored(instance, "stored-id", snapshot, reclaim: false)

      assert {:ok, _} = Sessions.lookup(instance, id)

      assert {:ok, _view} = Sessions.start_restored(instance, "stored-id", snapshot)
      assert {:error, :no_session} = Sessions.lookup(instance, id)
    end

    test "the entry of the session is in the Principals Registry", %{instance: instance} do
      assert {:ok, id} = Sessions.start(instance, principal_key: @alice)

      assert [{_pid, ^id}] = Registry.lookup(Instance.principals(instance), @alice)
    end

    test "a kill of a session frees its place", %{instance: instance} do
      assert {:ok, id} = Sessions.start(instance, principal_key: @alice)
      assert {:ok, view} = Sessions.lookup(instance, id)

      ref = Process.monitor(view.pid)
      Process.exit(view.pid, :kill)
      assert_receive {:DOWN, ^ref, _, _, _}

      assert Utils.eventually(fn ->
               Registry.lookup(Instance.principals(instance), @alice) == []
             end)

      assert {:ok, _} = Sessions.start(instance, principal_key: @alice)
    end

    test "an ended session frees its place at once", %{instance: instance} do
      assert {:ok, id} = Sessions.start(instance, principal_key: @alice)
      assert :ok = Sessions.terminate(instance, id)
      assert Registry.lookup(Instance.principals(instance), @alice) == []
      assert {:ok, _} = Sessions.start(instance, principal_key: @alice)
    end

    test "a restore does not count the session of the same id", %{instance: instance} do
      snapshot = %{
        principal_key: @alice,
        protocol_version: nil,
        client_info: %{"name" => "principal-limit", "version" => "1"},
        client_capabilities: %{},
        log_level: :warning,
        subscriptions: []
      }

      assert {:ok, id} = Sessions.start(instance, principal_key: @alice)
      assert {:ok, %{pid: pid}} = Sessions.lookup(instance, id)

      assert {:ok, %{pid: ^pid}} = Sessions.start_restored(instance, id, snapshot)
    end

    test "the count does not scan the Names Registry", %{instance: instance} do
      for i <- 1..2_000 do
        {:ok, _id} = Sessions.start(instance, principal_key: {nil, "other-#{i}"})
      end

      counted = {Registry, :count_select, 2}
      matched = {Registry, :count_match, 4}
      :erlang.trace_pattern(counted, true, [:call_count])
      :erlang.trace_pattern(matched, true, [:call_count])
      :erlang.trace_pattern(counted, :restart, [:call_count])
      :erlang.trace_pattern(matched, :restart, [:call_count])

      on_exit(fn ->
        :erlang.trace_pattern(counted, false, [])
        :erlang.trace_pattern(matched, false, [])
      end)

      assert {:ok, _id} = Sessions.start(instance, principal_key: @alice)

      assert {:call_count, 0} = :erlang.trace_info(counted, :call_count)
      assert {:call_count, 0} = :erlang.trace_info(matched, :call_count)
    end
  end
end
