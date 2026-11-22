# Benchmark

Fixed scenarios for the request path of one node. A change of the hot
path of the framework is compared with the numbers of a run before the
change: the table of a run and the table of the run before it tell
whether the change was a gain.

## Run

    mix bench

The script starts one instance of `Bench.Server`, one instance of
`Bench.BigServer`, one instance of `Bench.Server` named `Bench.Reclaim`
for the reclaim scenarios and one named `Bench.Load` for the concurrent
load, runs the twelve scenarios one after the other,
prints the table and the static measures and writes the result as JSON to
`bench/results/<git sha>.json`. The directory of the results is local
(see `bench/results/.gitignore`): the JSON files stay out of the
repository.

With the option `--compare`, the script prints the change in percent
for each number of the table, against a result file:

    mix bench --compare bench/results/<sha>.json

The comparison runs before the write, so a run on the same revision
compares against the run before it. A run on a new revision compares
against the file of the old revision.

## Compare revisions

    bench/compare.sh [--rounds N] <revision> [<revision> ...]

The script makes one worktree per revision under `./tmp/compare/`, copies
the bench files of the current tree over it, so every revision runs the
bench code of today, links the deps directory of the current tree into
the worktree (the revisions must share the dep versions) and runs
`mix bench` once per round (the default is 5). The rounds interleave the
revisions, so the drift of the machine hits each revision the same way.

At the end the script prints the median p50 and p95 of each scenario and
the median of each static measure for each revision (the summary comes
from `bench/summarize.exs`, which reads the result files of the rounds)
and removes the worktrees. The result files of the rounds stay in
`./tmp/compare/results/` until the next run of the script. A revision
before `OzMcp.Handler.Result` existed times `OzMcp.Handler.Shape.check/2`
for the check measures, so it gives a number too; a revision with neither
module gives `n/a` for the five check measures and its request scenarios
stay comparable. The first round pays the compile of each worktree; two
revisions with five rounds take about fifteen minutes plus the compiles.

## Scenarios

| Scenario | Work |
|---|---|
| `ping_10k` | One session. 10,000 `ping` requests, one after the other. |
| `stream_1k` | One session. 1,000 `tools/call` requests to `slow_echo`, each with a `progressToken` in `_meta`. The tool reports progress three times, so each answer is an event stream. Without the token, the tool sends nothing and the answer is not a stream. |
| `sessions_1k` | 1,000 `initialize` requests (1,000 sessions), then 1,000 `DELETE` requests. Two rows: the initializes (`sessions_1k`) and the deletes (`sessions_1k_delete`). |
| `principal_1k` | 10,000 sessions of other principals stay open. Then 1,000 `OzMcp.Sessions.start/2` calls, each for a new principal. The check of `max_sessions_per_principal` runs on each call, with 10,000 sessions in the `Names` Registry. |
| `reclaim_10k` | A full pool of 10,000 idle sessions. Then 1,000 `OzMcp.Sessions.start/2` calls: each call meets the full pool and ends one idle session. |
| `reclaim_10k_busy` | A full pool of 10,000 sessions, each with a request in flight. Then 1,000 `OzMcp.Sessions.start/2` calls: each call tries five `evict` calls that answer `:busy` and then refuses the new session. |
| `tools_call_200` | One session. 1,000 `tools/call` requests with no stream to the last tool of the last module of `Bench.BigServer`: the worst case of the module scan. |
| `resources_read_tpl` | One session. 1,000 `resources/read` requests that match the last template of the last module of `Bench.BigServer`. |
| `tools_list_200` | One session. 1,000 `tools/list` requests of `Bench.BigServer`. The name keeps its history: the server lists 202 tools today. |
| `tools_call_50_blocks` | One session. 1,000 `tools/call` requests to the tool whose callback returns a map with 50 text blocks with annotations: the cost of the check of a big result. |
| `resources_read_50_items` | One session. 1,000 `resources/read` requests to the resource whose callback returns a map with 50 items. |
| `load_1k` | 1,000 sessions in parallel, each with one `GET` stream and a loop of `tools/call` requests to `slow_echo` with a `progressToken`, for a fixed 10 s. See "Concurrent load". |

`Bench.BigServer` has 10 tool modules of 20 tools, one tool module whose
callback returns a map with 50 blocks, 5 prompt modules of 10 prompts,
5 resource modules of 10 resources, one resource module whose callback
returns a map with 50 items and 5 template modules of 10 templates. The
DSL modules give 200 tools and 50 resources; every template module uses
its own URI scheme.

