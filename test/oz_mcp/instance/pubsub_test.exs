defmodule OzMcp.Instance.PubSubTest do
  use ExUnit.Case, async: true

  alias OzMcp.Instance.Config
  alias OzMcp.Instance.PubSub
  alias OzMcp.PubSub.PG
  alias Support.Helpers.Utils
  alias Support.Servers

  @server Servers.Default

  setup do
    name = Module.concat(@server, "PubSub#{System.unique_integer([:positive])}")

    %{name: name}
  end

  test "specs/2 gives no child for a module without child_specs/1", %{name: name} do
    config = Config.parse!(server: @server, name: name, allowed_origins: [])

    assert config.opts.pubsub == OzMcp.PubSub.Registry
    assert PubSub.specs(name, config) == []
  end

  test "specs/2 gives the children of a module with child_specs/1", %{name: name} do
    config = Config.parse!(server: @server, name: name, allowed_origins: [], pubsub: PG)

    assert [_child] = PubSub.specs(name, config)
  end

  @tag :capture_log
  test "the first crash of a pubsub child stops the supervisor", %{name: name} do
    config = Config.parse!(server: @server, name: name, allowed_origins: [], pubsub: PG)

    pubsub =
      start_supervised!({PubSub, {name, PubSub.specs(name, config)}}, restart: :temporary)

    scope = PG.scope(name)
    assert is_pid(Process.whereis(scope))

    ref = Process.monitor(pubsub)
    Process.exit(Process.whereis(scope), :kill)

    assert_receive {:DOWN, ^ref, :process, ^pubsub, _reason}, 5_000

    assert Utils.eventually(fn -> not is_pid(Process.whereis(scope)) end)
  end
end
