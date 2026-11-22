#
# The cache of the ids that the snapshot module did not find: one miss
# costs one call of `load/2`, the next ones read the cache. The process
# also holds the tombstones of the ids whose delete did not end: a
# restore of such an id reads its table and pays no call of the store.
#
defmodule OzMcp.Session.RestoreCacheTest do
  use ExUnit.Case, async: true

  import Plug.Conn, only: [put_req_header: 3]
  import Plug.Test, only: [conn: 3]

  alias OzMcp.Session.RestoreCache
  alias OzMcp.Sessions
  alias Support.Helpers.PersistentSnapshot
  alias Support.Helpers.Utils
  alias Support.Servers

  @server_module Servers.Default
  @max_entries 10_000

  setup do
    Process.put(
      :restore_cache_instance,
      Module.concat(@server_module, "RC#{System.unique_integer([:positive])}")
    )

    Utils.start_instance(@server_module,
      name: server(),
      session_snapshot: PersistentSnapshot
    )

    :ok
  end

  # The name of the instance of the test: the setup gives it a name of its
  # own, so the tests of the file (and of the other files) run apart.
  #
  defp server, do: Process.get(:restore_cache_instance)

  # A POST that names a session id which no session and no snapshot
  # holds: the answer is 404 and the store of the user pays one call.
  #
  describe "an unknown id" do
    test "reaches the store once for 100 requests" do
      for i <- 1..100 do
        conn = ping("unknown-id")
        assert conn.status == 404, "request #{i}"
        assert decode_resp(conn) == json_rpc_error(1, -32001, "invalid session")
      end

      assert PersistentSnapshot.calls(server(), :load) == 1
    end

    test "reaches the store again after the ttl" do
      Utils.stop_instance(server())

      Utils.start_instance(Servers.Default,
        name: server(),
        session_snapshot: PersistentSnapshot,
        session_restore_miss_ttl_ms: 50
      )

      assert ping("unknown-id").status == 404
      Process.sleep(80)
      assert ping("unknown-id").status == 404

      assert PersistentSnapshot.calls(server(), :load) == 2
    end

    test "is not cached when the ttl is 0" do
      Utils.stop_instance(server())

      Utils.start_instance(Servers.Default,
        name: server(),
        session_snapshot: PersistentSnapshot,
        session_restore_miss_ttl_ms: 0
      )

      for _ <- 1..3, do: assert(ping("unknown-id").status == 404)

      assert PersistentSnapshot.calls(server(), :load) == 3
    end

    test "a failure of load is not cached" do
      PersistentSnapshot.fail(server(), :load, :raise)

      for _ <- 1..3 do
        log = Utils.capture_log(fn -> assert ping("unknown-id").status == 404 end)
        assert log =~ "session snapshot load failed"
      end

      assert PersistentSnapshot.calls(server(), :load) == 3

      PersistentSnapshot.heal(server(), :load)
      assert ping("unknown-id").status == 404
      assert PersistentSnapshot.calls(server(), :load) == 4
    end

    test "a snapshot with a wrong shape is not cached" do
      PersistentSnapshot.put(server(), "bad-id", %{
        principal_key: nil,
        protocol_version: "2025-11-25",
        client_info: %{"name" => "restore-test", "version" => "1"},
        client_capabilities: "not a map",
        log_level: nil,
        subscriptions: []
      })

      Utils.capture_log(fn -> assert ping("bad-id").status == 404 end)
      Utils.capture_log(fn -> assert ping("bad-id").status == 404 end)

      assert PersistentSnapshot.calls(server(), :load) == 2
    end
  end

  describe "the cap of the table" do
    @tag :capture_log
    test "holds no more entries than the cap" do
      table = Module.concat(server(), RestoreCache)

      for i <- 1..(@max_entries + 100) do
        RestoreCache.put_missing(server(), "id-#{i}", 60_000)
      end

      assert :ets.info(table, :size) == @max_entries

      # A miss that arrives while the table is full is not held.
      #
      assert :ets.lookup(table, "after-cap-id") == []

      RestoreCache.put_missing(server(), "after-cap-id", 60_000)
      assert :ets.lookup(table, "after-cap-id") == []
    end
  end

  describe "the sweep of the table" do
    test "holds the minimum interval, also with a tiny ttl" do
      Utils.stop_instance(server())

      Utils.start_instance(Servers.Default,
        name: server(),
        session_snapshot: PersistentSnapshot,
        session_restore_miss_ttl_ms: 1
      )

      {:ok, cache} = OzMcp.Instance.whereis(server(), :restore_cache)
      %{timer: timer} = :sys.get_state(cache)

      # A timer armed for 1 ms would be over (and `read_timer/1` would
      # give `false`) before this read runs. The read gives the rest of
      # the minimum interval instead: the process sweeps at most once
      # per second, also when no request comes.
      #
      remaining = Process.read_timer(timer)
      assert is_integer(remaining), "the sweep timer already fired"
      assert remaining > 500, "the sweep timer holds less than half of the minimum"
      assert remaining <= 1_000
    end

    test "removes the entries that passed their time" do
      table = Module.concat(server(), RestoreCache)
      expired_at = System.monotonic_time(:millisecond) - 1
      :ets.insert(table, {"expired-id", expired_at})

      {:ok, cache} = OzMcp.Instance.whereis(server(), :restore_cache)
      send(cache, :sweep)

      # The system message runs after the sweep message in the mailbox
      # of the cache: the read of the state waits for the sweep.
      #
      :sys.get_state(cache)
      assert :ets.lookup(table, "expired-id") == []
    end
  end

  describe "the tombstones of the ended ids" do
    test "put_deleted marks the id, clear_deleted removes the mark" do
      table = Module.concat([server(), RestoreCache, Tombstones])

      assert RestoreCache.deleted?(server(), "ended-id") == false
      assert :ets.lookup(table, "ended-id") == []

      :ok = RestoreCache.put_deleted(server(), "ended-id")
      assert RestoreCache.deleted?(server(), "ended-id") == true
      assert :ets.lookup(table, "ended-id") != []

      :ok = RestoreCache.clear_deleted(server(), "ended-id")
      assert RestoreCache.deleted?(server(), "ended-id") == false
      assert :ets.lookup(table, "ended-id") == []
    end

    test "an expired tombstone is no tombstone and the sweep removes it" do
      table = Module.concat([server(), RestoreCache, Tombstones])
      past = System.monotonic_time(:millisecond) - 1
      :ets.insert(table, {"expired-id", past})

      assert RestoreCache.deleted?(server(), "expired-id") == false

      {:ok, cache} = OzMcp.Instance.whereis(server(), :restore_cache)
      send(cache, :sweep)

      # The system message runs after the sweep message in the mailbox
      # of the cache: the read of the state waits for the sweep.
      #
      :sys.get_state(cache)
      assert :ets.lookup(table, "expired-id") == []
    end

    test "the table of the tombstones holds no cap" do
      table = Module.concat([server(), RestoreCache, Tombstones])

      for i <- 1..(@max_entries + 100) do
        RestoreCache.put_deleted(server(), "ended-#{i}")
      end

      assert :ets.info(table, :size) == @max_entries + 100
      assert RestoreCache.deleted?(server(), "ended-#{@max_entries + 100}") == true
    end

    test "run with a ttl of 0: the tombstones are held, the misses are not" do
      Utils.stop_instance(server())

      Utils.start_instance(Servers.Default,
        name: server(),
        session_snapshot: PersistentSnapshot,
        session_restore_miss_ttl_ms: 0
      )

      :ok = RestoreCache.put_deleted(server(), "ended-id")
      assert RestoreCache.deleted?(server(), "ended-id") == true

      :ok = RestoreCache.put_missing(server(), "unknown-id", 0)
      assert :ets.lookup(Module.concat(server(), RestoreCache), "unknown-id") == []
    end
  end

  describe "a restart of the instance" do
    test "gives an empty cache" do
      assert ping("unknown-id").status == 404
      assert PersistentSnapshot.calls(server(), :load) == 1

      Utils.stop_instance(server())

      Utils.start_instance(Servers.Default,
        name: server(),
        session_snapshot: PersistentSnapshot
      )

      assert ping("unknown-id").status == 404
      assert PersistentSnapshot.calls(server(), :load) == 2
    end
  end

  describe "a crash of the cache process" do
    @tag :capture_log
    test "ends no session, removes no task record and loses the tombstones" do
      session_id = Utils.create_session(server(), initialized: true)
      task_id = insert_task_record(session_id)
      :ok = RestoreCache.put_deleted(server(), "ended-id")
      assert RestoreCache.deleted?(server(), "ended-id")

      {:ok, old_cache} = OzMcp.Instance.whereis(server(), :restore_cache)
      ref = Process.monitor(old_cache)
      Process.exit(old_cache, :kill)
      assert_receive {:DOWN, ^ref, :process, ^old_cache, :killed}

      wait_new_cache(old_cache)

      assert {:ok, %{initialized: true}} = Sessions.state(server(), session_id)

      # The cache of the restart holds no tombstone: a restore of the id
      # reads the store again.
      #
      assert RestoreCache.deleted?(server(), "ended-id") == false

      assert {:ok, _record} =
               OzMcp.Tasks.get(server(), Utils.owner(session_id), task_id)

      # The cache of the restart holds misses again.
      #
      assert ping("unknown-id").status == 404
      assert ping("unknown-id").status == 404
      assert PersistentSnapshot.calls(server(), :load) == 1
    end
  end

  describe "two instances on one node" do
    test "have two caches" do
      second = Module.concat(server(), "Second")

      Utils.start_instance(Servers.Default,
        name: second,
        session_snapshot: PersistentSnapshot
      )

      assert ping("unknown-id").status == 404

      # The miss of the first instance is unknown to the second one: each
      # cache pays its own call of the store.
      #
      assert ping(second, "unknown-id").status == 404

      assert PersistentSnapshot.calls(server(), :load) +
               PersistentSnapshot.calls(second, :load) == 2
    end
  end

  defp insert_task_record(session_id) do
    now = DateTime.utc_now()
    task_id = OzMcp.Utils.Generator.task_id()

    :ok =
      OzMcp.Tasks.Records.put(OzMcp.Tasks.EtsStore, server(), %OzMcp.Tasks.EtsStore{
        task_id: task_id,
        session_id: session_id,
        owner_key: Utils.owner(session_id),
        seq: System.unique_integer([:positive]),
        status: :completed,
        created_at: now,
        last_updated_at: now,
        ttl: 60_000,
        result: {:ok, %{}}
      })

    task_id
  end

  defp wait_new_cache(old_pid) do
    wait_until(fn ->
      case OzMcp.Instance.whereis(server(), :restore_cache) do
        {:ok, pid} -> pid != old_pid and Process.alive?(pid)
        :not_running -> false
      end
    end)
  end

  defp wait_until(fun, retries \\ 1_500) do
    if Utils.eventually(fun, retries * 10) do
      :ok
    else
      flunk("condition was not met in time")
    end
  end

  defp ping(session_id), do: ping(server(), session_id)

  defp ping(instance, session_id) do
    body =
      :json.encode(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}) |> IO.iodata_to_binary()

    conn(:post, "/", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("mcp-session-id", session_id)
    |> OzMcp.Router.call(OzMcp.Router.init(server: instance, allowed_origins: []))
  end

  defp decode_resp(conn), do: :json.decode(conn.resp_body)

  defp json_rpc_error(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end
end
