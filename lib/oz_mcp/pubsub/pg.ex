defmodule OzMcp.PubSub.PG do
  @moduledoc """
  An `OzMcp.PubSub` that uses `:pg` (Erlang process groups).

  The module sends a broadcast to the sessions of all the nodes that are
  connected and run the same instance. Set it in the child spec:

      {OzMcp, server: MyApp.McpServer, pubsub: OzMcp.PubSub.PG, ...}

  Rules:

    * The instance has the same name on every node.
    * The nodes are connected (Erlang distribution). OzMcp does not connect
      them.
    * The delivery is "at most once". There is no acknowledgement and no
      order between two senders. A node that has just joined the cluster can
      miss a broadcast for a short time, until `:pg` has synchronised its
      groups.
    * A node that is cut from the cluster gets no broadcast. The sessions of
      the other nodes get it. The groups are synchronised again when the
      nodes connect.

  `OzMcp.Sessions.list_principal/2` and `OzMcp.Sessions.terminate_principal/2`
  read the sessions of the local node only.
  """

  @behaviour OzMcp.PubSub

  @doc "The name of the `:pg` scope of the instance."
  @spec scope(atom()) :: atom()
  def scope(instance), do: Module.concat(instance, PG)

  @impl true
  def child_specs(instance) do
    [%{id: {__MODULE__, instance}, start: {__MODULE__, :start_scope, [instance]}}]
  end

  # The wait of the instance start: after a `:kill` of the instance, the
  # old scope can still hold its name for a short time.
  #
  @doc false
  @spec start_scope(atom()) :: {:ok, pid()} | {:error, term()}
  def start_scope(instance) do
    OzMcp.Instance.start_retry(fn -> :pg.start_link(scope(instance)) end)
  end

  @impl true
  def subscribe(instance, topic) do
    :ok = :pg.join(scope(instance), topic, self())
  end

  @impl true
  def unsubscribe(instance, topic) do
    #
    # `:not_joined` means there is nothing to remove.
    #
    _ = :pg.leave(scope(instance), topic, self())
    :ok
  end

  @impl true
  def broadcast(instance, topic, message) do
    scope(instance)
    |> :pg.get_members(topic)
    |> Enum.each(&send(&1, {:oz_mcp_broadcast, message}))
  end
end
