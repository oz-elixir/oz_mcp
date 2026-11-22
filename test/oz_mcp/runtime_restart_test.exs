#
# End-to-end check of the restart behaviour of the runtime.
#
# One protected server with a task-capable tool loses its task reaper
# and one session process one after the other. The runtime keeps
# serving: the finished task survives the crash of the reaper.
#
# Two more checks run with two servers: a kill of the supervisor of one
# server does not touch the other server and a kill of the supervisor of
# the whole runtime restarts every server and loses every session.
#
defmodule OzMcp.RuntimeRestartTest do
  #
  # Sync: the runtime of the tests has a fixed name, the instances have the names of their server
  # modules and the setup resets the state of the Support.Auth.Default verifier.
  #

  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias OzMcp.Sessions
  alias OzMcp.Tasks
  alias Support.Helpers.Utils
  alias Support.Servers

  @server Servers.AuthorizedIsolation
  @other_server Servers.Default
  @resource_url "https://mcp.example.com/mcp"
  @initialize_params %{
    "protocolVersion" => "2025-11-25",
    "clientInfo" => %{"name" => "test-client", "version" => "1.0.0"}
  }

  setup do
    Support.Auth.Default.reset()
    :ok
  end

  describe "one protected server with a task-capable tool" do
    setup :start_runtime

    @tag :capture_log
    test "keeps serving after the death of the task reaper and a session" do
      #
      # A task-augmented call on a session finishes before anything dies.
      #
      session_1 = open_session()
      task_id = create_finished_task(session_1)

      # A second task is still running when the reaper dies.
      #
      Support.Entities.Tools.TaskSlowTest.use_instance(@server)
      previous = Support.Entities.Tools.TaskSlowTest.last_runner_pid()
      running_id = create_slow_task(session_1)

      # The task exists before its runner runs the tool: the test waits for
      # the runner, so the finish below reaches it.
      #
      Support.Entities.Tools.TaskSlowTest.await_runner(previous)
      running_owner = owner_of(running_id)
      running_pid = pid_of(@server, {:task, running_id})

      # A crash of the task reaper: the finished task keeps its record
      # and its stored result.
      #
      old_reaper = pid_of(@server, :tasks_reaper)
      Process.exit(old_reaper, :kill)
      new_reaper = wait_new_pid(@server, :tasks_reaper, old_reaper)
      refute new_reaper == old_reaper

      # The running task keeps its process and its record.
      #
      assert Process.alive?(running_pid)
      assert pid_of(@server, {:task, running_id}) == running_pid
      assert {:ok, %{status: :working}} = Tasks.get(@server, running_owner, running_id)

      Support.Entities.Tools.TaskSlowTest.finish()

      wait_until(fn ->
        match?({:ok, %{status: :completed}}, Tasks.get(@server, running_owner, running_id))
      end)

      assert {:ok, record} = Tasks.get(@server, owner_of(task_id), task_id)
      assert record.status == :completed

      assert {:ok, {:ok, _}} = Tasks.await(@server, owner_of(task_id), task_id, 5_000)

      # The runtime is alive and the server answers initialize again: a
      # new session works.
      #
      assert Process.alive?(Process.whereis(Utils.Runtime))
      assert Utils.runtime_running?()

      session_3 = open_session()
      session_4 = open_session()
      assert post_tools_list(session_3).status == 200

      # A crash of one session process: the other session is not touched.
      #
      {:ok, session_pid} = OzMcp.Instance.whereis(@server, {:session, session_3})
      Process.exit(session_pid, :kill)

      wait_until(fn -> Sessions.state(@server, session_3) == {:error, :no_session} end)
      assert post_tools_list(session_3).status == 404
      assert post_tools_list(session_4).status == 200

      assert post_tools_list(session_4).status == 200
    end
  end

  describe "a caller that waits in tasks/result while the task process dies" do
    setup :start_runtime

    @tag :capture_log
    test "the wait ends with an internal error and the task becomes failed" do
      {:ok, old_sessions} = lookup_server(@server)
      session_id = open_session()
      task_id = create_slow_task(session_id)

      task_pid = pid_of(@server, {:task, task_id})

      waiter =
        Task.async(fn ->
          post_json_rpc(3, "tasks/result", %{"taskId" => task_id})
          |> put_bearer("alice-token")
          |> put_session_id(session_id)
          |> call_router()
        end)

      wait_until(fn -> waiter_registered?(task_pid) end)
      Process.exit(task_pid, :kill)

      # The request process answers at HTTP 200 with an internal error
      # instead of crashing.
      #
      conn = Task.await(waiter, 30_000)

      assert conn.status == 200
      assert %{"error" => %{"code" => -32603}} = decode_resp(conn)

      # The reaper marks the record failed. The session supervisor keeps
      # its pid.
      #
      wait_until(fn ->
        match?({:ok, %{status: :failed}}, Tasks.get(@server, owner_of(task_id), task_id))
      end)

      assert {:ok, ^old_sessions} = lookup_server(@server)
    end
  end

  describe "a DELETE while a task process does not answer" do
    setup :start_runtime

    @tag :capture_log
    test "answers 200 and keeps the other sessions of the server" do
      session_1 = open_session()
      session_2 = open_session()
      task_id = create_slow_task(session_1)

      {:ok, server_pid} = lookup_server(@server)
      task_pid = pid_of(@server, {:task, task_id})
      :ok = :sys.suspend(task_pid)

      try do
        conn =
          conn(:delete, "/")
          |> put_bearer("alice-token")
          |> put_session_id(session_1)
          |> call_router()

        assert conn.status == 200
        assert {:ok, ^server_pid} = lookup_server(@server)
        assert post_tools_list(session_2).status == 200
      after
        :sys.resume(task_pid)
      end

      # The task process answers again and processes the termination of
      # the session: its task record is gone (its runner with it).
      #
      wait_until(fn ->
        Support.Helpers.TaskScan.all(@server) |> Enum.all?(&(&1.session_id != session_1))
      end)
    end
  end

  describe "a kill of a supervisor while two servers run" do
    setup :start_two_servers_runtime

    @tag :capture_log
    test "a kill of the session supervisor of one server does not touch the other server" do
      session_a = open_session(@server)
      task_id = create_finished_task(session_a)
      names = Process.whereis(OzMcp.Instance.names(@server))
      session_b = open_session(@other_server)

      {:ok, old_server_a} = lookup_server(@server)
      {:ok, server_b} = lookup_server(@other_server)
      old_supervisor_a = pid_of(@server, :sessions)

      Process.exit(old_supervisor_a, :kill)
      wait_new_pid(@server, :sessions, old_supervisor_a)
      wait_new_server(old_server_a)

      # The other server keeps its process and its session.
      #
      assert {:ok, ^server_b} = lookup_server(@other_server)
      assert post_tools_list(session_b, @other_server).status == 200

      # The killed server keeps the Names Registry and the task record.
      #
      assert Process.whereis(OzMcp.Instance.names(@server)) == names
      assert {:ok, %{status: :completed}} = Tasks.get(@server, owner_of(task_id), task_id)
      assert post_tools_list(session_a).status == 404

      # The killed server answers initialize again.
      #
      assert open_session(@server)

      # The instance keeps its pid.
      #
      assert is_pid(GenServer.whereis(OzMcp.Instance.names(@server)))
    end

    @tag :capture_log
    test "a kill of the Names Registry of one server restarts that server only" do
      session_a = open_session(@server)
      session_b = open_session(@other_server)

      runtime_pid = Process.whereis(Utils.Runtime)
      old_registry = Process.whereis(OzMcp.Instance.names(@server))
      {:ok, old_server_a} = lookup_server(@server)
      {:ok, server_b} = lookup_server(@other_server)

      Process.exit(old_registry, :kill)
      wait_new_named(OzMcp.Instance.names(@server), old_registry)

      # The runtime keeps its pid.
      #
      assert Process.whereis(Utils.Runtime) == runtime_pid

      wait_new_server(old_server_a)

      # The session of the killed instance is lost. The other server keeps
      # its process and its session.
      #
      assert post_tools_list(session_a, @server).status == 404
      assert {:ok, ^server_b} = lookup_server(@other_server)
      assert post_tools_list(session_b, @other_server).status == 200

      # Both servers answer initialize.
      #
      assert open_session(@server)
      assert open_session(@other_server)
    end
  end

  describe "a kill of the root of the runtime under a host supervisor" do
    setup do
      {:ok, host} =
        Supervisor.start_link(
          [
            Utils.runtime_spec(%{
              servers: [
                {@server, %{resource_url: @resource_url}},
                @other_server
              ],
              allowed_origins: []
            })
          ],
          strategy: :one_for_one
        )

      on_exit(fn ->
        try do
          Supervisor.stop(host)
        catch
          :exit, _ -> :ok
        end
      end)

      %{host: host}
    end

    @tag :capture_log
    test "a kill of the runtime lets the host restart it and both servers answer", %{
      host: host
    } do
      old_runtime = Process.whereis(Utils.Runtime)
      session_a = open_session(@server)

      Process.exit(old_runtime, :kill)
      new_runtime = wait_new_named(Utils.Runtime, old_runtime)

      assert Process.alive?(host)
      assert new_runtime != old_runtime

      wait_until(fn ->
        match?({:ok, _}, lookup_server(@server)) and
          match?({:ok, _}, lookup_server(@other_server))
      end)

      assert post_tools_list(session_a, @server).status == 404
      assert open_session(@server)
      assert open_session(@other_server)
    end

    @tag :capture_log
    test "a kill of a Names Registry keeps the runtime and both servers answer again" do
      runtime = Process.whereis(Utils.Runtime)
      old_registry = Process.whereis(OzMcp.Instance.names(@server))
      session_a = open_session(@server)

      Process.exit(old_registry, :kill)
      wait_new_named(OzMcp.Instance.names(@server), old_registry)

      wait_until(fn ->
        match?({:ok, _}, lookup_server(@server)) and
          match?({:ok, _}, lookup_server(@other_server))
      end)

      assert Process.whereis(Utils.Runtime) == runtime
      assert post_tools_list(session_a, @server).status == 404
      assert open_session(@server)
      assert open_session(@other_server)
    end
  end

  def start_runtime(_context) do
    {:ok, _pid} =
      Utils.start_runtime(%{
        servers: [
          {@server,
           %{
             resource_url: @resource_url
           }}
        ],
        allowed_origins: []
      })

    on_exit(fn ->
      Utils.stop_runtime()
    end)

    :ok
  end

  def start_two_servers_runtime(_context) do
    {:ok, _pid} =
      Utils.start_runtime(%{
        servers: [
          {@server, %{resource_url: @resource_url}},
          @other_server
        ],
        allowed_origins: []
      })

    on_exit(fn ->
      Utils.stop_runtime()
    end)

    :ok
  end

  defp open_session(server \\ @server) do
    conn =
      post_json_rpc(1, "initialize", @initialize_params)
      |> put_bearer("alice-token")
      |> call_router(server)

    assert conn.status == 200
    assert [session_id] = get_resp_header(conn, "mcp-session-id")

    conn =
      post_notification("notifications/initialized")
      |> put_bearer("alice-token")
      |> put_session_id(session_id)
      |> call_router(server)

    assert conn.status == 202
    session_id
  end

  # The owner of a task of a principal is the key of the principal.
  #
  defp owner_of(task_id) do
    {:ok, record} = OzMcp.Tasks.EtsStore.get(@server, task_id)
    record.owner_key
  end

  defp create_finished_task(session_id) do
    conn =
      post_json_rpc(2, "tools/call", %{"name" => "task_immediate", "task" => %{"ttl" => 60_000}})
      |> put_bearer("alice-token")
      |> put_session_id(session_id)
      |> call_router()

    assert conn.status == 200
    assert %{"task" => %{"taskId" => task_id}} = decode_resp(conn)["result"]

    assert {:ok, {:ok, _}} = Tasks.await(@server, owner_of(task_id), task_id, 5_000)

    task_id
  end

  defp create_slow_task(session_id) do
    conn =
      post_json_rpc(2, "tools/call", %{"name" => "task_slow", "task" => %{"ttl" => 60_000}})
      |> put_bearer("alice-token")
      |> put_session_id(session_id)
      |> call_router()

    assert conn.status == 200
    assert %{"task" => %{"taskId" => task_id}} = decode_resp(conn)["result"]

    task_id
  end

  defp waiter_registered?(task_pid) do
    match?({_state, %{streams: [_ | _]}}, :sys.get_state(task_pid))
  end

  defp post_tools_list(session_id, server \\ @server) do
    post_json_rpc(3, "tools/list")
    |> put_bearer("alice-token")
    |> put_session_id(session_id)
    |> call_router(server)
  end

  defp call_router(conn, server \\ @server),
    do: OzMcp.Router.call(conn, OzMcp.Router.init(server: server, allowed_origins: []))

  defp post_json_rpc(id, method, params \\ %{}) do
    body =
      %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
      |> :json.encode()
      |> IO.iodata_to_binary()

    conn(:post, "/", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
  end

  defp post_notification(method) do
    body =
      %{"jsonrpc" => "2.0", "method" => method, "params" => %{}}
      |> :json.encode()
      |> IO.iodata_to_binary()

    conn(:post, "/", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
  end

  defp put_bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp put_session_id(conn, session_id),
    do: put_req_header(conn, "mcp-session-id", session_id)

  defp decode_resp(conn), do: :json.decode(conn.resp_body)

  # The supervisor of the server processes has no name: it is a child of
  # the instance supervisor.
  #
  defp locate(server, key), do: OzMcp.Instance.whereis(server, key)

  defp pid_of(server, key) do
    case locate(server, key) do
      {:ok, pid} -> pid
      :not_running -> flunk("no process is registered under #{inspect(key)}")
    end
  end

  defp wait_new_pid(server, key, old_pid) do
    wait_until(fn ->
      case locate(server, key) do
        {:ok, pid} -> pid != old_pid and Process.alive?(pid)
        :not_running -> false
      end
    end)

    pid_of(server, key)
  end

  defp lookup_server(server), do: OzMcp.Instance.whereis(server, :sessions)

  defp wait_new_server(old_pid, server \\ @server) do
    wait_until(fn ->
      case lookup_server(server) do
        {:ok, pid} -> pid != old_pid and Process.alive?(pid)
        :not_running -> false
      end
    end)

    {:ok, pid} = lookup_server(server)
    pid
  end

  defp wait_new_named(name, old_pid) do
    wait_until(fn ->
      case Process.whereis(name) do
        pid when is_pid(pid) -> pid != old_pid and Process.alive?(pid)
        nil -> false
      end
    end)

    pid = Process.whereis(name)
    assert pid != nil
    pid
  end

  defp wait_until(fun, retries \\ 1_500) do
    if Utils.eventually(fun, retries * 10) do
      :ok
    else
      flunk("condition was not met in time")
    end
  end
end
