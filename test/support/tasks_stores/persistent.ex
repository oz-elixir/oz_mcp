#
# A task store that keeps its records when the instance stops. It
# implements the whole contract through the facade with the default
# store behind it and its `init/1` does nothing: the test process calls
# the init of the facade with the default store before the start of the
# instance, so the tables belong to the test process. They survive the
# stop and the start of the instance and the test can read them and
# write in them while no instance runs.
#
defmodule Support.TasksStores.Persistent do
  @behaviour OzMcp.Tasks.StoreBehaviour

  alias OzMcp.Tasks.EtsStore
  alias OzMcp.Tasks.Records

  @impl true
  def init(_instance), do: :ok

  @impl true
  def put(instance, record), do: Records.put(EtsStore, instance, record)

  @impl true
  def get(instance, task_id), do: Records.get(EtsStore, instance, task_id)

  @impl true
  def delete(instance, record), do: Records.delete(EtsStore, instance, record)

  @impl true
  def page(instance, owner_key, after_seq, limit),
    do: Records.page(EtsStore, instance, owner_key, after_seq, limit)

  @impl true
  def count_active(instance, scope), do: Records.count_active(EtsStore, instance, scope)

  @impl true
  def expired(instance, now_ms, limit),
    do: Records.expired(EtsStore, instance, now_ms, limit)

  @impl true
  def next_expiry(instance), do: Records.next_expiry(EtsStore, instance)

  @impl true
  def owner_usage(instance, owner_key), do: Records.owner_usage(EtsStore, instance, owner_key)

  @impl true
  defdelegate active(instance), to: EtsStore
end