The instances run with fixed options (`max_sessions: 20_000`,
`session_init_timeout_ms: 600_000`, the default
`max_sessions_per_principal`, no authorization) and stops at the end.
The instance `Bench.Reclaim` of the reclaim scenarios runs with
`max_sessions: 10_000` and the same long init timeout. The instance
`Bench.Load` runs with `max_sessions: 2_000`, the same long init timeout
and `max_sessions_per_principal: nil`: it is the one instance with no
limit per principal.
The long init timeout keeps the sessions of `principal_1k` and of the
reclaim scenarios open, because they are never initialized.

## How to read the table

| Column | Meaning |
|---|---|
| `count` | the requests of the row |
| `total ms` | the sum of the request times |
| `req/s` | requests per second (`count / total`) |
| `p50`, `p95`, `p99` | the percentiles of one request, in microseconds |
| `cfg/req` | reads of `OzMcp.Instance.config/1` per request |
| `calls/req` | calls to the session process per request |
| `scans/req` | calls of `Registry.count_select/2` per request |
| `compiles/req` | calls of `JSV.build/2` per request |

The counts come from a second, short run (100 requests) with the
call-count traces of the VM armed. The traces change the times, so the
counted run reports no time: `Bench.Runner.measure/3` reports the
times, `Bench.Runner.counts/3` the counters.

The static measures run with no request, after the instances stop:
`template_walk_us` is the mean time of `Catalog.find_template/2` for the
last template of `Bench.BigServer`, `list_build_us` is the mean time of
`Tool.build/1` on all its tools and `list_page_us` is the mean time of
one `OzMcp.Handler.Page.list/3` call of those tools with no page size.
The five measures of the check are the
median of the per-call means of five runs of 10,000 calls, after a warm-up;
the two cases with one block or one item run 100,000 calls per run.
`call_check_1_us` and `call_check_50_us` time the check of a `tools/call`
result map with one and with 50 text blocks with annotations,
`read_check_1_us` and `read_check_50_us` time the same for a
`resources/read` map with one and with 50 items. Each
measure runs its work one time first and stops the bench when the work
fails: a request that answers an `error` member or `isError: true`, or a
payload that does not pass its check. A revision
without `OzMcp.Handler.Result` times `OzMcp.Handler.Shape.check/2` of the
same payloads; a revision with neither module prints `n/a` for the five.
The two `off` measures, `call_check_50_off_us` and `read_check_50_off_us`,
time the same 50-block and 50-item payloads through the normalize step
with the runtime option `check_results: false`: the cost of the same
result with the check off. They print `n/a` on a revision without the
option.

For `load_1k`, `total ms` is the wall time of the window, not the sum of
the request times and `count` is the number of requests done. Its entry
has three more keys in the result file: `sessions`, `utilization` (the
scheduler utilization in percent) and `memory_per_session_bytes`; the
run prints them on a line after the table. Its counted run is 100
sessions for 1 s and its counters include the open and the delete of
those sessions.

A result from another machine is not comparable. The CPU, the count of
schedulers and the versions set the numbers: compare only two runs of
the same machine and prefer two runs with no other load on it. The
header of the table names the machine.

## Baseline

Machine: `cpm.local`, Intel Core i7-6700K @ 4.00 GHz, 8 schedulers.
Elixir 1.19.4, OTP 28. Git `d7f5beb`. Date 2026-10-31.

| Scenario | count | total ms | req/s | p50 | p95 | p99 | cfg/req | calls/req | scans/req |
|---|---|---|---|---|---|---|---|---|---|
| ping_10k | 10000 | 1733 | 5769 | 157 | 257 | 323 | 4.0 | 1.0 | 0.0 |
| stream_1k | 1000 | 483 | 2067 | 421 | 649 | 862 | 5.0 | 5.0 | 0.0 |
| sessions_1k | 1000 | 253 | 3945 | 237 | 356 | 432 | 5.0 | 0.0 | 0.0 |
| sessions_1k_delete | 1000 | 104 | 9581 | 95 | 155 | 196 | 6.0 | 1.0 | 0.0 |
| principal_1k | 1000 | 2049 | 488 | 1981 | 2854 | 3274 | 2.0 | 0.0 | 1.0 |

These numbers are a reference for this machine only. The start of a
session of a principal (`principal_1k`) costs about 2 ms at this
baseline: the check of the limit scans every entry of the `Names`
Registry on each start. A change that removes the scan is a gain only
when the table of a later run shows it.

