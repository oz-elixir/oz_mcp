#
# A second Erlang node for the tests with the tag `:cluster`.
#
# The node runs the code of this build (`_build/test`), so the server
# modules of the tests exist on it. The tests start an instance on the node
# with the same name as the local instance and connect the two nodes
# through the distribution.
#
defmodule Support.Helpers.ClusterNode do
  #
  # Starts a peer node with the code paths of this node. Returns
  # `{peer, node}`. The caller must stop the peer with `:peer.stop/1`.
  #
  @spec start(String.t()) :: {:peer.ref(), node()}
  def start(name) do
    #
    # `:peer.start/1`, not `start_link/1`: a linked peer ends with the test
    # process and `:peer.stop/1` in `on_exit` then exits with `:noproc`.
    #
    {:ok, peer, node} =
      :peer.start(%{
        name: String.to_atom("#{name}#{System.unique_integer([:positive])}"),
        host: ~c"127.0.0.1",
        longnames: true
      })

    :ok = :erpc.call(node, :code, :add_paths, [:code.get_path()])
    {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:elixir])
    {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:oz_mcp])
    {peer, node}
  end

  # Stops the peer node. A test that already stopped it gets `:ok`.
  #
  @spec stop(pid()) :: :ok | {:error, term()}
  def stop(peer) do
    if Process.alive?(peer), do: :peer.stop(peer), else: :ok
  end

  # Calls a function on the node.
  #
  @spec rpc(node(), module(), atom(), list()) :: term()
  def rpc(node, mod, fun, args), do: :erpc.call(node, mod, fun, args)

  # Starts an instance on the node and waits for it. `:erpc` runs in a short
  # process and a supervisor stops with its parent, so a process stays on the
  # node to hold the instance.
  #
  @spec start_instance(node(), keyword()) :: :ok
  def start_instance(node, opts) do
    pid = Node.spawn(node, __MODULE__, :hold_instance, [opts, self()])

    receive do
      {:instance_up, ^pid} -> :ok
    after
      5_000 -> raise "no instance on #{node}"
    end
  end

  @doc false
  @spec hold_instance(keyword(), pid()) :: no_return()
  def hold_instance(opts, caller) do
    {:ok, _} = Supervisor.start_link([{OzMcp, opts}], strategy: :one_for_one)
    send(caller, {:instance_up, self()})
    Process.sleep(:infinity)
  end

  # A process on the node that subscribes to the topic and forwards each
  # message to the caller of the test as `{:from_peer, message}`.
  #
  @spec subscribe_and_forward(node(), atom(), term()) :: pid()
  def subscribe_and_forward(node, instance, topic) do
    Node.spawn(node, __MODULE__, :subscribe_and_forward_on_node, [
      instance,
      topic,
      self()
    ])
  end

  @doc false
  @spec subscribe_and_forward_on_node(atom(), term(), pid()) :: no_return()
  def subscribe_and_forward_on_node(instance, topic, target) do
    :ok = OzMcp.PubSub.PG.subscribe(instance, topic)
    forward_loop(target)
  end

  # A process on the node that forwards each message to the caller of the test
  # as `{:from_peer, message}`. The tests use it as the stream of a session.
  #
  @spec spawn_forwarder(node(), pid()) :: pid()
  def spawn_forwarder(node, target), do: Node.spawn(node, __MODULE__, :forward, [target])

  @doc false
  @spec forward(pid()) :: no_return()
  def forward(target), do: forward_loop(target)

  defp forward_loop(target) do
    receive do
      message -> send(target, {:from_peer, message})
    end

    forward_loop(target)
  end
end
