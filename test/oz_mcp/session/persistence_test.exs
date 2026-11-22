defmodule OzMcp.Session.PersistenceTest do
  use ExUnit.Case, async: true

  alias OzMcp.Session.{Core, Persistence, View}
  alias OzMcp.Session.Snapshot.None

  defp core(attrs \\ []) do
    view =
      struct!(
        %View{},
        Keyword.merge(
          [principal_key: nil, protocol_version: "2025-06-18", client_info: %{}],
          Keyword.get(attrs, :view, [])
        )
      )

    opts =
      Map.merge(
        %{session_snapshot: None},
        Map.new(Keyword.get(attrs, :opts, []))
      )

    struct!(
      %Core{
        instance: __MODULE__,
        id: "session",
        view: view,
        opts: opts
      },
      Keyword.take(attrs, [:subscriptions, :subscription_scopes, :saved, :retired])
    )
  end

  test "the persistent part sorts the subscriptions and holds no empty scopes" do
    core =
      core(
        subscriptions: MapSet.new(["file:///b.md", "file:///a.md"]),
        view: [principal_key: "user@example.com", log_level: :debug]
      )

    assert Persistence.persistent(core) == %{
             principal_key: "user@example.com",
             protocol_version: "2025-06-18",
             client_info: %{},
             client_capabilities: %{},
             log_level: :debug,
             subscriptions: ["file:///a.md", "file:///b.md"]
           }
  end

  test "the persistent part holds the scopes when it has an entry" do
    scopes = %{"file:///a.md" => ["read"]}
    core = core(subscriptions: MapSet.new(["file:///a.md"]), subscription_scopes: scopes)

    assert Persistence.persistent(core).subscription_scopes == scopes
  end

  test "hold/1 sets the saved snapshot to the persistent part" do
    core = core(subscriptions: MapSet.new(["file:///a.md"]), view: [initialized: true])

    held = Persistence.hold(core)

    assert held.saved == Persistence.persistent(core)
  end

  test "a session with no snapshot module holds no saved snapshot" do
    core = core(view: [initialized: true])

    assert {^core, []} = Persistence.save(core)
  end

  test "a retired session writes no snapshot" do
    core = core(opts: [session_snapshot: FakeSnapshot], retired: true, view: [initialized: true])

    assert {^core, []} = Persistence.save(core)
  end

  test "a session that is not initialized writes no snapshot" do
    core = core(opts: [session_snapshot: FakeSnapshot])

    assert {^core, []} = Persistence.save(core)
  end

  test "a change that gives the snapshot of the last write writes nothing" do
    core = core(opts: [session_snapshot: FakeSnapshot], view: [initialized: true])
    core = %{core | saved: Persistence.persistent(core)}

    assert {^core, []} = Persistence.save(core)
  end

  test "a change that gives another snapshot stores it and writes it" do
    core =
      core(
        opts: [session_snapshot: FakeSnapshot],
        view: [initialized: true, log_level: :warning],
        subscriptions: MapSet.new(["file:///a.md"])
      )

    snapshot = Persistence.persistent(core)

    assert {%Core{saved: ^snapshot}, [{:snapshot, :save, ^snapshot}]} = Persistence.save(core)
  end

  test "a retire with no snapshot module only leaves the Registry" do
    core = core()

    assert {%Core{retired: true}, [{:unregister, :names}]} = Persistence.retire(core)
  end

  test "a retire writes the tombstone and deletes the snapshot before it leaves the Registry" do
    core = core(opts: [session_snapshot: FakeSnapshot])

    assert {%Core{retired: true}, effects} = Persistence.retire(core)

    assert effects == [
             {:tombstone, "session"},
             {:snapshot, :delete},
             {:unregister, :names}
           ]
  end

  test "a retire with a principal key leaves the principal first" do
    core = core(opts: [session_snapshot: FakeSnapshot], view: [principal_key: "user@example.com"])

    assert {%Core{retired: true}, effects} = Persistence.retire(core)

    assert effects == [
             {:tombstone, "session"},
             {:snapshot, :delete},
             {:unregister, :principals},
             {:unregister, :names}
           ]
  end

  test "a second retire does nothing" do
    core = core(opts: [session_snapshot: FakeSnapshot], retired: true)

    assert {^core, []} = Persistence.retire(core)
  end

  test "the Registry leaves the principal when the view has one" do
    core = core(view: [principal_key: "user@example.com"])

    assert Persistence.unregister(core) == [{:unregister, :principals}, {:unregister, :names}]
  end

  test "the Registry leaves no principal when the view has none" do
    assert Persistence.unregister(core()) == [{:unregister, :names}]
  end

  test "a normal end and a shutdown are not crashes" do
    refute Persistence.crash?(:normal)
    refute Persistence.crash?(:shutdown)
    refute Persistence.crash?({:shutdown, :idle})
    assert Persistence.crash?(:killed)
    assert Persistence.crash?({:error, :boom})
  end
end