## Reclaim of idle sessions

Machine: `cpm.local`, Intel Core i7-6700K @ 4.00 GHz, 8 schedulers.
Elixir 1.19.4, OTP 28. Git `a5cf7af`. Date 2026-11-09.

The instance of these two scenarios runs with `max_sessions: 10_000`.
`reclaim_10k` fills the pool with 10,000 idle sessions, then makes 1,000
`OzMcp.Sessions.start/2` calls: each call meets the full pool and ends
one idle session. `reclaim_10k_busy` gives each of the 10,000 sessions a
request in flight, so each start tries five `evict` calls that answer
`:busy` and then refuses the new session.

| Scenario | count | total ms | req/s | p50 | p95 | p99 | cfg/req | calls/req | scans/req |
|---|---|---|---|---|---|---|---|---|---|
| reclaim_10k | 1000 | 10530 | 95 | 10298 | 12721 | 16169 | 4.0 | 1.0 | 0.0 |
| reclaim_10k_busy | 1000 | 6549 | 153 | 6244 | 8422 | 11248 | 1.0 | 5.0 | 0.0 |

One start costs about 10.3 ms on the idle pool and about 6.2 ms on the
busy pool. Both are above the 5 ms target for one start. The idle cost
includes the end and the start of a session; the busy cost is the scan
of the 10,000 views and the five refused calls. The scan is not enough
at 10,000 sessions: a small batch per scan, or an ordered index, is the
next step. A second run gives `reclaim_10k` p50 10401 and
`reclaim_10k_busy` p50 5998.

## Concurrent load

Machine: `cpm.local`, Intel Core i7-6700K @ 4.00 GHz, 8 schedulers.
Elixir 1.19.4, OTP 28. Git `fb589a0` with the memory read of this change.
Date 2026-11-10.

`load_1k` opens 1,000 sessions, each with one `GET` stream, then runs one
loop of `tools/call` to `slow_echo` (with a `progressToken`, so each answer
is an event stream with three progress reports) in each session for 10 s,
with no think time. The latency is the time of one request, so it
includes the wait for a scheduler: 1,000 loops share 8 schedulers.

| Scenario | count | total ms | req/s | p50 | p95 | p99 | cfg/req | calls/req | scans/req |
|---|---|---|---|---|---|---|---|---|---|
| load_1k | 104041 | 10205 | 10194 | 46583 | 100829 | 2294900 | 1.1 | 3.0 | 0.0 |

The scheduler utilization over the window is 98.5 % (the normal
schedulers only) and the memory per session is 21 KiB. A second run
gives 101,805 requests, 9,988 req/s, p50 46784, p95 85108, p99 2118570, a
utilization of 98.4 % and 20 KiB per session. The p99 is about 2 s: a few requests wait much longer than the
median while the 1,000 loops compete.

The memory is the growth of `:erlang.memory(:total)` from before the
sessions open to after all the `GET` streams are attached, divided by
1,000. Each read follows a GC of all processes and repeats until two reads
are within 256 KiB. The growth includes the `GET` processes and the conns
of the bench.

The scenario runs in process through `Plug.Test`, like the others: it
measures no socket write and no HTTP server. The throughput and the
utilization include the client side, because the bench processes build and
send each request on the same node. For the socket cost of idle streams,
see "Heartbeat cost".

## Big server baseline

Machine: `cpm.local`, Intel Core i7-6700K @ 4.00 GHz, 8 schedulers.
Elixir 1.19.4, OTP 28. Git `04e069f`. Date 2026-11-01.

| Scenario | count | total ms | req/s | p50 | p95 | p99 | cfg/req | calls/req | scans/req | compiles/req |
|---|---|---|---|---|---|---|---|---|---|---|
| tools_call_200 | 1000 | 359 | 2785 | 331 | 507 | 672 | 1.0 | 3.0 | 0.0 | 0.0 |
| resources_read_tpl | 1000 | 304 | 3286 | 282 | 444 | 572 | 1.0 | 3.0 | 0.0 | 0.0 |
| tools_list_200 | 1000 | 3263 | 306 | 3112 | 4363 | 5917 | 1.0 | 1.0 | 0.0 | 0.0 |

The static measures are `template_walk_us` 8.4 and `list_build_us`
156.2. A second run gives `tools_call_200` p50 341, `resources_read_tpl`
p50 286, `tools_list_200` p50 3144, `template_walk_us` 18.0 and
`list_build_us` 161.6.

## Smoke test

