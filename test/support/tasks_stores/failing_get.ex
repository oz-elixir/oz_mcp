#
# A task store with the four required callbacks of
# OzMcp.Tasks.StoreBehaviour. It implements none of the optional index
# callbacks, so the facade keeps the default index for it. A test arms
# the store and the `get/2` of the store answers `{:error, :boom}`
# until the test clears it. The other callbacks stay honest, so a test
# can see what a read error of the store does to the index of the
# facade.
#
defmodule Support.TasksStores.FailingGet do
  @behaviour OzMcp.Tasks.StoreBehaviour

  def arm(instance), do: :persistent_term.put({__MODULE__, instance}, true)

  def clear(instance), do: :persistent_term.erase({__MODULE__, instance})

  def clear_instance(instance) do
    for {key, _value} <- :persistent_term.get(),
        match?({__MODULE__, ^instance}, key) do
      :persistent_term.erase(key)
    end

    :ok
  end

  @impl true
  defdelegate init(instance), to: OzMcp.Tasks.EtsStore

  @impl true
  defdelegate put(instance, record), to: OzMcp.Tasks.EtsStore

  @impl true
  defdelegate delete(instance, record), to: OzMcp.Tasks.EtsStore

  @impl true
  def get(instance, task_id) do
    if :persistent_term.get({__MODULE__, instance}, false) do
      {:error, :boom}
    else
      OzMcp.Tasks.EtsStore.get(instance, task_id)
    end
  end
end
