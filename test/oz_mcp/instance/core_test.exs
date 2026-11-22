defmodule OzMcp.Instance.CoreTest do
  use ExUnit.Case, async: true

  alias OzMcp.Instance
  alias OzMcp.Instance.Config
  alias OzMcp.Instance.Core
  alias OzMcp.Tasks.EtsStore
  alias OzMcp.Tasks.Records
  alias Support.Helpers.Utils
  alias Support.Servers

  @server Servers.Default

  setup do
    name = Module.concat(@server, "Core#{System.unique_integer([:positive])}")
    config = Config.parse!(server: @server, name: name, allowed_origins: [])

    %{config: config, name: name}
  end

  test "starts the four children and publishes the config", %{config: config, name: name} do
    core = start_supervised!({Core, config})

    assert is_pid(core)
    assert is_pid(Process.whereis(Instance.names(name)))
    assert is_pid(Process.whereis(Instance.topics(name)))
    assert is_pid(Process.whereis(Instance.principals(name)))
    assert {:ok, table} = Instance.whereis(name, :tasks_table)
    assert is_pid(table)
    assert Instance.config(name) == {:ok, config}
  end

  test "a kill of a Registry stops Core and starts four new children", %{
    config: config,
    name: name
  } do
    core = start_supervised!({Core, config})
    {names, topics, principals, table} = child_pids(name)
    ref = Process.monitor(core)

    Process.exit(topics, :kill)

    assert_receive {:DOWN, ^ref, :process, ^core, _reason}, 5_000

    assert Utils.eventually(fn ->
             new_core = core_pid()
             is_pid(new_core) and new_core != core
           end)

    assert Utils.eventually(fn ->
             {new_names, new_topics, new_principals, new_table} = child_pids(name)

             Enum.all?([new_names, new_topics, new_principals, new_table], &is_pid/1) and
               new_names != names and new_topics != topics and
               new_principals != principals and new_table != table
           end)

    assert Instance.config(name) == {:ok, config}
  end

  test "a kill of the task table owner empties the store and restarts the Registries", %{
    config: config,
    name: name
  } do
    start_supervised!({Core, config})
    record = record()
    :ok = Records.put(EtsStore, name, record)
    assert {:ok, _} = EtsStore.get(name, record.task_id)

    {names, topics, principals, table} = child_pids(name)

    Process.exit(table, :kill)

    assert Utils.eventually(fn ->
             {new_names, new_topics, new_principals, new_table} = child_pids(name)

             is_pid(new_table) and new_table != table and new_names != names and
               new_topics != topics and new_principals != principals
           end)

    assert Utils.eventually(fn -> :ets.whereis(EtsStore.table(name)) != :undefined end)
    assert EtsStore.get(name, record.task_id) == :not_found
  end

  defp child_pids(name) do
    table =
      case Instance.whereis(name, :tasks_table) do
        {:ok, pid} -> pid
        :not_running -> nil
      end

    {
      Process.whereis(Instance.names(name)),
      Process.whereis(Instance.topics(name)),
      Process.whereis(Instance.principals(name)),
      table
    }
  end

  defp core_pid do
    {:ok, supervisor} = ExUnit.fetch_test_supervisor()

    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {Core, pid, :supervisor, _modules} when is_pid(pid) -> pid
      _other -> nil
    end)
  end

  defp record do
    now = DateTime.utc_now()

    %EtsStore{
      task_id: OzMcp.Utils.Generator.task_id(),
      session_id: "session",
      owner_key: {:session, "session"},
      seq: System.unique_integer([:positive]),
      status: :completed,
      created_at: now,
      last_updated_at: now
    }
  end
end