The test suite does not run the benchmark. One test
(`test/bench_smoke_test.exs`, tag `:bench`, excluded by default) calls
`Bench.Runner` for each scenario with a count of 10, so the code of the
benchmark cannot rot. Run it with:

    mix test --only bench

## Heartbeat cost

The option `sse_heartbeat_ms` sets the idle interval of the keep-alive
comment of an open stream. Its default comes from this measure.

    MIX_ENV=test mix run bench/heartbeat.exs

The script is not part of `mix bench` and not part of CI: the scenarios
of `mix bench` run the plug through `Plug.Test`, with no HTTP server
and a heartbeat over `Plug.Test` measures no socket write. The script
starts one instance and one listener for each case, opens N sessions
with one idle `GET` stream each over raw `:gen_tcp` sockets and samples
the node for 60 s. It reports the scheduler utilization, the memory of
the node and the number of heartbeat writes that the sockets received
for each second.

One run holds the sockets of the client and of the server, about
`2 * N` handles. The script checks the limit of open files at the start
and stops with a message when it is lower than `2 * N + 1000`. The
option `--quick` runs a short window with 100 streams, to check the
script itself.

The Cowboy case sets `protocol_options: [idle_timeout: 300_000]` on the
listener: with the defaults, Cowboy closes a connection after 60 s with
no bytes from the client, which would cut the window short.

Machine: `cpm.local`, Intel Core i7-6700K @ 4.00 GHz, 8 schedulers.
Elixir 1.19.4, OTP 28. Git `e617d3a`. Date 2026-11-05.

| Server | heartbeat ms | streams | open s | writes/s mean | writes/s max | scheduler % | memory MiB |
|---|---|---|---|---|---|---|---|
| bandit | 30000 | 1000 | 2.0 | 25.3 | 520 | 0.01 | 138 |
| bandit | 30000 | 5000 | 9.0 | 158.5 | 609 | 0.09 | 397 |
| bandit | 15000 | 1000 | 2.0 | 59.3 | 508 | 0.03 | 139 |
| bandit | 15000 | 5000 | 9.7 | 327.5 | 581 | 0.19 | 398 |
| bandit | 5000 | 1000 | 2.0 | 192.5 | 514 | 0.11 | 139 |
| bandit | 5000 | 5000 | 8.1 | 999.7 | 1255 | 0.43 | 399 |
| cowboy | 15000 | 5000 | 10.3 | 331.3 | 528 | 0.22 | 576 |

The mean of the writes per second follows `N / interval` (5,000 streams
at 15 s is 333 writes per second). The max is higher: the sessions of a
run open one after the other in a few seconds, so the heartbeats of the
streams fall in the same instants and arrive in bursts.

The cost of the interval of 15 s is a scheduler utilization of 0.19 %
at 5,000 idle streams, 0.10 points above the value at 30 s. The default
is 15 s: it stays well under the 60 s idle timeout of many proxies and
of Cowboy and on Bandit a gone client is found within one to two
heartbeat intervals.

## Result of the changes

Machine as above. Git `5dd40df`, date 2026-10-31. The first row of each
scenario is the baseline (`d7f5beb`), the second row is the run after the
keyed principal count and the config pass.

| Scenario | Run | total ms | req/s | p50 | p95 | p99 | cfg/req | scans/req |
|---|---|---|---|---|---|---|---|---|
| ping_10k | baseline | 1733 | 5769 | 157 | 257 | 323 | 4.0 | 0.0 |
| ping_10k | after | 1738 | 5752 | 153 | 261 | 340 | 1.0 | 0.0 |
| stream_1k | baseline | 483 | 2067 | 421 | 649 | 862 | 5.0 | 0.0 |
| stream_1k | after | 491 | 2035 | 419 | 636 | 854 | 1.0 | 0.0 |
| sessions_1k | baseline | 253 | 3945 | 237 | 356 | 432 | 5.0 | 0.0 |
| sessions_1k | after | 243 | 4105 | 230 | 343 | 412 | 2.0 | 0.0 |
| sessions_1k_delete | baseline | 104 | 9581 | 95 | 155 | 196 | 6.0 | 0.0 |
| sessions_1k_delete | after | 96 | 10344 | 89 | 141 | 168 | 3.0 | 0.0 |
| principal_1k | baseline | 2049 | 488 | 1981 | 2854 | 3274 | 2.0 | 1.0 |
| principal_1k | after | 99 | 10033 | 88 | 157 | 193 | 2.0 | 0.0 |

