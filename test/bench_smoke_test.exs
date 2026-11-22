#
# Keeps the benchmark code working: each scenario of `Bench.Runner` runs
# with a small count, the trace counters name the hot paths and one
# request of each kind takes the path that the scenarios measure.
#
# The test is excluded by default (tag `:bench`): run it with
# `mix test --only bench`. The scenario of the principals keeps its full
# set of background sessions open, so the test takes longer than a unit
# test.
#
defmodule BenchSmokeTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias Bench.Runner
  alias OzMcp.Catalog

  # The suite excludes this tag by default: `mix test --only bench` runs it.
  #
  @moduletag :bench

  @instance Bench.Server
  @reclaim Bench.Reclaim
  @load Bench.Load
  @count 10

  setup do
    start_supervised!({OzMcp, [server: @instance] ++ Runner.instance_opts()})

    start_supervised!(
      {OzMcp, [server: @instance, name: @reclaim] ++ Runner.reclaim_instance_opts()}
    )

    start_supervised!({OzMcp, [server: @instance, name: @load] ++ Runner.load_instance_opts()})

    :ok
  end

  test "the concurrent load reports one row and leaves no session behind" do
    registry = OzMcp.Instance.names(@load)
    entries = Registry.count(registry)

    row = Bench.Load.run(@load, 20, 500)

    assert row.name == "load_1k"
    assert row.count > 0
    assert row.sessions == 20
    assert row.p50 <= row.p99
    assert row.per_second > 0
    assert row.utilization >= 0 and row.utilization <= 100
    assert is_integer(row.memory_per_session_bytes)

    assert Registry.count(registry) == entries
  end

  test "the utilization counts the normal schedulers only" do
    normal = :erlang.system_info(:schedulers)
    busy = for id <- 1..normal, do: {id, 0, 0}
    busy_later = for id <- 1..normal, do: {id, 1000, 1000}

    first = [{normal + 1, 0, 0} | busy]
    second = [{normal + 1, 0, 1000} | busy_later]

    assert Bench.Load.utilization(first, second) == 100.0
  end

  test "every scenario runs with a small count and reports its rows" do
    rows_of = %{
      ping_10k: ["ping_10k"],
      stream_1k: ["stream_1k"],
      sessions_1k: ["sessions_1k", "sessions_1k_delete"],
      principal_1k: ["principal_1k"]
    }

    for {scenario, names} <- rows_of do
      rows = Runner.measure(@instance, scenario, @count)
      counted = Runner.counts(@instance, scenario, @count) |> Map.new(&{&1.name, &1})

      assert Enum.map(rows, & &1.name) == names

      Enum.each(rows, fn row ->
        assert row.count == @count
        assert is_integer(row.total_ms) and row.total_ms >= 0
        assert row.per_second >= 0
        assert row.p50 >= 0 and row.p95 >= 0 and row.p99 >= 0

        counted_row = Map.fetch!(counted, row.name)

        assert counted_row.counts.ops == @count
        assert counted_row.counts.config_reads >= 0
        assert counted_row.counts.session_calls >= 0
        assert counted_row.counts.count_select >= 0
        assert counted_row.counts.compiles >= 0
      end)
    end
  end

  test "the load scenario reports its row and its counters" do
    assert [row] = Runner.measure(@load, :load_1k, @count)
    assert row.name == "load_1k"
    assert row.sessions == @count
    assert row.count > 0

    assert [%{name: "load_1k", counts: counts}] = Runner.counts(@load, :load_1k, @count)
    assert counts.ops > 0
    assert counts.session_calls > 0
  end

  test "the reclaim scenarios run with a small count and report their rows" do
    rows_of = %{
      reclaim_10k: ["reclaim_10k"],
      reclaim_10k_busy: ["reclaim_10k_busy"]
    }

    for {scenario, names} <- rows_of do
      rows = Runner.measure(@reclaim, scenario, @count)
      counted = Runner.counts(@reclaim, scenario, @count) |> Map.new(&{&1.name, &1})

      assert Enum.map(rows, & &1.name) == names

      Enum.each(rows, fn row ->
        assert row.count == @count
        assert is_integer(row.total_ms) and row.total_ms >= 0
        assert row.per_second >= 0
        assert row.p50 >= 0 and row.p95 >= 0 and row.p99 >= 0

        counted_row = Map.fetch!(counted, row.name)

        assert counted_row.counts.ops == @count
        assert counted_row.counts.session_calls > 0
        assert counted_row.counts.count_select >= 0
      end)
    end
  end

  test "the trace counters name the hot paths of the scenarios" do
    #
    # The start of a principal reads one key of the Principals Registry: it
    # does not scan the Names Registry.
    #
    [%{counts: counts}] = Runner.counts(@instance, :principal_1k, @count)
    assert counts.count_select == 0

    # A streamed call answers through calls to the session and each
    # stage of the pipeline reads the config.
    #
    [%{counts: counts}] = Runner.counts(@instance, :stream_1k, @count)
    assert counts.session_calls > 0
    assert counts.config_reads > 0

    # A ping reads the config too.
    #
    [%{counts: counts}] = Runner.counts(@instance, :ping_10k, @count)
    assert counts.config_reads > 0
  end

  test "the requests of the scenarios take the path that they measure" do
    #
    # The initialize of a session: the id travels in the answer header.
    #
    conn = Runner.post(@instance, nil, initialize_body(1))
    assert conn.status == 200
    assert [session] = get_resp_header(conn, "mcp-session-id")

    # The notification that initializes the session: accepted, no body.
    #
    conn =
      Runner.post(@instance, session, %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized"
      })

    assert conn.status == 202

    # A ping: the plain JSON answer of the request.
    #
    conn = Runner.post(@instance, session, %{"jsonrpc" => "2.0", "id" => 2, "method" => "ping"})
    assert conn.status == 200
    assert %{"result" => %{}} = JSON.decode!(conn.resp_body)

    # The plain tool: the answer stays JSON.
    #
    conn =
      Runner.post(@instance, session, %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools/call",
        "params" => %{"name" => "echo", "arguments" => %{"text" => "plain"}}
      })

    assert conn.status == 200

    assert get_resp_header(conn, "content-type")
           |> hd()
           |> String.starts_with?("application/json")

    assert %{"result" => %{"content" => [%{"text" => "plain"}]}} = JSON.decode!(conn.resp_body)

    # The streamed tool with a progressToken: the answer is an event
    # stream with the three progress reports and the result as the last
    # event.
    #
    conn =
      Runner.post(@instance, session, %{
        "jsonrpc" => "2.0",
        "id" => 4,
        "method" => "tools/call",
        "params" => %{
          "name" => "slow_echo",
          "arguments" => %{"text" => "streamed"},
          "_meta" => %{"progressToken" => 4}
        }
      })

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/event-stream"]

    progress_events = Regex.scan(~r/notifications\/progress/, conn.resp_body)
    assert length(progress_events) == 3
    assert conn.resp_body =~ ~s("text":"streamed")

    # The end of the session.
    #
    conn = Runner.delete(@instance, session)
    assert conn.status == 200

    assert Runner.delete(@instance, session).status == 404
  end

  test "the start of a session of a principal answers with its id" do
    assert {:ok, session} =
             OzMcp.Sessions.start(@instance, principal_key: {nil, "smoke-principal"})

    assert is_binary(session)
  end

  defp initialize_body(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "bench-smoke", "version" => "1.0.0"}
      }
    }
  end
