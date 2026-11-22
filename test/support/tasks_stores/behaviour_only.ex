#
# A task store with the four required callbacks of
# OzMcp.Tasks.StoreBehaviour, each of them a delegate to the default
# store. It implements none of the optional index callbacks, so the
# facade keeps the default index for it. The boot of the runtime must
# accept it: the check of the `:task_store` option asks for the required
# functions and nothing else.
#
defmodule Support.TasksStores.BehaviourOnly do
  @behaviour OzMcp.Tasks.StoreBehaviour

  @impl true
  defdelegate init(instance), to: OzMcp.Tasks.EtsStore

  @impl true
  defdelegate put(instance, record), to: OzMcp.Tasks.EtsStore

  @impl true
  defdelegate get(instance, task_id), to: OzMcp.Tasks.EtsStore

  @impl true
  defdelegate delete(instance, record), to: OzMcp.Tasks.EtsStore
end
