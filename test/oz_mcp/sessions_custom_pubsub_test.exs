defmodule OzMcp.SessionsCustomPubSubTest do
  use ExUnit.Case, async: true

  alias OzMcp.Sessions
  alias Support.Helpers.Utils
  alias Support.Servers

  @server_module Servers.Default
  @null Module.concat([@server_module, __MODULE__, Null])
  @forward Module.concat([@server_module, __MODULE__, Forward])
  @alice {"https://issuer.test", "alice"}
  @bob {"https://issuer.test", "bob"}

  setup do
    Utils.start_instance(@server_module, name: @null, pubsub: Support.Helpers.NullPubSub)

    Utils.start_instance(@server_module,
      name: @forward,
      pubsub: Support.Helpers.ForwardPubSub
    )

    :ok
  end

  describe "terminate_principal/2 with a PubSub module that keeps no subscriber" do
    test "ends every session of the principal and no other session" do
      a1 = Utils.create_session(@null, principal_key: @alice, initialized: true)
      a2 = Utils.create_session(@null, principal_key: @alice)
      b1 = Utils.create_session(@null, principal_key: @bob, initialized: true)

      assert {:ok, ended} = Sessions.terminate_principal(@null, @alice)
      assert Enum.sort(ended) == Enum.sort([a1, a2])
      assert Sessions.state(@null, a1) == {:error, :no_session}
      assert Sessions.state(@null, a2) == {:error, :no_session}
      assert {:ok, %{initialized: true}} = Sessions.state(@null, b1)
    end

    test "list_principal/2 gives the same ids" do
      a1 = Utils.create_session(@null, principal_key: @alice)

      assert {:ok, [^a1]} = Sessions.list_principal(@null, @alice)
      assert {:ok, [^a1]} = Sessions.terminate_principal(@null, @alice)
    end
  end

  describe "a custom PubSub module" do
    test "gets the log broadcast of a principal through broadcast/3" do
      Utils.create_session(@forward, principal_key: @alice, initialized: true)

      log = %{"jsonrpc" => "2.0", "method" => "notifications/message", "params" => %{}}
      assert :ok = Sessions.notify_log_message(@forward, :info, log, @alice)

      assert_received {:test_pubsub_broadcast, {:principal, @alice}}
    end
  end
end
