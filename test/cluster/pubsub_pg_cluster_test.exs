defmodule OzMcp.PubSubPGClusterTest do
  #
  # The tests use fixed instance names and start other nodes, so they run
  # alone. The tag `:cluster` keeps them out of `mix test` and `mix ci`;
  # run them with `mix test.cluster`.
  #
  use ExUnit.Case, async: false

  alias OzMcp.Instance
  alias OzMcp.PubSub.PG
  alias OzMcp.Session
  alias OzMcp.Sessions
  alias Support.Helpers.ClusterNode
  alias Support.Helpers.Utils
  alias Support.Servers

  @moduletag :cluster

  @instance Servers.Default
  @uri "file:///a.md"
  @key {"iss", "cluster"}

  setup do
    {peer, node} = ClusterNode.start("peer")
    on_exit(fn -> ClusterNode.stop(peer) end)
    %{peer: peer, node: node}
  end

  defp updated(uri),
    do: %{
      "jsonrpc" => "2.0",
      "method" => "notifications/resources/updated",
      "params" => %{"uri" => uri}
    }

  # The same instance name on both nodes: a `Registry`, a `:pg` scope and a
  # supervisor name belong to one node, so the two instances do not collide.
  #
  defp start_pair(node, opts \\ []) do
    opts = Keyword.merge([server: @instance, name: @instance, pubsub: PG], opts)
    Utils.start_instance(@instance, Keyword.drop(opts, [:server]))
    :ok = ClusterNode.start_instance(node, opts)
  end

  test "a broadcast on node A reaches a subscriber on node B", %{node: node} do
    start_pair(node)
    ClusterNode.subscribe_and_forward(node, @instance, :initialized)
    wait_for_members(node, :initialized, 1)

    assert :ok = PG.broadcast(@instance, :initialized, :hello)
    assert_receive {:from_peer, {:oz_mcp_broadcast, :hello}}, 5_000
  end

  test "a resource update on node A reaches the session on node B", %{node: node} do
    start_pair(node)

    forwarder = ClusterNode.spawn_forwarder(node, self())

    session_id =
      ClusterNode.rpc(node, Utils, :create_session, [
        @instance,
        [initialized: true, streams: [forwarder]]
      ])

    assert :ok = ClusterNode.rpc(node, Sessions, :subscribe, [@instance, session_id, @uri])
    wait_for_members(node, {:subscription, @uri}, 1)

    assert :ok = Sessions.notify_subscribers(@instance, @uri, updated(@uri))

    assert_receive {:from_peer, {:oz_mcp_stream, _, {:event, _id, data}}}, 5_000

    assert %{"method" => "notifications/resources/updated", "params" => %{"uri" => @uri}} =
             data |> IO.iodata_to_binary() |> :json.decode()
  end

  test "a node that leaves gets no message and the other nodes still work", %{
    peer: peer,
    node: node
  } do
    start_pair(node)
    ClusterNode.subscribe_and_forward(node, @instance, :initialized)
    wait_for_members(node, :initialized, 1)

    assert ClusterNode.stop(peer) == :ok

    assert :ok = PG.subscribe(@instance, :initialized)
    assert :ok = PG.broadcast(@instance, :initialized, :after_leave)

    assert_receive {:oz_mcp_broadcast, :after_leave}, 5_000
    refute_receive {:from_peer, _}, 100
  end

  test "terminate_principal/2 ends the local sessions only", %{node: node} do
    start_pair(node)

    local_id = Utils.create_session(@instance, principal_key: @key)

    remote_id =
      ClusterNode.rpc(node, Utils, :create_session, [
        @instance,
        [principal_key: @key]
      ])

    assert {:ok, [_id]} = Sessions.terminate_principal(@instance, @key)

    assert Utils.eventually(fn ->
             Instance.whereis(@instance, {:session, local_id}) == :not_running
           end)

    assert {:ok, _view} = ClusterNode.rpc(node, Sessions, :lookup, [@instance, remote_id])
  end

  test "the limit of sessions for a principal is local to a node", %{node: node} do
    start_pair(node, max_sessions_per_principal: 2)

    # The sessions hold a stream, so the reclaim cannot end them and the
    # limit is the only answer of a third start.
    #
    for _ <- 1..2 do
      assert {:ok, id} = Sessions.start(@instance, principal_key: @key)
      assert {:ok, _} = Session.open_stream(@instance, id, :get, self(), nil)
    end

    for _ <- 1..2 do
      assert {:ok, id} =
               ClusterNode.rpc(node, Sessions, :start, [@instance, [principal_key: @key]])

      assert {:ok, _} =
               ClusterNode.rpc(node, Session, :open_stream, [@instance, id, :get, self(), nil])
    end

    assert {:error, :too_many_sessions} = Sessions.start(@instance, principal_key: @key)

    assert {:error, :too_many_sessions} =
             ClusterNode.rpc(node, Sessions, :start, [@instance, [principal_key: @key]])
  end

  # A short loop with a time limit: the membership of `:pg` reaches the
  # nodes after a short time.
  #
  defp wait_for_members(node, topic, count) do
    assert Utils.eventually(fn ->
             node
             |> members(topic)
             |> length() == count
           end)
  end

  defp members(node, topic),
    do: ClusterNode.rpc(node, :pg, :get_members, [PG.scope(@instance), topic])
end
