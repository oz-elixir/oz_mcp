#
# A task store that wraps the default store and counts the calls of the
# four required callbacks. The manager must call the module of the
# `:task_store` option for every required store call, so a test can arm
# `reset/0`, run a task through its lifecycle and read the counter with
# `calls/0`. The optional index callbacks are not part of this contract:
# the facade keeps the default index for the store.
#
defmodule Support.TasksStores.Counting do
  def reset, do: :persistent_term.put({__MODULE__, :calls}, %{})

  def calls, do: :persistent_term.get({__MODULE__, :calls}, %{})

  defp count(function) do
    key = {__MODULE__, :calls}

    # Several processes call the store (the manager and the reaper): the
    # read-modify-write of the counters takes a lock.
    #
    :global.trans({{__MODULE__, :lock}, self()}, fn ->
      :persistent_term.put(
        key,
        :persistent_term.get(key, %{}) |> Map.update(function, 1, &(&1 + 1))
      )
    end)
  end

  def init(server_id) do
    count(:init)
    OzMcp.Tasks.EtsStore.init(server_id)
  end

  def get(server_id, task_id) do
    count(:get)
    OzMcp.Tasks.EtsStore.get(server_id, task_id)
  end

  def delete(server_id, record) do
    count(:delete)
    OzMcp.Tasks.EtsStore.delete(server_id, record)
  end

  def put(server_id, record) do
    count(:put)
    OzMcp.Tasks.EtsStore.put(server_id, record)
  end
end