end

#
# Keeps the scenarios and the measures of the tool-heavy server of the
# benchmark working. The test is excluded by default (tag `:bench`): run
# it with `mix test --only bench`.
#
defmodule BenchBigServerSmokeTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias Bench.Runner
  alias OzMcp.Catalog

  @moduletag :bench

  @instance Bench.BigServer
  @count 10

  setup do
    start_supervised!({OzMcp, [server: @instance] ++ Runner.instance_opts()})
    :ok
  end

  test "the tool-heavy server holds the expected entities" do
    catalog = Catalog.fetch(@instance)

    assert Catalog.ordered(catalog, :tools).count == 201
    assert Catalog.ordered(catalog, :prompts).count == 50
    assert Catalog.ordered(catalog, :resources).count == 51
    assert Catalog.ordered(catalog, :templates).count == 50

    assert {Bench.BigServer.Tools.T10, %{name: "tool_10_20"}} =
             Catalog.find_tool(catalog, @instance.last_tool_name())

    assert {Bench.BigServer.Templates.T5, %{uriTemplate: "bench-tpl-5://items/10/{id}"}, params} =
             Catalog.find_template(catalog, @instance.last_template_uri())

    assert params == %{"id" => "1"}
  end

  test "every tool-heavy scenario runs with a small count and reports its rows" do
    rows_of = %{
      tools_call_200: ["tools_call_200"],
      resources_read_tpl: ["resources_read_tpl"],
      tools_list_200: ["tools_list_200"],
      tools_call_50_blocks: ["tools_call_50_blocks"],
      resources_read_50_items: ["resources_read_50_items"]
    }

    for {scenario, names} <- rows_of do
      rows = Runner.measure(@instance, scenario, @count)
      counted = Runner.counts(@instance, scenario, @count) |> Map.new(&{&1.name, &1})

      assert Enum.map(rows, & &1.name) == names

      Enum.each(rows, fn row ->
        assert row.count == @count
        assert is_integer(row.total_ms) and row.total_ms >= 0
        assert row.per_second >= 0
        assert row.p50 >= 0 and row.p95 >= 0 and row.p99 >= 0

        counted_row = Map.fetch!(counted, row.name)

        assert counted_row.counts.ops == @count
        assert counted_row.counts.config_reads >= 0
        assert counted_row.counts.session_calls >= 0
        assert counted_row.counts.count_select >= 0
        assert counted_row.counts.compiles >= 0
      end)
    end
  end

  test "the static measures time the last template, the tool list and the check" do
    measures = Runner.static_measures(@instance, 1, 200, 200)

    assert measures.template_walk_us >= 0
    assert measures.list_build_us >= 0
    assert measures.list_page_us >= 0
    assert is_number(measures.call_check_1_us) and measures.call_check_1_us >= 0
    assert is_number(measures.call_check_50_us) and measures.call_check_50_us >= 0
    assert is_number(measures.read_check_1_us) and measures.read_check_1_us >= 0
    assert is_number(measures.read_check_50_us) and measures.read_check_50_us >= 0
    assert is_number(measures.call_check_50_off_us) and measures.call_check_50_off_us >= 0
    assert is_number(measures.read_check_50_off_us) and measures.read_check_50_off_us >= 0
  end

  test "a check measure stops on a payload that fails its check" do
    assert is_number(
             Runner.check_us(
               "call_check_1_us",
               "tools/call",
               %{content: [%{type: "text", text: "bench"}]},
               1,
               1
             )
           )

    assert_raise RuntimeError, ~r/call_check_1_us.*does not pass its check/, fn ->
      Runner.check_us("call_check_1_us", "tools/call", %{content: [%{text: "bad"}]}, 1, 1)
    end
  end

  test "the result-heavy callbacks answer with their payloads" do
    session = initialized_session()

    conn =
      Runner.post(@instance, session, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => @instance.many_blocks_tool(), "arguments" => %{}}
      })

    assert conn.status == 200
    assert %{"result" => %{"content" => blocks}} = JSON.decode!(conn.resp_body)
    assert length(blocks) == 50

    conn =
      Runner.post(@instance, session, %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "resources/read",
        "params" => %{"uri" => @instance.many_items_uri()}
      })

    assert conn.status == 200
    assert %{"result" => %{"contents" => items}} = JSON.decode!(conn.resp_body)
    assert length(items) == 50
  end

  # One initialized session: the `initialize` request, then the
  # `notifications/initialized` of the client.
  #
  defp initialized_session do
    conn =
      Runner.post(@instance, nil, %{
        "jsonrpc" => "2.0",
        "id" => 0,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "bench-smoke", "version" => "1.0.0"}
        }
      })

    assert [session] = get_resp_header(conn, "mcp-session-id")

    conn =
      Runner.post(@instance, session, %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized"
      })

    assert conn.status == 202
    session
  end
end
