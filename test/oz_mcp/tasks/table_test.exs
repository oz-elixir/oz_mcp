defmodule OzMcp.Tasks.TableTest do
  use ExUnit.Case, async: true

  alias OzMcp.Tasks.EtsStore
  alias OzMcp.Tasks.Index
  alias Support.Helpers.Utils
  alias Support.Servers

  @server Module.concat(Servers.TasksTest, __MODULE__)

  setup do
    Utils.start_instance(Servers.TasksTest, name: @server)
    :ok
  end

  test "the owner process holds the four tables of the instance" do
    assert {:ok, owner} = OzMcp.Instance.whereis(@server, :tasks_table)

    for name <- [
          EtsStore.table(@server),
          Index.index_table(@server),
          Index.expiry_table(@server),
          Index.counters_table(@server)
        ] do
      assert :ets.info(name, :owner) == owner
      assert :ets.info(name, :protection) == :public
    end

    assert :ets.info(EtsStore.table(@server), :type) == :set
    assert :ets.info(Index.index_table(@server), :type) == :ordered_set
    assert :ets.info(Index.expiry_table(@server), :type) == :ordered_set
    assert :ets.info(Index.counters_table(@server), :type) == :set
  end

  test "a request process can write a record directly" do
    now = DateTime.utc_now()

    record = %EtsStore{
      task_id: "direct",
      session_id: "s",
      owner_key: "s",
      seq: 1,
      status: :working,
      created_at: now,
      last_updated_at: now
    }

    task = Task.async(fn -> EtsStore.put(@server, record) end)
    assert Task.await(task, 30_000) == :ok
    assert {:ok, ^record} = EtsStore.get(@server, "direct")
  end
end
