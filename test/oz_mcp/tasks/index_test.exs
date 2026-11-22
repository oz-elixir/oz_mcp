defmodule OzMcp.Tasks.IndexTest do
  use ExUnit.Case, async: true
  alias OzMcp.Tasks.EtsStore
  alias OzMcp.Tasks.Index
  alias OzMcp.Tasks.Records
  alias OzMcp.Utils.Generator
  alias Support.Helpers.TaskScan

  setup do
    server_id = String.to_atom("oz_mcp_tasks_index_test_#{System.unique_integer([:positive])}")
    :ok = Records.init(EtsStore, server_id)
    %{server_id: server_id}
  end

  describe "init/1" do
    test "creates a named public ETS ordered_set table for the owner index", %{
      server_id: server_id
    } do
      info = :ets.info(Index.index_table(server_id))

      assert info[:type] == :ordered_set
      assert info[:named_table] == true
      assert info[:protection] == :public
      assert info[:read_concurrency] == true
    end

    test "creates a named public ETS ordered_set table for the expiry index", %{
      server_id: server_id
    } do
      info = :ets.info(Index.expiry_table(server_id))

      assert info[:type] == :ordered_set
      assert info[:named_table] == true
      assert info[:protection] == :public
      assert info[:read_concurrency] == true
    end

    test "creates a named public ETS set table for the active counters", %{server_id: server_id} do
      info = :ets.info(Index.counters_table(server_id))

      assert info[:type] == :set
      assert info[:named_table] == true
      assert info[:protection] == :public
      assert info[:read_concurrency] == true
      assert info[:write_concurrency] == true
    end

    test "starts empty" do
      server_id = String.to_atom("oz_mcp_tasks_index_test_#{System.unique_integer([:positive])}")
      :ok = Records.init(EtsStore, server_id)

      assert :ets.tab2list(EtsStore.table(server_id)) == []
      assert :ets.tab2list(Index.index_table(server_id)) == []
      assert :ets.tab2list(Index.expiry_table(server_id)) == []
      assert :ets.tab2list(Index.counters_table(server_id)) == []
    end
  end

  describe "table names" do
    test "derive the table names from the server id", %{server_id: server_id} do
      assert Index.index_table(server_id) == Module.concat(server_id, TasksIndex)
      assert Index.expiry_table(server_id) == Module.concat(server_id, TasksExpiry)
      assert Index.counters_table(server_id) == Module.concat(server_id, TasksCounters)
    end
  end

  describe "a store that owns its index" do
    test "gets no helper tables" do
      server_id = String.to_atom("oz_mcp_tasks_index_test_#{System.unique_integer([:positive])}")

      assert Records.own_index?(Support.TasksStores.OwnIndex)
      assert :ok = Records.init(Support.TasksStores.OwnIndex, server_id)

      assert :ets.whereis(Index.index_table(server_id)) == :undefined
      assert :ets.whereis(Index.expiry_table(server_id)) == :undefined
      assert :ets.whereis(Index.counters_table(server_id)) == :undefined
    end

    test "the facade calls the store for every operation" do
      server_id = String.to_atom("oz_mcp_tasks_index_test_#{System.unique_integer([:positive])}")
      :ok = Records.init(Support.TasksStores.OwnIndex, server_id)
      on_exit(fn -> Support.TasksStores.OwnIndex.clear(server_id) end)

      record = build_record(server_id, seq: 1)
      record = %{record | bytes: :erlang.external_size(record)}

      assert :ok = Records.put(Support.TasksStores.OwnIndex, server_id, record)
      assert Support.TasksStores.OwnIndex.stored(server_id) == [{:put, record}]

      assert Records.count_active(
               Support.TasksStores.OwnIndex,
               server_id,
               {:owner, record.owner_key}
             ) ==
               0

      assert Records.page(Support.TasksStores.OwnIndex, server_id, record.owner_key, 0, 10) ==
               {[], nil}

      assert Records.expired(Support.TasksStores.OwnIndex, server_id, 0, 10) == []
      assert Records.next_expiry(Support.TasksStores.OwnIndex, server_id) == nil

      assert Records.owner_usage(Support.TasksStores.OwnIndex, server_id, record.owner_key) ==
               {0, 0}

      assert Records.delete(Support.TasksStores.OwnIndex, server_id, record) == :ok
      assert Support.TasksStores.OwnIndex.stored(server_id) == [{:delete, record}, {:put, record}]
    end
  end

  describe "put/3 writes the owner index entry" do
    test "the entry holds the owner key, the seq and the task id", %{server_id: server_id} do
      record = build_record(server_id, session_id: "session-1", seq: 7)

      :ok = Records.put(EtsStore, server_id, record)

      assert :ets.lookup(Index.index_table(server_id), {"session-1", 7}) == [
               {{"session-1", 7}, record.task_id}
             ]
    end
  end

  describe "delete/3" do
    test "removes the record and its index entry", %{server_id: server_id} do
      record = build_record(server_id, session_id: "session-1", seq: 5)
      :ok = Records.put(EtsStore, server_id, record)

      assert :ok = Records.delete(EtsStore, server_id, record)

      assert EtsStore.get(server_id, record.task_id) == :not_found
      assert :ets.lookup(Index.index_table(server_id), {"session-1", 5}) == []
    end

    test "the record no longer shows up in pages", %{server_id: server_id} do
      r1 = put_record(server_id, session_id: "session-1", seq: 1)
      r2 = put_record(server_id, session_id: "session-1", seq: 2)

      :ok = Records.delete(EtsStore, server_id, r1)

      assert {records, nil} = Records.page(EtsStore, server_id, "session-1", 0, 10)
      assert Enum.map(records, & &1.task_id) == [r2.task_id]
    end
  end

  describe "all_by_owner/2" do
    test "returns an empty list when the store is empty", %{server_id: server_id} do
      assert TaskScan.all_by_owner(server_id, "session-1") == []
    end

    test "returns an empty list for an unknown session", %{server_id: server_id} do
      put_record(server_id, session_id: "session-1", seq: 1)

      assert TaskScan.all_by_owner(server_id, "stranger") == []
    end

    test "returns the session's records in seq order", %{server_id: server_id} do
      for seq <- [5, 1, 4, 2, 3] do
        put_record(server_id, session_id: "session-1", seq: seq)
      end

      records = TaskScan.all_by_owner(server_id, "session-1")

      assert Enum.map(records, & &1.seq) == [1, 2, 3, 4, 5]
    end

    test "never leaks records from another session", %{server_id: server_id} do
      r1 = put_record(server_id, session_id: "session-1", seq: 1)
      r2 = put_record(server_id, session_id: "session-2", seq: 2)
      r3 = put_record(server_id, session_id: "session-1", seq: 3)

      records = TaskScan.all_by_owner(server_id, "session-1")
      assert Enum.map(records, & &1.task_id) == [r1.task_id, r3.task_id]

      other = TaskScan.all_by_owner(server_id, "session-2")
      assert Enum.map(other, & &1.task_id) == [r2.task_id]
    end

    test "skips a stale index entry whose record is gone", %{server_id: server_id} do
      r1 = put_record(server_id, session_id: "session-1", seq: 1)
      r2 = put_record(server_id, session_id: "session-1", seq: 2)

      :ets.delete(EtsStore.table(server_id), r1.task_id)

      records = TaskScan.all_by_owner(server_id, "session-1")

      assert Enum.map(records, & &1.task_id) == [r2.task_id]
    end
  end

  describe "page/4" do
    test "returns an empty page when the store is empty", %{server_id: server_id} do
      assert Records.page(EtsStore, server_id, "session-1", 0, 10) == {[], nil}
    end

    test "returns all records in seq order when they fit in one page", %{server_id: server_id} do
      for seq <- [5, 1, 4, 2, 3] do
        put_record(server_id, session_id: "session-1", seq: seq)
      end

      {records, next_cursor} = Records.page(EtsStore, server_id, "session-1", 0, 10)

      assert Enum.map(records, & &1.seq) == [1, 2, 3, 4, 5]
      assert next_cursor == nil
    end

    test "paginates via next_cursor when there are more records than the limit", %{
      server_id: server_id
    } do
      r1 = put_record(server_id, session_id: "session-1", seq: 1)
      r2 = put_record(server_id, session_id: "session-1", seq: 2)
      r3 = put_record(server_id, session_id: "session-1", seq: 3)
      r4 = put_record(server_id, session_id: "session-1", seq: 4)
      r5 = put_record(server_id, session_id: "session-1", seq: 5)

      {page1, cursor1} = Records.page(EtsStore, server_id, "session-1", 0, 2)
      assert Enum.map(page1, & &1.task_id) == [r1.task_id, r2.task_id]
      assert cursor1 == 2

      {page2, cursor2} = Records.page(EtsStore, server_id, "session-1", cursor1, 2)
      assert Enum.map(page2, & &1.task_id) == [r3.task_id, r4.task_id]
      assert cursor2 == 4

      {page3, cursor3} = Records.page(EtsStore, server_id, "session-1", cursor2, 2)
      assert Enum.map(page3, & &1.task_id) == [r5.task_id]
      assert cursor3 == nil
    end

    test "returns nil next_cursor when the last page is exactly full", %{server_id: server_id} do
      put_record(server_id, session_id: "session-1", seq: 1)
      put_record(server_id, session_id: "session-1", seq: 2)

      {records, next_cursor} = Records.page(EtsStore, server_id, "session-1", 0, 2)

      assert length(records) == 2
      assert next_cursor == nil
    end

    test "never leaks records from another session", %{server_id: server_id} do
      r1 = put_record(server_id, session_id: "session-1", seq: 1)
      r2 = put_record(server_id, session_id: "session-1", seq: 2)
      other1 = put_record(server_id, session_id: "session-2", seq: 3)
      other2 = put_record(server_id, session_id: "session-2", seq: 4)

      {s1_records, s1_cursor} = Records.page(EtsStore, server_id, "session-1", 0, 10)
      assert Enum.map(s1_records, & &1.task_id) == [r1.task_id, r2.task_id]
      assert s1_cursor == nil

      {s2_records, s2_cursor} = Records.page(EtsStore, server_id, "session-2", 0, 10)
      assert Enum.map(s2_records, & &1.task_id) == [other1.task_id, other2.task_id]
      assert s2_cursor == nil
    end

    test "returns {[], nil} when after_seq is beyond the last record", %{server_id: server_id} do
      put_record(server_id, session_id: "session-1", seq: 1)
      put_record(server_id, session_id: "session-1", seq: 2)

      assert Records.page(EtsStore, server_id, "session-1", 2, 10) == {[], nil}
      assert Records.page(EtsStore, server_id, "session-1", 99, 10) == {[], nil}
    end

    test "returns {[], nil} for an unknown session", %{server_id: server_id} do
      put_record(server_id, session_id: "session-1", seq: 1)

      assert Records.page(EtsStore, server_id, "stranger", 0, 10) == {[], nil}
    end

    test "pages the records of an owner that is not a session id", %{server_id: server_id} do
      r1 = put_record(server_id, owner_key: {:user, "a"}, seq: 1)
      r2 = put_record(server_id, owner_key: {:user, "a"}, seq: 2)
      _other = put_record(server_id, owner_key: {:user, "b"}, seq: 3)

      assert Records.page(EtsStore, server_id, {:user, "a"}, 0, 1) == {[r1], 1}
      assert Records.page(EtsStore, server_id, {:user, "a"}, 1, 1) == {[r2], nil}
    end
  end

  describe "the expiry index" do
    test "a write replaces the entry of the old expiry time", %{server_id: server_id} do
      record = build_record(server_id, status: :completed, expires_at_ms: 100)
      :ok = Records.put(EtsStore, server_id, record)

      assert :ets.tab2list(Index.expiry_table(server_id)) == [{{100, record.task_id}}]

      :ok = Records.put(EtsStore, server_id, %{record | expires_at_ms: 200})
      assert :ets.tab2list(Index.expiry_table(server_id)) == [{{200, record.task_id}}]

      :ok = Records.put(EtsStore, server_id, %{record | expires_at_ms: nil})
      assert :ets.tab2list(Index.expiry_table(server_id)) == []
    end

    test "a delete removes the entry", %{server_id: server_id} do
      record = build_record(server_id, status: :completed, expires_at_ms: 100)
      :ok = Records.put(EtsStore, server_id, record)
      :ok = Records.delete(EtsStore, server_id, record)

      assert :ets.tab2list(Index.expiry_table(server_id)) == []
    end

    test "next_expiry/2 reads the head", %{server_id: server_id} do
      assert Records.next_expiry(EtsStore, server_id) == nil

      put_record(server_id, status: :completed, expires_at_ms: 300)
      put_record(server_id, status: :completed, expires_at_ms: 200)

      assert Records.next_expiry(EtsStore, server_id) == 200
    end

    test "expired/4 returns the records in the order of the index, up to the limit", %{
      server_id: server_id
    } do
      late = put_record(server_id, status: :completed, expires_at_ms: 300)
      first = put_record(server_id, status: :completed, expires_at_ms: 100)
      second = put_record(server_id, status: :completed, expires_at_ms: 200)
      _future = put_record(server_id, status: :completed, expires_at_ms: 9_000)

      assert Records.expired(EtsStore, server_id, 300, 10) == [first, second, late]
      assert Records.expired(EtsStore, server_id, 300, 2) == [first, second]
      assert Records.expired(EtsStore, server_id, 50, 10) == []
    end
  end

  describe "count_active/3" do
    test "counts the working and input_required records of an owner", %{server_id: server_id} do
      put_record(server_id, owner_key: {:user, "a"}, status: :working)
      put_record(server_id, owner_key: {:user, "a"}, status: :input_required)
      put_record(server_id, owner_key: {:user, "a"}, status: :completed)
      put_record(server_id, owner_key: {:user, "b"}, status: :working)

      assert Records.count_active(EtsStore, server_id, {:owner, {:user, "a"}}) == 2
      assert Records.count_active(EtsStore, server_id, {:owner, {:user, "b"}}) == 1
      assert Records.count_active(EtsStore, server_id, {:owner, {:user, "c"}}) == 0
    end

    test "counts the active records of a session", %{server_id: server_id} do
      put_record(server_id, session_id: "s1", owner_key: :x, status: :working)
      put_record(server_id, session_id: "s1", owner_key: :y, status: :working)
      put_record(server_id, session_id: "s1", owner_key: :y, status: :failed)
      put_record(server_id, session_id: "s2", owner_key: :y, status: :working)

      assert Records.count_active(EtsStore, server_id, {:session, "s1"}) == 2
    end

    test "the counters equal the scan after many parallel writers", %{server_id: id} do
      tasks =
        for _ <- 1..200 do
          Task.async(fn ->
            r = build_record(id, status: :working, session_id: "s#{:rand.uniform(5)}")
            :ok = Records.put(EtsStore, id, r)

            if :rand.uniform(2) == 1, do: Records.put(EtsStore, id, %{r | status: :completed})

            r
          end)
        end

      Task.await_many(tasks)

      for sid <- for(i <- 1..5, do: "s#{i}") do
        assert Records.count_active(EtsStore, id, {:session, sid}) ==
                 Support.Helpers.TaskScan.active(id, {:session, sid})
      end
    end
  end

  describe "the active counters" do
    test "a write of an active record adds one to the session and the owner", %{
      server_id: id
    } do
      :ok =
        Records.put(
          EtsStore,
          id,
          build_record(id, status: :working, session_id: "s1", owner_key: {:p, 1})
        )

      assert counter(id, {:session, "s1"}) == 1
      assert counter(id, {:owner, {:p, 1}}) == 1
    end

    test "a status change inside the active states changes nothing", %{server_id: id} do
      r = build_record(id, status: :working)
      :ok = Records.put(EtsStore, id, r)
      :ok = Records.put(EtsStore, id, %{r | status: :input_required})

      assert counter(id, {:session, r.session_id}) == 1
      assert counter(id, {:owner, r.owner_key}) == 1
    end

    test "a terminal status removes the entry", %{server_id: id} do
      r = build_record(id, status: :working)
      :ok = Records.put(EtsStore, id, r)
      :ok = Records.put(EtsStore, id, %{r | status: :completed})

      assert counter(id, {:session, r.session_id}) == 0
      assert counter(id, {:owner, r.owner_key}) == 0
      assert counter(id, {:records, r.owner_key}) == 1
    end

    test "an owner key that holds a session tuple does not clash with the session key", %{
      server_id: id
    } do
      r = build_record(id, status: :working, session_id: "s1", owner_key: {:session, "s1"})
      :ok = Records.put(EtsStore, id, r)

      assert counter(id, {:session, "s1"}) == 1
      assert counter(id, {:owner, {:session, "s1"}}) == 1

      :ok = Records.put(EtsStore, id, %{r | status: :failed})

      assert counter(id, {:session, "s1"}) == 0
      assert counter(id, {:owner, {:session, "s1"}}) == 0
      assert counter(id, {:records, {:session, "s1"}}) == 1
    end

    test "a delete of a stale copy uses the stored status", %{server_id: id} do
      r = build_record(id, status: :working)
      :ok = Records.put(EtsStore, id, r)
      :ok = Records.put(EtsStore, id, %{r | status: :completed})
      :ok = Records.delete(EtsStore, id, r)

      assert :ets.tab2list(Index.counters_table(id)) == []
    end

    test "a delete of a stale copy removes the stored expiry entry", %{server_id: id} do
      r = build_record(id, status: :working)
      :ok = Records.put(EtsStore, id, r)
      :ok = Records.put(EtsStore, id, %{r | status: :completed, expires_at_ms: 1_000})
      :ok = Records.delete(EtsStore, id, r)

      assert :ets.tab2list(Index.expiry_table(id)) == []
    end

    test "a double delete gives no negative count", %{server_id: id} do
      r = build_record(id, status: :working)
      :ok = Records.put(EtsStore, id, r)
      :ok = Records.delete(EtsStore, id, r)
      :ok = Records.delete(EtsStore, id, r)

      assert :ets.tab2list(Index.counters_table(id)) == []
    end

    test "a record that was never counted gives no negative count", %{server_id: id} do
      #
      # The case of a writer that dies between the insert of the record
      # and the increment of the counter: the record is in the table, the
      # counter was never touched.
      #
      r = build_record(id, status: :working)
      :ets.insert(EtsStore.table(id), {r.task_id, r})
      :ok = Records.put(EtsStore, id, %{r | status: :failed})

      # The record counter stays below the truth and no counter goes
      # below zero. The bytes counter takes the bytes of the record that
      # replaced the uncounted one.
      #
      assert counter(id, {:session, r.session_id}) == 0
      assert counter(id, {:owner, r.owner_key}) == 0
      assert counter(id, {:records, r.owner_key}) == 0
      assert counter(id, {:bytes, r.owner_key}) > 0
    end
  end

  describe "owner_usage/3" do
    test "a write adds one record and its bytes and the record holds its size", %{
      server_id: id
    } do
      r = put_record(id, owner_key: {:user, "a"})

      assert {:ok, stored} = EtsStore.get(id, r.task_id)
      assert stored.bytes > 0
      assert stored.bytes == :erlang.external_size(%{stored | bytes: 0})

      assert Records.owner_usage(EtsStore, id, {:user, "a"}) == {1, stored.bytes}
    end

    test "counts the records of one owner only", %{server_id: id} do
      a1 = put_record(id, owner_key: {:user, "a"})
      a2 = put_record(id, owner_key: {:user, "a"}, status: :completed)
      b = put_record(id, owner_key: {:user, "b"})

      assert Records.owner_usage(EtsStore, id, {:user, "a"}) == {2, bytes([a1, a2])}
      assert Records.owner_usage(EtsStore, id, {:user, "b"}) == {1, bytes([b])}
      assert Records.owner_usage(EtsStore, id, {:user, "c"}) == {0, 0}
    end

    test "a replace changes the bytes by the difference and keeps the count", %{
      server_id: id
    } do
      owner = {:user, "a"}
      r = put_record(id, owner_key: owner, status: :working)
      assert {:ok, first} = EtsStore.get(id, r.task_id)

      big = %{
        r
        | status: :completed,
          result: {:ok, %{"data" => String.duplicate("x", 500)}}
      }

      :ok = Records.put(EtsStore, id, big)
      assert {:ok, bigger} = EtsStore.get(id, r.task_id)
      assert bigger.bytes > first.bytes
      assert Records.owner_usage(EtsStore, id, owner) == {1, bigger.bytes}

      :ok = Records.put(EtsStore, id, %{bigger | result: nil})
      assert {:ok, smaller} = EtsStore.get(id, r.task_id)
      assert smaller.bytes < bigger.bytes
      assert Records.owner_usage(EtsStore, id, owner) == {1, smaller.bytes}
    end

    test "a delete removes the record and its bytes and the last one removes the entries", %{
      server_id: id
    } do
      owner = {:user, "a"}
      r1 = put_record(id, owner_key: owner)
      r2 = put_record(id, owner_key: owner, status: :completed)

      assert Records.owner_usage(EtsStore, id, owner) == {2, bytes([r1, r2])}

      :ok = Records.delete(EtsStore, id, r1)
      assert {:ok, stored2} = EtsStore.get(id, r2.task_id)
      assert Records.owner_usage(EtsStore, id, owner) == {1, stored2.bytes}

      :ok = Records.delete(EtsStore, id, r2)
      assert Records.owner_usage(EtsStore, id, owner) == {0, 0}
      assert :ets.lookup(Index.counters_table(id), {:records, owner}) == []
      assert :ets.lookup(Index.counters_table(id), {:bytes, owner}) == []
    end

    test "a delete of a missing record changes nothing", %{server_id: id} do
      owner = {:user, "a"}
      r = put_record(id, owner_key: owner)
      before = Records.owner_usage(EtsStore, id, owner)

      :ok = Records.delete(EtsStore, id, build_record(id, owner_key: owner))

      assert Records.owner_usage(EtsStore, id, owner) == before
      assert EtsStore.get(id, r.task_id) != :not_found
    end

    test "the ledger equals a scan of the records after random operations", %{server_id: id} do
      :rand.seed(:exsss, {11, 22, 33})
      owner = {:user, "a"}

      Enum.reduce(1..150, [], fn _step, records ->
        records =
          case {records, :rand.uniform(5)} do
            {[], _} ->
              [put_record(id, owner_key: owner) | records]

            {records, 1} ->
              [put_record(id, owner_key: owner) | records]

            {records, 2} ->
              r = Enum.random(records)

              r = %{
                r
                | result: {:ok, %{"padding" => String.duplicate("x", :rand.uniform(300))}}
              }

              :ok = Records.put(EtsStore, id, r)
              Enum.map(records, fn old -> if old.task_id == r.task_id, do: r, else: old end)

            {records, 3} ->
              r = Enum.random(records)
              :ok = Records.delete(EtsStore, id, r)
              Enum.reject(records, &(&1.task_id == r.task_id))

            {records, _} ->
              :ok = Records.delete(EtsStore, id, build_record(id, owner_key: owner))
              records
          end

        assert_usage(id, owner)
        records
      end)
    end

    test "a failed put never raises the ledger above the scan", %{server_id: _id} do
      owner = {:user, "a"}

      instance =
        String.to_atom("oz_mcp_tasks_index_failing_#{System.unique_integer([:positive])}")

      :ok = Records.init(Support.TasksStores.Failing, instance)
      on_exit(fn -> Support.TasksStores.Failing.clear_instance(instance) end)

      r = build_record(instance, owner_key: owner)
      :ok = Records.put(Support.TasksStores.Failing, instance, r)

      Support.TasksStores.Failing.arm(instance, :put, :error)

      big = %{r | result: {:ok, %{"data" => String.duplicate("x", 500)}}}
      assert Records.put(Support.TasksStores.Failing, instance, big) == {:error, :boom}

      {records, used_bytes} = Records.owner_usage(Support.TasksStores.Failing, instance, owner)
      scan = TaskScan.all_by_owner(instance, owner)

      assert records <= length(scan)
      assert used_bytes <= Enum.sum(Enum.map(scan, & &1.bytes))
    end
  end

  describe "a read error of the store" do
    setup do
      instance =
        String.to_atom("oz_mcp_tasks_index_failing_get_#{System.unique_integer([:positive])}")

      :ok = Records.init(Support.TasksStores.FailingGet, instance)
      on_exit(fn -> Support.TasksStores.FailingGet.clear_instance(instance) end)

      %{instance: instance}
    end

    test "a put answers the error and the store and the counters do not change", %{
      instance: instance
    } do
      record = build_record(instance, owner_key: {:user, "a"})

      Support.TasksStores.FailingGet.arm(instance)

      assert Records.put(Support.TasksStores.FailingGet, instance, record) == {:error, :boom}

      assert :ets.tab2list(EtsStore.table(instance)) == []
      assert :ets.tab2list(Index.index_table(instance)) == []
      assert :ets.tab2list(Index.expiry_table(instance)) == []
      assert :ets.tab2list(Index.counters_table(instance)) == []
    end

    test "a delete answers the error and the record and the counters stay", %{instance: instance} do
      owner = {:user, "a"}
      record = build_record(instance, owner_key: owner)
      :ok = Records.put(Support.TasksStores.FailingGet, instance, record)
      {:ok, stored} = EtsStore.get(instance, record.task_id)
      before = Records.owner_usage(Support.TasksStores.FailingGet, instance, owner)

      Support.TasksStores.FailingGet.arm(instance)

      assert Records.delete(Support.TasksStores.FailingGet, instance, stored) == {:error, :boom}

      assert {:ok, ^stored} = EtsStore.get(instance, record.task_id)
      assert Records.owner_usage(Support.TasksStores.FailingGet, instance, owner) == before
    end

    test "after the error is cleared, the counters equal a scan of the records", %{
      instance: instance
    } do
      owner = {:user, "a"}
      r1 = build_record(instance, owner_key: owner)
      :ok = Records.put(Support.TasksStores.FailingGet, instance, r1)

      Support.TasksStores.FailingGet.arm(instance)

      big = %{r1 | result: {:ok, %{"data" => String.duplicate("x", 500)}}}
      assert Records.put(Support.TasksStores.FailingGet, instance, big) == {:error, :boom}
      assert Records.delete(Support.TasksStores.FailingGet, instance, r1) == {:error, :boom}

      Support.TasksStores.FailingGet.clear(instance)

      :ok = Records.put(Support.TasksStores.FailingGet, instance, big)
      :ok = Records.delete(Support.TasksStores.FailingGet, instance, big)

      :ok =
        Records.put(
          Support.TasksStores.FailingGet,
          instance,
          build_record(instance, owner_key: owner)
        )

      scan = TaskScan.all_by_owner(instance, owner)

      assert Records.owner_usage(Support.TasksStores.FailingGet, instance, owner) ==
               {length(scan), bytes(scan)}
    end
  end

  defp assert_usage(server_id, owner_key) do
    scan = TaskScan.all_by_owner(server_id, owner_key)
    assert Records.owner_usage(EtsStore, server_id, owner_key) == {length(scan), bytes(scan)}
  end

  defp bytes(records), do: records |> Enum.map(& &1.bytes) |> Enum.sum()

  defp build_record(_server_id, attrs) do
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
    record = build_record(server_id, attrs)
    :ok = Records.put(EtsStore, server_id, record)
    {:ok, stored} = EtsStore.get(server_id, record.task_id)
    stored
  end

  defp counter(server_id, key) do
    case :ets.lookup(Index.counters_table(server_id), key) do
      [{^key, count}] -> count
      [] -> 0
    end
  end
end
