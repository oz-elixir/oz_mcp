#
# A PubSub that keeps no subscriber. It is a test double for the behaviour.
#
defmodule Support.Helpers.NullPubSub do
  @behaviour OzMcp.PubSub

  @impl true
  def subscribe(_instance, _topic), do: :ok

  @impl true
  def unsubscribe(_instance, _topic), do: :ok

  @impl true
  def broadcast(_instance, _topic, _message), do: :ok
end
