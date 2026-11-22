#
# A task store that has four of the five optional index callbacks but
# not page/4. The boot of the runtime must refuse it: the optional
# callbacks go together, all of them or none of them.
#
defmodule Support.TasksStores.NoPage do
  defdelegate init(server_id), to: OzMcp.Tasks.EtsStore
  defdelegate get(server_id, task_id), to: OzMcp.Tasks.EtsStore
  defdelegate delete(server_id, record), to: OzMcp.Tasks.EtsStore
  defdelegate put(server_id, record), to: OzMcp.Tasks.EtsStore

  # The three callbacks below exist only to make the set partial: the
  # boot refuses the module before the first call.
  #
  def count_active(server_id, scope), do: OzMcp.Tasks.Index.count_active(server_id, scope)

  def expired(server_id, now_ms, limit),
    do: OzMcp.Tasks.Index.expired(OzMcp.Tasks.EtsStore, server_id, now_ms, limit)

  def next_expiry(server_id), do: OzMcp.Tasks.Index.next_expiry(server_id)

  def owner_usage(server_id, owner_key),
    do: OzMcp.Tasks.Index.owner_usage(server_id, owner_key)
end
