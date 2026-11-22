#
# A PubSub that uses `OzMcp.PubSub.Registry` and sends
# `{:test_pubsub_broadcast, topic}` to the caller of each broadcast.
# It is a test double for the behaviour.
#
defmodule Support.Helpers.ForwardPubSub do
  @behaviour OzMcp.PubSub

  alias OzMcp.PubSub.Registry, as: Default

  @impl true
  def subscribe(instance, topic), do: Default.subscribe(instance, topic)

  @impl true
  def unsubscribe(instance, topic), do: Default.unsubscribe(instance, topic)

  @impl true
  def broadcast(instance, topic, message) do
    send(self(), {:test_pubsub_broadcast, topic})
    Default.broadcast(instance, topic, message)
  end
end
