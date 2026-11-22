#
# A PubSub that uses `OzMcp.PubSub.Registry` and starts an `Agent` for each
# instance. It is a test double for the optional `child_specs/1` callback.
#
defmodule Support.Helpers.ChildPubSub do
  @behaviour OzMcp.PubSub

  alias OzMcp.PubSub.Registry, as: Default

  # The name of the `Agent` that the instance starts for this module.
  #
  @spec probe(atom()) :: atom()
  def probe(instance), do: Module.concat(instance, Probe)

  @impl true
  def child_specs(instance) do
    [
      %{
        id: {__MODULE__, instance},
        start: {Agent, :start_link, [fn -> :ok end, [name: probe(instance)]]}
      }
    ]
  end

  @impl true
  def subscribe(instance, topic), do: Default.subscribe(instance, topic)

  @impl true
  def unsubscribe(instance, topic), do: Default.unsubscribe(instance, topic)

  @impl true
  def broadcast(instance, topic, message), do: Default.broadcast(instance, topic, message)
end