The principal count removes the scan: `principal_1k` goes from about
2 ms to about 0.1 ms for each start. The config pass removes the reads
of the Registry from the request path. `ping_10k` is not slower: the
total moved from 1733 ms to 1738 ms, inside the run-to-run variance of
this machine.

## Entity model and result check

Machine: `cpm.local`, Intel Core i7-6700K @ 4.00 GHz, 8 schedulers.
Elixir 1.19.4, OTP 28. Date 2026-11-08.

The machine runs the BEAM with no JIT (the `emu_flavor` of the VM is
`emu`). A machine with the JIT gives other numbers.

The table comes from `bench/compare.sh --rounds 5 da6e659 4b00c41 c3ecf85
HEAD`: five interleaved rounds on one quiet machine. Each request number
is the median p50 or p95 of one request, in microseconds; each static
measure is the median of its per-run means, in microseconds. `da6e659`
is the start of the entity model and of the result check, `4b00c41` the
end of its second follow-up, `c3ecf85` the end of its fourth follow-up
and `HEAD` the current tree. A revision before the two runtime options
of the check existed prints `n/a` for the two `off` measures and a
revision before the result check existed times the former shape check
of the same payloads, so its check measures are numbers too.

| Metric | da6e659 | 4b00c41 | c3ecf85 | HEAD |
|---|---|---|---|---|
| `tools_call_200` p50 | 356 | 359 | 358 | 361 |
| `tools_call_200` p95 | 530 | 504 | 506 | 517 |
| `resources_read_tpl` p50 | 325 | 334 | 338 | 342 |
| `resources_read_tpl` p95 | 457 | 462 | 474 | 487 |
| `tools_list_200` p50 | 3308 | 3161 | 3184 | 3143 |
| `tools_list_200` p95 | 4094 | 3885 | 3990 | 3883 |
| `tools_call_50_blocks` p50 | 526 | 553 | 557 | 557 |
| `tools_call_50_blocks` p95 | 716 | 719 | 725 | 763 |
| `resources_read_50_items` p50 | 436 | 485 | 501 | 460 |
| `resources_read_50_items` p95 | 601 | 647 | 669 | 652 |
| `tools_call_dynamic` p50 | 330 | 344 | 349 | 351 |
| `tools_call_dynamic` p95 | 457 | 469 | 463 | 501 |
| `template_walk_us` | 10.2 | 12.3 | 10.4 | 10.3 |
| `list_build_us` | 136.6 | 125.0 | 134.4 | 128.6 |
| `list_page_us` | 2.4 | 22.6 | 10.5 | 3.1 |
| `call_check_1_us` | 1.0 | 2.1 | 2.1 | 2.1 |
| `call_check_50_us` | 10.5 | 30.9 | 27.7 | 27.6 |
| `read_check_1_us` | 0.8 | 2.3 | 2.3 | 1.7 |
| `read_check_50_us` | 10.2 | 42.5 | 47.3 | 13.2 |
| `call_check_50_off_us` | n/a | n/a | 0.1 | 0.1 |
| `read_check_50_off_us` | n/a | n/a | 0.1 | 0.1 |
| `dynamic_normalize_us` | n/a | 2.6 | 2.5 | 2.5 |

The gates, with the start value of each measure from the `da6e659`
column:

| Gate | Verdict |
|---|---|
| The check of a `tools/call` result with one block stays at most three times the start value | pass: `call_check_1_us` 2.1, gate 3.0 |
| The check of a `tools/call` result with 50 blocks stays at most three times the start value | pass: `call_check_50_us` 27.6, gate 31.5 |
| The check of a `resources/read` result with one item stays at most three times the start value | pass: `read_check_1_us` 1.7, gate 2.4 |
| The check of a `resources/read` result with 50 items stays at most four times the start value | pass: `read_check_50_us` 13.2, gate 40.8 |
| Each static check measure stays at most its value at `4b00c41` | pass: 2.1 against 2.1, 27.6 against 30.9, 1.7 against 2.3, 13.2 against 42.5 |
| The list of a static module is not slower than the start value | pass: `list_build_us` 128.6 against 136.6, `tools_list_200` p50 3143 against 3308 |
| The page of the static lists costs at most two times the start value and `tools_list_200` p50 stays at most the start value | pass: `list_page_us` 3.1, gate 4.8; `tools_list_200` p50 3143 against 3308 |
| Each request scenario stays within +5 % of the start value on the median p50 | fail: `tools_call_50_blocks` +5.9 % (526 to 557), `resources_read_50_items` +5.5 % (436 to 460), `tools_call_dynamic` +6.4 % (330 to 351), `resources_read_tpl` +5.2 % (325 to 342); `tools_call_200` +1.4 % and `tools_list_200` -5.0 % pass |

