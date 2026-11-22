defmodule OzMcp.PubSub.Registry do
  @moduledoc "The default `OzMcp.PubSub`: a duplicate `Registry` of the instance."

  @behaviour OzMcp.PubSub

  alias OzMcp.Instance

  @impl true
  def subscribe(instance, topic) do
    {:ok, _owner} = Registry.register(Instance.topics(instance), topic, nil)
    :ok
  end

  @impl true
  def unsubscribe(instance, topic), do: Registry.unregister(Instance.topics(instance), topic)

  @impl true
  def broadcast(instance, topic, message) do
    Registry.dispatch(Instance.topics(instance), topic, fn entries ->
      for {pid, _value} <- entries, do: send(pid, {:oz_mcp_broadcast, message})
    end)
  end
end
