#
# The scenarios and the measures of the benchmark.
#
# The caller starts one instance of `Bench.Server` and one instance of
# `Bench.BigServer` (`instance_opts/0` holds the options) and hands the
# instance of each scenario to the call. The scenarios:
#
# | Scenario | Server | Work |
# |---|---|---|
# | `:ping_10k` | `Bench.Server` | One session, `count` ping requests, one after the other. |
# | `:stream_1k` | `Bench.Server` | One session, `count` streamed `tools/call` requests to `slow_echo`, each with a `progressToken` in `_meta`: the tool reports progress three times, so each answer is an event stream. |
# | `:sessions_1k` | `Bench.Server` | `count` initialize requests (one session each), then `count` DELETE requests. Two rows: `sessions_1k` and `sessions_1k_delete`. |
# | `:principal_1k` | `Bench.Server` | 10,000 sessions of other principals stay open, then `count` `OzMcp.Sessions.start/2` calls, each for a new principal. |
# | `:reclaim_10k` | `Bench.Reclaim` | 10,000 idle sessions fill the pool, then `count` `OzMcp.Sessions.start/2` calls. Each call meets the full pool and reclaims one idle session. |
# | `:reclaim_10k_busy` | `Bench.Reclaim` | 10,000 sessions each hold a request in flight, then `count` `OzMcp.Sessions.start/2` calls. Each call meets the full pool and gets the refusal, because no session is idle. |
# | `:tools_call_200` | `Bench.BigServer` | One session, `count` `tools/call` requests with no stream to the last tool of the last module: the worst case of the module scan. |
# | `:resources_read_tpl` | `Bench.BigServer` | One session, `count` `resources/read` requests that match the last template of the last module. |
# | `:tools_list_200` | `Bench.BigServer` | One session, `count` `tools/list` requests. |
# | `:tools_call_50_blocks` | `Bench.BigServer` | One session, `count` `tools/call` requests to the tool whose callback returns a map with 50 text blocks with annotations: the cost of the check of a big result. |
# | `:resources_read_50_items` | `Bench.BigServer` | One session, `count` `resources/read` requests to the resource whose callback returns a map with 50 items. |
# | `:load_1k` | `Bench.Load` | `count` sessions in parallel, each with one `GET` stream and a loop of streamed `tools/call` requests to `slow_echo`, for a fixed 10 s (`Bench.Load.run/3`). `count` of the row is the requests done and `total_ms` the wall time. |
#
# `measure/3` times each request with `:timer.tc/1` and returns one row
# per phase with the total time, the requests per second and the p50,
# p95 and p99 latencies of one request in microseconds. Each request
# scenario sends one request before the timing and stops the bench when
# the answer holds an `error` member or `isError: true`, so the bench
# never times an error path.
#
# `counts/3` repeats the work of the scenario in a short run with the
# call-count traces of the VM armed (`OzMcp.Instance.config/1`,
# `OzMcp.Session.call/3`, `Registry.count_select/2`, `JSV.build/2`) and
# returns one entry per phase with the counter of each trace. The traces
# change the times, so the counted run reports no time. Call `counts/3`
# after `measure/3`: the scenario then runs against the state that the
# measured run left (the sessions that it keeps open) and the count of
# the seeded sessions of `:principal_1k` stays at its fixed size.
#
# `static_measures/1` times pieces of work that run with no request: the
# last template scan of the server, the build of all the tools of
# `Bench.BigServer`, one `Handler.Page.list/3` call of those tools, the
# check of four result maps (one and 50 text blocks of `tools/call`, one
# and 50 items of `resources/read`), the same 50-block and 50-item
# payloads through the normalize step of `Invoke` with the checks of a
# result off. The check uses
# `OzMcp.Handler.Result.normalize/2`, or `OzMcp.Handler.Shape.check/2`
# at a revision that has no `Handler.Result`, so an old revision gives a
# number too. Each check measure runs its payload one time before the
# timing and stops the bench when the payload does not pass. Each check
# value is the median of five runs after a warm-up; a run
# has 10,000 calls, the two cases with one block or item 100,000 calls. A
# revision without the check modules gives `nil` for the check measures
# and a revision without the runtime options gives `nil` for the two
# measures with the `_off` suffix.
#
defmodule Bench.Runner do
  import Plug.Conn
  import Plug.Test

  alias OzMcp.{Catalog, Instance}
  alias OzMcp.Session
  alias OzMcp.Sessions
  alias OzMcp.Structs.Tool

  # The check modules do not exist on every revision that
  # `bench/compare.sh` runs. A plain atom keeps the compile quiet on a
  # tree that has no such module.
  #
  @result :"Elixir.OzMcp.Handler.Result"
  @shape :"Elixir.OzMcp.Handler.Shape"
  @invoke :"Elixir.OzMcp.Handler.Invoke"

  @router OzMcp.Router

  # The instance holds every session that the scenarios open: the
  # sessions of `:principal_1k` are never initialized and a short init
  # timeout would end them while the scenario runs. The cap sits above
  # the sum of the sessions of all the scenarios.
  #
  @instance_opts [max_sessions: 20_000, session_init_timeout_ms: 600_000]

  # The sessions of other principals that `:principal_1k` keeps open.
  #
  @background_sessions 10_000

  # The sessions of the pool of the reclaim scenarios.
  #
  @reclaim_sessions 10_000

  @reclaim_instance_opts [max_sessions: @reclaim_sessions, session_init_timeout_ms: 600_000]

  # The instance of the concurrent load: 1,000 sessions of the load fit
  # under the cap and no principal limit applies.
  #
  @load_instance_opts [
    max_sessions: 2_000,
    max_sessions_per_principal: nil,
    session_init_timeout_ms: 600_000
  ]

  # The timed window of `:load_1k` and the window of its counted run.
  #
  @load_ms 10_000
  @load_counted_ms 1_000

  @protocol_version "2025-11-25"

  @scenarios [
    :ping_10k,
    :stream_1k,
    :sessions_1k,
    :principal_1k,
    :reclaim_10k,
    :reclaim_10k_busy,
    :tools_call_200,
    :resources_read_tpl,
    :tools_list_200,
    :tools_call_50_blocks,
    :resources_read_50_items,
    :load_1k
  ]

  @traces %{
    config_reads: {Instance, :config, 1},
    #
    # A private function: the counter sees it.
    #
    session_calls: {OzMcp.Session, :call, 3},
    count_select: {Registry, :count_select, 2},
    compiles: {JSV, :build, 2}
  }

  # The repetitions of each measure of `static_measures/1`.
  #
  @static_repeats 1_000

  # The scale of the check measures of `static_measures/1`: the median
  # over the runs of the per-call means, after a warm-up of one tenth of
  # the calls. The two cases with one block or one item pay 100,000
  # calls, because one call is short.
  #
  @measure_runs 5
  @measure_calls 10_000
  @measure_calls_long 100_000

  # The payloads of the check measures: one text block with annotations,
  # one read item and one tool with an inputSchema. The cases with 50
  # items repeat the block or the item, so the measure shows the cost
  # that grows with the size of the result.
  #
  @check_block %{type: "text", text: "bench", annotations: %{priority: 0.5}}
  @check_item %{uri: "bench-res-check://items/1", text: "bench"}
  @call_check_1 %{content: [@check_block]}
  @call_check_50 %{content: for(_ <- 1..50, do: @check_block)}
  @read_check_1 %{contents: [@check_item]}

  @read_check_50 %{
    contents: for(n <- 1..50, do: %{uri: "bench-res-check://items/#{n}", text: "bench"})
  }

  @typedoc "One phase of a scenario: the times of one run."
  @type row :: %{
          :name => String.t(),
          :count => pos_integer(),
          :total_ms => non_neg_integer(),
          :per_second => non_neg_integer(),
          :p50 => non_neg_integer(),
          :p95 => non_neg_integer(),
          :p99 => non_neg_integer(),
          optional(:sessions) => pos_integer(),
          optional(:utilization) => float(),
          optional(:memory_per_session_bytes) => integer()
        }

  @typedoc "The counters of one phase: the raw counts of a short run."
  @type counts :: %{
          config_reads: non_neg_integer(),
          session_calls: non_neg_integer(),
          count_select: non_neg_integer(),
          ops: pos_integer()
        }

  @typedoc "One phase of a scenario: the name of the phase and its counters."
  @type counted_row :: %{name: String.t(), counts: counts()}

  # The scenarios, in the order of the report.
  #
  @spec scenarios() :: [atom()]
  def scenarios, do: @scenarios

  # The options of the instance under benchmark: a high cap of sessions and
  # a long init timeout, so the sessions that a scenario keeps open survive
  # the run.
  #
  @spec instance_opts() :: keyword()
  def instance_opts, do: @instance_opts

  # The options of the instance under benchmark by the reclaim scenarios: a
  # pool of 10,000 sessions and a long init timeout, so the seeded sessions
  # stay open and the pool stays full.
  #
  @spec reclaim_instance_opts() :: keyword()
  def reclaim_instance_opts, do: @reclaim_instance_opts

  # The options of the instance under benchmark by the concurrent load: a
  # pool of 2,000 sessions, no limit per principal and a long init timeout.
  #
  @spec load_instance_opts() :: keyword()
  def load_instance_opts, do: @load_instance_opts

  # Runs one scenario and returns one row per phase. See the moduledoc for
  # the work of each scenario.
  #
  @spec measure(Instance.t(), atom(), pos_integer()) :: [row()]
  def measure(instance, scenario, count)

  def measure(instance, :ping_10k, count) do
    session = initialized_session(instance)
    probe!(&ping(instance, session, &1))
    [run("ping_10k", count, &ping(instance, session, &1))]
  end

  def measure(instance, :stream_1k, count) do
    session = initialized_session(instance)
    probe!(&streamed_call(instance, session, &1))
    [run("stream_1k", count, &streamed_call(instance, session, &1))]
  end

  def measure(instance, :sessions_1k, count) do
    probe!(fn i -> post(instance, nil, initialize_body(i)) end)
    table = :ets.new(:bench_sessions, [:set, :public])

    try do
      created =
        run("sessions_1k", count, fn i ->
          {:ok, session} = initialize(instance, i)
          true = :ets.insert(table, {i, session})
        end)

      by_index =
        Map.new(1..count, fn i ->
          [{^i, session}] = :ets.lookup(table, i)
          {i, session}
        end)

      deleted =
        run("sessions_1k_delete", count, fn i ->
          delete(instance, Map.fetch!(by_index, i))
        end)

      [created, deleted]
    after
      :ets.delete(table)
    end
  end

  def measure(instance, :principal_1k, count) do
    seed_background(instance)
    [run("principal_1k", count, &new_principal_session(instance, &1))]
  end

  def measure(instance, :reclaim_10k, count) do
    seed_reclaim(instance)
    [run("reclaim_10k", count, &reclaim_start(instance, &1))]
  end

  def measure(instance, :reclaim_10k_busy, count) do
    seed_reclaim(instance)
    busy_reclaim(instance)
    [run("reclaim_10k_busy", count, &reclaim_start(instance, &1))]
  end

  def measure(instance, :tools_call_200, count) do
    session = initialized_session(instance)
    probe!(&plain_call(instance, session, &1))
    [run("tools_call_200", count, &plain_call(instance, session, &1))]
  end

  def measure(instance, :resources_read_tpl, count) do
    session = initialized_session(instance)
    probe!(&template_read(instance, session, &1))
    [run("resources_read_tpl", count, &template_read(instance, session, &1))]
  end

  def measure(instance, :tools_list_200, count) do
    session = initialized_session(instance)
    probe!(&tools_list(instance, session, &1))
    [run("tools_list_200", count, &tools_list(instance, session, &1))]
  end

  def measure(instance, :tools_call_50_blocks, count) do
    session = initialized_session(instance)
    probe!(&blocks_call(instance, session, &1))
    [run("tools_call_50_blocks", count, &blocks_call(instance, session, &1))]
  end

  def measure(instance, :resources_read_50_items, count) do
    session = initialized_session(instance)
    probe!(&many_items_read(instance, session, &1))
    [run("resources_read_50_items", count, &many_items_read(instance, session, &1))]
  end

  def measure(instance, :load_1k, count) do
    [Bench.Load.run(instance, count, @load_ms)]
  end

  # Times pieces of work that run with no request, in microseconds:
  # `template_walk_us` is the mean time of `Catalog.find_template/2` for
  # the last template of the server, `list_build_us` is the mean time of
  # `Tool.build/1` on all the tools of the server, `list_page_us` is the
  # mean time of one `Handler.Page.list/3` call of those tools with no page
  # size and the measures of the check are the
  # median of the per-call means of `@measure_runs` runs after a warm-up.
  # The check measures time `OzMcp.Handler.Result.normalize/2` of a
  # `tools/call` map with one and with 50 text blocks with annotations and
  # of a `resources/read` map with one and with 50 items; the two measures
  # with the `_off` suffix time the same payloads through the normalize
  # step of `OzMcp.Handler.Invoke` with the checks of a result off (the
  # runtime option `check_results` is false).
  # At a revision that has no `Handler.Result`, the check measures time
  # `Handler.Shape.check/2` of the same payloads. A revision without the
  # check modules gives `nil` for the check measures and a revision
  # without the option gives `nil` for the two `_off` measures.
  #
  @spec static_measures(module()) :: %{
          template_walk_us: float(),
          list_build_us: float(),
          list_page_us: float(),
          call_check_1_us: float() | nil,
          call_check_50_us: float() | nil,
          read_check_1_us: float() | nil,
          read_check_50_us: float() | nil,
          call_check_50_off_us: float() | nil,
          read_check_50_off_us: float() | nil
        }
  def static_measures(server),
    do: static_measures(server, @measure_runs, @measure_calls, @measure_calls_long)

  # The static measures at the scale of a test: `runs` runs of `calls`
  # calls each and `calls_long` calls for the two cases with one block or
  # one item. The bench scale is 5, 10,000 and 100,000.
  #
  @spec static_measures(module(), pos_integer(), pos_integer(), pos_integer()) :: %{
          template_walk_us: float(),
          list_build_us: float(),
          list_page_us: float(),
          call_check_1_us: float() | nil,
          call_check_50_us: float() | nil,
          read_check_1_us: float() | nil,
          read_check_50_us: float() | nil,
          call_check_50_off_us: float() | nil,
          read_check_50_off_us: float() | nil
        }
  def static_measures(server, runs, calls, calls_long) do
    uri = server.last_template_uri()

    tools =
      Catalog.fetch(server)
      |> Catalog.ordered(:tools)
      |> Map.fetch!(:pairs)
      |> Enum.map(&elem(&1, 0))

    %{
      template_walk_us: mean_us(fn -> Catalog.find_template(Catalog.fetch(server), uri) end),
      list_build_us: mean_us(fn -> Enum.each(tools, &Tool.build/1) end),
      list_page_us: list_page_us(server),
      call_check_1_us: check_us("call_check_1_us", "tools/call", @call_check_1, calls_long, runs),
      call_check_50_us: check_us("call_check_50_us", "tools/call", @call_check_50, calls, runs),
      read_check_1_us:
        check_us("read_check_1_us", "resources/read", @read_check_1, calls_long, runs),
      read_check_50_us:
        check_us("read_check_50_us", "resources/read", @read_check_50, calls, runs),
      call_check_50_off_us:
        check_off_us("call_check_50_off_us", "tools/call", @call_check_50, calls, runs),
      read_check_50_off_us:
        check_off_us("read_check_50_off_us", "resources/read", @read_check_50, calls, runs)
    }
  end

  defp mean_us(fun) do
    {us, _} = :timer.tc(fn -> Enum.each(1..@static_repeats, fn _ -> fun.() end) end)
    Float.round(us / @static_repeats, 1)
  end

  # Times the check of one result `payload` for `method`: the median of the
  # per-call means of `runs` runs of `calls` calls, after a warm-up. The
  # check is `OzMcp.Handler.Result.normalize/2`, or
  # `OzMcp.Handler.Shape.check/2` at a revision that has no
  # `Handler.Result`. Gives `nil` when the tree has neither module. Runs
  # the payload one time first and stops the bench when it does not pass,
  # so a measure never times the error path.
  #
  @spec check_us(String.t(), String.t(), map(), pos_integer(), pos_integer()) :: float() | nil
  def check_us(label, method, payload, calls, runs) do
    case check_fun(method, payload) do
      nil ->
        nil

      fun ->
        check = fun.()
        verify!(label, check)
        median_us(fun, calls, runs)
    end
  end

  defp check_fun(method, payload) do
    cond do
      Code.ensure_loaded?(@result) ->
        fn -> apply(@result, :normalize, [method, payload]) end

      Code.ensure_loaded?(@shape) ->
        fn -> apply(@shape, :check, [method, payload]) end

      true ->
        nil
    end
  end

  # The same payloads through the normalize step of `Invoke` with the
  # checks of a result off. The function exists on a revision from the
  # runtime options on: an older revision gives `nil`.
  #
  defp check_off_us(label, method, payload, calls, runs) do
    if Code.ensure_loaded?(@invoke) and function_exported?(@invoke, :normalize_unchecked, 2) do
      fun = fn -> apply(@invoke, :normalize_unchecked, [payload, method]) end
      verify!(label, fun.())
      median_us(fun, calls, runs)
    end
  end

  defp list_page_us(server) do
    context = OzMcp.Context.new(server, :http_streamable, :rpc)
    mean_us(fn -> OzMcp.Handler.Page.list(context, :tools, nil) end)
  end

  defp verify!(_label, :ok), do: :ok
  defp verify!(_label, {:ok, _value}), do: :ok

  defp verify!(label, other) do
    raise "static measure #{label}: the payload does not pass its check: #{inspect(other)}"
  end

  defp median_us(fun, calls, runs) do
    warmup = div(calls, 10)

    if warmup > 0 do
      for _ <- 1..warmup, do: fun.()
    end

    means =
      for _ <- 1..runs do
        {us, _} = :timer.tc(fn -> for(_ <- 1..calls, do: fun.()) end)
        us / calls
      end

    means |> Enum.sort() |> Enum.at(div(runs, 2)) |> Float.round(2)
  end

  # Repeats the work of one scenario in a short run with the call-count
  # traces armed and returns one entry per phase with the raw counter of
  # each trace. See the moduledoc for the rules of the run.
  #
  @spec counts(Instance.t(), atom(), pos_integer()) :: [counted_row()]
  def counts(instance, scenario, count)

  def counts(instance, :ping_10k, count) do
    session = initialized_session(instance)
    [counted_row("ping_10k", count, &ping(instance, session, &1))]
  end

  def counts(instance, :stream_1k, count) do
    session = initialized_session(instance)
    [counted_row("stream_1k", count, &streamed_call(instance, session, &1))]
  end

  def counts(instance, :sessions_1k, count) do
    table = :ets.new(:bench_counts, [:set, :public])

    try do
      created =
        counted(count, fn i ->
          {:ok, session} = initialize(instance, i)
          true = :ets.insert(table, {i, session})
        end)

      by_index =
        Map.new(1..count, fn i ->
          [{^i, session}] = :ets.lookup(table, i)
          {i, session}
        end)

      deleted = counted(count, fn i -> delete(instance, Map.fetch!(by_index, i)) end)

      [
        %{name: "sessions_1k", counts: Map.put(created, :ops, count)},
        %{name: "sessions_1k_delete", counts: Map.put(deleted, :ops, count)}
      ]
    after
      :ets.delete(table)
    end
  end

  def counts(instance, :principal_1k, count) do
    seed_background(instance)
    traced = counted(count, &new_principal_session(instance, &1))
    [%{name: "principal_1k", counts: Map.put(traced, :ops, count)}]
  end

  def counts(instance, :reclaim_10k, count) do
    seed_reclaim(instance)
    [counted_row("reclaim_10k", count, &reclaim_start(instance, &1))]
  end

  def counts(instance, :reclaim_10k_busy, count) do
    seed_reclaim(instance)
    busy_reclaim(instance)
    [counted_row("reclaim_10k_busy", count, &reclaim_start(instance, &1))]
  end

  def counts(instance, :tools_call_200, count) do
    session = initialized_session(instance)
    [counted_row("tools_call_200", count, &plain_call(instance, session, &1))]
  end

  def counts(instance, :resources_read_tpl, count) do
    session = initialized_session(instance)
    [counted_row("resources_read_tpl", count, &template_read(instance, session, &1))]
  end

  def counts(instance, :tools_list_200, count) do
    session = initialized_session(instance)
    [counted_row("tools_list_200", count, &tools_list(instance, session, &1))]
  end

  def counts(instance, :tools_call_50_blocks, count) do
    session = initialized_session(instance)
    [counted_row("tools_call_50_blocks", count, &blocks_call(instance, session, &1))]
  end

  def counts(instance, :resources_read_50_items, count) do
    session = initialized_session(instance)
    [counted_row("resources_read_50_items", count, &many_items_read(instance, session, &1))]
  end

  # The counters cover the whole run, so they include the open and the
  # delete of the sessions.
  #
  def counts(instance, :load_1k, count) do
    arm_traces()
    row = Bench.Load.run(instance, count, @load_counted_ms)
    traces = read_traces()
    disarm_traces()

    [%{name: "load_1k", counts: Map.put(traces, :ops, row.count)}]
  end

  # ---- Measures ----

  # Times `count` calls of `fun` one after the other. `fun` gets the index
  # of the call, starting at 1. Returns the row of the times.
  #
  @spec run(String.t(), pos_integer(), (pos_integer() -> term())) :: row()
  def run(name, count, fun) do
    flush()

    samples =
      for i <- 1..count do
        {us, _} = :timer.tc(fn -> fun.(i) end)
        flush()
        us
      end

    sorted = Enum.sort(samples)
    total = Enum.sum(sorted)

    %{
      name: name,
      count: count,
      total_ms: div(total, 1000),
      per_second: round(count * 1_000_000 / max(total, 1)),
      p50: percentile(sorted, 0.50),
      p95: percentile(sorted, 0.95),
      p99: percentile(sorted, 0.99)
    }
  end

  # The value at the fraction `p` of a sorted list.
  #
  @spec percentile([number()], float()) :: number()
  def percentile(sorted, p),
    do: Enum.at(sorted, min(round(length(sorted) * p), length(sorted) - 1))

  # The adapter of Plug.Test sends the response to the caller. Without
  # this read, the mailbox grows at each request and each selective
  # receive of the run gets slower. The read is out of the measured time.
  #
  defp flush do
    receive do
      _message -> flush()
    after
      0 -> :ok
    end
  end

  # Runs one request before the timing of its scenario. An answer that
  # holds an `error` member or `isError: true` stops the bench: a scenario
  # must measure the path of a good answer, not the path of an error.
  #
  defp probe!(fun) do
    case fun.(0) do
      %Plug.Conn{} = conn -> check_answer!(conn)
      _other -> :ok
    end
  end

  defp check_answer!(%Plug.Conn{resp_body: body}) when is_binary(body) do
    if String.starts_with?(body, "{") do
      case JSON.decode(body) do
        {:ok, %{"error" => error}} ->
          raise "a benchmark request answered an error: #{inspect(error)}"

        {:ok, %{"result" => %{"isError" => true}}} ->
          raise "a benchmark request answered isError: true"

        _other ->
          :ok
      end
    else
      :ok
    end
  end

  defp check_answer!(_conn), do: :ok

  # ---- Trace counters ----

  # One short run with the traces armed. The traces change the times of
  # the requests: the caller never reports the times of this run.
  #
  defp counted(count, fun) do
    arm_traces()

    for i <- 1..count, do: fun.(i)

    flush()
    traces = read_traces()
    disarm_traces()
    traces
  end

  defp counted_row(name, count, fun),
    do: %{name: name, counts: Map.put(counted(count, fun), :ops, count)}

  defp arm_traces do
    Code.ensure_loaded!(OzMcp.Session)
    Code.ensure_loaded!(JSV)

    for mfa <- Map.values(@traces) do
      #
      # Arming a call-count trace sets its counter to zero.
      #
      :erlang.trace_pattern(mfa, true, [:call_count])
      :erlang.trace_pattern(mfa, :restart, [:call_count])
    end
  end

  defp read_traces do
    Map.new(@traces, fn {key, mfa} ->
      case :erlang.trace_info(mfa, :call_count) do
        {:call_count, n} when is_integer(n) -> {key, n}
        _other -> {key, 0}
      end
    end)
  end

  defp disarm_traces do
    for mfa <- Map.values(@traces) do
      :erlang.trace_pattern(mfa, false, [:call_count])
    end
  end

  # ---- Requests ----

  # Sends one JSON-RPC message to the endpoint of the instance and returns
  # the conn. The path is `/`: the router is called directly and only the
  # forward of a host removes its mount prefix.
  #
  @spec post(Instance.t(), String.t() | nil, map()) :: Plug.Conn.t()
  def post(instance, session_id, body) do
    conn(:post, "/", JSON.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> session_header(session_id)
    |> put_req_header("mcp-protocol-version", @protocol_version)
    |> @router.call(@router.init(instance: instance))
  end

  # Ends the session of a `DELETE` request and returns the conn.
  #
  @spec delete(Instance.t(), String.t()) :: Plug.Conn.t()
  def delete(instance, session_id) do
    conn(:delete, "/")
    |> put_req_header("mcp-session-id", session_id)
    |> put_req_header("mcp-protocol-version", @protocol_version)
    |> @router.call(@router.init(instance: instance))
  end

  defp session_header(conn, nil), do: conn
  defp session_header(conn, session_id), do: put_req_header(conn, "mcp-session-id", session_id)

  # Opens one initialized session: the `initialize` request, then the
  # `notifications/initialized` of the client. Returns the session id.
  #
  @spec initialized_session(Instance.t()) :: String.t()
  def initialized_session(instance) do
    {:ok, session} = initialize(instance, 0)

    conn = post(instance, session, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

    if conn.status == 202 do
      session
    else
      raise "the session did not initialize (status #{conn.status})"
    end
  end

  defp initialize(instance, id) do
    conn = post(instance, nil, initialize_body(id))

    case get_resp_header(conn, "mcp-session-id") do
      [session] -> {:ok, session}
      [] -> raise "no session in the answer of initialize (status #{conn.status})"
    end
  end

  defp initialize_body(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @protocol_version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "bench", "version" => "1.0.0"}
      }
    }
  end

  defp ping(instance, session, i) do
    post(instance, session, %{"jsonrpc" => "2.0", "id" => i, "method" => "ping"})
  end

  defp streamed_call(instance, session, i) do
    post(instance, session, %{
      "jsonrpc" => "2.0",
      "id" => i,
      "method" => "tools/call",
      "params" => %{
        "name" => "slow_echo",
        "arguments" => %{"text" => "bench"},
        "_meta" => %{"progressToken" => i}
      }
    })
  end

  defp plain_call(instance, session, i) do
    post(instance, session, %{
      "jsonrpc" => "2.0",
      "id" => i,
      "method" => "tools/call",
      "params" => %{
        "name" => instance.last_tool_name(),
        "arguments" => %{"text" => "bench"}
      }
    })
  end

  defp template_read(instance, session, i) do
    post(instance, session, %{
      "jsonrpc" => "2.0",
      "id" => i,
      "method" => "resources/read",
      "params" => %{"uri" => instance.last_template_uri()}
    })
  end

  defp tools_list(instance, session, i) do
    post(instance, session, %{"jsonrpc" => "2.0", "id" => i, "method" => "tools/list"})
  end

  defp blocks_call(instance, session, i) do
    post(instance, session, %{
      "jsonrpc" => "2.0",
      "id" => i,
      "method" => "tools/call",
      "params" => %{"name" => instance.many_blocks_tool(), "arguments" => %{}}
    })
  end

  defp many_items_read(instance, session, i) do
    post(instance, session, %{
      "jsonrpc" => "2.0",
      "id" => i,
      "method" => "resources/read",
      "params" => %{"uri" => instance.many_items_uri()}
    })
  end

  defp new_principal_session(instance, i) do
    {:ok, _session} = Sessions.start(instance, principal_key: {nil, "p-#{i}"})
  end

  # A start on the reclaim instance: the pool is full, so the start
  # reclaims one idle session, or gets the refusal when none is idle.
  #
  defp reclaim_start(instance, _i), do: Sessions.start(instance)

  # Fills the pool of the reclaim instance to its cap. A later run finds
  # the cap and starts no session, so the fixed size of the pool stays.
  #
  defp seed_reclaim(instance) do
    case @reclaim_sessions - session_count(instance) do
      missing when missing > 0 ->
        for _ <- 1..missing do
          {:ok, _session} = Sessions.start(instance)
        end

      _other ->
        :ok
    end

    :ok
  end

  # One request in flight on each session of the pool, owned by the
  # caller. The view keeps `streams: 0`, so the scan keeps every session,
  # but the session answers `:busy` to an evict. A second call adds one
  # more request, with a new id.
  #
  defp busy_reclaim(instance) do
    for id <- session_ids(instance) do
      _ = Session.open_request(instance, id, System.unique_integer([:positive]), self(), nil)
    end

    :ok
  end

  defp session_ids(instance) do
    Instance.select(instance, [{{{:session, :"$1"}, :_, :_}, [], [:"$1"]}])
  end

  # The sessions of other principals. A run leaves them open: a later
  # run seeds only the sessions that are missing, so the fixed size of
  # the set stays.
  #
  defp seed_background(instance) do
    case @background_sessions - session_count(instance) do
      missing when missing > 0 ->
        for j <- 1..missing do
          {:ok, _session} = Sessions.start(instance, principal_key: {nil, "bg-#{j}"})
        end

      _other ->
        :ok
    end

    :ok
  end

  defp session_count(instance) do
    instance
    |> Instance.select([{{{:session, :_}, :_, :_}, [], [true]}])
    |> length()
  end
end
