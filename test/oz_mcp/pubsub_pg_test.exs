defmodule OzMcp.PubSubPGTest do
  #
  # Each test starts its own instance with a unique name, so the tests
  # run in parallel: the `:pg` scope belongs to the instance.
  #
  use ExUnit.Case, async: true

  use Support.Helpers.PubSubContract,
    module: OzMcp.PubSub.PG,
    members: fn server, topic -> :pg.get_members(OzMcp.PubSub.PG.scope(server), topic) end

  alias OzMcp.Instance
  alias OzMcp.PubSub.PG
  alias OzMcp.Sessions
  alias Support.Helpers.Utils
  alias Support.Servers

  @server_module Servers.Default
  @uri "file:///a.md"

  setup do
    name = Module.concat(@server_module, "PG#{System.unique_integer([:positive])}")
    Utils.start_instance(@server_module, name: name, pubsub: PG)
    %{server: name}
  end

  defp updated(uri),
    do: %{
      "jsonrpc" => "2.0",
      "method" => "notifications/resources/updated",
      "params" => %{"uri" => uri}
    }

  test "the instance starts the :pg scope", %{server: server} do
    assert is_pid(Process.whereis(PG.scope(server)))
  end

  test "a subscription reaches the session through the scope", %{server: server} do
    subscribed = Utils.create_session(server, initialized: true, streams: [self()])
    :ok = Sessions.subscribe(server, subscribed, @uri)

    Utils.create_session(server, initialized: true, streams: [self()])

    assert :ok = Sessions.notify_subscribers(server, @uri, updated(@uri))

    assert {_, %{"method" => "notifications/resources/updated"}} =
             Utils.receive_event(5_000)

    refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
  end

  test "a log message of a principal reaches only its sessions", %{server: server} do
    key = {"iss", "a"}

    mine =
      Utils.create_session(server,
        initialized: true,
        principal_key: key,
        streams: [self()]
      )

    other =
      Utils.create_session(server,
        initialized: true,
        principal_key: {"iss", "b"},
        streams: [self()]
      )

    quiet =
      Utils.create_session(server,
        initialized: true,
        principal_key: key,
        streams: [self()]
      )

    :ok = Sessions.set_log_level(server, mine, :info)
    :ok = Sessions.set_log_level(server, other, :info)
    :ok = Sessions.set_log_level(server, quiet, :error)

    log = %{"jsonrpc" => "2.0", "method" => "notifications/message", "params" => %{}}
    assert :ok = Sessions.notify_log_message(server, :info, log, key)

    assert {_, ^log} = Utils.receive_event(5_000)
    refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
  end

  test "the broadcast message is a plain term", %{server: server} do
    topic = {:subscription, @uri}
    message = {:session_event, {:log, :info}, "{}"}

    :ok = PG.subscribe(server, topic)
    :ok = PG.broadcast(server, topic, message)

    assert_receive {:oz_mcp_broadcast, ^message}

    assert message |> :erlang.term_to_binary() |> :erlang.binary_to_term() == message
  end

  @tag :capture_log
  test "a kill of the :pg scope restarts the sessions", %{server: server} do
    session_id = Utils.create_session(server)
    assert {:ok, _pid} = Instance.whereis(server, {:session, session_id})
    old_scope = Process.whereis(PG.scope(server))

    Process.exit(old_scope, :kill)

    assert Utils.eventually(fn ->
             Instance.whereis(server, {:session, session_id}) == :not_running
           end)

    assert Utils.eventually(fn ->
             is_pid(Process.whereis(PG.scope(server))) and
               Process.whereis(PG.scope(server)) != old_scope
           end)
  end

  @tag :capture_log
  test "a kill of the instance supervisor lets the same instance start again" do
    name = Module.concat(@server_module, "PGKill#{System.unique_integer([:positive])}")

    opts = [server: @server_module, name: name, allowed_origins: [], pubsub: PG]

    supervisor =
      start_supervised!({OzMcp, opts}, id: {:instance, name}, restart: :temporary)

    assert is_pid(Process.whereis(PG.scope(name)))

    Process.exit(supervisor, :kill)
    assert Utils.eventually(fn -> not Process.alive?(supervisor) end)

    start_supervised!({OzMcp, opts}, id: {:instance, name}, restart: :temporary)

    assert {:ok, %OzMcp.Instance.Config{}} = Instance.config(name)
    assert is_pid(Process.whereis(PG.scope(name)))
  end
end
