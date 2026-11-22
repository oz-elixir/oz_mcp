defmodule OzMcp.PubSubTest do
  #
  # Each test starts its own instance with a unique name, so the tests
  # run in parallel.
  #
  use ExUnit.Case, async: true

  use Support.Helpers.PubSubContract,
    module: OzMcp.PubSub.Registry,
    members: fn server, topic ->
      Registry.lookup(OzMcp.Instance.topics(server), topic)
    end

  alias OzMcp.Instance
  alias OzMcp.Instance.Config
  alias OzMcp.Sessions
  alias Support.Helpers.ChildPubSub
  alias Support.Helpers.SessionProbe
  alias Support.Helpers.Utils
  alias Support.Servers

  @server_module Servers.Default
  @uri "file:///a.md"

  setup do
    name = Module.concat(@server_module, "T#{System.unique_integer([:positive])}")
    Utils.start_instance(@server_module, name: name)
    %{server: name}
  end

  defp updated(uri),
    do: %{
      "jsonrpc" => "2.0",
      "method" => "notifications/resources/updated",
      "params" => %{"uri" => uri}
    }

  describe "OzMcp.PubSub.Registry" do
    test "the implementation starts no process" do
      refute function_exported?(OzMcp.PubSub.Registry, :child_specs, 1)
    end
  end

  describe "the broadcast to the sessions" do
    test "reaches only the sessions of the topic", %{server: server} do
      subscribed = Utils.create_session(server, initialized: true, streams: [self()])
      :ok = Sessions.subscribe(server, subscribed, @uri)

      Utils.create_session(server, initialized: true, streams: [self()])

      assert :ok = Sessions.notify_subscribers(server, @uri, updated(@uri))

      assert {_, %{"method" => "notifications/resources/updated"}} =
               Utils.receive_event(5_000)

      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    test "a session that unsubscribes gets no resources/updated", %{server: server} do
      session_id = Utils.create_session(server, initialized: true, streams: [self()])
      :ok = Sessions.subscribe(server, session_id, @uri)
      :ok = Sessions.unsubscribe(server, session_id, @uri)

      assert :ok = Sessions.notify_subscribers(server, @uri, updated(@uri))
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    test "a second subscribe does not duplicate the notification", %{server: server} do
      session_id = Utils.create_session(server, initialized: true, streams: [self()])
      :ok = Sessions.subscribe(server, session_id, @uri)
      :ok = Sessions.subscribe(server, session_id, @uri)

      assert :ok = Sessions.notify_subscribers(server, @uri, updated(@uri))

      assert {_, _} = Utils.receive_event(5_000)
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end

    test "a log message of a principal reaches only its sessions, with the level filter", %{
      server: server
    } do
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

    test "terminate_principal ends the sessions of the principal", %{server: server} do
      mine = Utils.create_session(server, principal_key: {"iss", "a"})
      other = Utils.create_session(server, initialized: true, principal_key: {"iss", "b"})

      assert {:ok, [^mine]} = Sessions.terminate_principal(server, {"iss", "a"})
      assert SessionProbe.initialized?(server, mine) == {:error, :no_session}
      assert SessionProbe.initialized?(server, other) == true
    end

    test "1,000 sessions get a list_changed with no central process", %{server: server} do
      sessions =
        for _ <- 1..1000 do
          Utils.create_session(server, initialized: true, streams: [self()])
        end

      assert length(sessions) == 1000

      message = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}
      assert :ok = Sessions.notify_all(server, message)

      for _ <- 1..1000, do: assert({_, ^message} = Utils.receive_event(5_000))
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100
    end
  end

  describe "the option pubsub" do
    test "defaults to OzMcp.PubSub.Registry" do
      config = Config.parse!(%{server: @server_module, allowed_origins: []})
      assert config.opts.pubsub == OzMcp.PubSub.Registry
    end

    test "refuses a module that is not a pubsub" do
      assert_raise ArgumentError, ~r/pubsub module .* must export/, fn ->
        Config.parse!(%{server: @server_module, allowed_origins: [], pubsub: String})
      end
    end
  end

  describe "the child specs of a PubSub module" do
    test "an instance starts the child specs of its PubSub module" do
      name = unique_name("Child")

      Utils.start_instance(@server_module, name: name, pubsub: ChildPubSub)

      assert is_pid(Process.whereis(ChildPubSub.probe(name)))
    end

    test "a module with no child_specs/1 still boots" do
      name = unique_name("NoChild")

      Utils.start_instance(@server_module, name: name, pubsub: Support.Helpers.NullPubSub)

      assert {:ok, %Config{}} = Instance.config(name)
    end

    test "a crash of a child of the PubSub module restarts the sessions" do
      name = unique_name("Restart")

      Utils.start_instance(@server_module, name: name, pubsub: ChildPubSub)
      session_id = Utils.create_session(name)
      assert {:ok, _pid} = Instance.whereis(name, {:session, session_id})

      Process.exit(Process.whereis(ChildPubSub.probe(name)), :kill)

      assert Utils.eventually(fn ->
               Instance.whereis(name, {:session, session_id}) == :not_running
             end)
    end
  end

  defp unique_name(tag),
    do: Module.concat(@server_module, "#{tag}#{System.unique_integer([:positive])}")
end