The four static gates of the check pass. The read with 50 items went
from 47.3 to 13.2 µs when the absolute URI rule left the check of a
callback result and the page of the static lists went from 10.5 to
3.1 µs when the static runs of a list moved to the catalog.

The request scenarios that pay the per-block and per-item cost of the
check and the cost of the normalizer of a dynamic module, stay above
+5 % of the start value. `resources_read_tpl` sits at +5.2 %, on the
edge of the gate: the run before this one gave +3.3 % for the same
scenario. The user decided to go on with the request gates as they are,
so these gates keep their verdict `fail`. With `check_results: false`,
the same payloads cost 0.1 µs (`call_check_50_off_us`,
`read_check_50_off_us`): an operator who turns the check off pays none
of it.

## Size of `lib/`

`Bench.TextSize` counts the lines of `lib/**/*.ex` with three rules. A
doc line is a non-blank line of a `@moduledoc`, `@doc` or `@typedoc`
heredoc, with its opening and closing line, or a one-line `@moduledoc`,
`@doc` or `@typedoc` string; a comment line starts with `#` and has
text; all other non-blank lines are code. A line that is only `#`, or
only `#` and dashes, is a frame and is not counted: a frame carries no
text and costs no maintenance, as a blank line.

The numbers under the old rule, which counted every line of a comment
as text:

| Measure | Start (`0be3e32`) | TASK 2 (`bebf47c`) | TASK 3 (`49b36a1`) |
|---|---|---|---|
| code | 18,041 | 18,041 | 18,041 |
| docs | 6,814 | 6,281 | 6,227 |
| comments | 4,406 | 4,971 | 4,812 |
| text (docs + comments) | 11,220 | 11,252 | 11,039 |
| share of the non-blank lines | 38.3% | 38.4% | 38.0% |
| share under the rule of the review | 40.1% | 39.9% | 39.5% |

Under the old rule, the text of TASK 2 went up, because the frame lines
that the cut added to the comments were counted as text; under the
current rule, the text went from 10,222 to 9,342 lines.

The numbers under the current rule, with the frame lines left out:

| Measure | Value |
|---|---|
| code | 18,856 |
| docs | 5,068 |
| comments | 1,868 |
| text (docs + comments) | 6,936 |
| share of the non-blank lines | 26.9% |
| share under the rule of the review | 32.7% |
| date | 2026-11-10 |
| git sha | `76099fc`, the state this change started from |

The fall of the text is not a cut: on the same code, the old rule counts
11,039 lines and the new rule leaves the 1,843 frame and dash lines of
the comments out of the count.

The numbers after the cut of the docs and comments:

| Measure | Value |
|---|---|
| code | 18,041 |
| docs | 5,537 |
| comments | 2,187 |
| text (docs + comments) | 7,724 |
| share of the non-blank lines | 29.98% |
| share under the rule of the review | 35.9% |
| date | 2026-11-06 |
| git sha | `fcc2da6`, the state this change started from |

The cut took the text from 9,196 to 7,724 lines and the share from 33.8%
to 29.98%: the moduledoc of an internal module gives its role, its
callers and at most one hazard, a comment gives a reason, a protocol
rule or a race and a rule that a guide also gives lives in the guide
once.

The numbers after the "Internal module" warning, which each internal
module now starts with (the 17 modules that did not have it got it and
the 17 that had it now share one text):

| Measure | Value |
|---|---|
| code | 18,041 |
| docs | 5,590 |
| comments | 2,187 |
| text (docs + comments) | 7,777 |
| share of the non-blank lines | 30.12% |
| share under the rule of the review | 36.1% |
| date | 2026-11-07 |
| git sha | `301bdca`, the state this change started from |

The numbers after the text cut of the catalog, the bind stage and the
result path:

| Measure | Value |
|---|---|
| code | 18,325 |
| docs | 5,567 |
| comments | 2,185 |
| text (docs + comments) | 7,752 |
| share of the non-blank lines | 29.73% |
| share under the rule of the review | 35.7% |
| date | 2026-11-07 |
| git sha | `a3f7ed9`, the state this change started from |

The test `test/oz_mcp/text_size_test.exs` fails when the text grows.
Comments say why, not what. The guard holds the line count (`7_749`)
and the share rounded up to the third decimal (`0.293`).

