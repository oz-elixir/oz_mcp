defmodule OzMcp.InstanceTest do
  #
  # Sync: the tests use fixed global instance names and one test uses the default name of an
  # instance (the server module).
  #
  use ExUnit.Case, async: false

  alias OzMcp.Instance
  alias OzMcp.Instance.Config
  alias OzMcp.Sessions
  alias OzMcp.Telemetry
  alias Support.Helpers.Utils
  alias Support.Servers

  @server Servers.RuntimeTest

  describe "child_spec/1 and start_link/1" do
    test "starts an instance with the server module as the default name" do
      pid = start_supervised!({OzMcp, server: @server, allowed_origins: []})

      assert is_pid(pid)
      assert is_pid(GenServer.whereis(Instance.names(@server)))
      assert Instance.whereis(@server, :sessions) != :not_running
    end

    test "starts an instance with an explicit name" do
      pid = start_supervised!({OzMcp, server: @server, name: :my_instance, allowed_origins: []})

      assert is_pid(pid)
      assert is_pid(GenServer.whereis(Instance.names(:my_instance)))
      assert is_pid(GenServer.whereis(Instance.topics(:my_instance)))
      assert Instance.whereis(:my_instance, :sessions) != :not_running
    end

    test "the child spec id contains the instance name" do
      spec = Instance.child_spec(server: @server, name: :spec_name, allowed_origins: [])
      assert spec.id == {Instance, :spec_name}
      assert spec.type == :supervisor
    end

    test "the instance registers itself under <Name>.Instance" do
      start_supervised!({OzMcp, server: @server, name: RegisteredName, allowed_origins: []})

      assert is_pid(Process.whereis(RegisteredName.Instance))
    end
  end

  describe "config/1" do
    test "reads the config from the meta of the Names Registry" do
      start_supervised!(
        {OzMcp, server: @server, name: :cfg, allowed_origins: ["http://localhost"]}
      )

      assert {:ok, %Config{} = config} = Instance.config(:cfg)
      assert config.name == :cfg
      assert config.server == @server
      assert config.transport == :http
      assert config.opts.allowed_origins == ["http://localhost"]
    end

    test "returns :not_running for a stopped instance" do
      assert Instance.config(:never_started_instance) == :not_running
    end
  end

  describe "whereis/2" do
    test "resolves processes registered in the Names Registry of the instance" do
      start_supervised!({OzMcp, server: @server, name: :w, allowed_origins: []})

      assert {:ok, server_pid} = Instance.whereis(:w, :sessions)
      assert is_pid(server_pid)
      assert Process.alive?(server_pid)
    end

    test "returns :not_running for an unknown key" do
      start_supervised!({OzMcp, server: @server, name: :w2, allowed_origins: []})

      assert Instance.whereis(:w2, :no_such_key) == :not_running
    end

    test "returns :not_running when the instance does not run" do
      assert Instance.whereis(:never_started_instance, :sessions) == :not_running
    end

    test "returns :not_running for a dead process that the Registry still holds" do
      start_supervised!({OzMcp, server: @server, name: :w3, allowed_origins: []})
      names = Instance.names(:w3)

      partitions =
        for i <- 0..(System.schedulers_online() - 1),
            pid = Process.whereis(Module.concat(names, "PIDPartition#{i}")),
            do: pid

      Enum.each(partitions, &:sys.suspend/1)

      try do
        parent = self()

        probe =
          spawn(fn ->
            {:ok, _} = Registry.register(names, :probe, nil)
            send(parent, :registered)
            Process.sleep(:infinity)
          end)

        assert_receive :registered
        ref = Process.monitor(probe)
        Process.exit(probe, :kill)
        assert_receive {:DOWN, ^ref, :process, ^probe, :killed}

        # The entry is still there (partitions are suspended), so only the check hides it.
        #
        assert [{^probe, _}] = Registry.lookup(names, :probe)
        assert Instance.whereis(:w3, :probe) == :not_running
      after
        Enum.each(partitions, &:sys.resume/1)
      end
    end
  end

  describe "via/2" do
    test "builds a via tuple into the Names Registry of the instance" do
      start_supervised!({OzMcp, server: @server, name: :v, allowed_origins: []})

      assert {:ok, server_pid} = Instance.whereis(:v, :sessions)
      assert Instance.via(:v, :sessions) == {:via, Registry, {Instance.names(:v), :sessions}}
      assert Process.alive?(server_pid)
    end
  end

  describe "Config.parse!/1" do
    test "defaults the name to the server module" do
      config = Config.parse!(%{server: @server, allowed_origins: []})

      assert config.name == @server
      assert config.server == @server
      assert config.transport == :http
    end

    test "accepts keyword lists" do
      config = Config.parse!(server: @server, name: :kw, allowed_origins: [])

      assert config.name == :kw
    end

    test "defaults the transport to :http" do
      config = Config.parse!(%{server: @server, allowed_origins: []})
      assert config.transport == :http
    end

    test "accepts the :stdio transport without allowed_origins" do
      config = Config.parse!(%{server: @server, transport: :stdio})

      assert config.transport == :stdio
      assert config.opts.allowed_origins == []
    end

    test "merges the server defaults into opts" do
      config = Config.parse!(%{server: @server, allowed_origins: []})

      assert config.opts.session_timeout_ms == 3_600_000
      assert config.opts.session_init_timeout_ms == 30_000
      assert config.opts.max_tasks_per_session == 100
      assert config.opts.sse_heartbeat_ms == 15_000
      assert config.opts.sse_event_log_size == 256
      assert config.opts.task_max_ttl_ms == 86_400_000
      assert config.opts.allowed_hosts == :any
    end

    test "the session and task limits have a finite default" do
      config = Config.parse!(%{server: @server, allowed_origins: []})

      assert config.opts.max_sessions == 10_000
      assert config.opts.max_sessions_per_principal == 100
      assert config.opts.max_streams_per_session == 8
      assert config.opts.max_tasks_per_principal == 1_000
    end

    test "nil turns a limit off" do
      config =
        Config.parse!(%{
          server: @server,
          allowed_origins: [],
          max_sessions: nil,
          max_sessions_per_principal: nil,
          max_streams_per_session: nil,
          max_tasks_per_principal: nil
        })

      assert config.opts.max_sessions == nil
      assert config.opts.max_sessions_per_principal == nil
      assert config.opts.max_streams_per_session == nil
      assert config.opts.max_tasks_per_principal == nil
    end

    test "an instance with max_sessions: nil has no cap on its session supervisor" do
      start_supervised!(
        {OzMcp, server: @server, name: :no_cap, allowed_origins: [], max_sessions: nil}
      )

      {:ok, supervisor} = Instance.whereis(:no_cap, :sessions)

      assert :sys.get_state(supervisor).max_children == :infinity
    end

    test "honors overrides of the server opts" do
      config =
        Config.parse!(%{
          server: @server,
          allowed_origins: [],
          session_timeout_ms: 60_000,
          max_sessions: 5
        })

      assert config.opts.session_timeout_ms == 60_000
      assert config.opts.max_sessions == 5
    end

    test "accepts the :any default of allowed_hosts" do
      config = Config.parse!(%{server: @server, allowed_origins: [], allowed_hosts: :any})

      assert config.opts.allowed_hosts == :any
    end

    test "lower-cases the names of allowed_hosts" do
      config =
        Config.parse!(%{
          server: @server,
          allowed_origins: [],
          allowed_hosts: ["LocalHost", "[::1]"]
        })

      assert config.opts.allowed_hosts == ["localhost", "[::1]"]
    end

    test "raises for allowed_hosts that is not :any or a list" do
      assert_raise ArgumentError,
                   ~r/allowed_hosts must be :any or a list of host names, got: "localhost"/,
                   fn ->
                     Config.parse!(%{
                       server: @server,
                       allowed_origins: [],
                       allowed_hosts: "localhost"
                     })
                   end
    end

    test "raises for an element of allowed_hosts that is not a string" do
      assert_raise ArgumentError, ~r/allowed_hosts must hold non-empty strings/, fn ->
        Config.parse!(%{server: @server, allowed_origins: [], allowed_hosts: [:localhost]})
      end
    end

    test "raises for an empty name in allowed_hosts" do
      assert_raise ArgumentError, ~r/allowed_hosts must hold non-empty strings/, fn ->
        Config.parse!(%{server: @server, allowed_origins: [], allowed_hosts: [""]})
      end
    end

    test "publishes the opts including resource metadata" do
      config =
        Config.parse!(%{
          server: Servers.Authorized,
          allowed_origins: [],
          resource_url: "https://mcp.example.com/mcp"
        })

      assert config.opts.resource_url == "https://mcp.example.com/mcp"

      assert config.opts.resource_metadata_url ==
               "https://mcp.example.com/.well-known/oauth-protected-resource/mcp"
    end

    test "raises without the :server option" do
      assert_raise ArgumentError, ~r/OzMcp needs the option :server/, fn ->
        Config.parse!(%{allowed_origins: []})
      end
    end

    test "raises for a server module that is not loaded" do
      assert_raise ArgumentError, fn ->
        Config.parse!(%{server: NoSuchServerModule, allowed_origins: []})
      end
    end

    test "raises for a name that is a string" do
      assert_raise ArgumentError, ~r/name must be an atom/, fn ->
        Config.parse!(%{server: @server, name: "not-an-atom", allowed_origins: []})
      end
    end

    test "raises for a name that is nil, true or false" do
      for name <- [nil, true, false] do
        assert_raise ArgumentError, ~r/name must be an atom/, fn ->
          Config.parse!(%{server: @server, name: name, allowed_origins: []})
        end
      end
    end

    test "raises for a name that is not an atom" do
      for name <- ["x", 1] do
        assert_raise ArgumentError, ~r/name must be an atom/, fn ->
          Config.parse!(%{server: @server, name: name, allowed_origins: []})
        end
      end
    end

    test "accepts an atom name" do
      config = Config.parse!(%{server: @server, name: :my_server, allowed_origins: []})
      assert config.name == :my_server
    end

    test "raises for an invalid transport" do
      assert_raise ArgumentError, ~r/transport must be :http or :stdio/, fn ->
        Config.parse!(%{server: @server, transport: :tcp, allowed_origins: []})
      end
    end

    test "raises for the wildcard origin" do
      assert_raise ArgumentError, ~r/is not a wildcard/, fn ->
        Config.parse!(%{server: @server, allowed_origins: ["*"]})
      end
    end

    test "raises for an invalid origin" do
      assert_raise ArgumentError, ~r/allowed_origins must hold non-empty strings/, fn ->
        Config.parse!(%{server: @server, allowed_origins: [:localhost]})
      end
    end

    test "raises for an unknown option, for example a misspelled name" do
      assert_raise ArgumentError, ~r/unknown option\(s\) for .*: \[:session_timout\]/, fn ->
        Config.parse!(%{server: @server, allowed_origins: [], session_timout: 600})
      end
    end

    test "raises for the derived key resource_metadata_url" do
      assert_raise ArgumentError,
                   ~r/unknown option\(s\) for .*: \[:resource_metadata_url\]/,
                   fn ->
                     Config.parse!(%{
                       server: @server,
                       allowed_origins: [],
                       resource_metadata_url: "https://a.example"
                     })
                   end
    end

    test "raises for an invalid server option value" do
      assert_raise ArgumentError,
                   "session_init_timeout_ms must be a positive integer, got: 1.5",
                   fn ->
                     Config.parse!(%{
                       server: @server,
                       allowed_origins: [],
                       session_init_timeout_ms: 1.5
                     })
                   end
    end

    test "accepts the new name of each time option" do
      config =
        Config.parse!(%{
          server: @server,
          allowed_origins: [],
          session_timeout_ms: 1_000,
          request_timeout_ms: 1_000,
          task_max_ttl_ms: 1_000
        })

      assert config.opts.session_timeout_ms == 1_000
      assert config.opts.request_timeout_ms == 1_000
      assert config.opts.task_max_ttl_ms == 1_000
    end

    test "raises when a protected server has no resource_url" do
      assert_raise ArgumentError,
                   ~r/declares an authorization block, its opts must set :resource_url/,
                   fn ->
                     Config.parse!(%{server: Servers.Authorized, allowed_origins: []})
                   end
    end

    test "raises when an open server sets a resource_url" do
      assert_raise ArgumentError, ~r/declares no authorization block/, fn ->
        Config.parse!(%{
          server: @server,
          allowed_origins: [],
          resource_url: "https://mcp.example.com/mcp"
        })
      end
    end

    # ---- Check of the options at boot

    for {key, bad} <- [
          session_timeout_ms: 0,
          session_timeout_ms: -1,
          session_timeout_ms: 1.5,
          session_timeout_ms: nil,
          session_timeout_ms: "600",
          task_page_size: 0,
          task_page_size: nil,
          task_page_size: 1.5,
          task_poll_interval_ms: 0,
          task_poll_interval_ms: -5,
          task_poll_interval_ms: "1000",
          tasks_follow_session: nil,
          tasks_follow_session: "yes"
        ] do
      test "refuses #{key}: #{inspect(bad)}" do
        key = unquote(key)
        bad = unquote(bad)

        assert_raise ArgumentError, ~r/#{key} must be/, fn ->
          Config.parse!(Map.merge(%{server: @server, allowed_origins: []}, %{key => bad}))
        end
      end
    end

    test "the message of session_timeout_ms names the unit" do
      assert_raise ArgumentError,
                   ~r/session_timeout_ms must be a positive integer \(ms\)/,
                   fn ->
                     Config.parse!(%{server: @server, allowed_origins: [], session_timeout_ms: 0})
                   end
    end

    test "accepts a nil task_poll_interval_ms" do
      config = Config.parse!(%{server: @server, allowed_origins: [], task_poll_interval_ms: nil})

      assert config.opts.task_poll_interval_ms == nil
    end

    test "refuses a default TTL above the cap" do
      assert_raise ArgumentError, ~r/task_default_ttl_ms \(5000\) must not be higher/, fn ->
        Config.parse!(%{
          server: @server,
          allowed_origins: [],
          task_default_ttl_ms: 5_000,
          task_max_ttl_ms: 1_000
        })
      end
    end

    test "refuses a default TTL above the default cap" do
      assert_raise ArgumentError, ~r/task_default_ttl_ms .* must not be higher/, fn ->
        Config.parse!(%{server: @server, allowed_origins: [], task_default_ttl_ms: 86_400_001})
      end
    end

    test "accepts a default TTL equal to the cap" do
      assert %Config{} =
               Config.parse!(%{
                 server: @server,
                 allowed_origins: [],
                 task_default_ttl_ms: 1_000,
                 task_max_ttl_ms: 1_000
               })
    end

    test "accepts a default TTL with no cap" do
      assert %Config{} =
               Config.parse!(%{
                 server: @server,
                 allowed_origins: [],
                 task_default_ttl_ms: 5_000,
                 task_max_ttl_ms: nil
               })
    end
  end

  describe "telemetry_prefix" do
    test "defaults to [:oz_mcp] and builds the full event names once" do
      config = Config.parse!(%{server: @server, allowed_origins: []})

      assert config.opts.telemetry_prefix == [:oz_mcp]
      assert %Telemetry{} = telemetry = config.telemetry
      assert telemetry.instance == @server
      assert telemetry.server == @server
      assert telemetry.spans.request.start == [:oz_mcp, :request, :start]
      assert telemetry.spans.request.stop == [:oz_mcp, :request, :stop]
      assert telemetry.spans.request.exception == [:oz_mcp, :request, :exception]
      assert telemetry.points.limit_reached == [:oz_mcp, :limit, :reached]
    end

    test "accepts a custom prefix" do
      config =
        Config.parse!(%{
          server: @server,
          allowed_origins: [],
          telemetry_prefix: [:oz_mcp, :engineering]
        })

      assert config.opts.telemetry_prefix == [:oz_mcp, :engineering]
      assert config.telemetry.spans.request.stop == [:oz_mcp, :engineering, :request, :stop]

      assert config.telemetry.points.session_restore == [
               :oz_mcp,
               :engineering,
               :session,
               :restore
             ]
    end

    for bad <- [[], "oz_mcp", [:oz_mcp, "x"], nil] do
      test "refuses #{inspect(bad)}" do
        bad = unquote(bad)

        assert_raise ArgumentError,
                     ~r/telemetry_prefix must be a non-empty list of atoms/,
                     fn ->
                       Config.parse!(%{
                         server: @server,
                         allowed_origins: [],
                         telemetry_prefix: bad
                       })
                     end
      end
    end

    test "two instances with two prefixes keep two sets of names" do
      start_supervised!(
        {OzMcp,
         server: @server, name: :tel_a, allowed_origins: [], telemetry_prefix: [:oz_mcp, :a]},
        id: :tel_a
      )

      start_supervised!(
        {OzMcp,
         server: @server, name: :tel_b, allowed_origins: [], telemetry_prefix: [:oz_mcp, :b]},
        id: :tel_b
      )

      assert {:ok, config_a} = Instance.config(:tel_a)
      assert {:ok, config_b} = Instance.config(:tel_b)

      assert config_a.telemetry.spans.request.stop == [:oz_mcp, :a, :request, :stop]
      assert config_b.telemetry.spans.request.stop == [:oz_mcp, :b, :request, :stop]
      assert config_a.telemetry != config_b.telemetry
    end
  end

  describe "two instances of one server module" do
    test "keep their sessions apart" do
      start_supervised!({OzMcp, server: @server, name: :twin_a, allowed_origins: []}, id: :a)
      start_supervised!({OzMcp, server: @server, name: :twin_b, allowed_origins: []}, id: :b)

      assert {:ok, session_a} = Sessions.start(:twin_a)
      assert {:ok, session_b} = Sessions.start(:twin_b)

      assert {:ok, _state} = Sessions.state(:twin_a, session_a)
      refute match?({:ok, _}, Sessions.state(:twin_a, session_b))
      refute match?({:ok, _}, Sessions.state(:twin_b, session_a))

      assert :ok = Sessions.terminate(:twin_a, session_a)
      assert {:ok, _state} = Sessions.state(:twin_b, session_b)
    end

    test "have their own processes and Registries" do
      start_supervised!({OzMcp, server: @server, name: :own_a, allowed_origins: []}, id: :a)
      start_supervised!({OzMcp, server: @server, name: :own_b, allowed_origins: []}, id: :b)

      assert {:ok, pid_a} = Instance.whereis(:own_a, :sessions)
      assert {:ok, pid_b} = Instance.whereis(:own_b, :sessions)
      assert pid_a != pid_b
      assert Process.whereis(Instance.names(:own_a)) != Process.whereis(Instance.names(:own_b))
    end

    test "a kill of the Names Registry of one instance restarts that instance only" do
      start_supervised!({OzMcp, server: @server, name: :kill_a, allowed_origins: []}, id: :a)
      start_supervised!({OzMcp, server: @server, name: :kill_b, allowed_origins: []}, id: :b)

      {:ok, old_a} = Instance.whereis(:kill_a, :sessions)
      {:ok, old_b} = Instance.whereis(:kill_b, :sessions)

      Process.exit(Process.whereis(Instance.names(:kill_a)), :kill)

      assert wait_until(fn ->
               match?({:ok, pid} when pid != old_a, Instance.whereis(:kill_a, :sessions))
             end)

      assert {:ok, ^old_b} = Instance.whereis(:kill_b, :sessions)
    end
  end

  describe "start and stop" do
    test "one instance starts and stops 50 times in a loop" do
      for _ <- 1..50 do
        {:ok, pid} =
          Supervisor.start_link([{OzMcp, server: @server, allowed_origins: []}],
            strategy: :one_for_one
          )

        assert {:ok, _} = Instance.whereis(@server, :sessions)
        Supervisor.stop(pid)
        assert Instance.whereis(@server, :sessions) == :not_running
      end
    end
  end

  describe "ETS tables" do
    test "two instances of one server module have two sets of sessions and tables" do
      start_supervised!({OzMcp, server: @server, name: :tables_a, allowed_origins: []}, id: :a)
      start_supervised!({OzMcp, server: @server, name: :tables_b, allowed_origins: []}, id: :b)

      session_id = Utils.create_session(:tables_a)

      assert [{^session_id, _}] = Utils.sessions(:tables_a)
      assert [] = Utils.sessions(:tables_b)

      refute :ets.whereis(OzMcp.Tasks.EtsStore.table(:tables_a)) == :undefined
      refute :ets.whereis(OzMcp.Tasks.EtsStore.table(:tables_b)) == :undefined
      refute OzMcp.Tasks.EtsStore.table(:tables_a) == OzMcp.Tasks.EtsStore.table(:tables_b)
    end

    test "the task tables are public" do
      start_supervised!({OzMcp, server: @server, name: :tables_c, allowed_origins: []})

      assert :ets.info(OzMcp.Tasks.EtsStore.table(:tables_c), :protection) == :public
      assert :ets.info(OzMcp.Tasks.Index.index_table(:tables_c), :protection) == :public
    end
  end

  defp wait_until(fun, retries \\ 1_500) do
    Utils.eventually(fun, retries * 10)
  end
end
