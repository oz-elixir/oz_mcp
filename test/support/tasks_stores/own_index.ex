#
# A task store that implements the whole contract, with an index of its
# own: it keeps no table of the facade and it needs no facade step
# around its writes. The tests of the facade use it to check that a
# store which owns its index is called directly.
#
defmodule Support.TasksStores.OwnIndex do
  @behaviour OzMcp.Tasks.StoreBehaviour

  def stored(instance), do: :persistent_term.get({__MODULE__, instance}, [])

  def clear(instance), do: :persistent_term.erase({__MODULE__, instance})

  defp record(instance, call, record),
    do: :persistent_term.put({__MODULE__, instance}, [{call, record} | stored(instance)])

  @impl true
  def init(_instance), do: :ok

  @impl true
  def put(instance, record) do
    record(instance, :put, record)
    :ok
  end

  @impl true
  def get(_instance, _task_id), do: :not_found

  @impl true
  def delete(instance, record) do
    record(instance, :delete, record)
    :ok
  end

  @impl true
  def page(_instance, _owner_key, _after_seq, _limit), do: {[], nil}

  @impl true
  def count_active(_instance, _key), do: 0

  @impl true
  def expired(_instance, _now_ms, _limit), do: []

  @impl true
  def next_expiry(_instance), do: nil

  @impl true
  def owner_usage(_instance, _owner_key), do: {0, 0}
end
