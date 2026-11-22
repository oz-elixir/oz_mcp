defmodule OzMcp.Session.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias OzMcp.Session.{Core, Subscriptions, View}
  alias OzMcp.Session.Snapshot.None

  defp core(attrs \\ []) do
    view = struct!(%View{}, Keyword.get(attrs, :view, []))

    opts =
      Map.merge(
        %{session_snapshot: None, max_subscriptions_per_session: 10},
        Map.new(Keyword.get(attrs, :opts, []))
      )

    struct!(
      %Core{
        instance: __MODULE__,
        id: "session",
        view: view,
        opts: opts
      },
      Keyword.take(attrs, [:subscriptions, :subscription_scopes])
    )
  end

  test "a new subscription joins the topic and stores the URI" do
    core = core(view: [initialized: true])

    assert {core, effects} = Subscriptions.subscribe(core, "file:///a.md", [])

    assert effects == [
             {:pubsub, :subscribe, {:subscription, "file:///a.md"}},
             {:reply, :ok}
           ]

    assert core.subscriptions == MapSet.new(["file:///a.md"])
  end

  test "a new subscription of a session that is not initialized joins no topic" do
    core = core()

    assert {core, effects} = Subscriptions.subscribe(core, "file:///a.md", [])

    assert effects == [{:reply, :ok}]
    assert core.subscriptions == MapSet.new(["file:///a.md"])
  end

  test "the pubsub effect goes before the write of the snapshot and the reply" do
    core = core(opts: [session_snapshot: FakeSnapshot], view: [initialized: true])

    assert {_core, effects} = Subscriptions.subscribe(core, "file:///a.md", ["files:read"])

    assert [
             {:pubsub, :subscribe, {:subscription, "file:///a.md"}},
             {:snapshot, :save, snapshot},
             {:reply, :ok}
           ] = effects

    assert snapshot.subscriptions == ["file:///a.md"]
  end

  test "a repeat subscribe replaces the scopes and joins nothing again" do
    core =
      core(
        view: [initialized: true],
        subscriptions: MapSet.new(["file:///a.md"]),
        subscription_scopes: %{"file:///a.md" => ["files:write"]}
      )

    assert {core, effects} = Subscriptions.subscribe(core, "file:///a.md", ["files:read"])

    assert effects == [{:reply, :ok}]
    assert core.subscription_scopes == %{"file:///a.md" => ["files:read"]}
  end

  test "an empty list of scopes removes the entry of the scopes" do
    core =
      core(
        subscriptions: MapSet.new(["file:///a.md"]),
        subscription_scopes: %{"file:///a.md" => ["files:write"]}
      )

    assert {core, [{:reply, :ok}]} = Subscriptions.subscribe(core, "file:///a.md", [])
    assert core.subscription_scopes == %{}
  end

  test "the scopes are stored unique and sorted" do
    core = core()

    assert {core, _effects} =
             Subscriptions.subscribe(core, "file:///a.md", ["b", "a", "b"])

    assert core.subscription_scopes == %{"file:///a.md" => ["a", "b"]}
  end

  test "a new subscription over the limit is refused and stores nothing" do
    core =
      core(
        opts: [max_subscriptions_per_session: 1],
        view: [initialized: true],
        subscriptions: MapSet.new(["file:///a.md"])
      )

    assert {^core, effects} = Subscriptions.subscribe(core, "file:///b.md", [])

    assert effects == [
             {:limit, :max_subscriptions_per_session, 1},
             {:reply, {:error, :too_many_subscriptions}}
           ]
  end

  test "a repeat subscribe at the limit is accepted" do
    core =
      core(
        opts: [max_subscriptions_per_session: 1],
        subscriptions: MapSet.new(["file:///a.md"])
      )

    assert {_core, [{:reply, :ok}]} = Subscriptions.subscribe(core, "file:///a.md", [])
  end

  test "the limit is nil when the session has none" do
    core = core(opts: [max_subscriptions_per_session: nil])

    refute Subscriptions.full?(core)
  end

  test "full? counts the URIs of the set" do
    core = core(opts: [max_subscriptions_per_session: 2])
    refute Subscriptions.full?(core)

    core = %{core | subscriptions: MapSet.new(["file:///a.md", "file:///b.md"])}
    assert Subscriptions.full?(core)
  end

  test "an unsubscribe leaves the topic and removes the subscription" do
    core =
      core(
        subscriptions: MapSet.new(["file:///a.md"]),
        subscription_scopes: %{"file:///a.md" => ["files:read"]}
      )

    assert {core, effects} = Subscriptions.unsubscribe(core, "file:///a.md")

    assert effects == [
             {:pubsub, :unsubscribe, {:subscription, "file:///a.md"}},
             {:reply, :ok}
           ]

    assert core.subscriptions == MapSet.new()
    assert core.subscription_scopes == %{}
  end

  test "a touch with no granted scopes checks nothing" do
    core = core(subscription_scopes: %{"file:///a.md" => ["files:read"]})

    assert {^core, []} = Subscriptions.drop_lost_scopes(core, nil)
  end

  test "a touch with no scoped subscription checks nothing" do
    core = core(subscriptions: MapSet.new(["file:///a.md"]))

    assert {^core, []} = Subscriptions.drop_lost_scopes(core, [])
  end

  test "a touch with all the scopes keeps the subscription" do
    core = core(subscription_scopes: %{"file:///a.md" => ["files:read"]})

    assert {^core, []} = Subscriptions.drop_lost_scopes(core, ["files:read", "files:write"])
  end

  test "a touch with fewer scopes ends the subscription and reports the drop" do
    core =
      core(
        subscriptions: MapSet.new(["file:///a.md", "file:///b.md"]),
        subscription_scopes: %{
          "file:///a.md" => ["files:write"],
          "file:///b.md" => ["files:read"]
        }
      )

    assert {core, effects} = Subscriptions.drop_lost_scopes(core, ["files:read"])

    assert effects == [
             {:pubsub, :unsubscribe, {:subscription, "file:///a.md"}},
             {:telemetry, :subscription_dropped, %{count: 1}, %{reason: :scope}}
           ]

    assert core.subscriptions == MapSet.new(["file:///b.md"])
    assert core.subscription_scopes == %{"file:///b.md" => ["files:read"]}
  end

  test "the drop writes the snapshot when the module holds one" do
    core =
      core(
        opts: [session_snapshot: FakeSnapshot],
        view: [initialized: true],
        subscriptions: MapSet.new(["file:///a.md"]),
        subscription_scopes: %{"file:///a.md" => ["files:write"]}
      )

    assert {_core, effects} = Subscriptions.drop_lost_scopes(core, [])

    assert [
             {:pubsub, :unsubscribe, {:subscription, "file:///a.md"}},
             {:telemetry, :subscription_dropped, %{count: 1}, %{reason: :scope}},
             {:snapshot, :save, snapshot}
           ] = effects

    assert snapshot.subscriptions == []
  end

  test "the topics of a session are initialized and its subscriptions" do
    core =
      core(subscriptions: MapSet.new(["file:///a.md", "file:///b.md"]))

    assert {^core, effects} = Subscriptions.topics(core)

    assert [{:pubsub, :subscribe, :initialized} | topics] = effects

    assert Enum.sort(topics) == [
             {:pubsub, :subscribe, {:subscription, "file:///a.md"}},
             {:pubsub, :subscribe, {:subscription, "file:///b.md"}}
           ]
  end
end
