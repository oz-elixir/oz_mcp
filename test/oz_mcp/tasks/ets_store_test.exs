defmodule OzMcp.Tasks.EtsStoreTest do
  use ExUnit.Case, async: true
  alias OzMcp.Tasks.EtsStore
  alias OzMcp.Utils.Generator

  setup do
    server_id = String.to_atom("oz_mcp_tasks_store_test_#{System.unique_integer([:positive])}")
    EtsStore.init(server_id)
    %{server_id: server_id}
  end

  describe "init/1" do
    test "creates a named public ETS set table for the records", %{server_id: server_id} do
      info = :ets.info(EtsStore.table(server_id))

      assert info[:type] == :set
      assert info[:named_table] == true
      assert info[:protection] == :public
      assert info[:read_concurrency] == true
    end

    test "starts empty" do
      server_id = String.to_atom("oz_mcp_tasks_store_test_#{System.unique_integer([:positive])}")
      EtsStore.init(server_id)

      assert :ets.tab2list(EtsStore.table(server_id)) == []
    end
  end

  describe "table/1" do
    test "derives the table name from the server id", %{server_id: server_id} do
      assert EtsStore.table(server_id) == Module.concat(server_id, TasksTable)
    end
  end

  describe "put/2 and get/2" do
    test "round-trips a record", %{server_id: server_id} do
      record = build_record(seq: 1)

      assert :ok = EtsStore.put(server_id, record)
      assert {:ok, ^record} = EtsStore.get(server_id, record.task_id)
    end

    test "round-trips the principal snapshot", %{server_id: server_id} do
      principal = OzMcp.Auth.Principal.new!(subject: "alice", issuer: "https://issuer.test")
      record = build_record(seq: 2, principal: principal)

      assert :ok = EtsStore.put(server_id, record)
      assert {:ok, ^record} = EtsStore.get(server_id, record.task_id)
    end

    test "defaults the principal to nil", %{server_id: _server_id} do
      record = build_record(seq: 3)

      assert record.principal == nil
    end

    test "returns :not_found for an unknown task id", %{server_id: server_id} do
      assert EtsStore.get(server_id, "nope") == :not_found
    end
  end

  describe "expired?/2" do
    test "returns false when ttl is nil (unlimited)" do
      record = build_record(ttl: nil)

      assert EtsStore.expired?(record) == false
    end

    test "returns false when created_at + ttl is in the future" do
      record = build_record(created_at: DateTime.utc_now(), ttl: 60_000)

      assert EtsStore.expired?(record) == false
    end

    test "returns true when created_at + ttl is in the past" do
      created_at = DateTime.add(DateTime.utc_now(), -10_000, :millisecond)
      record = build_record(created_at: created_at, ttl: 1_000)

      assert EtsStore.expired?(record) == true
    end

    test "returns true when now is exactly the expiry time" do
      created_at = DateTime.utc_now()
      record = build_record(created_at: created_at, ttl: 5_000)

      assert EtsStore.expired?(record, DateTime.add(created_at, 5_000, :millisecond)) == true
    end

    test "accepts an explicit now" do
      created_at = DateTime.utc_now()
      record = build_record(created_at: created_at, ttl: 5_000)

      assert EtsStore.expired?(record, DateTime.add(created_at, 4_999, :millisecond)) == false
      assert EtsStore.expired?(record, DateTime.add(created_at, 5_001, :millisecond)) == true
    end

    test "is cheap for a huge ttl" do
      record = build_record(created_at: DateTime.utc_now(), ttl: 1_000_000_000_000_000_000_000)

      {micros, result} = :timer.tc(fn -> EtsStore.expired?(record) end)

      assert result == false
      assert micros < 100_000
    end

    test "deadline_ms/1 gives the integer deadline, or nil" do
      created_at = ~U[2026-01-01 00:00:00.000Z]

      assert EtsStore.deadline_ms(build_record(created_at: created_at, ttl: 10_000)) ==
               DateTime.to_unix(created_at, :millisecond) + 10_000

      assert EtsStore.deadline_ms(build_record(ttl: nil)) == nil
    end
  end

  describe "active/1" do
    test "returns the working and input_required records only", %{server_id: server_id} do
      working = put_record(server_id, status: :working, seq: 1)
      input_required = put_record(server_id, status: :input_required, seq: 2)
      put_record(server_id, status: :completed, seq: 3)
      put_record(server_id, status: :failed, seq: 4)
      put_record(server_id, status: :cancelled, seq: 5)

      records = EtsStore.active(server_id)

      assert Enum.sort_by(records, & &1.task_id) ==
               Enum.sort_by([working, input_required], & &1.task_id)
    end

    test "returns the whole records of several owners and sessions", %{server_id: server_id} do
      r1 = put_record(server_id, session_id: "s1", owner_key: {:user, "a"}, seq: 1)
      r2 = put_record(server_id, session_id: "s2", owner_key: {:user, "b"}, seq: 2)

      records = EtsStore.active(server_id)

      assert Enum.sort_by(records, & &1.task_id) == Enum.sort_by([r1, r2], & &1.task_id)
    end

    test "returns an empty list when the store is empty", %{server_id: server_id} do
      assert EtsStore.active(server_id) == []
    end

    test "returns an empty list when only terminal records are stored", %{server_id: server_id} do
      put_record(server_id, status: :completed, seq: 1)
      put_record(server_id, status: :failed, seq: 2)
      put_record(server_id, status: :cancelled, seq: 3)

      assert EtsStore.active(server_id) == []
    end
  end

  describe "the store behaviour" do
    test "the optional callbacks are active/1 and the five index callbacks" do
      optional = [
        active: 1,
        page: 4,
        count_active: 2,
        expired: 3,
        next_expiry: 1,
        owner_usage: 2
      ]

      assert Enum.sort(OzMcp.Tasks.StoreBehaviour.behaviour_info(:optional_callbacks)) ==
               Enum.sort(optional)
    end

    test "active/1 and the index callbacks are not required functions of the boot check" do
      required = [init: 1, put: 2, get: 2, delete: 2]
      optional = OzMcp.Tasks.StoreBehaviour.behaviour_info(:optional_callbacks)

      callbacks = OzMcp.Tasks.StoreBehaviour.behaviour_info(:callbacks)

      assert Enum.sort(callbacks -- required) == Enum.sort(optional)
      assert Enum.sort(required ++ optional) == Enum.sort(callbacks)
    end

    test "the default store implements the required callbacks only" do
      exported = [
        init: 1,
        put: 2,
        get: 2,
        delete: 2,
        active: 1
      ]

      for {name, arity} <- exported do
        assert function_exported?(EtsStore, name, arity), "missing #{name}/#{arity}"
      end

      for {name, arity} <- OzMcp.Tasks.Records.index_callbacks() do
        refute function_exported?(EtsStore, name, arity), "unexpected #{name}/#{arity}"
      end
    end
  end

  defp build_record(attrs) do
    now = DateTime.utc_now()

    %EtsStore{
      task_id: Generator.task_id(),
      session_id: "session-1",
      owner_key: attrs[:owner_key] || attrs[:session_id] || "session-1",
      seq: System.unique_integer([:positive]),
      status: :working,
      created_at: now,
      last_updated_at: now
    }
    |> struct!(attrs)
  end

  defp put_record(server_id, attrs) do
    record = build_record(attrs)
    :ok = EtsStore.put(server_id, record)
    record
  end
end
