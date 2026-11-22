#
# The `limit` event: one event each time that the server refuses work
# because a limit of the instance, of a principal or of a session is
# reached. The metadata holds the limit, the value of its option and the
# scope and no id of a session or of a principal.
#
defmodule OzMcp.LimitTelemetryTest do
  use ExUnit.Case, async: true

  alias OzMcp.Auth.Principal
  alias OzMcp.Session
  alias OzMcp.Sessions
  alias OzMcp.Structs.Task
  alias OzMcp.Tasks
  alias Support.Helpers.PersistentSnapshot
  alias Support.Helpers.TelemetryCapture
  alias Support.Helpers.Utils
  alias Support.Servers

  @server_module Servers.Default
  @tasks_module Servers.TasksTest
  @alice {"https://issuer.test", "alice"}
  @bob {"https://issuer.test", "bob"}

  setup context do
    ref = TelemetryCapture.attach()
    opts = Map.get(context, :limit_opts) || %{}
    server = Map.get(context, :server_module) || @server_module
    name = Module.concat(server, "L#{System.unique_integer([:positive])}")

    Utils.start_instance(server, [name: name] ++ Map.to_list(opts))

    if server == @tasks_module, do: Support.Entities.Tools.TaskSlowTest.use_instance(name)

    %{ref: ref, instance: name}
  end

  describe "max_sessions" do
    @tag limit_opts: %{max_sessions: 1}
    test "a start over the limit with no idle session gives the refusal event", %{
      ref: ref,
      instance: instance
    } do
      assert {:ok, id} = Sessions.start(instance)
      assert {:ok, _} = Session.open_stream(instance, id, :get, self(), nil)
      assert {:error, :too_many_sessions} = Sessions.start(instance)

      assert [event] = limit_events(ref, instance)
      {_, measurements, meta} = event

      assert measurements == %{count: 1}
      assert meta.instance == instance
      assert meta.server == @server_module
      assert meta.limit == :max_sessions
      assert meta.limit_value == 1
      assert meta.scope == :instance
      assert meta.outcome == :refused

      assert MapSet.new(Map.keys(meta)) ==
               MapSet.new([:instance, :server, :limit, :limit_value, :scope, :outcome])
    end

    @tag limit_opts: %{max_sessions: 1}
    test "a reclaim gives one event with the outcome of the replacement", %{
      ref: ref,
      instance: instance
    } do
      assert {:ok, _id} = Sessions.start(instance)
      assert {:ok, _id} = Sessions.start(instance)

      assert [event] = limit_events(ref, instance)
      {_, measurements, meta} = event

      assert measurements == %{count: 1}
      assert meta.limit == :max_sessions
      assert meta.limit_value == 1
      assert meta.scope == :instance
      assert meta.outcome == :replaced
    end

    test "a start under the limit gives no event", %{ref: ref, instance: instance} do
      assert {:ok, _id} = Sessions.start(instance)
      _ = TelemetryCapture.drain(ref, instance)

      assert [] = limit_events(ref, instance)
    end
  end

  describe "max_sessions_per_principal" do
    @tag limit_opts: %{max_sessions_per_principal: 1}
    test "a busy session of one principal gives one event, another key gives none", %{
      ref: ref,
      instance: instance
    } do
      assert {:ok, id} = Sessions.start(instance, principal_key: @alice)
      assert {:ok, _} = Session.open_stream(instance, id, :get, self(), nil)
      assert {:error, :too_many_sessions} = Sessions.start(instance, principal_key: @alice)
      assert {:ok, _id} = Sessions.start(instance, principal_key: @bob)

      assert [event] = limit_events(ref, instance)
      {_, measurements, meta} = event

      assert measurements == %{count: 1}
      assert meta.limit == :max_sessions_per_principal
      assert meta.limit_value == 1
      assert meta.scope == :principal
      assert meta.outcome == :refused
      assert meta.instance == instance
      assert meta.server == @server_module
    end

    @tag limit_opts: %{max_sessions_per_principal: 1}
    test "a reclaim of one principal gives one event with the outcome of the replacement", %{
      ref: ref,
      instance: instance
    } do
      assert {:ok, _id} = Sessions.start(instance, principal_key: @alice)
      assert {:ok, _id} = Sessions.start(instance, principal_key: @alice)

      assert [event] = limit_events(ref, instance)
      {_, measurements, meta} = event

      assert measurements == %{count: 1}
      assert meta.limit == :max_sessions_per_principal
      assert meta.limit_value == 1
      assert meta.scope == :principal
      assert meta.outcome == :replaced
    end

    @tag limit_opts: %{max_sessions_per_principal: 1, session_snapshot: PersistentSnapshot}
    test "a restore over the limit with no idle session gives the refusal event", %{
      ref: ref,
      instance: instance
    } do
      assert {:ok, id} = Sessions.start(instance, principal_key: @alice)
      assert {:ok, _} = Session.open_stream(instance, id, :get, self(), nil)

      snapshot = %{
        principal_key: @alice,
        protocol_version: nil,
        client_info: %{"name" => "limit-telemetry", "version" => "1"},
        client_capabilities: %{},
        log_level: :warning,
        subscriptions: []
      }

      :ok = PersistentSnapshot.put(instance, "stored-id", snapshot)

      assert {:error, :too_many_sessions} =
               Sessions.start_restored(instance, "stored-id", snapshot)

      assert [event] = limit_events(ref, instance)
      {_, measurements, meta} = event

      assert measurements == %{count: 1}
      assert meta.limit == :max_sessions_per_principal
      assert meta.limit_value == 1
      assert meta.scope == :principal
      assert meta.outcome == :refused
    end
  end

  describe "max_streams_per_session" do
    @tag limit_opts: %{max_streams_per_session: 1}
    test "a second GET stream over the limit gives one event with the outcome of the replacement",
         %{
           ref: ref,
           instance: instance
         } do
      session_id = Utils.create_session(instance, initialized: true)
      first = fake_stream()
      second = fake_stream()

      assert {:ok, _} = Session.open_stream(instance, session_id, :get, first, nil)

      # The second stream ends the first one and takes the slot.
      #
      assert {:ok, _} = Session.open_stream(instance, session_id, :get, second, nil)

      assert [event] = limit_events(ref, instance)
      {_, measurements, meta} = event

      assert measurements == %{count: 1}
      assert meta.limit == :max_streams_per_session
      assert meta.limit_value == 1
      assert meta.scope == :session
      assert meta.outcome == :replaced
      assert meta.instance == instance
      assert meta.server == @server_module
    end

    @tag limit_opts: %{max_streams_per_session: 1}
    test "the stdio stream over the limit gives the same event", %{ref: ref, instance: instance} do
      session_id = Utils.create_session(instance, initialized: true)
      first = fake_stream()
      second = fake_stream()

      assert {:ok, _} = Session.open_stream(instance, session_id, :stdio, first, nil)

      assert {:error, :too_many_streams} =
               Session.open_stream(instance, session_id, :stdio, second, nil)

      assert [event] = limit_events(ref, instance)
      assert elem(event, 2).limit == :max_streams_per_session
      assert elem(event, 2).scope == :session
      assert elem(event, 2).outcome == :refused
    end

    @tag limit_opts: %{max_streams_per_session: 1}
    test "a resume over the limit replaces the oldest stream", %{ref: ref, instance: instance} do
      session_id = Utils.create_session(instance, initialized: true)
      first = fake_stream()
      second = fake_stream()

      assert {:ok, %{priming_id: priming}} =
               Session.open_stream(instance, session_id, :get, first, nil)

      assert :ok = Session.close_stream(instance, session_id, first)
      assert {:ok, _} = Session.open_stream(instance, session_id, :get, second, nil)

      _ = TelemetryCapture.drain(ref, instance)

      # The resume of the ended stream would open a second live stream: it
      # replaces the oldest stream instead.
      #
      assert {:ok, _} = Session.open_stream(instance, session_id, :get, first, priming)

      assert [event] = limit_events(ref, instance)
      assert elem(event, 2).limit == :max_streams_per_session
      assert elem(event, 2).scope == :session
      assert elem(event, 2).outcome == :replaced
    end

    @tag limit_opts: %{max_streams_per_session: nil}
    test "a limit that nil turned off gives no event", %{ref: ref, instance: instance} do
      session_id = Utils.create_session(instance, initialized: true)

      for _ <- 1..3 do
        assert {:ok, _} = Session.open_stream(instance, session_id, :get, fake_stream(), nil)
      end

      _ = TelemetryCapture.drain(ref, instance)

      assert [] = limit_events(ref, instance)
    end
  end

  describe "max_subscriptions_per_session" do
    @tag limit_opts: %{max_subscriptions_per_session: 2}
    test "a new uri over the limit gives one event with the scope of the session", %{
      ref: ref,
      instance: instance
    } do
      session_id = Utils.create_session(instance, initialized: true)

      assert :ok = Sessions.subscribe(instance, session_id, "file:///a.md")
      assert :ok = Sessions.subscribe(instance, session_id, "file:///b.md")

      # A repeat subscribe of a uri in the set is not a new subscription.
      #
      assert :ok = Sessions.subscribe(instance, session_id, "file:///a.md")

      assert {:error, :too_many_subscriptions} =
               Sessions.subscribe(instance, session_id, "file:///c.md")

      assert [event] = limit_events(ref, instance)
      {_, measurements, meta} = event

      assert measurements == %{count: 1}
      assert meta.limit == :max_subscriptions_per_session
      assert meta.limit_value == 2
      assert meta.scope == :session
      assert meta.outcome == :refused
      assert meta.instance == instance
      assert meta.server == @server_module

      assert MapSet.new(Map.keys(meta)) ==
               MapSet.new([:instance, :server, :limit, :limit_value, :scope, :outcome])
    end

    @tag limit_opts: %{max_subscriptions_per_session: 1}
    test "an unsubscribe makes room again", %{ref: ref, instance: instance} do
      session_id = Utils.create_session(instance, initialized: true)

      assert :ok = Sessions.subscribe(instance, session_id, "file:///a.md")

      assert {:error, :too_many_subscriptions} =
               Sessions.subscribe(instance, session_id, "file:///b.md")

      assert :ok = Sessions.unsubscribe(instance, session_id, "file:///a.md")
      assert :ok = Sessions.subscribe(instance, session_id, "file:///b.md")

      # One event: the refusal between the two successful subscribes.
      #
      assert [event] = limit_events(ref, instance)
      assert elem(event, 2).limit == :max_subscriptions_per_session
      assert elem(event, 2).scope == :session
      assert elem(event, 2).outcome == :refused
      assert elem(event, 2).limit_value == 1
    end
  end

  describe "max_tasks_per_session" do
    @tag server_module: @tasks_module, limit_opts: %{max_tasks_per_session: 1}
    test "a second task of one session gives one event with the scope of the session", %{
      ref: ref,
      instance: instance
    } do
      session_id = Utils.create_session(instance, initialized: true)
      {first, runner} = create_slow_task(instance, session_id)

      assert {:error, {:too_many_tasks, :max_tasks_per_session}} =
               Tasks.create(instance, slow_attrs(session_id))

      assert [event] = limit_events(ref, instance)
      {_, measurements, meta} = event

      assert measurements == %{count: 1}
      assert meta.limit == :max_tasks_per_session
      assert meta.limit_value == 1
      assert meta.scope == :session
      assert meta.outcome == :refused
      assert meta.instance == instance
      assert meta.server == @tasks_module

      send(runner, :finish)
      assert {:ok, {:ok, _}} = Tasks.await(instance, Utils.owner(session_id), first.taskId)
    end
  end

  describe "max_tasks_per_principal" do
    @tag server_module: @tasks_module, limit_opts: %{max_tasks_per_principal: 1}
    test "a second task of one principal gives one event, another principal gives none", %{
      ref: ref,
      instance: instance
    } do
      alice = Principal.new!(issuer: "https://issuer.test", subject: "alice")
      bob = Principal.new!(issuer: "https://issuer.test", subject: "bob")
      session_id = Utils.create_session(instance, initialized: true)

      {first, first_runner} = create_slow_task(instance, session_id, principal: alice)

      assert {:error, {:too_many_tasks, :max_tasks_per_principal}} =
               Tasks.create(instance, slow_attrs(session_id, principal: alice))

      Support.Entities.Tools.TaskSlowTest.reset()

      assert {:ok, _} = Tasks.create(instance, slow_attrs(session_id, principal: bob))
      bob_runner = wait_for_runner()

      assert [event] = limit_events(ref, instance)
      {_, measurements, meta} = event

      assert measurements == %{count: 1}
      assert meta.limit == :max_tasks_per_principal
      assert meta.limit_value == 1
      assert meta.scope == :principal
      assert meta.outcome == :refused
      assert meta.instance == instance
      assert meta.server == @tasks_module

      send(first_runner, :finish)
      send(bob_runner, :finish)

      assert {:ok, {:ok, _}} =
               Tasks.await(instance, {:principal, Principal.key(alice)}, first.taskId)
    end
  end

  describe "max_task_records_per_owner" do
    @tag limit_opts: %{
           max_task_records_per_owner: 1,
           max_tasks_per_session: 1,
           max_tasks_per_principal: 1
         }
    test "the records of the session give the scope of the session", %{
      ref: ref,
      instance: instance
    } do
      session_id = Utils.create_session(instance, initialized: true)
      _task = create_completed_task(instance, session_id)

      assert {:error, {:too_many_tasks, :max_task_records_per_owner}} =
               Tasks.create(instance, completed_attrs(session_id))

      assert [event] = limit_events(ref, instance)
      {_, measurements, meta} = event

      assert measurements == %{count: 1}
      assert meta.limit == :max_task_records_per_owner
      assert meta.limit_value == 1
      assert meta.scope == :session
      assert meta.outcome == :refused
    end

    @tag limit_opts: %{
           max_task_records_per_owner: 1,
           max_tasks_per_session: 1,
           max_tasks_per_principal: 1
         }
    test "the records of a principal give the scope of the principal", %{
      ref: ref,
      instance: instance
    } do
      alice = Principal.new!(issuer: "https://issuer.test", subject: "alice")
      session_id = Utils.create_session(instance, initialized: true)
      _task = create_completed_task(instance, session_id, principal: alice)

      assert {:error, {:too_many_tasks, :max_task_records_per_owner}} =
               Tasks.create(instance, completed_attrs(session_id, principal: alice))

      assert [event] = limit_events(ref, instance)
      assert elem(event, 2).limit == :max_task_records_per_owner
      assert elem(event, 2).scope == :principal
      assert elem(event, 2).outcome == :refused
    end

    @tag limit_opts: %{
           max_task_records_per_owner: 1,
           max_tasks_per_session: 1,
           max_tasks_per_principal: 1
         }
    test "the active limit of the session comes before the record limit", %{
      ref: ref,
      instance: instance
    } do
      session_id = Utils.create_session(instance, initialized: true)
      {_task, runner} = create_slow_task(instance, session_id)

      assert {:error, {:too_many_tasks, :max_tasks_per_session}} =
               Tasks.create(instance, slow_attrs(session_id))

      assert [event] = limit_events(ref, instance)
      assert elem(event, 2).limit == :max_tasks_per_session
      assert elem(event, 2).outcome == :refused

      send(runner, :finish)
    end
  end

  describe "max_task_bytes_per_owner" do
    @tag limit_opts: %{max_task_bytes_per_owner: 1_000}
    test "the byte budget gives its own limit name and the scope of the owner", %{
      ref: ref,
      instance: instance
    } do
      session_id = Utils.create_session(instance, initialized: true)
      settled = {:completed, nil, {:ok, %{"data" => String.duplicate("x", 5_000)}}}

      assert {:ok, %Task{status: :completed}} =
               Tasks.create(instance, Map.put(completed_attrs(session_id), :settled, settled))

      assert {:error, {:too_many_tasks, :max_task_bytes_per_owner}} =
               Tasks.create(instance, completed_attrs(session_id))

      assert [event] = limit_events(ref, instance)
      {_, _, meta} = event

      assert meta.limit == :max_task_bytes_per_owner
      assert meta.limit_value == 1_000
      assert meta.scope == :session
      assert meta.outcome == :refused
    end
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  # The events of the limit in the drained list. The drain consumes the
  # mailbox, so the test drains one time and picks the events here.
  #
  defp limit_events(ref, instance) do
    events = TelemetryCapture.drain(ref, instance)
    Enum.filter(events, fn {name, _, _} -> name == [:oz_mcp, :limit, :reached] end)
  end

  defp completed_attrs(session_id, extra \\ %{}) do
    Map.merge(
      %{
        session_id: session_id,
        tool: {Support.Entities.Tools.TaskImmediateTest, "task_immediate"},
        request: %{"name" => "task_immediate", "arguments" => %{}},
        ttl: 60_000,
        progress_token: nil
      },
      Map.new(extra)
    )
  end

  defp create_completed_task(instance, session_id, extra \\ %{}) do
    attrs = completed_attrs(session_id, extra)
    owner = Tasks.owner_key(%{principal: attrs[:principal], session_id: session_id})

    assert {:ok, %Task{} = task} = Tasks.create(instance, attrs)
    assert {:ok, {:ok, _}} = Tasks.await(instance, owner, task.taskId, 5_000)

    task
  end

  defp slow_attrs(session_id, extra \\ %{}) do
    Map.merge(
      %{
        session_id: session_id,
        tool: {Support.Entities.Tools.TaskSlowTest, "task_slow"},
        request: %{"name" => "task_slow", "arguments" => %{}},
        ttl: nil,
        progress_token: nil
      },
      Map.new(extra)
    )
  end

  defp create_slow_task(instance, session_id, extra \\ %{}) do
    Support.Entities.Tools.TaskSlowTest.reset()

    assert {:ok, %Task{} = task} = Tasks.create(instance, slow_attrs(session_id, extra))

    {task, wait_for_runner()}
  end

  defp wait_for_runner do
    assert Utils.eventually(fn ->
             Support.Entities.Tools.TaskSlowTest.last_runner_pid() != nil
           end)

    Support.Entities.Tools.TaskSlowTest.last_runner_pid()
  end

  defp fake_stream do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end
end
