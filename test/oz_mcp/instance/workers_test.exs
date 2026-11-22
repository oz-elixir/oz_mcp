defmodule OzMcp.Instance.WorkersTest do
  use ExUnit.Case, async: true

  alias OzMcp.Instance
  alias OzMcp.Instance.Config
  alias OzMcp.Instance.Core
  alias OzMcp.Instance.Workers
  alias Support.Helpers.PersistentSnapshot
  alias Support.Helpers.Utils
  alias Support.Servers

  @server Servers.Default
  @workers [:calls, :sessions, :tasks_reaper, :tasks]
  @snapshot_workers [:restore_cache, :snapshot_writer]

  setup do
    name = Module.concat(@server, "Workers#{System.unique_integer([:positive])}")

    %{name: name}
  end

  test "starts four children without a snapshot module", %{name: name} do
    config = Config.parse!(server: @server, name: name, allowed_origins: [])
    start_supervised!({Core, config})
    workers = start_supervised!({Workers, config})

    assert length(Supervisor.which_children(workers)) == 4
    assert_pids(name, @workers)
  end

  test "starts six children with a snapshot module", %{name: name} do
    config = snapshot_config(name)

    start_supervised!({Core, config})
    workers = start_supervised!({Workers, config})

    assert length(Supervisor.which_children(workers)) == 6
    assert_pids(name, @workers ++ @snapshot_workers)
  end

  for killed <- @workers do
    test "a kill of #{killed} restarts that worker only", %{name: name} do
      config = Config.parse!(server: @server, name: name, allowed_origins: [])

      start_supervised!({Core, config})
      start_supervised!({Workers, config})

      assert_restart_only(name, unquote(killed), @workers)
    end
  end

  for killed <- @snapshot_workers do
    test "a kill of #{killed} restarts that worker only", %{name: name} do
      config = snapshot_config(name)

      start_supervised!({Core, config})
      start_supervised!({Workers, config})

      assert_restart_only(name, unquote(killed), @workers ++ @snapshot_workers)
    end
  end

  defp snapshot_config(name) do
    Config.parse!(
      server: @server,
      name: name,
      allowed_origins: [],
      session_snapshot: PersistentSnapshot
    )
  end

  defp assert_pids(name, keys) do
    for key <- keys do
      assert {:ok, pid} = Instance.whereis(name, key)
      assert is_pid(pid)
    end
  end

  defp assert_restart_only(name, killed, keys) do
    {:ok, old} = Instance.whereis(name, killed)
    others = for other <- keys, other != killed, do: {other, pid_of(name, other)}

    Process.exit(old, :kill)

    assert Utils.eventually(fn -> restarted?(name, killed, old) end)

    for {other, pid} <- others do
      assert(Instance.whereis(name, other) == {:ok, pid},
        message: "#{other} restarted after a kill of #{killed}"
      )
    end
  end

  defp restarted?(name, key, old) do
    case Instance.whereis(name, key) do
      {:ok, new} -> new != old
      :not_running -> false
    end
  end

  defp pid_of(name, key) do
    {:ok, pid} = Instance.whereis(name, key)
    pid
  end
end
