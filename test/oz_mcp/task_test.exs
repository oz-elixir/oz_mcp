#
# Tests for OzMcp.Task through the OzMcp.Tasks facade.
# See: lib/oz_mcp/task.ex
#
defmodule OzMcp.TaskTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias OzMcp.PostStream
  alias OzMcp.Structs.Task
  alias OzMcp.Tasks
  alias OzMcp.Tasks.EtsStore
  alias OzMcp.Tasks.Index
  alias OzMcp.Tasks.Records
  alias Support.Helpers.SessionProbe
  alias Support.Helpers.TaskScan
  alias Support.Helpers.TelemetryCapture
  alias Support.Helpers.Utils
  alias Support.Servers

  @server_module Servers.TasksTest

  @server Module.concat(@server_module, __MODULE__)

  # The child id of the invoke supervisor of the instance: the name it
  # registers under in the names registry of the instance.
  #
  @calls_child_id {OzMcp.Instance.names(@server), :calls}
  setup context do
    opts = Map.get(context, :task_opts) || %{}

    Utils.start_instance(@server_module, [name: @server] ++ Map.to_list(opts))
    Support.Entities.Tools.TaskSlowTest.use_instance(@server)

    session_id = Utils.create_session(@server, initialized: true, streams: [self()])

    %{session_id: session_id}
  end

  describe "create" do
    test "does not emit a status notification on creation (A7)", %{session_id: session_id} do
      previous = Support.Entities.Tools.TaskSlowTest.last_runner_pid()
      task = create_task(session_id, tool: slow_tool())
      runner = Support.Entities.Tools.TaskSlowTest.await_runner(previous)

      # The wait is part of the check: no status notification arrives.
      #
      refute_receive {:oz_mcp_stream, _, {:event, _, %{method: "notifications/tasks/status"}}},
                     50

      send(runner, :finish)

      assert {_, _} = Utils.receive_event(5_000)

      assert {:ok, {:ok, _}} =
               Tasks.await(@server, Utils.owner(session_id), task.taskId, 5_000)
    end

    test "creates a working task and returns the wire Task struct", %{session_id: session_id} do
      task = create_task(session_id)

      assert is_binary(task.taskId)
      assert task.status == :working
      assert task.ttl == 86_400_000
      assert task.statusMessage == nil
      assert task.pollInterval == nil
      assert String.length(task.createdAt) == 20
      assert String.match?(task.createdAt, ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/)
      assert String.match?(task.lastUpdatedAt, ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/)

      assert {:ok, {:ok, _result}} =
               Tasks.await(@server, Utils.owner(session_id), task.taskId, 5_000)

      assert {:ok, stored} = Tasks.get(@server, Utils.owner(session_id), task.taskId)
      assert stored.status == :completed
    end

    test "passes the exact 8-key runner ctx to the tool (A17, A18)", %{session_id: session_id} do
      task = create_task(session_id, progress_token: "tok-1")

      assert {:ok, {:ok, _}} =
               Tasks.await(@server, Utils.owner(session_id), task.taskId, 5_000)

      assert Support.Entities.Tools.TaskImmediateTest.last_ctx() == %{
               instance: @server,
               server: @server_module,
               session_id: session_id,
               request_id: nil,
               progress_token: "tok-1",
               task_id: task.taskId,
               client_capabilities: %{},
               principal: nil
             }
    end

    test "the runner ctx carries the capabilities of the client", %{session_id: session_id} do
      task = create_task(session_id, client_capabilities: %{"elicitation" => %{}})

      assert {:ok, {:ok, _}} =
               Tasks.await(@server, Utils.owner(session_id), task.taskId, 5_000)

      assert Support.Entities.Tools.TaskImmediateTest.last_ctx().client_capabilities == %{
               "elicitation" => %{}
             }
    end

    test "stores the principal of the request in the record and gives it to the runner ctx", %{
      session_id: session_id
    } do
      principal =
        OzMcp.Auth.Principal.new!(
          issuer: "https://issuer.test",
          subject: "alice",
          scopes: ["files:read"]
        )

      task = create_task(session_id, principal: principal)

      owner = Tasks.owner_key(%{principal: principal, session_id: session_id})
      assert {:ok, {:ok, _}} = Tasks.await(@server, owner, task.taskId, 5_000)

      assert {:ok, record} = EtsStore.get(@server, task.taskId)
      assert record.principal == principal
      assert record.owner_key == {:principal, {"https://issuer.test", "alice"}}

      assert Support.Entities.Tools.TaskImmediateTest.last_ctx().principal == principal
    end

    @tag task_opts: %{task_default_ttl_ms: 2_000, task_max_ttl_ms: 5_000}
    test "resolves the ttl: requested honored, default applied, max capped", %{
      session_id: session_id
    } do
      assert create_task(session_id).ttl == 2_000
      assert create_task(session_id, ttl: 100).ttl == 100
      assert create_task(session_id, ttl: 9_000).ttl == 5_000
    end

    test "resolves the ttl: a task with no ttl gets the cap by default", %{session_id: session_id} do
      assert create_task(session_id).ttl == 86_400_000
      assert create_task(session_id, ttl: 100).ttl == 100
      assert create_task(session_id, ttl: 86_400_000).ttl == 86_400_000
      assert create_task(session_id, ttl: 86_400_001).ttl == 86_400_000
    end

    @tag task_opts: %{task_default_ttl_ms: 600_000}
    test "resolves the ttl: the default ttl wins over the cap default", %{session_id: session_id} do
      assert create_task(session_id).ttl == 600_000
      assert create_task(session_id, ttl: 9_000).ttl == 9_000
    end

    @tag task_opts: %{task_default_ttl_ms: 100_000, task_max_ttl_ms: 600_000}
    test "resolves the ttl: the cap bounds the requested ttl too", %{session_id: session_id} do
      assert create_task(session_id).ttl == 100_000
      assert create_task(session_id, ttl: 9_000).ttl == 9_000
      assert create_task(session_id, ttl: 9_000_000).ttl == 600_000
    end

    @tag task_opts: %{task_max_ttl_ms: nil}
    test "resolves the ttl: a nil cap keeps a task with no ttl unlimited", %{
      session_id: session_id
    } do
      assert create_task(session_id).ttl == nil
      assert create_task(session_id, ttl: 9_000_000).ttl == 9_000_000
      assert create_task(session_id, ttl: 10 ** 21).ttl == Tasks.ttl_ceiling_ms()
      assert create_task(session_id, ttl: Tasks.ttl_ceiling_ms()).ttl == Tasks.ttl_ceiling_ms()
    end

    @tag task_opts: %{task_default_ttl_ms: nil, task_max_ttl_ms: nil}
    test "resolves the ttl: a huge ttl is lowered to the ceiling and the task stays alive", %{
      session_id: session_id
    } do
      task = create_task(session_id, ttl: 10 ** 21, tool: slow_tool())
      assert task.ttl == Tasks.ttl_ceiling_ms()

      assert {:ok, record} = EtsStore.get(@server, task.taskId)
      assert is_pid(record.pid) and Process.alive?(record.pid)

      finish_runners([task])

      assert {:ok, {:ok, _}} =
               Tasks.await(@server, Utils.owner(session_id), task.taskId, 5_000)
    end

    @tag task_opts: %{task_default_ttl_ms: nil, task_max_ttl_ms: nil}
    test "resolves the ttl: with both options off, no ttl stays unlimited", %{
      session_id: session_id
    } do
      assert create_task(session_id).ttl == nil
      assert create_task(session_id, ttl: 100).ttl == 100
    end

    @tag task_opts: %{task_poll_interval_ms: 1_000}
    test "the option task_poll_interval_ms is the poll interval of a record", %{
      session_id: session_id
    } do
      assert create_task(session_id).pollInterval == 1_000

      # The value of the create wins over the option of the instance
      #
      assert create_task(session_id, poll_interval: 2_500).pollInterval == 2_500
    end

    test "a create with no poll interval and no instance option gives no hint", %{
      session_id: session_id
    } do
      assert create_task(session_id).pollInterval == nil
      assert create_task(session_id, poll_interval: 5_000).pollInterval == 5_000
    end

    @tag task_opts: %{task_poll_interval_ms: 1_000}
    test "a poll interval of another shape gives the instance option", %{session_id: session_id} do
      for value <- ["5", 0, -1] do
        task = create_task(session_id, poll_interval: value)
        assert task.pollInterval == 1_000

        assert {:ok, stored} = Tasks.get(@server, Utils.owner(session_id), task.taskId)
        assert stored.pollInterval == 1_000
      end
    end

    test "a poll interval of another shape with no instance option gives no hint", %{
      session_id: session_id
    } do
      for value <- ["5", 0, -1] do
        task = create_task(session_id, poll_interval: value)
        assert task.pollInterval == nil

        assert {:ok, stored} = Tasks.get(@server, Utils.owner(session_id), task.taskId)
        assert stored.pollInterval == nil
      end
    end

    test "a pre-settled task lands directly in its terminal status without a runner", %{
      session_id: session_id
    } do
      settled = {:failed, "The tool execution reported an error.", {:ok, %{isError: true}}}

      assert {:ok, %Task{} = task} =
               Tasks.create(@server, %{
                 session_id: session_id,
                 tool: {Support.Entities.Tools.TaskImmediateTest, "task_immediate"},
                 request: %{"name" => "task_immediate"},
                 ttl: 5_000,
                 progress_token: nil,
                 settled: settled
               })

      assert task.status == :failed
      assert task.statusMessage == "The tool execution reported an error."

      # The stored outcome is replayed by tasks/result
      #
      assert {:ok, {:ok, result}} =
               Tasks.await(@server, Utils.owner(session_id), task.taskId, 5_000)

      assert result == %{isError: true}

      # No runner was spawned for the tool callback
      #
      assert {:ok, record} = EtsStore.get(@server, task.taskId)
      assert record.runner_pid == nil
      assert record.status == :failed
      refute Map.has_key?(record, :request)

      # The result of the create shows the status: no notification
      #
      refute_receive {:oz_mcp_stream, _, {:event, _, _data}}, 100
    end

    @tag task_opts: %{task_store: Support.TasksStores.Failing}
    test "a settled create whose store cannot write the record gives :unavailable", %{
      session_id: session_id
    } do
      on_exit(fn -> Support.TasksStores.Failing.clear_instance(@server) end)

      attrs = %{
        session_id: session_id,
        tool: {Support.Entities.Tools.TaskImmediateTest, "task_immediate"},
        ttl: 5_000,
        progress_token: nil,
        settled: {:failed, "The tool execution reported an error.", {:ok, %{isError: true}}}
      }

      for mode <- [:error, :raise, :exit] do
        Support.TasksStores.Failing.arm(@server, :put, mode)

        # The store holds no record: the client must not poll a task
        # that does not exist.
        #
        assert {:error, :unavailable} = Tasks.create(@server, attrs)
        assert TaskScan.all(@server) == []
      end

      # The store writes again: the same settled create succeeds.
      #
      Support.TasksStores.Failing.clear(@server, :put)

      assert {:ok, %Task{status: :failed}} = Tasks.create(@server, attrs)
      assert [%{status: :failed}] = TaskScan.all(@server)
    end
  end

  describe "the task limit" do
    @tag task_opts: %{max_tasks_per_session: 2}
    test "refuses a task of the session when the active tasks reach the limit", %{
      session_id: session_id
    } do
      assert %Task{} = create_task(session_id, tool: slow_tool())
      assert %Task{} = create_task(session_id, tool: slow_tool())

      assert {:error, {:too_many_tasks, :max_tasks_per_session}} = create_task_raw(session_id)
    end

    @tag task_opts: %{max_tasks_per_session: 2}
    test "a task that reaches a terminal status frees a slot", %{session_id: session_id} do
      task1 = create_task(session_id, tool: slow_tool())
      task2 = create_task(session_id, tool: slow_tool())

      assert {:error, {:too_many_tasks, :max_tasks_per_session}} = create_task_raw(session_id)

      finish_runners([task1, task2])

      assert {:ok, {:ok, _}} =
               Tasks.await(@server, Utils.owner(session_id), task1.taskId, 5_000)

      assert {:ok, {:ok, _}} =
               Tasks.await(@server, Utils.owner(session_id), task2.taskId, 5_000)

      assert %Task{} = create_task(session_id)
    end

    @tag task_opts: %{max_tasks_per_session: 2}
    test "a cancel frees a slot for a new create", %{session_id: session_id} do
      task1 = create_task(session_id, tool: slow_tool())
      _task2 = create_task(session_id, tool: slow_tool())

      assert {:error, {:too_many_tasks, :max_tasks_per_session}} = create_task_raw(session_id)

      assert {:ok, %Task{status: :cancelled}} =
               Tasks.cancel(@server, Utils.owner(session_id), task1.taskId)

      assert %Task{} = create_task(session_id)
    end

    @tag task_opts: %{max_tasks_per_session: 2}
    test "a pre-settled task passes the limit and lands in its terminal status", %{
      session_id: session_id
    } do
      assert %Task{} = create_task(session_id, tool: slow_tool())
      assert %Task{} = create_task(session_id, tool: slow_tool())

      settled = {:failed, "The tool execution reported an error.", {:ok, %{isError: true}}}

      assert {:ok, %Task{} = task} =
               Tasks.create(@server, %{
                 session_id: session_id,
                 tool: {Support.Entities.Tools.TaskImmediateTest, "task_immediate"},
                 request: %{"name" => "task_immediate", "arguments" => %{}},
                 ttl: 5_000,
                 progress_token: nil,
                 settled: settled
               })

      assert task.status == :failed

      assert {:ok, {:ok, result}} =
               Tasks.await(@server, Utils.owner(session_id), task.taskId, 5_000)

      assert result == %{isError: true}
    end

    @tag task_opts: %{max_tasks_per_session: 1}
    test "the tasks of a different session do not count", %{session_id: session_id} do
      assert %Task{} = create_task(session_id, tool: slow_tool())

      other_session_id = Utils.create_session(@server, initialized: true, streams: [self()])

      assert %Task{} = create_task(other_session_id)

      assert {:error, {:too_many_tasks, :max_tasks_per_session}} = create_task_raw(session_id)
    end

    @tag task_opts: %{max_tasks_per_session: nil}
    test "a nil limit keeps the tasks of the session unlimited", %{session_id: session_id} do
      for _ <- 1..101, do: assert(%Task{} = create_task(session_id, tool: slow_tool()))
    end
  end

  describe "the record limits" do
    @tag task_opts: %{
           max_task_records_per_owner: 3,
           max_tasks_per_session: 3,
           max_tasks_per_principal: 3
         }
    test "refuses a create when the owner has the maximum records", %{session_id: session_id} do
      tasks = for _ <- 1..3, do: completed_task(session_id)

      assert {:error, {:too_many_tasks, :max_task_records_per_owner}} =
               create_task_raw(session_id)

      for task <- tasks do
        assert {:ok, %Task{status: :completed}} =
                 Tasks.get(@server, Utils.owner(session_id), task.taskId)
      end
    end

    @tag task_opts: %{
           max_task_records_per_owner: 1,
           max_tasks_per_session: 1,
           max_tasks_per_principal: 1
         }
    test "a settled task counts and a settled create is refused at the limit", %{
      session_id: session_id
    } do
      settled = {:failed, "The tool execution reported an error.", {:ok, %{isError: true}}}

      assert {:ok, %Task{status: :failed}} =
               create_task_raw(session_id, %{settled: settled})

      assert {:error, {:too_many_tasks, :max_task_records_per_owner}} =
               create_task_raw(session_id, %{settled: settled})
    end

    @tag task_opts: %{max_tasks_per_session: 1}
    test "the active limits do not apply to a settled task", %{session_id: session_id} do
      task = create_slow_task_only(session_id, %{})

      assert {:ok, %Task{status: :failed}} =
               create_task_raw(session_id,
                 settled: {:failed, "The tool execution reported an error.", {:ok, %{}}}
               )

      finish_runners([task])

      assert {:ok, {:ok, _}} =
               Tasks.await(@server, Utils.owner(session_id), task.taskId, 5_000)
    end

    @tag task_opts: %{max_task_bytes_per_owner: 1_000}
    test "refuses a create when the owner passes the byte budget", %{session_id: session_id} do
      settled = {:completed, nil, {:ok, %{"data" => String.duplicate("x", 5_000)}}}

      assert {:ok, %Task{status: :completed}} =
               create_task_raw(session_id, %{settled: settled})

      assert {:error, {:too_many_tasks, :max_task_bytes_per_owner}} = create_task_raw(session_id)
    end

    @tag task_opts: %{
           max_task_records_per_owner: 1,
           max_tasks_per_session: 1,
           max_tasks_per_principal: 1
         }
    test "the records of another owner do not count", %{session_id: session_id} do
      _task = completed_task(session_id)

      assert {:error, {:too_many_tasks, :max_task_records_per_owner}} =
               create_task_raw(session_id)

      other_session_id = Utils.create_session(@server, initialized: true, streams: [self()])

      assert %Task{} = create_task(other_session_id)
    end

    @tag task_opts: %{
           max_task_records_per_owner: 1,
           max_tasks_per_session: 1,
           max_tasks_per_principal: 1
         }
    test "the records of a principal count in all its sessions", %{session_id: session_id} do
      alice = OzMcp.Auth.Principal.new!(issuer: "https://issuer.test", subject: "alice")
      bob = OzMcp.Auth.Principal.new!(issuer: "https://issuer.test", subject: "bob")

      _task = completed_task(session_id, %{principal: alice})

      other_session_id = Utils.create_session(@server, initialized: true, streams: [self()])

      assert {:error, {:too_many_tasks, :max_task_records_per_owner}} =
               create_task_raw(other_session_id, %{principal: alice})

      assert %Task{} = create_task(session_id, %{principal: bob})
    end

    @tag task_opts: %{
           max_task_records_per_owner: 1,
           max_tasks_per_session: 1,
           max_tasks_per_principal: 1
         }
    test "a record that expires frees the slot", %{session_id: session_id} do
      #
      # No read of the record: with a short ttl the record can expire before
      # a read. The wait is for the expiry itself.
      #
      task = create_task(session_id, ttl: 100)

      wait_until(fn -> EtsStore.get(@server, task.taskId) == :not_found end)

      assert %Task{} = create_task(session_id)
    end
  end

  describe "a store failure in the limit check" do
    #
    # The reads of the limits come from the store. A wrong answer, a
    # raise or an exit is a failure of the store, not a limit: the create
    # gives `{:error, :unavailable}` and no limit event.
    #
    @tag task_opts: %{task_store: Support.TasksStores.Failing}
    test "a create with a runner gives :unavailable when the store fails in owner_usage", %{
      session_id: session_id
    } do
      on_exit(fn -> Support.TasksStores.Failing.clear_instance(@server) end)
      ref = TelemetryCapture.attach()

      for mode <- [:error, :raise, :exit] do
        Support.TasksStores.Failing.arm(@server, :owner_usage, mode)

        assert {:error, :unavailable} = create_task_raw(session_id)
        assert TaskScan.all(@server) == []
        assert [] = limit_events(ref)
      end

      # The store answers again: the same create succeeds.
      #
      Support.TasksStores.Failing.clear(@server, :owner_usage)

      assert %Task{} = create_task(session_id)
    end

    @tag task_opts: %{task_store: Support.TasksStores.Failing}
    test "a settled create gives :unavailable when the store fails in owner_usage", %{
      session_id: session_id
    } do
      on_exit(fn -> Support.TasksStores.Failing.clear_instance(@server) end)
      ref = TelemetryCapture.attach()

      settled = {:failed, "The tool execution reported an error.", {:ok, %{isError: true}}}

      for mode <- [:error, :raise, :exit] do
        Support.TasksStores.Failing.arm(@server, :owner_usage, mode)

        assert {:error, :unavailable} = create_task_raw(session_id, %{settled: settled})
        assert TaskScan.all(@server) == []
        assert [] = limit_events(ref)
      end

      # The store answers again: the same settled create succeeds.
      #
      Support.TasksStores.Failing.clear(@server, :owner_usage)

      assert {:ok, %Task{status: :failed}} = create_task_raw(session_id, %{settled: settled})
    end

    @tag task_opts: %{task_store: Support.TasksStores.Failing}
    test "a create with a runner gives :unavailable when the store fails in count_active", %{
      session_id: session_id
    } do
      on_exit(fn -> Support.TasksStores.Failing.clear_instance(@server) end)
      ref = TelemetryCapture.attach()

      for mode <- [:error, :raise, :exit] do
        Support.TasksStores.Failing.arm(@server, :count_active, mode)

        assert {:error, :unavailable} = create_task_raw(session_id)
        assert TaskScan.all(@server) == []
        assert [] = limit_events(ref)
      end

      # The settled path reads no active counter: the same create succeeds.
      #
      settled = {:failed, "The tool execution reported an error.", {:ok, %{isError: true}}}

      assert {:ok, %Task{status: :failed}} = create_task_raw(session_id, %{settled: settled})

      # The store answers again: the create with a runner succeeds.
      #
      Support.TasksStores.Failing.clear(@server, :count_active)

      assert %Task{} = create_task(session_id)
    end

    defp limit_events(ref) do
      ref
      |> TelemetryCapture.drain(@server)
      |> Enum.filter(fn {name, _, _} -> name == [:oz_mcp, :limit, :reached] end)
    end
  end

  describe "the counters of the active tasks" do
    test "the counters and the scan agree at each step of the lifecycle", %{
      session_id: session_id
    } do
      owner = Utils.owner(session_id)
      assert_agree(session_id, owner)

      # create: the task is working and holds a slot
      #
      task = create_slow_task_only(session_id, %{})
      assert Records.count_active(EtsStore, @server, {:session, session_id}) == 1
      assert Records.count_active(EtsStore, @server, {:owner, owner}) == 1
      assert_agree(session_id, owner)

      # the normal end frees the slot
      #
      finish_runners([task])

      assert {:ok, {:ok, _}} = Tasks.await(@server, owner, task.taskId, 5_000)
      assert Records.count_active(EtsStore, @server, {:session, session_id}) == 0
      assert_agree(session_id, owner)

      # a cancel frees the slot
      #
      task = create_slow_task_only(session_id, %{})

      assert {:ok, %Task{status: :cancelled}} = Tasks.cancel(@server, owner, task.taskId)
      assert Records.count_active(EtsStore, @server, {:session, session_id}) == 0
      assert_agree(session_id, owner)

      # the expiry of a working task frees the slot
      #
      task = create_slow_task_only(session_id, %{ttl: 1_000})
      assert Records.count_active(EtsStore, @server, {:session, session_id}) == 1
      assert_agree(session_id, owner)

      wait_until(fn -> EtsStore.get(@server, task.taskId) == :not_found end)
      assert Records.count_active(EtsStore, @server, {:session, session_id}) == 0
      assert_agree(session_id, owner)

      # a crash: the reaper writes failed and frees the slot
      #
      task = create_slow_task_only(session_id, %{})
      {:ok, pid} = OzMcp.Instance.whereis(@server, {:task, task.taskId})
      assert Records.count_active(EtsStore, @server, {:session, session_id}) == 1

      Process.exit(pid, :kill)

      wait_until(fn ->
        match?({:ok, %{status: :failed}}, Tasks.get(@server, owner, task.taskId))
      end)

      assert Records.count_active(EtsStore, @server, {:session, session_id}) == 0
      assert Records.count_active(EtsStore, @server, {:owner, owner}) == 0
      assert_agree(session_id, owner)
      assert active_counter_entries() == []
    end

    @tag :capture_log
    test "a kill of the task process brings the counters back to 0", %{session_id: session_id} do
      owner = Utils.owner(session_id)
      {task, _runner} = create_slow_task(session_id)
      {:ok, pid} = OzMcp.Instance.whereis(@server, {:task, task.taskId})

      assert Records.count_active(EtsStore, @server, {:session, session_id}) == 1
      assert Records.count_active(EtsStore, @server, {:owner, owner}) == 1

      Process.exit(pid, :kill)

      wait_until(fn ->
        match?({:ok, %{status: :failed}}, Tasks.get(@server, owner, task.taskId))
      end)

      assert Records.count_active(EtsStore, @server, {:session, session_id}) == 0
      assert Records.count_active(EtsStore, @server, {:owner, owner}) == 0
      assert active_counter_entries() == []
    end

    @tag task_opts: %{tasks_follow_session: true}
    test "the end of the session empties the counters of its tasks", %{session_id: session_id} do
      owner = Utils.owner(session_id)
      {task, runner} = create_slow_task(session_id)

      assert Records.count_active(EtsStore, @server, {:session, session_id}) == 1
      assert Records.count_active(EtsStore, @server, {:owner, owner}) == 1

      assert :ok = terminate_session_tasks(session_id)

      wait_until(fn -> not Process.alive?(runner) end)
      assert Tasks.get(@server, owner, task.taskId) == {:error, :no_task}

      assert Records.count_active(EtsStore, @server, {:session, session_id}) == 0
      assert Records.count_active(EtsStore, @server, {:owner, owner}) == 0
      assert active_counter_entries() == []
    end

    @tag task_opts: %{tasks_follow_session: true, session_timeout_ms: 100}
    test "a running task holds its session until it ends" do
      session_id = Utils.create_session(@server, initialized: true)
      {:ok, pid} = OzMcp.Instance.whereis(@server, {:session, session_id})
      ref = Process.monitor(pid)
      owner = Utils.owner(session_id)
      {task, runner} = create_slow_task(session_id)

      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 350
      assert {:ok, %{status: :working}} = Tasks.get(@server, owner, task.taskId)

      send(runner, :finish)
      assert {:ok, {:ok, _}} = Tasks.await(@server, owner, task.taskId, 5_000)
      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :idle}}, 2_000
    end

    @tag :capture_log
    @tag task_opts: %{tasks_follow_session: true, session_timeout_ms: 100}
    test "a killed task process lets its session expire" do
      session_id = Utils.create_session(@server, initialized: true)
      {:ok, pid} = OzMcp.Instance.whereis(@server, {:session, session_id})
      ref = Process.monitor(pid)
      {task, _runner} = create_slow_task(session_id)
      {:ok, task_pid} = OzMcp.Instance.whereis(@server, {:task, task.taskId})

      Process.exit(task_pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :idle}}, 2_000
    end
  end

  describe "runner outcomes" do
    test "{:ok, result} completes the task, stores the outcome and notifies the session", %{
      session_id: session_id
    } do
      task = create_task(session_id)

      assert {:ok, {:ok, result}} =
               Tasks.await(@server, Utils.owner(session_id), task.taskId, 5_000)

      assert is_map(result)
      assert result[:isError] == nil

      assert_status_notification(task.taskId, "completed")
    end

    test "isError: true fails the task but keeps the tool result (A6)", %{session_id: session_id} do
      task =
        create_task(session_id, tool: {Support.Entities.Tools.TaskIsErrorTest, "task_is_error"})

      assert {:ok, {:ok, result}} =
               Tasks.await(@server, Utils.owner(session_id), task.taskId, 5_000)

      assert result[:isError] == true

      assert {:ok, stored} = Tasks.get(@server, Utils.owner(session_id), task.taskId)
      assert stored.status == :failed
      assert stored.statusMessage == "The tool execution reported an error."

      assert_status_notification(task.taskId, "failed")
    end

    test "an unbuilt %CallToolResult{} struct is built and fails the task like a built result", %{
      session_id: session_id
    } do
      task =
        create_task(session_id,
          tool: {Support.Entities.Tools.TaskUnbuiltStructTest, "task_unbuilt"}
        )

      assert {:ok, {:ok, result}} =
               Tasks.await(@server, Utils.owner(session_id), task.taskId, 5_000)

      assert result == %{
               content: [%{type: "text", text: "tool failure"}],
               isError: true
             }

      assert {:ok, stored} = Tasks.get(@server, Utils.owner(session_id), task.taskId)
      assert stored.status == :failed
      assert stored.statusMessage == "The tool execution reported an error."

      assert_status_notification(task.taskId, "failed")
    end

    test "{:error, %Error{}} fails the task with the error outcome", %{session_id: session_id} do
      task = create_task(session_id, tool: {Support.Entities.Tools.TaskErrorTest, "task_error"})

      assert {:ok, {:error, err}} =
               Tasks.await(@server, Utils.owner(session_id), task.taskId, 5_000)

      assert err == %{code: -32000, message: "boom", data: nil}

      assert {:ok, stored} = Tasks.get(@server, Utils.owner(session_id), task.taskId)
      assert stored.status == :failed
      assert stored.statusMessage == "boom"
    end

    test "{:error, plain map} fails the task with the error outcome", %{session_id: session_id} do
      task =
        create_task(session_id,
          tool: {Support.Entities.Tools.TaskErrorTest, "task_error"},
          request: %{"name" => "task_error", "arguments" => %{"shape" => "plain_map"}}
        )

      assert {:ok, {:error, err}} =
               Tasks.await(@server, Utils.owner(session_id), task.taskId, 5_000)

      assert err == %{code: -32000, message: "boom", data: %{"detail" => "extra"}}

      assert {:ok, stored} = Tasks.get(@server, Utils.owner(session_id), task.taskId)
      assert stored.status == :failed
      assert stored.statusMessage == "boom"
    end

    @tag :capture_log
    test "a crashing runner fails the task with -32603 (A5)", %{session_id: session_id} do
      task = create_task(session_id, tool: {Support.Entities.Tools.TaskCrashTest, "task_crash"})

      assert {:ok, {:error, err}} =
               Tasks.await(@server, Utils.owner(session_id), task.taskId, 5_000)

      assert err.code == -32603
      assert err.message == "internal error"

      assert {:ok, stored} = Tasks.get(@server, Utils.owner(session_id), task.taskId)
      assert stored.status == :failed
      assert stored.statusMessage == "internal error"
    end

    @tag :capture_log
    test "a task tool that returns a map with no content gives a failed task", %{
      session_id: session_id
    } do
      task =
        create_task(session_id,
          tool: {Support.Entities.Tools.TaskBadShapeTest, "task_bad_shape"},
          request: %{"name" => "task_bad_shape", "arguments" => %{"shape" => "empty_map"}}
        )

      owner = Utils.owner(session_id)

      assert {:ok, {:error, %{code: -32603, message: "internal error"}}} =
               Tasks.await(@server, owner, task.taskId, 5_000)

      assert {:ok, %Task{status: :failed, statusMessage: "internal error"}} =
               Tasks.get(@server, owner, task.taskId)
    end

    @tag :capture_log
    test "a task tool that returns a bad top-level _meta key gives a failed task", %{
      session_id: session_id
    } do
      task =
        create_task(session_id,
          tool: {Support.Entities.Tools.TaskBadShapeTest, "task_bad_shape"},
          request: %{"name" => "task_bad_shape", "arguments" => %{"shape" => "bad_meta"}}
        )

      owner = Utils.owner(session_id)

      assert {:ok, {:error, %{code: -32603, message: "internal error"}}} =
               Tasks.await(@server, owner, task.taskId, 5_000)

      assert {:ok, %Task{status: :failed, statusMessage: "internal error"}} =
               Tasks.get(@server, owner, task.taskId)
    end

    @tag :capture_log
    test "a task tool that returns a reserved _meta prefix gives a failed task", %{
      session_id: session_id
    } do
      task =
        create_task(session_id,
          tool: {Support.Entities.Tools.TaskBadShapeTest, "task_bad_shape"},
          request: %{"name" => "task_bad_shape", "arguments" => %{"shape" => "reserved_meta"}}
        )

      owner = Utils.owner(session_id)

      assert {:ok, {:error, %{code: -32603, message: "internal error"}}} =
               Tasks.await(@server, owner, task.taskId, 5_000)

      assert {:ok, %Task{status: :failed, statusMessage: "internal error"}} =
               Tasks.get(@server, owner, task.taskId)
    end

    test "a task tool that returns the _meta key of the framework completes", %{
      session_id: session_id
    } do
      task =
        create_task(session_id,
          tool: {Support.Entities.Tools.TaskBadShapeTest, "task_bad_shape"},
          request: %{"name" => "task_bad_shape", "arguments" => %{"shape" => "framework_meta"}}
        )

      owner = Utils.owner(session_id)

      assert {:ok, {:ok, %{content: [], _meta: _}}} =
               Tasks.await(@server, owner, task.taskId, 5_000)

      assert {:ok, %Task{status: :completed}} = Tasks.get(@server, owner, task.taskId)
    end

    @tag :capture_log
    test "a task tool that returns a string gives a failed task", %{session_id: session_id} do
      task =
        create_task(session_id,
          tool: {Support.Entities.Tools.TaskBadShapeTest, "task_bad_shape"},
          request: %{"name" => "task_bad_shape", "arguments" => %{"shape" => "text"}}
        )

      owner = Utils.owner(session_id)

      assert {:ok, {:error, %{code: -32603, message: "internal error"}}} =
               Tasks.await(@server, owner, task.taskId, 5_000)

      assert {:ok, %Task{status: :failed, statusMessage: "internal error"}} =
               Tasks.get(@server, owner, task.taskId)
    end

    test "a task tool that returns a map with content still completes", %{session_id: session_id} do
      owner = Utils.owner(session_id)

      string_content =
        create_task(session_id,
          tool: {Support.Entities.Tools.TaskBadShapeTest, "task_bad_shape"},
          request: %{"name" => "task_bad_shape", "arguments" => %{"shape" => "string_content"}}
        )

      assert {:ok, {:ok, %{content: [%{"type" => "text", "text" => "ok"}]}}} =
               Tasks.await(@server, owner, string_content.taskId, 5_000)

      assert {:ok, %Task{status: :completed}} = Tasks.get(@server, owner, string_content.taskId)

      built =
        create_task(session_id,
          tool: {Support.Entities.Tools.TaskBadShapeTest, "task_bad_shape"},
          request: %{"name" => "task_bad_shape", "arguments" => %{}}
        )

      assert {:ok, {:ok, %{content: [%{type: "text", text: "ok"}]}}} =
               Tasks.await(@server, owner, built.taskId, 5_000)

      assert {:ok, %Task{status: :completed}} = Tasks.get(@server, owner, built.taskId)
    end
  end

  describe "the task process" do
    @tag :capture_log
    test "a non-map result of the runner makes a failed task", %{session_id: session_id} do
      {task, _runner} = create_slow_task(session_id)
      {:ok, pid} = OzMcp.Instance.whereis(@server, {:task, task.taskId})

      send(pid, {:runner_finished, {:ok, "text"}})

      owner = Utils.owner(session_id)

      assert {:ok, {:error, %{code: -32603, message: "internal error"}}} =
               Tasks.await(@server, owner, task.taskId, 5_000)

      assert {:ok, %Task{status: :failed, statusMessage: "internal error"}} =
               Tasks.get(@server, owner, task.taskId)
    end

    test "a terminal status stops the process and the record keeps the result", %{
      session_id: session_id
    } do
      {task, runner} = create_slow_task(session_id)
      {:ok, pid} = OzMcp.Instance.whereis(@server, {:task, task.taskId})
      ref = Process.monitor(pid)

      send(runner, :finish)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
      assert {:ok, record} = EtsStore.get(@server, task.taskId)
      assert record.status == :completed
      assert record.pid == nil
      assert record.expires_at_ms != nil
    end

    test "the progress and the status message keep last_updated_at", %{session_id: session_id} do
      {task, runner} = create_slow_task(session_id, %{progress_token: "pt-2"})
      assert {:ok, before_record} = EtsStore.get(@server, task.taskId)

      # The wait is part of the check: time must pass, so an update of
      # `last_updated_at` could not hide behind equal timestamps.
      #
      Process.sleep(20)
      Tasks.progress(@server, task.taskId, 1, 2, "step")
      Tasks.status_message(@server, task.taskId, "halfway")
      Utils.sync_task(@server, task.taskId)

      assert {:ok, record} = EtsStore.get(@server, task.taskId)
      assert record.status_message == "halfway"
      assert record.last_updated_at == before_record.last_updated_at

      assert {:ok, out_id, _task_pid} =
               Tasks.request(@server, task.taskId, "elicitation/create", nil)

      Utils.sync_task(@server, task.taskId)

      assert {:ok, changed} = EtsStore.get(@server, task.taskId)
      assert DateTime.compare(changed.last_updated_at, before_record.last_updated_at) == :gt

      assert :ok = Tasks.cancel_request(@server, task.taskId, out_id)

      send(runner, :finish)
    end

    test "a cancel stops the runner with the exit :shutdown", %{session_id: session_id} do
      {task, runner} = create_slow_task(session_id)
      ref = Process.monitor(runner)

      assert {:ok, %Task{status: :cancelled}} =
               Tasks.cancel(@server, Utils.owner(session_id), task.taskId)

      assert_receive {:DOWN, ^ref, :process, ^runner, :shutdown}, 5_000
    end

    test "the waiters of a terminal task get the result at once", %{session_id: session_id} do
      {task, runner} = create_slow_task(session_id)

      await_in_background(session_id, task.taskId, nil)
      wait_until(fn -> waiter_registered?(task.taskId) end)

      send(runner, :finish)
      assert_receive {:awaited, {:ok, {:ok, _}}}, 5_000

      assert {:ok, {:ok, _}} = Tasks.await(@server, Utils.owner(session_id), task.taskId, 100)
    end
  end

  describe "the runner and the await waiters" do
    @tag :capture_log
    test "a kill of the task process stops its runner", %{session_id: session_id} do
      {task, runner} = create_slow_task(session_id)
      {:ok, pid} = OzMcp.Instance.whereis(@server, {:task, task.taskId})

      Process.exit(pid, :kill)

      wait_until(fn -> not Process.alive?(runner) end)
    end

    @tag :capture_log
    test "a runner that is killed fails the task and the task process survives the exit message",
         %{session_id: session_id} do
      {task, runner} = create_slow_task(session_id)

      Process.exit(runner, :kill)

      wait_until(fn ->
        match?(
          {:ok, %{status: :failed}},
          Tasks.get(@server, Utils.owner(session_id), task.taskId)
        )
      end)

      assert {:ok, stored} = Tasks.get(@server, Utils.owner(session_id), task.taskId)
      assert stored.statusMessage == "The task runner crashed."
    end

    @tag :capture_log
    test "a runner that dies with a big reason fails the task with the fixed message and logs the reason",
         %{session_id: session_id} do
      owner = Utils.owner(session_id)
      {task, runner} = create_slow_task(session_id)

      marker = "runner-crash-marker"

      reason =
        {:runner_boom, String.duplicate(marker <> " ", 300),
         [{__MODULE__, :test_runner_exit, 0, [file: ~c"task_test.exs", line: 1]}]}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Process.exit(runner, reason)

          wait_until(fn ->
            match?({:ok, %{status: :failed}}, Tasks.get(@server, owner, task.taskId))
          end)
        end)

      assert {:ok, stored} = Tasks.get(@server, owner, task.taskId)
      assert stored.statusMessage == "The task runner crashed."

      # The notification carries the record: its message is fixed too.
      #
      {_, notification} = Utils.receive_event(5_000)
      assert notification["method"] == "notifications/tasks/status"
      params = notification["params"]
      assert params["taskId"] == task.taskId
      assert params["status"] == "failed"
      assert params["statusMessage"] == "The task runner crashed."

      # The reason goes to the log, cut to a small size.
      #
      assert log =~ "runner crashed:"
      assert log =~ marker

      reason_line =
        log |> String.split("\n") |> Enum.find(&String.contains?(&1, "runner crashed:"))

      logged_reason = reason_line |> String.split("runner crashed: ") |> List.last()

      # The text of the reason is cut to about 2000 bytes and an ellipsis
      # follows: the log never carries the whole 6000-byte marker. The
      # small slack over the cut absorbs the bytes that the Logger
      # formatter can put around the message in the captured line.
      #
      assert byte_size(logged_reason) <= 2_000 + 100
      assert String.valid?(logged_reason)
    end

    @tag :capture_log
    test "a crash reason with a newline stays on one log line", %{session_id: session_id} do
      {task, runner} = create_slow_task(session_id)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Process.exit(runner, {:runner_boom, "first line\nsecond line"})

          wait_until(fn ->
            match?(
              {:ok, %{status: :failed}},
              Tasks.get(@server, Utils.owner(session_id), task.taskId)
            )
          end)
        end)

      lines = Enum.filter(String.split(log, "\n"), &String.contains?(&1, "runner crashed:"))
      assert length(lines) == 1

      # The newline of the reason is escaped: the log has one line only.
      #
      assert lines |> List.last() |> String.contains?(~S(first line\nsecond line))
    end

    @tag :capture_log
    test "a shutdown of the task supervisor stops the task, writes a failed record and stops its runner",
         %{session_id: session_id} do
      owner = Utils.owner(session_id)
      {task, runner} = create_slow_task(session_id)
      {:ok, pid} = OzMcp.Instance.whereis(@server, {:task, task.taskId})

      assert :ok = DynamicSupervisor.terminate_child(OzMcp.Instance.via(@server, :tasks), pid)

      wait_until(fn ->
        match?({:ok, %{status: :failed}}, Tasks.get(@server, owner, task.taskId))
      end)

      assert {:ok, stored} = Tasks.get(@server, owner, task.taskId)
      assert stored.statusMessage == "The server stopped the task."

      assert_status_notification(task.taskId, "failed")

      wait_until(fn -> not Process.alive?(runner) end)

      assert Records.count_active(EtsStore, @server, {:session, session_id}) == 0
      assert Records.count_active(EtsStore, @server, {:owner, owner}) == 0
      assert_agree(session_id, owner)
      assert active_counter_entries() == []
    end

    test "a caller of await that stops leaves no entry in the task", %{session_id: session_id} do
      {task, runner} = create_slow_task(session_id)

      caller =
        spawn(fn -> Tasks.await(@server, Utils.owner(session_id), task.taskId, :infinity) end)

      wait_until(fn -> waiter_registered?(task.taskId) end)
      assert [{_from, ref}] = task_waiters(task.taskId)
      assert is_reference(ref)

      Process.exit(caller, :kill)

      wait_until(fn -> task_waiters(task.taskId) == [] end)

      send(runner, :finish)
    end

    test "a caller that times out leaves no entry", %{session_id: session_id} do
      {task, runner} = create_slow_task(session_id)

      for _ <- 1..100 do
        assert {:error, :timeout} =
                 Tasks.await(@server, Utils.owner(session_id), task.taskId, 10)
      end

      assert task_waiters(task.taskId) == []

      send(runner, :finish)
    end

    test "a live await gives the result and leaves no monitor", %{session_id: session_id} do
      {task, runner} = create_slow_task(session_id)
      {:ok, task_pid} = OzMcp.Instance.whereis(@server, {:task, task.taskId})

      waiter =
        Elixir.Task.async(fn ->
          answer = Tasks.await(@server, Utils.owner(session_id), task.taskId, 5_000)
          {answer, Process.info(self(), :monitored_by)}
        end)

      wait_until(fn -> waiter_registered?(task.taskId) end)
      assert {:monitored_by, monitored} = Process.info(waiter.pid, :monitored_by)
      assert task_pid in monitored

      send(runner, :finish)

      assert {{:ok, {:ok, _}}, {:monitored_by, monitored}} = Elixir.Task.await(waiter, 5_000)
      refute task_pid in monitored
    end

    test "an await with no timeout arms no await timer and still gets the result", %{
      session_id: session_id
    } do
      {task, runner} = create_slow_task(session_id)

      await_in_background(session_id, task.taskId, nil)
      wait_until(fn -> waiter_registered?(task.taskId) end)

      # The wait is part of the check: the waiter holds while the task works.
      #
      refute_receive {:awaited, _}, 300

      send(runner, :finish)
      assert_receive {:awaited, {:ok, {:ok, _}}}, 5_000
    end
  end

  describe "a runner that cannot start" do
    test "the create returns the failed task, with no process and no notification", %{
      session_id: session_id
    } do
      owner = Utils.owner(session_id)
      supervisor = stop_calls_child()

      task = create_task(session_id)

      assert task.status == :failed
      assert task.statusMessage == "The task runner cannot start."

      # tasks/get shows the same terminal record
      #
      assert {:ok, stored} = Tasks.get(@server, owner, task.taskId)
      assert stored.status == :failed
      assert stored.statusMessage == "The task runner cannot start."

      # The record holds no pid of a process
      #
      assert {:ok, record} = EtsStore.get(@server, task.taskId)
      assert record.pid == nil
      assert record.runner_pid == nil

      # tasks/result replays the generic internal error
      #
      assert {:ok, {:error, %{code: -32_603, message: "internal error", data: nil}}} =
               Tasks.await(@server, owner, task.taskId, 5_000)

      # No process of the task stays registered for its id
      #
      wait_until(fn ->
        match?(:not_running, OzMcp.Instance.whereis(@server, {:task, task.taskId}))
      end)

      # No status notification goes out: no client knew the id of the task
      #
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 200

      # The store holds no active task for the session and the owner
      #
      assert Records.count_active(EtsStore, @server, {:session, session_id}) == 0
      assert Records.count_active(EtsStore, @server, owner) == 0
      assert_agree(session_id, owner)

      restart_calls_child(supervisor)

      # A normal start does not change
      #
      task = create_task(session_id)
      assert task.status == :working

      assert {:ok, {:ok, _}} = Tasks.await(@server, owner, task.taskId, 5_000)
    end
  end

  describe "output schema" do
    test "a structuredContent matching the outputSchema completes the task", %{
      session_id: session_id
    } do
      task = create_structured_task(session_id, "valid")

      assert {:ok, {:ok, result}} =
               Tasks.await(@server, Utils.owner(session_id), task.taskId, 5_000)

      assert result[:structuredContent] == %{"result" => "ok"}

      assert {:ok, stored} = Tasks.get(@server, Utils.owner(session_id), task.taskId)
      assert stored.status == :completed

      assert_status_notification(task.taskId, "completed")
    end

    test "a structuredContent with atom keys completes the task, as the wire form passes", %{
      session_id: session_id
    } do
      task = create_structured_task(session_id, "atom_keys")

      assert {:ok, {:ok, result}} =
               Tasks.await(@server, Utils.owner(session_id), task.taskId, 5_000)

      assert result[:structuredContent] == %{result: "ok"}

      assert {:ok, stored} = Tasks.get(@server, Utils.owner(session_id), task.taskId)
      assert stored.status == :completed
    end

    test "a structuredContent that violates the outputSchema fails the task", %{
      session_id: session_id
    } do
      task = create_structured_task(session_id, "wrong")

      assert {:ok, {:error, err}} =
               Tasks.await(@server, Utils.owner(session_id), task.taskId, 5_000)

      assert err == %{
               code: -32603,
               message: "tool output does not match outputSchema",
               data: ["'result' value is not of type string"]
             }

      assert {:ok, stored} = Tasks.get(@server, Utils.owner(session_id), task.taskId)
      assert stored.status == :failed
      assert stored.statusMessage == "tool output does not match outputSchema"

      assert_status_notification(task.taskId, "failed")
    end

    test "a missing structuredContent fails the task", %{session_id: session_id} do
      task = create_structured_task(session_id, "missing")

      assert {:ok, {:error, err}} =
               Tasks.await(@server, Utils.owner(session_id), task.taskId, 5_000)

      assert err == %{
               code: -32603,
               message: "tool output does not match outputSchema",
               data: ["'structuredContent' is missing, the tool declares an outputSchema"]
             }

      assert {:ok, stored} = Tasks.get(@server, Utils.owner(session_id), task.taskId)
      assert stored.status == :failed
      assert stored.statusMessage == "tool output does not match outputSchema"
    end

    test "an isError result fails the task with the tool result, never an output error", %{
      session_id: session_id
    } do
      task = create_structured_task(session_id, "is_error")

      assert {:ok, {:ok, result}} =
               Tasks.await(@server, Utils.owner(session_id), task.taskId, 5_000)

      assert result[:isError] == true

      assert {:ok, stored} = Tasks.get(@server, Utils.owner(session_id), task.taskId)
      assert stored.status == :failed
      assert stored.statusMessage == "The tool execution reported an error."
    end

    test "without an output_schema attribute, a violating result completes the task", %{
      session_id: session_id
    } do
      task = create_structured_task(session_id, "wrong", output_schema: nil)

      assert {:ok, {:ok, result}} =
               Tasks.await(@server, Utils.owner(session_id), task.taskId, 5_000)

      assert result[:structuredContent] == %{"result" => 42}

      assert {:ok, stored} = Tasks.get(@server, Utils.owner(session_id), task.taskId)
      assert stored.status == :completed
    end

    @tag :capture_log
    test "a schema that does not compile fails the task as an internal error and the runner does not crash",
         %{session_id: session_id} do
      #
      # The handler refuses such a schema before the create, so only a
      # direct call of the create reaches the check of the runner.
      #
      bad_schema = %{type: "object", properties: %{result: %{type: "float"}}}
      owner = Utils.owner(session_id)

      # The capture reads the log of every process, so the checks look for
      # the line of this task id.
      #
      {task, log} =
        ExUnit.CaptureLog.with_log(fn ->
          task = create_task(session_id, %{output_schema: bad_schema})

          assert {:ok, {:error, err}} = Tasks.await(@server, owner, task.taskId, 5_000)
          assert err == %{code: -32603, message: "internal error", data: nil}

          assert {:ok, stored} = Tasks.get(@server, owner, task.taskId)
          assert stored.status == :failed
          assert stored.statusMessage == "internal error"

          assert_status_notification(task.taskId, "failed")
          task
        end)

      # The guard of the runner logged the defect. The runner did not
      # crash: no line of a `:DOWN` of this runner is in the log.
      #
      assert log =~ "user callback crashed"
      assert log =~ "the output schema of the tool does not compile"
      refute log =~ "task #{task.taskId} runner crashed"
    end
  end

  describe "cancel" do
    test "cancels a working task, kills the runner and stores the cancel outcome (A4)", %{
      session_id: session_id
    } do
      {task, runner} = create_slow_task(session_id)
      runner_ref = Process.monitor(runner)

      assert {:ok, cancelled} = Tasks.cancel(@server, Utils.owner(session_id), task.taskId)
      assert cancelled.status == :cancelled
      assert cancelled.statusMessage == "The task was cancelled by request."

      # The cancel kills the runner: the DOWN of the runner arrives.
      #
      assert_receive {:DOWN, ^runner_ref, :process, ^runner, _}, 5_000

      assert {:ok, {:error, err}} =
               Tasks.await(@server, Utils.owner(session_id), task.taskId, 1_000)

      assert err == %{code: -32800, message: "task was cancelled", data: nil}

      assert_status_notification(task.taskId, "cancelled")
    end

    test "refuses to cancel a terminal task", %{session_id: session_id} do
      task = create_task(session_id)

      assert {:ok, {:ok, _}} =
               Tasks.await(@server, Utils.owner(session_id), task.taskId, 5_000)

      assert {:error, {:terminal, :completed}} =
               Tasks.cancel(@server, Utils.owner(session_id), task.taskId)
    end
  end

  describe "terminate_session_tasks" do
    test "kills a working task's runner, deletes the record and fails the waiter", %{
      session_id: session_id
    } do
      {task, runner} = create_slow_task(session_id)
      assert task.ttl == 86_400_000

      await_in_background(session_id, task.taskId, 10_000)
      wait_until(fn -> waiter_registered?(task.taskId) end)

      runner_ref = Process.monitor(runner)
      assert :ok = terminate_session_tasks(session_id)

      # The terminate kills the runner: the DOWN of the runner arrives.
      #
      assert_receive {:DOWN, ^runner_ref, :process, ^runner, _}, 5_000

      assert Tasks.get(@server, Utils.owner(session_id), task.taskId) == {:error, :no_task}
      assert Support.Helpers.TaskScan.all(@server) == []
      assert :ets.tab2list(Index.index_table(@server)) == []

      assert_receive {:awaited, {:error, :session_terminated}}, 5_000

      # The wait is part of the check: no status notification follows the end.
      #
      refute_receive {:oz_mcp_stream, _, {:event, _, %{method: "notifications/tasks/status"}}},
                     50
    end

    test "kills an input_required task and fails its waiter", %{session_id: session_id} do
      {task, runner} = create_slow_task(session_id)

      assert {:ok, out_id, _task_pid} =
               Tasks.request(@server, task.taskId, "elicitation/create", nil)

      Utils.sync_task(@server, task.taskId)

      assert {:ok, stored} = Tasks.get(@server, Utils.owner(session_id), task.taskId)
      assert stored.status == :input_required

      assert_status_notification(task.taskId, "input_required")

      await_in_background(session_id, task.taskId, 10_000)
      wait_until(fn -> waiter_registered?(task.taskId) end)

      runner_ref = Process.monitor(runner)
      assert :ok = terminate_session_tasks(session_id)

      # The terminate kills the runner: the DOWN of the runner arrives.
      #
      assert_receive {:DOWN, ^runner_ref, :process, ^runner, _}, 5_000
      assert Tasks.get(@server, Utils.owner(session_id), task.taskId) == {:error, :no_task}

      assert_receive {:awaited, {:error, :session_terminated}}, 5_000

      # The test process is the waiter of the held request: the end of the
      # session ends its wait too.
      #
      assert_receive {:oz_mcp_client_answer, ^out_id, {:error, :session_terminated}}, 5_000

      # The wait is part of the check: no status notification follows the end.
      #
      refute_receive {:oz_mcp_stream, _, {:event, _, %{method: "notifications/tasks/status"}}},
                     50
    end

    test "deletes terminal records without a transition raise or notification", %{
      session_id: session_id
    } do
      completed = create_task(session_id)

      assert {:ok, {:ok, _}} =
               Tasks.await(@server, Utils.owner(session_id), completed.taskId, 5_000)

      assert_status_notification(completed.taskId, "completed")

      {cancelled, runner} = create_slow_task(session_id)

      assert {:ok, _} = Tasks.cancel(@server, Utils.owner(session_id), cancelled.taskId)
      assert_status_notification(cancelled.taskId, "cancelled")

      assert :ok = terminate_session_tasks(session_id)

      assert Tasks.get(@server, Utils.owner(session_id), completed.taskId) ==
               {:error, :no_task}

      assert Tasks.get(@server, Utils.owner(session_id), cancelled.taskId) ==
               {:error, :no_task}

      assert Support.Helpers.TaskScan.all(@server) == []

      refute_receive {:oz_mcp_stream, _, {:event, _, %{method: "notifications/tasks/status"}}}, 50

      refute Process.alive?(runner)
    end

    test "is a no-op for an unknown session and leaves other tasks intact", %{
      session_id: session_id
    } do
      task = create_task(session_id)

      assert :ok = terminate_session_tasks("stranger")

      assert {:ok, _} = Tasks.get(@server, Utils.owner(session_id), task.taskId)
    end

    test "the cast form kills the runner and deletes the records of the session", %{
      session_id: session_id
    } do
      {task, runner} = create_slow_task(session_id)

      assert :ok = Tasks.terminate_session_async(@server, session_id)

      wait_until(fn -> not Process.alive?(runner) end)

      wait_until(fn ->
        Tasks.get(@server, Utils.owner(session_id), task.taskId) == {:error, :no_task}
      end)

      wait_until(fn -> Support.Helpers.TaskScan.all(@server) == [] end)
      assert :ets.tab2list(Index.index_table(@server)) == []

      refute_receive {:oz_mcp_stream, _, {:event, _, %{method: "notifications/tasks/status"}}}, 50
    end

    test "the cast form fails the waiters of tasks/result with :session_terminated", %{
      session_id: session_id
    } do
      {task, _runner} = create_slow_task(session_id)

      await_in_background(session_id, task.taskId, 10_000)
      wait_until(fn -> waiter_registered?(task.taskId) end)

      assert :ok = Tasks.terminate_session_async(@server, session_id)

      assert_receive {:awaited, {:error, :session_terminated}}, 5_000

      wait_until(fn ->
        Tasks.get(@server, Utils.owner(session_id), task.taskId) == {:error, :no_task}
      end)

      refute_receive {:oz_mcp_stream, _, {:event, _, %{method: "notifications/tasks/status"}}}, 50
    end
  end

  describe "await_result" do
    test "returns immediately for a terminal task", %{session_id: session_id} do
      task = create_task(session_id)

      assert {:ok, {:ok, _}} =
               Tasks.await(@server, Utils.owner(session_id), task.taskId, 5_000)
    end

    test "blocks until the task completes", %{session_id: session_id} do
      {task, runner} = create_slow_task(session_id)

      await_in_background(session_id, task.taskId, 5_000)
      wait_until(fn -> waiter_registered?(task.taskId) end)

      send(runner, :finish)

      assert_receive {:awaited, {:ok, {:ok, _}}}, 5_000
    end

    test "times out with an integer timeout", %{session_id: session_id} do
      {task, runner} = create_slow_task(session_id)

      assert {:error, :timeout} =
               Tasks.await(@server, Utils.owner(session_id), task.taskId, 50)

      send(runner, :finish)
    end

    test "a nil timeout has no limit", %{session_id: session_id} do
      {task, runner} = create_slow_task(session_id)

      await_in_background(session_id, task.taskId, nil)
      wait_until(fn -> waiter_registered?(task.taskId) end)

      refute_receive {:awaited, _}, 200

      send(runner, :finish)
      assert_receive {:awaited, {:ok, {:ok, _}}}, 5_000
    end

    test "an :infinity timeout has no limit", %{session_id: session_id} do
      {task, runner} = create_slow_task(session_id)

      await_in_background(session_id, task.taskId, :infinity)
      wait_until(fn -> waiter_registered?(task.taskId) end)

      refute_receive {:awaited, _}, 200

      send(runner, :finish)
      assert_receive {:awaited, {:ok, {:ok, _}}}, 5_000
    end
  end

  describe "ownership (D2)" do
    test "another session gets :no_task, never an existence leak", %{session_id: session_id} do
      other = Utils.create_session(@server, initialized: true)

      task = create_task(session_id)

      assert {:ok, {:ok, _}} =
               Tasks.await(@server, Utils.owner(session_id), task.taskId, 5_000)

      assert Tasks.get(@server, Utils.owner(other), task.taskId) == {:error, :no_task}
      assert Tasks.cancel(@server, Utils.owner(other), task.taskId) == {:error, :no_task}

      assert Tasks.await(@server, Utils.owner(other), task.taskId, 10) == {:error, :no_task}
    end
  end

  describe "list" do
    test "paginates a session's tasks with an opaque decimal cursor (A10)", %{
      session_id: session_id
    } do
      other = Utils.create_session(@server, initialized: true)

      t1 = create_task(session_id)
      t2 = create_task(session_id)
      t3 = create_task(session_id)
      create_task(other)

      {:ok, page1, cursor} = Tasks.list(@server, Utils.owner(session_id), nil, 2)
      assert Enum.map(page1, & &1.taskId) == [t1.taskId, t2.taskId]
      assert is_binary(cursor)

      {:ok, page2, nil} = Tasks.list(@server, Utils.owner(session_id), cursor, 2)
      assert Enum.map(page2, & &1.taskId) == [t3.taskId]

      {:ok, all, nil} = Tasks.list(@server, Utils.owner(session_id), nil, 50)
      assert Enum.map(all, & &1.taskId) == [t1.taskId, t2.taskId, t3.taskId]

      {:ok, other_tasks, nil} = Tasks.list(@server, Utils.owner(other), nil, 50)
      assert length(other_tasks) == 1
    end

    test "rejects an invalid cursor", %{session_id: session_id} do
      assert {:error, :invalid_cursor} =
               Tasks.list(@server, Utils.owner(session_id), "abc", 10)

      assert {:error, :invalid_cursor} =
               Tasks.list(@server, Utils.owner(session_id), "-1", 10)
    end

    @tag task_opts: %{task_page_size: 2}
    test "a nil limit falls back to the task_page_size opt", %{session_id: session_id} do
      t1 = create_task(session_id)
      t2 = create_task(session_id)
      _t3 = create_task(session_id)

      assert {:ok, tasks, cursor} = Tasks.list(@server, Utils.owner(session_id), nil, nil)
      assert Enum.map(tasks, & &1.taskId) == [t1.taskId, t2.taskId]
      assert is_binary(cursor)
    end
  end

  describe "expiry" do
    test "a record that passed its ttl is removed when it is read", %{session_id: session_id} do
      now = DateTime.utc_now()

      record = %EtsStore{
        task_id: OzMcp.Utils.Generator.task_id(),
        session_id: session_id,
        owner_key: Utils.owner(session_id),
        seq: System.unique_integer([:positive]),
        status: :completed,
        created_at: DateTime.add(now, -10, :second),
        last_updated_at: now,
        ttl: 1,
        result: {:ok, %{}}
      }

      :ok = Records.put(EtsStore, @server, record)

      assert Tasks.get(@server, Utils.owner(session_id), record.task_id) == {:error, :expired}
      assert Tasks.get(@server, Utils.owner(session_id), record.task_id) == {:error, :no_task}
    end

    test "peek reports an expired record and removes nothing", %{session_id: session_id} do
      record = expired_record(session_id)
      :ok = Records.put(EtsStore, @server, record)

      assert Tasks.peek(@server, Utils.owner(session_id), record.task_id) ==
               {:error, :expired}

      assert {:ok, %{task_id: task_id}} = EtsStore.get(@server, record.task_id)
      assert task_id == record.task_id

      assert Tasks.get(@server, Utils.owner(session_id), record.task_id) ==
               {:error, :expired}

      assert EtsStore.get(@server, record.task_id) == :not_found
    end

    test "peek of an expired record sends no expire cast to a live process", %{
      session_id: session_id
    } do
      {task, runner} = create_slow_task(session_id)
      assert {:ok, record} = EtsStore.get(@server, task.taskId)

      expired = %{record | created_at: DateTime.add(DateTime.utc_now(), -10, :second), ttl: 1}
      :ok = Records.put(EtsStore, @server, expired)

      assert Tasks.peek(@server, Utils.owner(session_id), task.taskId) ==
               {:error, :expired}

      {:messages, messages} = Process.info(runner, :messages)
      refute Enum.any?(messages, &match?({:"$gen_cast", :expire}, &1))

      assert {:ok, _record} = EtsStore.get(@server, task.taskId)

      send(runner, :finish)
      wait_until(fn -> not Process.alive?(runner) end)
    end

    test "the ttl ends a working task: the waiters get :expired, the runner stops", %{
      session_id: session_id
    } do
      task = create_slow_task_only(session_id, %{ttl: 1_000})

      await_in_background(session_id, task.taskId, 10_000)
      wait_until(fn -> waiter_registered?(task.taskId) end)

      runner = wait_for_runner()

      assert_receive {:awaited, {:error, :expired}}, 5_000
      wait_until(fn -> not Process.alive?(runner) end)

      assert Tasks.get(@server, Utils.owner(session_id), task.taskId) == {:error, :no_task}
      assert EtsStore.get(@server, task.taskId) == :not_found

      # The expiry sends no status notification.
      #
      refute_receive {:oz_mcp_stream, _, {:event, _, %{method: "notifications/tasks/status"}}}
    end

    test "the ttl abandons the held requests of the task", %{session_id: session_id} do
      task = create_slow_task_only(session_id, %{ttl: 1_000})
      runner = wait_for_runner()

      {out_id, holder} = hold_request(task.taskId)
      {stream, :ok} = attach_stream(session_id, task.taskId)

      wait_until(fn -> EtsStore.get(@server, task.taskId) == :not_found end)

      {:streamed, conn} = answer_stream(stream)

      assert [%{"requestId" => ^out_id, "reason" => "task expired", "_meta" => meta}] =
               cancelled_notices(conn)

      assert meta == %{"io.modelcontextprotocol/related-task" => %{"taskId" => task.taskId}}

      wait_until(fn -> not Process.alive?(runner) end)

      send(holder, :stop)
    end

    test "tasks/cancel and tasks/result of an expired task give :no_task", %{
      session_id: session_id
    } do
      task = create_slow_task_only(session_id, %{ttl: 1_000})
      runner = wait_for_runner()

      wait_until(fn -> not Process.alive?(runner) end)
      wait_until(fn -> EtsStore.get(@server, task.taskId) == :not_found end)

      assert Tasks.cancel(@server, Utils.owner(session_id), task.taskId) == {:error, :no_task}

      assert Tasks.await(@server, Utils.owner(session_id), task.taskId, 1_000) ==
               {:error, :no_task}
    end

    test "the reaper deletes the record of a terminal task at its ttl", %{
      session_id: session_id
    } do
      task = create_task(session_id, ttl: 100)

      assert {:ok, {:ok, _}} =
               Tasks.await(@server, Utils.owner(session_id), task.taskId, 5_000)

      wait_until(fn -> EtsStore.get(@server, task.taskId) == :not_found end)
    end
  end

  describe "the attached streams" do
    defp stream_count(task_id),
      do: task_id |> task_pid() |> :sys.get_state() |> elem(1) |> then(&length(&1.streams))

    test "a stream that detaches or exits is forgotten", %{session_id: session_id} do
      {task, _runner} = create_slow_task(session_id)

      assert {:attached, _pid} =
               Tasks.attach(@server, Utils.owner(session_id), task.taskId, "s", %{
                 session_id: session_id,
                 client_capabilities: %{}
               })

      {pid, :ok} = attach_stream(session_id, task.taskId)
      assert stream_count(task.taskId) == 2

      Process.unlink(pid)
      Process.exit(pid, :kill)
      wait_until(fn -> stream_count(task.taskId) == 1 end)

      assert :ok = Tasks.detach(@server, task.taskId)
      assert stream_count(task.taskId) == 0

      Support.Entities.Tools.TaskSlowTest.finish()
    end

    test "each stream gets the outcome of the task", %{session_id: session_id} do
      {task, _runner} = create_slow_task(session_id)

      assert {:attached, _pid} =
               Tasks.attach(@server, Utils.owner(session_id), task.taskId, "s", %{
                 session_id: session_id,
                 client_capabilities: %{}
               })

      Support.Entities.Tools.TaskSlowTest.finish()

      task_id = task.taskId
      assert_receive {:oz_mcp_task_result, ^task_id, {:ok, {:ok, _result}}}, 5_000
    end

    test "a task that ended gives its outcome at once", %{session_id: session_id} do
      task = create_task(session_id)

      assert {:ok, {:ok, _}} =
               Tasks.await(@server, Utils.owner(session_id), task.taskId, 5_000)

      assert {:done, {:ok, {:ok, _result}}} =
               Tasks.attach(@server, Utils.owner(session_id), task.taskId, "s", %{
                 session_id: session_id,
                 client_capabilities: %{}
               })

      assert {:done, {:error, :no_task}} =
               Tasks.attach(@server, Utils.owner(session_id), "unknown", "s", %{
                 session_id: session_id,
                 client_capabilities: %{}
               })
    end
  end

  describe "a task store with the required callbacks only" do
    @tag task_opts: %{task_store: Support.TasksStores.BehaviourOnly}
    test "the create, the list, the cancel, the expiry and the end of the session run", %{
      session_id: session_id
    } do
      #
      # A slow task that the test cancels and that the list shows.
      #
      task = create_slow_task_only(session_id, %{})

      assert {:ok, [listed], nil} = Tasks.list(@server, Utils.owner(session_id), nil, 10)
      assert listed.taskId == task.taskId

      assert {:ok, %{status: :cancelled}} =
               Tasks.cancel(@server, Utils.owner(session_id), task.taskId)

      # A task whose ttl ends: the record goes away.
      #
      ended = create_task(session_id, ttl: 1_000)

      wait_until(fn -> Records.get(EtsStore, @server, ended.taskId) == :not_found end)

      # The end of the session stops a task that runs and removes its
      # record.
      #
      {slow, _runner} = create_slow_task(session_id)
      assert :ok = terminate_session_tasks(session_id)

      wait_until(fn -> Records.get(EtsStore, @server, slow.taskId) == :not_found end)
    end
  end

  describe "a custom task store" do
    @tag task_opts: %{task_store: Support.TasksStores.Counting}
    test "every store call goes to the module of the :task_store option", %{
      session_id: session_id
    } do
      Support.TasksStores.Counting.reset()
      on_exit(fn -> Support.TasksStores.Counting.reset() end)

      {task, runner} = create_slow_task(session_id)

      assert {:ok, _} = Tasks.get(@server, Utils.owner(session_id), task.taskId)
      assert {:ok, [_listed], nil} = Tasks.list(@server, Utils.owner(session_id), nil, 10)

      assert {:ok, %{status: :cancelled}} =
               Tasks.cancel(@server, Utils.owner(session_id), task.taskId)

      assert :ok = terminate_session_tasks(session_id)

      calls = Support.TasksStores.Counting.calls()

      for function <- [:put, :get, :delete] do
        assert Map.get(calls, function, 0) >= 1, "expected at least one #{function} call"
      end

      refute Process.alive?(runner)
    end
  end

  describe "requests to the client" do
    #
    # The ids of the requests that wait in the process of the task.
    #
    defp pending_ids(task_id), do: Tasks.pending_request_ids(@server, task_id)

    test "the task makes the id of each request from the id of the task", %{
      session_id: session_id
    } do
      {task, runner} = create_slow_task(session_id)

      assert {:ok, out_id1, task_pid} = Tasks.request(@server, task.taskId, "ping", nil)
      assert {:ok, out_id2, ^task_pid} = Tasks.request(@server, task.taskId, "ping", nil)

      assert out_id1 == "t." <> task.taskId <> ".1"
      assert out_id2 == "t." <> task.taskId <> ".2"

      assert Enum.sort(pending_ids(task.taskId)) == Enum.sort([out_id1, out_id2])

      # One request goes, the other stays held.
      #
      assert :ok = Tasks.cancel_request(@server, task.taskId, out_id1)
      assert pending_ids(task.taskId) == [out_id2]

      assert :ok = Tasks.cancel_request(@server, task.taskId, out_id2)
      assert pending_ids(task.taskId) == []

      # A request that is not held, or that is already gone: no error.
      #
      assert :ok = Tasks.cancel_request(@server, task.taskId, "t." <> task.taskId <> ".9")

      send(runner, :finish)
    end

    test "a request to a task that does not run gives :no_task" do
      assert Tasks.request(@server, "unknown", "ping", nil) == {:error, :no_task}
      assert :ok = Tasks.cancel_request(@server, "unknown", "t.unknown.1")
      assert pending_ids("unknown") == []
    end

    test "the end of a waiter that is not the runner cancels its request", %{
      session_id: session_id
    } do
      task = create_slow_task_only(session_id, %{})
      _runner = wait_for_runner()

      {out_id, holder} = hold_request(task.taskId)
      {stream, :ok} = attach_stream(session_id, task.taskId)

      assert pending_ids(task.taskId) == [out_id]

      Process.unlink(holder)
      Process.exit(holder, :kill)

      wait_until(fn -> pending_ids(task.taskId) == [] end)

      {:streamed, conn} = answer_stream(stream)

      assert [%{"requestId" => ^out_id, "reason" => "the request ended", "_meta" => meta}] =
               cancelled_notices(conn)

      assert meta == %{"io.modelcontextprotocol/related-task" => %{"taskId" => task.taskId}}

      assert {:ok, record} = EtsStore.get(@server, task.taskId)
      assert record.status == :working

      Support.Entities.Tools.TaskSlowTest.finish()
    end

    test "the runner is the waiter: the task holds no second monitor" do
      instance = Module.concat(Servers.Outbound, __MODULE__)
      Utils.start_instance(Servers.Outbound, name: instance)
      session_id = Utils.create_session(instance, initialized: true, streams: [self()])

      assert {:ok, task} =
               Tasks.create(instance, %{
                 session_id: session_id,
                 tool: {Support.Entities.Tools.OutboundTest, "outbound"},
                 request: %{
                   "name" => "outbound",
                   "arguments" => %{"feature" => "roots", "timeout" => 60_000}
                 },
                 ttl: nil,
                 progress_token: nil,
                 client_capabilities: %{"roots" => %{}}
               })

      # The runner asks the client (roots/list): the request is held and
      # the runner is monitored once, as the runner.
      #
      wait_until(fn -> Tasks.pending_request_ids(instance, task.taskId) != [] end)

      {:ok, task_pid} = OzMcp.Instance.whereis(instance, {:task, task.taskId})
      {_state, data} = :sys.get_state(task_pid)

      assert map_size(data.held) == 1
      assert data.waiter_refs == %{}

      assert {:ok, %{status: :cancelled}} =
               Tasks.cancel(instance, Utils.owner(session_id), task.taskId)
    end

    test "the runner can end while a process that it started still waits", %{
      session_id: session_id
    } do
      {task, runner} = create_slow_task(session_id)
      {_out_id, holder} = hold_request(task.taskId)

      send(runner, :finish)

      # The waiter gets the end of the task at once, not at its timeout.
      #
      assert_receive {:answer, {:error, :no_task}}, 5_000
      wait_until(fn -> pending_ids(task.taskId) == [] end)

      send(holder, :stop)
    end

    test "a task process that stops ends the wait with :no_task", %{session_id: session_id} do
      {task, _runner} = create_slow_task(session_id)

      ctx = %{
        server: @server_module,
        instance: @server,
        session_id: session_id,
        client_capabilities: %{"roots" => %{}},
        task_id: task.taskId
      }

      waiting = Elixir.Task.async(fn -> OzMcp.Outbound.request(ctx, "roots/list", nil) end)
      wait_until(fn -> pending_ids(task.taskId) != [] end)

      {:ok, pid} = OzMcp.Instance.whereis(@server, {:task, task.taskId})
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000

      assert Elixir.Task.await(waiting, 5_000) == {:error, :no_task}
    end

    test "the answer of the client goes to the task of its owner", %{session_id: session_id} do
      {task, runner} = create_slow_task(session_id)
      {out_id, holder} = hold_request(task.taskId)

      # The owner of the task answers: the task hands the answer to the
      # process that waits.
      #
      assert :ok =
               Tasks.deliver(
                 @server,
                 Utils.owner(session_id),
                 nil,
                 out_id,
                 {:ok, %{"n" => 1}}
               )

      assert_receive {:answer, {:ok, %{"n" => 1}}}, 5_000
      wait_until(fn -> pending_ids(task.taskId) == [] end)

      assert {:ok, record} = EtsStore.get(@server, task.taskId)
      assert record.status == :working

      # An answer of another owner is ignored in silence: the waiter of
      # the task gets nothing.
      #
      other = Utils.create_session(@server, initialized: true)
      {out_id2, holder2} = hold_request(task.taskId)

      assert :ok =
               Tasks.deliver(@server, Utils.owner(other), nil, out_id2, {:ok, %{"n" => 2}})

      refute_receive {:answer, {:ok, %{"n" => 2}}}, 200

      assert :ok =
               Tasks.deliver(
                 @server,
                 Utils.owner(session_id),
                 nil,
                 out_id2,
                 {:ok, %{"n" => 2}}
               )

      assert_receive {:answer, {:ok, %{"n" => 2}}}, 5_000

      Process.unlink(holder2)
      Process.exit(holder2, :kill)

      send(runner, :finish)
      send(holder, :stop)
    end

    test "an answer that fails a check changes nothing", %{session_id: session_id} do
      {task, runner} = create_slow_task(session_id)
      {out_id, holder} = hold_request(task.taskId)

      # An unknown task, an unknown request of the task and ids that do
      # not have the form of an id of a request of a task: all are
      # ignored and the answer is :ok.
      #
      assert :ok =
               Tasks.deliver(@server, Utils.owner(session_id), nil, "t.unknown.1", {:ok, %{}})

      assert :ok =
               Tasks.deliver(
                 @server,
                 Utils.owner(session_id),
                 nil,
                 "t." <> task.taskId <> ".9",
                 {:ok, %{}}
               )

      assert :ok =
               Tasks.deliver(
                 @server,
                 Utils.owner(session_id),
                 nil,
                 "t." <> task.taskId,
                 {:ok, %{}}
               )

      assert :ok =
               Tasks.deliver(
                 @server,
                 Utils.owner(session_id),
                 nil,
                 "t." <> task.taskId <> ".1.extra",
                 {:ok, %{}}
               )

      # The wait is part of the check: no notification arrives.
      #
      refute_receive {:answer, _}, 50
      assert pending_ids(task.taskId) == [out_id]

      send(runner, :finish)
      send(holder, :stop)
    end

    test "a principal that does not hold the scopes of the task cannot answer", %{
      session_id: session_id
    } do
      principal =
        OzMcp.Auth.Principal.new!(
          issuer: "https://issuer.test",
          subject: "alice",
          scopes: ["files:read", "files:write"]
        )

      owner = Tasks.owner_key(%{principal: principal, session_id: session_id})

      {task, runner} =
        create_slow_task(session_id, %{principal: principal, required_scopes: ["files:write"]})

      {out_id, holder} = hold_request(task.taskId)

      # The principal of the owner holds the scope: the answer reaches the
      # waiter of the task.
      #
      assert :ok = Tasks.deliver(@server, owner, principal, out_id, {:ok, %{"n" => 1}})
      assert_receive {:answer, {:ok, %{"n" => 1}}}, 5_000

      # A principal without the scope cannot answer for the task.
      #
      stranger =
        OzMcp.Auth.Principal.new!(
          issuer: "https://issuer.test",
          subject: "bob",
          scopes: ["files:read"]
        )

      {out_id2, holder2} = hold_request(task.taskId)

      assert :ok = Tasks.deliver(@server, owner, stranger, out_id2, {:ok, %{"n" => 2}})

      refute_receive {:answer, {:ok, %{"n" => 2}}}, 200
      assert pending_ids(task.taskId) == [out_id2]

      Process.unlink(holder2)
      Process.exit(holder2, :kill)

      send(runner, :finish)
      send(holder, :stop)
    end

    test "the answer of the client travels through the handler by owner key", %{
      session_id: session_id
    } do
      {task, runner} = create_slow_task(session_id)
      {out_id, holder} = hold_request(task.taskId)

      # The context of a session without a principal (the stdio shape):
      # the owner key of the answer is the session itself.
      #
      context = %OzMcp.Context{
        instance: @server,
        session_id: session_id,
        rpc_id: out_id,
        principal: nil
      }

      assert :ok = OzMcp.Outbound.deliver(context, {:ok, %{"n" => 1}})
      assert_receive {:answer, {:ok, %{"n" => 1}}}, 5_000
      wait_until(fn -> pending_ids(task.taskId) == [] end)

      send(runner, :finish)
      send(holder, :stop)
    end

    test "the answer for a request of the session goes to the session", %{session_id: session_id} do
      assert {:ok, out_id, _session_pid} =
               OzMcp.Sessions.request_client(@server, session_id, {:request, 7}, {"ping", nil})

      context = %OzMcp.Context{instance: @server, session_id: session_id, rpc_id: out_id}
      assert :ok = OzMcp.Outbound.deliver(context, {:ok, %{}})

      tag = OzMcp.Outbound.answer_tag()
      assert_receive {^tag, ^out_id, {:ok, %{}}}, 5_000
    end

    test "an integer response id goes to the session and never to the task", %{
      session_id: session_id
    } do
      {task, runner} = create_slow_task(session_id)
      {out_id, holder} = hold_request(task.taskId)

      context = %OzMcp.Context{instance: @server, session_id: session_id, rpc_id: 7}
      assert :ok = OzMcp.Outbound.deliver(context, {:ok, %{}})

      # The wait is part of the check: no notification arrives.
      #
      refute_receive {:answer, _}, 50
      assert pending_ids(task.taskId) == [out_id]

      send(runner, :finish)
      send(holder, :stop)
    end

    test "a ping of a task does not change the status", %{session_id: session_id} do
      {task, runner} = create_slow_task(session_id)

      assert {:ok, out_id, _task_pid} = Tasks.request(@server, task.taskId, "ping", nil)
      wait_until(fn -> pending_ids(task.taskId) == [out_id] end)

      assert {:ok, record} = EtsStore.get(@server, task.taskId)
      assert record.status == :working

      assert :ok = Tasks.cancel_request(@server, task.taskId, out_id)

      assert {:ok, record} = EtsStore.get(@server, task.taskId)
      assert record.status == :working

      send(runner, :finish)
    end

    test "the polls of a client task do not change the status while a stream carries them", %{
      session_id: session_id
    } do
      {task, runner} = create_slow_task(session_id)

      {stream, :ok} = attach_stream(session_id, task.taskId, %{"tasks" => %{"cancel" => %{}}})

      {get_id, get_holder} = hold_request(task.taskId, "tasks/get", %{"taskId" => "c1"})

      {result_id, result_holder} =
        hold_request(task.taskId, "tasks/result", %{"taskId" => "c1"})

      {cancel_id, cancel_holder} =
        hold_request(task.taskId, "tasks/cancel", %{"taskId" => "c1"})

      wait_until(fn ->
        pending_ids(task.taskId) == Enum.sort([get_id, result_id, cancel_id])
      end)

      assert {:ok, record} = EtsStore.get(@server, task.taskId)
      assert record.status == :working

      # The status did not change: no status notification.
      #
      refute_receive {:oz_mcp_stream, _, {:event, _, %{method: "notifications/tasks/status"}}}, 50

      messages = answer_stream_messages(stream)

      for id <- [get_id, result_id, cancel_id] do
        assert %{"id" => ^id, "params" => params} =
                 Enum.find(messages, &match?(%{"id" => ^id}, &1))

        assert params["taskId"] == "c1"
        refute Map.has_key?(params, "_meta")
      end

      for holder <- [get_holder, result_holder, cancel_holder] do
        Process.unlink(holder)
        Process.exit(holder, :kill)
      end

      wait_until(fn -> pending_ids(task.taskId) == [] end)

      send(runner, :finish)
    end

    test "a poll with no stream moves the task to input_required and the next attach serves it",
         %{session_id: session_id} do
      {task, runner} = create_slow_task(session_id)

      {out_id, holder} = hold_request(task.taskId, "tasks/get", %{"taskId" => "c1"})
      wait_until(fn -> pending_ids(task.taskId) == [out_id] end)

      assert {:ok, record} = EtsStore.get(@server, task.taskId)
      assert record.status == :input_required
      assert record.status_message == "waiting for the client: tasks/get"
      assert_status_notification(task.taskId, "input_required")

      # The client opens a tasks/result stream: the held poll goes to it.
      #
      {stream, :ok} = attach_stream(session_id, task.taskId, %{"tasks" => %{}})

      assert %{"id" => ^out_id, "params" => %{"taskId" => "c1"}} =
               Enum.find(answer_stream_messages(stream), &match?(%{"id" => ^out_id}, &1))

      # The answer of the client moves the task back to working.
      #
      assert :ok =
               Tasks.deliver(
                 @server,
                 Utils.owner(session_id),
                 nil,
                 out_id,
                 {:ok, %{"taskId" => "c1", "status" => "working"}}
               )

      assert_receive {:answer, {:ok, %{"status" => "working"}}}, 5_000
      wait_until(fn -> pending_ids(task.taskId) == [] end)
      assert_status_notification(task.taskId, "working")

      send(holder, :stop)
      send(runner, :finish)
    end

    test "a held poll that loses its stream moves the task to input_required", %{
      session_id: session_id
    } do
      {task, runner} = create_slow_task(session_id)

      {stream, :ok} = attach_stream(session_id, task.taskId, %{"tasks" => %{}})
      {out_id, holder} = hold_request(task.taskId, "tasks/get", %{"taskId" => "c1"})
      wait_until(fn -> pending_ids(task.taskId) == [out_id] end)

      assert {:ok, record} = EtsStore.get(@server, task.taskId)
      assert record.status == :working

      assert :ok = detach_stream(stream)

      assert_status_notification(task.taskId, "input_required")

      assert {:ok, record} = EtsStore.get(@server, task.taskId)
      assert record.status == :input_required
      assert record.status_message == "the stream of a poll ended"

      # A new stream gets the held poll and its answer moves the task back
      # to working.
      #
      {new_stream, :ok} = attach_stream(session_id, task.taskId, %{"tasks" => %{}}, 2)

      assert %{"id" => ^out_id} =
               Enum.find(answer_stream_messages(new_stream), &match?(%{"id" => ^out_id}, &1))

      assert :ok =
               Tasks.deliver(
                 @server,
                 Utils.owner(session_id),
                 nil,
                 out_id,
                 {:ok, %{"taskId" => "c1", "status" => "working"}}
               )

      assert_receive {:answer, {:ok, %{"status" => "working"}}}, 5_000
      wait_until(fn -> pending_ids(task.taskId) == [] end)
      assert_status_notification(task.taskId, "working")

      send(holder, :stop)
      send(runner, :finish)
    end

    test "a held poll whose stream process dies moves the task to input_required", %{
      session_id: session_id
    } do
      {task, runner} = create_slow_task(session_id)

      {stream, :ok} = attach_stream(session_id, task.taskId, %{"tasks" => %{}})
      {out_id, holder} = hold_request(task.taskId, "tasks/get", %{"taskId" => "c1"})
      wait_until(fn -> pending_ids(task.taskId) == [out_id] end)

      Process.unlink(stream)
      Process.exit(stream, :kill)

      assert_status_notification(task.taskId, "input_required")

      assert {:ok, record} = EtsStore.get(@server, task.taskId)
      assert record.status == :input_required

      send(holder, :stop)
      send(runner, :finish)
    end

    test "one of two streams ending keeps the status working", %{session_id: session_id} do
      {task, runner} = create_slow_task(session_id)

      {stream, :ok} = attach_stream(session_id, task.taskId, %{"tasks" => %{}}, 1)
      {other, :ok} = attach_stream(session_id, task.taskId, %{"tasks" => %{}}, 2)

      {out_id, holder} = hold_request(task.taskId, "tasks/get", %{"taskId" => "c1"})
      wait_until(fn -> pending_ids(task.taskId) == [out_id] end)

      assert :ok = detach_stream(stream)

      assert {:ok, record} = EtsStore.get(@server, task.taskId)
      assert record.status == :working

      # The status did not change: no status notification.
      #
      refute_receive {:oz_mcp_stream, _, {:event, _, %{method: "notifications/tasks/status"}}},
                     100

      assert %{"id" => ^out_id} =
               Enum.find(answer_stream_messages(other), &match?(%{"id" => ^out_id}, &1))

      send(holder, :stop)
      send(runner, :finish)
    end

    test "a held ping with no stream left keeps the status working", %{session_id: session_id} do
      {task, runner} = create_slow_task(session_id)

      {stream, :ok} = attach_stream(session_id, task.taskId, %{"tasks" => %{}})
      assert {:ok, out_id, _task_pid} = Tasks.request(@server, task.taskId, "ping", nil)
      wait_until(fn -> pending_ids(task.taskId) == [out_id] end)

      assert :ok = detach_stream(stream)

      assert {:ok, record} = EtsStore.get(@server, task.taskId)
      assert record.status == :working

      refute_receive {:oz_mcp_stream, _, {:event, _, %{method: "notifications/tasks/status"}}},
                     100

      assert :ok = Tasks.cancel_request(@server, task.taskId, out_id)

      send(runner, :finish)
    end

    test "a stream that ends with no held request changes nothing", %{session_id: session_id} do
      {task, runner} = create_slow_task(session_id)

      {stream, :ok} = attach_stream(session_id, task.taskId, %{"tasks" => %{}})

      assert :ok = detach_stream(stream)

      assert {:ok, record} = EtsStore.get(@server, task.taskId)
      assert record.status == :working

      refute_receive {:oz_mcp_stream, _, {:event, _, %{method: "notifications/tasks/status"}}},
                     100

      send(runner, :finish)
    end

    test "the first request of a client task keeps input_required and carries the related-task meta",
         %{session_id: session_id} do
      {task, runner} = create_slow_task(session_id)

      capabilities = %{
        "sampling" => %{},
        "tasks" => %{"requests" => %{"sampling" => %{"createMessage" => %{}}}}
      }

      {stream, :ok} = attach_stream(session_id, task.taskId, capabilities)

      request_params = %{
        "messages" => [],
        "maxTokens" => 10,
        "task" => %{"ttl" => 1_000}
      }

      ctx = %{
        server: @server_module,
        instance: @server,
        session_id: session_id,
        client_capabilities: capabilities,
        task_id: task.taskId
      }

      waiting =
        Elixir.Task.async(fn ->
          OzMcp.Outbound.request(ctx, "sampling/createMessage", request_params)
        end)

      wait_until(fn -> pending_ids(task.taskId) != [] end)
      [out_id] = pending_ids(task.taskId)

      # Until the client answers with the CreateTaskResult, the request
      # needs the client to act: the task is input_required.
      #
      assert {:ok, record} = EtsStore.get(@server, task.taskId)
      assert record.status == :input_required

      assert %{"id" => ^out_id, "method" => "sampling/createMessage", "params" => params} =
               Enum.find(answer_stream_messages(stream), &match?(%{"id" => ^out_id}, &1))

      assert params["_meta"] == %{
               "io.modelcontextprotocol/related-task" => %{"taskId" => task.taskId}
             }

      assert :ok =
               Tasks.deliver(
                 @server,
                 Utils.owner(session_id),
                 nil,
                 out_id,
                 {:ok, %{"task" => %{"taskId" => "c1", "status" => "working"}}}
               )

      assert Elixir.Task.await(waiting, 5_000) ==
               {:ok, %{"task" => %{"taskId" => "c1", "status" => "working"}}}

      wait_until(fn -> pending_ids(task.taskId) == [] end)

      send(runner, :finish)
    end

    test "a held request goes only to the streams whose client accepts it", %{
      session_id: session_id
    } do
      {task, runner} = create_slow_task(session_id)

      {elicit_stream, :ok} = attach_stream(session_id, task.taskId, %{"elicitation" => %{}}, 1)
      {plain_stream, :ok} = attach_stream(session_id, task.taskId, %{}, 2)

      {out_id1, holder} = hold_request(task.taskId)
      assert {:ok, out_id2, _task_pid} = Tasks.request(@server, task.taskId, "ping", nil)

      wait_until(fn ->
        pending_ids(task.taskId) == Enum.sort([out_id1, out_id2])
      end)

      # The cancel notice of the elicitation goes to the streams whose
      # client declared the capability.
      #
      assert :ok = Tasks.cancel_request(@server, task.taskId, out_id1)

      elicit = answer_stream_messages(elicit_stream)
      plain = answer_stream_messages(plain_stream)

      assert %{"method" => "elicitation/create", "id" => ^out_id1} =
               Enum.find(elicit, &(&1["method"] == "elicitation/create"))

      assert Enum.any?(elicit, &match?(%{"method" => "ping", "id" => ^out_id2}, &1))

      assert Enum.any?(
               elicit,
               &match?(
                 %{"method" => "notifications/cancelled", "params" => %{"requestId" => ^out_id1}},
                 &1
               )
             )

      assert Enum.any?(plain, &match?(%{"method" => "ping", "id" => ^out_id2}, &1))
      refute Enum.any?(plain, &(&1["method"] == "elicitation/create"))
      refute Enum.any?(plain, &(&1["method"] == "notifications/cancelled"))

      Process.unlink(holder)
      Process.exit(holder, :kill)

      send(runner, :finish)
    end

    test "a held request, then an attach, then a second request: each goes to the stream one time",
         %{
           session_id: session_id
         } do
      {task, runner} = create_slow_task(session_id)

      # A request is held before the stream of the `tasks/result` request
      # attaches: the attach sends it to the stream.
      #
      {out_id1, holder} = hold_request(task.taskId)
      {stream, :ok} = attach_stream(session_id, task.taskId)

      # A second request after the attach goes to the stream too.
      #
      assert {:ok, out_id2, _task_pid} = Tasks.request(@server, task.taskId, "ping", nil)
      wait_until(fn -> pending_ids(task.taskId) == Enum.sort([out_id1, out_id2]) end)

      messages = answer_stream_messages(stream)

      assert Enum.count(messages, &match?(%{"id" => ^out_id1}, &1)) == 1
      assert Enum.count(messages, &match?(%{"id" => ^out_id2}, &1)) == 1

      Process.unlink(holder)
      Process.exit(holder, :kill)

      send(runner, :finish)
    end

    @tag task_opts: %{tasks_follow_session: false}
    test "the end of the creator session does not end the wait of a request of the task", %{
      session_id: session_id
    } do
      {task, runner} = create_slow_task(session_id)
      {out_id, holder} = hold_request(task.taskId)

      assert :ok = OzMcp.Sessions.terminate(@server, session_id)
      Utils.sync_task(@server, task.taskId)

      # The task keeps its request and its waiter keeps waiting.
      #
      assert pending_ids(task.taskId) == [out_id]
      #
      # The wait is part of the check: no notification arrives.
      #
      refute_receive {:answer, _}, 50

      send(runner, :finish)
      assert_receive {:answer, {:error, :no_task}}, 5_000

      send(holder, :stop)
    end
  end

  describe "the tracking of the creator session" do
    test "the session tracks a task that it can stop and forgets it at the end", %{
      session_id: session_id
    } do
      {task, runner} = create_slow_task(session_id)
      Utils.sync_server(@server, session_id)

      assert MapSet.member?(Utils.session_data(@server, session_id).tasks, task.taskId)

      send(runner, :finish)
      assert_status_notification(task.taskId, "completed")

      wait_until(fn -> Utils.session_data(@server, session_id).tasks == MapSet.new() end)
    end

    @tag task_opts: %{tasks_follow_session: false}
    test "the session does not track a task that outlives it", %{session_id: session_id} do
      {_task, runner} = create_slow_task(session_id)
      Utils.sync_server(@server, session_id)

      assert Utils.session_data(@server, session_id).tasks == MapSet.new()

      send(runner, :finish)
    end

    @tag task_opts: %{tasks_follow_session: false}
    test "a cancel works after the end of the creator session", %{session_id: session_id} do
      {task, runner} = create_slow_task(session_id)

      assert :ok = OzMcp.Sessions.terminate(@server, session_id)
      Utils.sync_task(@server, task.taskId)

      assert {:ok, %Task{status: :cancelled}} =
               Tasks.cancel(@server, Utils.owner(session_id), task.taskId)

      wait_until(fn -> not Process.alive?(runner) end)

      assert {:ok, %Task{status: :cancelled}} =
               Tasks.get(@server, Utils.owner(session_id), task.taskId)
    end

    @tag task_opts: %{tasks_follow_session: false}
    test "a task keeps the capabilities of its record and asks the client after the end of its session",
         %{session_id: session_id} do
      capabilities = %{"roots" => %{}}
      task = create_slow_task_only(session_id, %{client_capabilities: capabilities})
      wait_for_runner()

      assert :ok = OzMcp.Sessions.terminate(@server, session_id)
      Utils.sync_task(@server, task.taskId)

      # The ctx of the runner carries the capabilities of the record: the
      # framework reads them from the task, never from its session (the
      # session is gone).
      #
      wait_until(fn ->
        case Support.Entities.Tools.TaskSlowTest.last_ctx() do
          %{task_id: task_id} -> task_id == task.taskId
          _other -> false
        end
      end)

      ctx = Support.Entities.Tools.TaskSlowTest.last_ctx()
      assert {:ok, ^capabilities} = OzMcp.Context.fetch_client_capabilities(ctx)
      assert OzMcp.Context.client_supports?(ctx, "roots")

      # A request to the client does not need the creator session: it is
      # held (the task gets it) instead of failing with :session_not_found.
      #
      runner_ctx = %{
        server: @server_module,
        instance: @server,
        session_id: session_id,
        client_capabilities: capabilities,
        task_id: task.taskId
      }

      waiting =
        Elixir.Task.async(fn ->
          OzMcp.Outbound.request(runner_ctx, "roots/list", nil, timeout: 200)
        end)

      wait_until(fn -> pending_ids(task.taskId) != [] end)
      assert Elixir.Task.await(waiting, 5_000) == {:error, :timeout}
      wait_until(fn -> pending_ids(task.taskId) == [] end)

      Support.Entities.Tools.TaskSlowTest.finish()
    end

    test "a session that does not exist takes the tracking casts without an error" do
      assert :ok = OzMcp.Session.track_task(@server, "no-such-session", "t-unknown")
      assert :ok = OzMcp.Session.untrack_task(@server, "no-such-session", "t-unknown")
    end
  end

  describe "a crash of the task process" do
    @tag :capture_log
    test "the record becomes failed and the client gets the status notification", %{
      session_id: session_id
    } do
      {task, runner} = create_slow_task(session_id)
      {:ok, pid} = OzMcp.Instance.whereis(@server, {:task, task.taskId})

      Process.exit(pid, :kill)

      wait_until(fn ->
        match?(
          {:ok, %{status: :failed}},
          Tasks.get(@server, Utils.owner(session_id), task.taskId)
        )
      end)

      assert {:ok, stored} = Tasks.get(@server, Utils.owner(session_id), task.taskId)
      assert stored.statusMessage == "The task process crashed."

      assert_status_notification(task.taskId, "failed")
      send(runner, :finish)
    end

    @tag :capture_log
    test "a crash of the table owner deletes all records", %{session_id: session_id} do
      task = create_task(session_id)

      assert {:ok, {:ok, _}} =
               Tasks.await(@server, Utils.owner(session_id), task.taskId, 5_000)

      assert {:ok, tables_pid} = OzMcp.Instance.whereis(@server, :tasks_table)

      Process.exit(tables_pid, :kill)

      wait_new_process(@server, :tasks_table, tables_pid)

      assert Support.Helpers.TaskScan.all(@server) == []
      assert :ets.tab2list(Index.index_table(@server)) == []
      assert Tasks.get(@server, Utils.owner(session_id), task.taskId) == {:error, :no_task}
    end
  end

  describe "a stop of the child by the host" do
    test "an attached tasks/result request ends with the result of the failed record", %{
      session_id: session_id
    } do
      {task, runner} = create_slow_task(session_id)

      assert {:attached, _pid} =
               Tasks.attach(@server, Utils.owner(session_id), task.taskId, "s", %{
                 session_id: session_id,
                 client_capabilities: %{}
               })

      {:ok, pid} = OzMcp.Instance.whereis(@server, {:task, task.taskId})
      assert :ok = DynamicSupervisor.terminate_child(OzMcp.Instance.via(@server, :tasks), pid)

      task_id = task.taskId

      assert_receive {:oz_mcp_task_result, ^task_id,
                      {:ok,
                       {:error,
                        %{code: -32603, message: "The server stopped the task.", data: nil}}}},
                     5_000

      wait_until(fn -> not Process.alive?(runner) end)
    end

    test "the waiter of a held request gets :no_task at the stop of the child", %{
      session_id: session_id
    } do
      {task, runner} = create_slow_task(session_id)
      {_out_id, holder} = hold_request(task.taskId)

      {:ok, pid} = OzMcp.Instance.whereis(@server, {:task, task.taskId})
      assert :ok = DynamicSupervisor.terminate_child(OzMcp.Instance.via(@server, :tasks), pid)

      assert_receive {:answer, {:error, :no_task}}, 5_000

      assert {:ok, %{status: :failed}} = EtsStore.get(@server, task.taskId)
      assert pending_ids(task.taskId) == []
      wait_until(fn -> not Process.alive?(runner) end)

      send(holder, :stop)
    end

    test "a failure of the status notification does not stop the streams and the waiters", %{
      session_id: session_id
    } do
      owner = Utils.owner(session_id)
      {task, runner} = create_slow_task(session_id)

      # A stream with no session does not count for the notifier. With the
      # owner key below, the notification of the stop has no target at all
      # and raises.
      #
      assert {:attached, _pid} =
               Tasks.attach(@server, owner, task.taskId, "s", %{
                 session_id: nil,
                 client_capabilities: %{}
               })

      await_in_background(session_id, task.taskId, 5_000)
      wait_until(fn -> waiter_registered?(task.taskId) end)

      {:ok, pid} = OzMcp.Instance.whereis(@server, {:task, task.taskId})

      :sys.replace_state(pid, fn {state, data} ->
        {state, put_in(data.record.owner_key, {:notifier, :broken})}
      end)

      assert :ok = DynamicSupervisor.terminate_child(OzMcp.Instance.via(@server, :tasks), pid)

      task_id = task.taskId
      outcome = {:error, %{code: -32603, message: "The server stopped the task.", data: nil}}

      assert_receive {:oz_mcp_task_result, ^task_id, {:ok, ^outcome}}, 5_000
      assert_receive {:awaited, {:ok, ^outcome}}, 5_000

      assert {:ok, %{status: :failed}} = EtsStore.get(@server, task.taskId)
      wait_until(fn -> not Process.alive?(runner) end)
    end

    @tag task_opts: %{task_store: Support.TasksStores.Failing}
    @tag :capture_log
    test "a crash writes no record in terminate: the retry of the reaper writes it", %{
      session_id: session_id
    } do
      on_exit(fn -> Support.TasksStores.Failing.clear_instance(@server) end)

      owner = Utils.owner(session_id)
      {task, runner} = create_slow_task(session_id)
      {:ok, pid} = OzMcp.Instance.whereis(@server, {:task, task.taskId})

      # A raise of the store in put/2 makes the next cast that writes the
      # record crash the task: terminate/3 runs for a crash, not for a
      # shutdown and it writes nothing.
      #
      Support.TasksStores.Failing.arm(@server, :put, :raise)
      Tasks.status_message(@server, task.taskId, "halfway")

      wait_until(fn -> not Process.alive?(pid) end)
      assert {:ok, %{status: :working}} = EtsStore.get(@server, task.taskId)

      Support.TasksStores.Failing.clear(@server, :put)

      wait_until(fn ->
        match?({:ok, %{status: :failed}}, Tasks.get(@server, owner, task.taskId))
      end)

      assert {:ok, stored} = Tasks.get(@server, owner, task.taskId)
      assert stored.statusMessage == "The task process crashed."

      wait_until(fn -> not Process.alive?(runner) end)
    end

    @tag task_opts: %{task_store: Support.TasksStores.Failing}
    @tag :capture_log
    test "a stop of the child with a store that raises stops the task and its runner", %{
      session_id: session_id
    } do
      on_exit(fn -> Support.TasksStores.Failing.clear_instance(@server) end)

      {task, runner} = create_slow_task(session_id)
      {:ok, pid} = OzMcp.Instance.whereis(@server, {:task, task.taskId})

      Support.TasksStores.Failing.arm(@server, :put, :raise)

      assert :ok = DynamicSupervisor.terminate_child(OzMcp.Instance.via(@server, :tasks), pid)

      wait_until(fn -> not Process.alive?(runner) end)
      wait_until(fn -> OzMcp.Instance.whereis(@server, {:task, task.taskId}) == :not_running end)

      # The write of the record failed: the retry of the reaper after the
      # :DOWN of the task writes it.
      #
      Support.TasksStores.Failing.clear(@server, :put)

      wait_until(fn ->
        match?({:ok, %{status: :failed}}, EtsStore.get(@server, task.taskId))
      end)

      assert {:ok, stored} = EtsStore.get(@server, task.taskId)
      assert stored.status_message == "The server stopped the task."
    end
  end

  describe "progress and status casts" do
    test "forwards notifications/progress with the task progress token and the related-task _meta",
         %{session_id: session_id} do
      {task, runner} = create_slow_task(session_id, %{progress_token: "pt-1"})

      Tasks.progress(@server, task.taskId, 1, 2, "step 1")

      {_, notification} = Utils.receive_event(5_000)
      assert notification["method"] == "notifications/progress"

      assert notification["params"] == %{
               "progress" => 1,
               "progressToken" => "pt-1",
               "total" => 2,
               "message" => "step 1",
               "_meta" => %{"io.modelcontextprotocol/related-task" => %{"taskId" => task.taskId}}
             }

      send(runner, :finish)
    end

    test "drops a progress value that does not increase", %{session_id: session_id} do
      {task, runner} = create_slow_task(session_id, %{progress_token: "pt-drop"})

      for value <- [1, 2, 2, 1, 3] do
        assert :ok = Tasks.progress(@server, task.taskId, value, 10, nil)
      end

      Utils.sync_task(@server, task.taskId)

      values =
        for _ <- 1..3 do
          {_, notification} = Utils.receive_event(5_000)
          assert notification["method"] == "notifications/progress"
          notification["params"]["progress"]
        end

      assert values == [1, 2, 3]
      refute_receive {:oz_mcp_stream, _, {:event, _, %{method: "notifications/progress"}}}, 50

      send(runner, :finish)
    end

    test "sends nothing when the task has no progress token", %{session_id: session_id} do
      {task, runner} = create_slow_task(session_id)

      Tasks.progress(@server, task.taskId, 1, 2, nil)

      refute_receive {:oz_mcp_stream, _, {:event, _, %{method: "notifications/progress"}}}, 50

      send(runner, :finish)
    end

    test "updates statusMessage without changing status", %{session_id: session_id} do
      {task, runner} = create_slow_task(session_id)

      Tasks.status_message(@server, task.taskId, "halfway there")
      Utils.sync_task(@server, task.taskId)

      assert {:ok, stored} = Tasks.get(@server, Utils.owner(session_id), task.taskId)
      assert stored.status == :working
      assert stored.statusMessage == "halfway there"

      refute_receive {:oz_mcp_stream, _, {:event, _, %{method: "notifications/tasks/status"}}}, 50

      send(runner, :finish)
    end

    test "a held request moves the task to input_required and notifies", %{
      session_id: session_id
    } do
      {task, runner} = create_slow_task(session_id)

      assert {:ok, out_id, _task_pid} =
               Tasks.request(@server, task.taskId, "elicitation/create", nil)

      assert {:ok, stored} = Tasks.get(@server, Utils.owner(session_id), task.taskId)
      assert stored.status == :input_required
      assert stored.statusMessage == "waiting for the client: elicitation/create"

      assert_status_notification(task.taskId, "input_required")

      # tasks/result keeps blocking through input_required (A3)
      #
      await_in_background(session_id, task.taskId, 5_000)
      wait_until(fn -> waiter_registered?(task.taskId) end)

      # the end of the request moves the task back to working
      #
      assert :ok = Tasks.cancel_request(@server, task.taskId, out_id)
      assert_status_notification(task.taskId, "working")

      send(runner, :finish)

      assert_receive {:awaited, {:ok, {:ok, _}}}, 5_000
      assert_status_notification(task.taskId, "completed")
    end

    test "progress on a terminal task is a no-op", %{session_id: session_id} do
      task = create_task(session_id)

      assert {:ok, {:ok, _}} =
               Tasks.await(@server, Utils.owner(session_id), task.taskId, 5_000)

      Tasks.progress(@server, task.taskId, 1, 2, nil)

      refute_receive {:oz_mcp_stream, _, {:event, _, %{method: "notifications/progress"}}}, 50
    end
  end

  describe "a call that no clause takes" do
    test "answers {:error, :badarg} at once", %{session_id: session_id} do
      {task, _runner} = create_slow_task(session_id)
      pid = task_pid(task.taskId)

      {micros, answer} = :timer.tc(fn -> :gen_statem.call(pid, :nonsense) end)
      assert answer == {:error, :badarg}
      assert micros < 100_000

      finish_runners([task])

      assert {:ok, {:ok, _}} =
               Tasks.await(@server, Utils.owner(session_id), task.taskId, 5_000)
    end

    test "the warning holds the tag only", %{session_id: session_id} do
      {task, _runner} = create_slow_task(session_id)
      pid = task_pid(task.taskId)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :gen_statem.call(pid, {:nonsense, "secret-text"}) == {:error, :badarg}
        end)

      assert log =~ "task call :nonsense"
      refute log =~ "secret-text"

      finish_runners([task])

      assert {:ok, {:ok, _}} =
               Tasks.await(@server, Utils.owner(session_id), task.taskId, 5_000)
    end
  end

  defp create_task_raw(session_id, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          session_id: session_id,
          tool: {Support.Entities.Tools.TaskImmediateTest, "task_immediate"},
          request: %{"name" => "task_immediate", "arguments" => %{}},
          ttl: nil,
          progress_token: nil
        },
        Map.new(attrs)
      )

    Tasks.create(@server, attrs)
  end

  defp create_task(session_id, attrs \\ %{}) do
    assert {:ok, %Task{} = task} = create_task_raw(session_id, attrs)
    task
  end

  # A task of the immediate tool that reaches its terminal status, so its
  # record stays in the store and counts for the record limits.
  #
  defp completed_task(session_id, attrs \\ %{}) do
    task = create_task(session_id, attrs)
    owner = Tasks.owner_key(%{principal: attrs[:principal], session_id: session_id})

    assert {:ok, {:ok, _}} = Tasks.await(@server, owner, task.taskId, 5_000)

    task
  end

  defp expired_record(session_id) do
    now = DateTime.utc_now()

    %EtsStore{
      task_id: OzMcp.Utils.Generator.task_id(),
      session_id: session_id,
      owner_key: Utils.owner(session_id),
      seq: System.unique_integer([:positive]),
      status: :completed,
      created_at: DateTime.add(now, -10, :second),
      last_updated_at: now,
      ttl: 1,
      result: {:ok, %{}}
    }
  end

  # The active entries of the counters of the instance. The ledger of the
  # records and the bytes has one entry for each owner that holds a
  # record, so a test of the active counters ignores those keys.
  #
  defp active_counter_entries do
    for {{kind, _value} = key, count} <- :ets.tab2list(Index.counters_table(@server)),
        kind in [:session, :owner],
        do: {key, count}
  end

  # The counter of the store and the scan of the records must always give
  # the same number for the session and for the owner.
  #
  defp assert_agree(session_id, owner) do
    for key <- [{:session, session_id}, {:owner, owner}] do
      assert Records.count_active(EtsStore, @server, key) ==
               Support.Helpers.TaskScan.active(@server, key)
    end
  end

  # The runner of a task blocked in the slow tool: a :finish ends it and
  # the task reaches its terminal status.
  #
  defp finish_runners(tasks) do
    for task <- tasks do
      assert {:ok, record} = EtsStore.get(@server, task.taskId)
      send(record.runner_pid, :finish)
    end
  end

  # Creates a task of the structured tool for the given shape, with the
  # outputSchema of the tool, as the handler does on a task-augmented
  # tools/call.
  #
  defp create_structured_task(session_id, shape, extra_attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          tool: {Support.Entities.Tools.TaskStructuredTest, "task_structured"},
          request: %{"name" => "task_structured", "arguments" => %{"shape" => shape}},
          output_schema: Support.Entities.Tools.TaskStructuredTest.schema()
        },
        Map.new(extra_attrs)
      )

    create_task(session_id, attrs)
  end

  defp slow_tool do
    {Support.Entities.Tools.TaskSlowTest, "task_slow"}
  end

  defp create_slow_task(session_id, extra_attrs \\ %{}) do
    task = create_slow_task_only(session_id, extra_attrs)
    {task, wait_for_runner()}
  end

  # Resets the stale runner pid first: :persistent_term outlives the
  # previous test's runner, so wait_for_runner/1 must wait for THIS run.
  #
  defp create_slow_task_only(session_id, extra_attrs) do
    Support.Entities.Tools.TaskSlowTest.reset()
    create_task(session_id, Map.merge(%{tool: slow_tool()}, extra_attrs))
  end

  defp wait_for_runner do
    assert Utils.eventually(fn ->
             Support.Entities.Tools.TaskSlowTest.last_runner_pid() != nil
           end)

    Support.Entities.Tools.TaskSlowTest.last_runner_pid()
  end

  defp await_in_background(session_id, task_id, timeout) do
    parent = self()

    spawn_link(fn ->
      send(
        parent,
        {:awaited, Tasks.await(@server, Utils.owner(session_id), task_id, timeout)}
      )
    end)
  end

  # The tasks/result stream of a task and the requests it holds. A process
  # of the task holds a request while it waits for the answer of the
  # client; the end of the task (a cancel, the expiry, the end of the
  # session) writes a cancellation notice for each held request on the
  # attached stream and each waiter gets the error of the end.
  #

  # A process that sends a request for the task and stays alive. It
  # reports the id the client answers and the outcome it got.
  #
  defp hold_request(task_id), do: hold_request(task_id, "elicitation/create", nil)

  defp hold_request(task_id, method, params) do
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, out_id, _task_pid} = Tasks.request(@server, task_id, method, params)

        send(parent, {:held, out_id})

        receive do
          :stop ->
            :ok

          {:oz_mcp_client_answer, ^out_id, outcome} ->
            send(parent, {:answer, outcome})

            receive do
              :stop -> :ok
            end
        end
      end)

    assert_receive {:held, out_id}, 5_000
    {out_id, pid}
  end

  # A process that plays a tasks/result request: it owns a response
  # stream, attaches it to the task (with the capabilities of its client)
  # and answers when told. The answer carries the body of the stream: the
  # messages the task pushed while the stream was open.
  #
  defp attach_stream(session_id, task_id, capabilities \\ %{"elicitation" => %{}}) do
    attach_stream(session_id, task_id, capabilities, 1)
  end

  defp attach_stream(session_id, task_id, capabilities, request_id) do
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, stream} =
          Utils.begin_stream(@server, session_id, request_id, conn(:post, "/"), & &1)

        {:attached, _task} =
          Tasks.attach(@server, Utils.owner(session_id), task_id, stream.stream_id, %{
            session_id: session_id,
            client_capabilities: capabilities
          })

        send(parent, {:attached, self(), :ok})

        await = fn await ->
          receive do
            :detach ->
              :ok = Tasks.detach(@server, task_id)
              send(parent, {:detached, self()})
              await.(await)

            :answer ->
              outcome =
                PostStream.answer(
                  %{"jsonrpc" => "2.0", "id" => request_id, "result" => %{}},
                  stream
                )

              send(parent, {:answered, self(), elem(outcome, 0)})
          end
        end

        await.(await)
      end)

    assert_receive {:attached, ^pid, result}, 5_000
    {pid, result}
  end

  defp detach_stream(pid) do
    send(pid, :detach)
    assert_receive {:detached, ^pid}, 5_000
    :ok
  end

  defp answer_stream(pid) do
    send(pid, :answer)
    assert_receive {:answered, ^pid, outcome}, 5_000
    outcome
  end

  # The JSON messages the stream of a tasks/result request carried: the
  # task writes them while the stream is open.
  #
  defp answer_stream_messages(pid) do
    {:streamed, conn} = answer_stream(pid)

    for [data] <- Regex.scan(~r/^data: (.+)$/m, conn.resp_body, capture: :all_but_first),
        do: :json.decode(data)
  end

  # The params of every notifications/cancelled written on the body of
  # the stream.
  #
  defp cancelled_notices(conn) do
    for [data] <- Regex.scan(~r/^data: (.+)$/m, conn.resp_body, capture: :all_but_first),
        %{"method" => "notifications/cancelled", "params" => params} <- [:json.decode(data)],
        do: params
  end

  defp terminate_session_tasks(session_id) do
    SessionProbe.terminate_tasks(@server, session_id)
  end

  defp wait_until(fun) do
    if Utils.eventually(fun) do
      :ok
    else
      flunk("condition was not met in time")
    end
  end

  # Takes the invoke supervisor of the instance out of the tree: the start
  # of a runner then ends with an exit. The restart of the other children
  # does not run (a restart strategy acts on a crash only), so the rest of
  # the instance stays as it is.
  #
  defp stop_calls_child do
    supervisor = Support.Helpers.TreeProbe.workers(@server)
    assert is_pid(supervisor)
    assert :ok = Supervisor.terminate_child(supervisor, @calls_child_id)
    wait_until(fn -> OzMcp.Instance.whereis(@server, :calls) == :not_running end)
    supervisor
  end

  defp restart_calls_child(supervisor) do
    wait_until(fn -> OzMcp.Instance.whereis(@server, :calls) == :not_running end)
    assert {:ok, _pid} = Supervisor.restart_child(supervisor, @calls_child_id)
    :ok
  end

  defp task_pid(task_id) do
    case OzMcp.Instance.whereis(@server, {:task, task_id}) do
      {:ok, pid} -> pid
      :not_running -> nil
    end
  end

  defp waiter_registered?(task_id) do
    case task_pid(task_id) do
      nil -> false
      pid -> match?({_state, %{waiters: [_ | _]}}, :sys.get_state(pid))
    end
  end

  # The waiters of `tasks/result` that the process of the task holds.
  #
  defp task_waiters(task_id) do
    case task_pid(task_id) do
      nil -> []
      pid -> pid |> :sys.get_state() |> elem(1) |> Map.fetch!(:waiters)
    end
  end

  defp wait_new_process(module, key, old_pid) do
    wait_until(fn ->
      case OzMcp.Instance.whereis(module, key) do
        {:ok, pid} -> pid != old_pid and Process.alive?(pid)
        :not_running -> false
      end
    end)
  end

  defp assert_status_notification(task_id, status) do
    {_, notification} = Utils.receive_event(5_000)
    assert notification["method"] == "notifications/tasks/status"

    params = notification["params"]
    assert params["taskId"] == task_id
    assert params["status"] == status
  end
end
