defmodule OzMcp.RuntimeTest do
  use ExUnit.Case
  import Support.Factories.Server
  alias OzMcp.Instance
  alias OzMcp.Sessions
  alias Support.Helpers.Utils
  alias Support.Servers

  @server Servers.RuntimeTest
  @other_server Servers.RuntimeOther

  setup do
    {:ok, pid} =
      Utils.start_runtime(%{
        servers: [
          Servers.RuntimeTest,
          Servers.RuntimeOther
        ],
        allowed_origins: []
      })

    on_exit(fn -> Utils.stop_runtime() end)

    %{runtime: pid}
  end

  describe "start_link/1" do
    test "starts the runtime supervisor" do
      #
      # The setup already started the runtime; here we just assert it is alive
      # and registered under its global name
      #
      assert is_pid(GenServer.whereis(Utils.Runtime))
    end

    test "starts an OzMcp.Instance for each declared module" do
      assert is_pid(GenServer.whereis(Instance.names(@server)))
      assert is_pid(GenServer.whereis(Instance.names(@other_server)))
    end

    test "the Names Registry of each instance is alive and usable" do
      #
      # Looking up an unknown key on a dead registry raises; on a live one it
      # returns an empty list
      #
      assert Registry.lookup(Instance.names(@server), :no_such_server) == []
    end

    test "starts a session supervisor for each declared module" do
      #
      # The servers were started by setup
      #
      assert {:ok, pid_a} = Instance.whereis(@server, :sessions)
      assert {:ok, pid_b} = Instance.whereis(@other_server, :sessions)
      assert is_pid(pid_a)
      assert is_pid(pid_b)
      assert pid_a != pid_b
    end

    test "does not start a server for an undeclared name" do
      assert Instance.whereis(:not_declared_at_boot, :sessions) == :not_running
    end
  end

  describe "start_link/1 duplicate entity keys" do
    test "raises when two tool modules of one server declare the same name" do
      server =
        module "RuntimeDupTools" do
          tools do
            tool Support.Entities.Tools.DslTest.WithAnnotations
            tool Support.Entities.Tools.DslTest.WithIcons
          end
        end
        |> compile()

      config = %{servers: [server], allowed_origins: []}

      assert_raise ArgumentError,
                   "server #{inspect(server)}: the tool name \"doc\" " <>
                     "is declared in [Support.Entities.Tools.DslTest.WithAnnotations, Support.Entities.Tools.DslTest.WithIcons]",
                   fn -> Utils.start_runtime(config) end
    end

    test "raises for the stdio transport too" do
      server =
        module "RuntimeDupToolsStdio" do
          tools do
            tool Support.Entities.Tools.DslTest.WithAnnotations
            tool Support.Entities.Tools.DslTest.WithIcons
          end
        end
        |> compile()

      config = %{transport: :stdio, servers: [server]}

      assert_raise ArgumentError,
                   "server #{inspect(server)}: the tool name \"doc\" " <>
                     "is declared in [Support.Entities.Tools.DslTest.WithAnnotations, Support.Entities.Tools.DslTest.WithIcons]",
                   fn -> Utils.start_runtime(config) end
    end
  end

  describe "tasks table wiring" do
    test "starts a OzMcp.Tasks.Table for each declared module" do
      assert {:ok, pid_a} = Instance.whereis(@server, :tasks_table)
      assert {:ok, pid_b} = Instance.whereis(@other_server, :tasks_table)
      assert is_pid(pid_a)
      assert is_pid(pid_b)
      assert pid_a != pid_b
    end

    test "does not start a tasks table for an undeclared name" do
      assert Instance.whereis(:not_declared_at_boot, :tasks_table) == :not_running
    end
  end

  describe "a crash of one process of a server" do
    test "the task table restarts and restarts Core with the sessions" do
      session_id = Utils.create_session(@server, initialized: true)
      {:ok, sessions_pid} = Instance.whereis(@server, :sessions)
      {:ok, table_pid} = Instance.whereis(@server, :tasks_table)
      core_pid = Support.Helpers.TreeProbe.core(@server)

      Process.exit(table_pid, :kill)
      wait_new_table(@server, table_pid)

      assert Utils.eventually(fn ->
               case Support.Helpers.TreeProbe.core(@server) do
                 pid when is_pid(pid) -> pid != core_pid
                 nil -> false
               end
             end)

      assert Utils.eventually(fn ->
               case Instance.whereis(@server, :sessions) do
                 {:ok, pid} -> pid != sessions_pid
                 :not_running -> false
               end
             end)

      assert Sessions.state(@server, session_id) == {:error, :no_session}
    end

    test "a crash of one session keeps the other sessions and the task table" do
      crashed = Utils.create_session(@server, initialized: true)
      other = Utils.create_session(@server, initialized: true)
      {:ok, table_pid} = Instance.whereis(@server, :tasks_table)
      {:ok, pid} = Instance.whereis(@server, {:session, crashed})

      Process.exit(pid, :kill)
      wait_until(fn -> Sessions.lookup(@server, crashed) == {:error, :no_session} end)

      assert {:ok, ^table_pid} = Instance.whereis(@server, :tasks_table)
      assert {:ok, %{initialized: true}} = Sessions.state(@server, other)
    end
  end

  describe "a crash loop of one server" do
    test "keeps the other server and its sessions" do
      other_session_id = Utils.create_session(@other_server, initialized: true)
      {:ok, other_pid} = Instance.whereis(@other_server, :sessions)
      {:ok, table} = Instance.whereis(@server, :tasks_table)

      Enum.reduce(1..5, table, fn _, old ->
        Process.exit(old, :kill)
        wait_new_table(@server, old)
      end)

      assert {:ok, ^other_pid} = Instance.whereis(@other_server, :sessions)
      assert {:ok, %{initialized: true}} = Sessions.state(@other_server, other_session_id)
    end
  end

  defp wait_until(fun, retries \\ 1_500) do
    if Utils.eventually(fun, retries * 10) do
      :ok
    else
      flunk("condition was not met in time")
    end
  end

  defp wait_new_table(instance, old_pid) do
    wait_until(fn ->
      match?({:ok, pid} when pid != old_pid, Instance.whereis(instance, :tasks_table))
    end)

    {:ok, pid} = Instance.whereis(instance, :tasks_table)
    pid
  end
end
