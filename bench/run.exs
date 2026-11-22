# The entry point of the benchmark: `mix bench`.
#
#   mix bench
#   mix bench --compare bench/results/<sha>.json
#
# The script starts one instance of `Bench.Server` and one instance of
# `Bench.BigServer`, runs the scenarios one after the other (the times,
# then the counters of a second short run), prints the table and writes
# the result as JSON to `bench/results/<git sha>.json`. With `--compare`,
# it also prints the change in percent for each number of the table
# against the result file.
#

#
# The output of the benchmark: the table, the static measures, the text
# share of `lib/`, the result file and the comparison with an older
# result file.
#
defmodule Bench.Report do
  #
  # The columns of the times and the counters printed per request of
  # the short counted run.
  #
  @time_keys [:total_ms, :per_second, :p50, :p95, :p99]
  @count_keys [:config_reads, :session_calls, :count_select, :compiles]

  # The versions, the schedulers and the warning of the machine.
  #
  def header do
    IO.puts(
      "Elixir #{System.version()} / OTP #{System.otp_release()} / " <>
        "#{System.schedulers_online()} schedulers / #{machine()}"
    )

    IO.puts("A result from another machine is not comparable.")
  end

  # One row of the table for each entry.
  #
  def table(entries) do
    header =
      [
        "scenario",
        "count",
        "total ms",
        "req/s",
        "p50",
        "p95",
        "p99",
        "cfg/req",
        "calls/req",
        "scans/req",
        "compiles/req"
      ]

    rows = [header | Enum.map(entries, &cells/1)]

    widths =
      for index <- 0..(length(header) - 1) do
        rows |> Enum.map(&Enum.at(&1, index)) |> Enum.map(&String.length/1) |> Enum.max()
      end

    IO.puts("")

    Enum.each(rows, fn cells ->
      [name | numbers] = cells
      [name_width | number_widths] = widths

      line =
        String.pad_trailing(name, name_width) <>
          (numbers
           |> Enum.zip(number_widths)
           |> Enum.map_join("  ", fn {cell, width} -> String.pad_leading(cell, width) end))

      IO.puts(String.trim_trailing(line))
    end)

    :ok
  end

  defp cells(entry) do
    [
      entry.name
      | Enum.map([entry.count | Enum.map(@time_keys, &Map.fetch!(entry, &1))], &to_string/1) ++
          Enum.map(@count_keys, &number_cell(entry.counts, &1))
    ]
  end

  defp number_cell(counts, key), do: to_string(per_op(counts, key))

  # Prints the sessions, the utilization and the memory of the `load_1k` entry.
  #
  def print_load(entries) do
    case Enum.find(entries, &(&1.name == "load_1k")) do
      nil ->
        :ok

      row ->
        IO.puts("")

        IO.puts(
          "load_1k: #{row.sessions} sessions, scheduler utilization " <>
            "#{Float.round(row.utilization, 1)}%, memory per session " <>
            "#{div(row.memory_per_session_bytes, 1024)} KiB"
        )
    end
  end

  # Prints the measures that run with no request.
  #
  def print_measures(measures) do
    IO.puts("")

    IO.puts(
      "static measures (no request): template_walk_us #{measures.template_walk_us}  " <>
        "list_build_us #{measures.list_build_us}  list_page_us #{measures.list_page_us}"
    )

    IO.puts("static measures of the check: " <> check_cells(measures))

    :ok
  end

  defp check_cells(measures) do
    [
      {:call_check_1_us, "call_check_1_us"},
      {:call_check_50_us, "call_check_50_us"},
      {:read_check_1_us, "read_check_1_us"},
      {:read_check_50_us, "read_check_50_us"},
      {:call_check_50_off_us, "call_check_50_off_us"},
      {:read_check_50_off_us, "read_check_50_off_us"}
    ]
    |> Enum.map_join("  ", fn {key, label} -> "#{label} #{cell(measures[key])}" end)
  end

  defp cell(nil), do: "n/a"
  defp cell(value), do: to_string(value)

  # Prints the code, docs and comments of `lib/` and the share of text.
  #
  def print_text_size(counts) do
    IO.puts("")

    IO.puts(
      "text of lib/ (rule of bench/README.md): code #{counts.code}  docs #{counts.docs}  " <>
        "comments #{counts.comments}  share #{share(counts)}"
    )

    :ok
  end

  defp share(counts), do: "#{Float.round(Bench.TextSize.text_share(counts) * 100, 1)}%"

  # Writes the result as JSON and returns the path.
  #
  def write(entries, measures) do
    File.mkdir_p!("bench/results")
    sha = git_sha()
    path = Path.join("bench/results", "#{sha}.json")

    doc = %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      machine: machine(),
      elixir: System.version(),
      otp: System.otp_release(),
      schedulers: System.schedulers_online(),
      git_sha: sha,
      results: entries,
      measures: measures
    }

    File.write!(path, JSON.encode!(doc))
    path
  end

  # The change in percent of each number, against the result file.
  #
  def compare(path, entries) do
    {:ok, doc} = path |> File.read!() |> JSON.decode()
    by_name = Map.new(doc["results"], &{&1["name"], &1})

    IO.puts("\nchange against #{path}:")

    for entry <- entries, old = Map.get(by_name, entry.name) do
      old_counts = old["counts"] || %{}

      changes =
        Enum.concat(
          for key <- @time_keys,
              old_value = old[Atom.to_string(key)],
              is_number(old_value),
              old_value != 0 do
            {key, change(Map.fetch!(entry, key) * 1.0, old_value * 1.0)}
          end,
          for key <- @count_keys,
              old_value = per_op(old_counts, key),
              old_value != 0 do
            {key, change(per_op(entry.counts, key), old_value)}
          end
        )

      IO.puts(
        "  #{entry.name}:  " <>
          Enum.map_join(changes, "  ", fn {key, value} -> "#{key} #{signed(value)}%" end)
      )
    end

    :ok
  end

  # The counters of a result file travel as a map with string keys, the
  # counters of a run as a map with atom keys: `per_op/2` reads both.
  #
  defp per_op(counts, key), do: fetch_number(counts, key) / fetch_number(counts, :ops)

  defp fetch_number(map, key) when is_map_key(map, key), do: to_number(Map.fetch!(map, key))

  defp fetch_number(map, key) when is_atom(key), do: fetch_number(map, Atom.to_string(key))
  defp fetch_number(_map, _key), do: 0

  defp to_number(value) when is_number(value), do: value
  defp to_number(_other), do: 0

  defp change(new, old), do: Float.round((new - old) / old * 100, 1)

  defp signed(value) when value >= 0, do: "+#{value}"
  defp signed(value), do: "#{value}"

  defp machine do
    {name, 0} = System.cmd("hostname", [])
    String.trim(name)
  rescue
    _error -> "unknown host"
  end

  defp git_sha do
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true)
    String.trim(sha)
  rescue
    _error -> "unknown"
  end
end

alias Bench.Runner

counts_of = %{
  ping_10k: 10_000,
  stream_1k: 1_000,
  sessions_1k: 1_000,
  principal_1k: 1_000,
  reclaim_10k: 1_000,
  reclaim_10k_busy: 1_000,
  tools_call_200: 1_000,
  resources_read_tpl: 1_000,
  tools_list_200: 1_000,
  tools_call_50_blocks: 1_000,
  resources_read_50_items: 1_000,
  load_1k: 1_000
}

short_counts = 100

{opts, _argv} = OptionParser.parse!(System.argv(), strict: [compare: :string])

children = [
  {OzMcp, [server: Bench.Server] ++ Runner.instance_opts()},
  {OzMcp, [server: Bench.BigServer] ++ Runner.instance_opts()},
  {OzMcp, [server: Bench.Server, name: Bench.Reclaim] ++ Runner.reclaim_instance_opts()},
  {OzMcp, [server: Bench.Server, name: Bench.Load] ++ Runner.load_instance_opts()}
]

{:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)

big_server_scenarios = [
  :tools_call_200,
  :resources_read_tpl,
  :tools_list_200,
  :tools_call_50_blocks,
  :resources_read_50_items
]

reclaim_scenarios = [:reclaim_10k, :reclaim_10k_busy]

Bench.Report.header()

entries =
  for scenario <- Runner.scenarios() do
    IO.puts("running #{scenario} ...")

    instance =
      cond do
        scenario in big_server_scenarios -> Bench.BigServer
        scenario in reclaim_scenarios -> Bench.Reclaim
        scenario == :load_1k -> Bench.Load
        true -> Bench.Server
      end

    rows = Runner.measure(instance, scenario, Map.fetch!(counts_of, scenario))

    counted = Runner.counts(instance, scenario, short_counts) |> Map.new(&{&1.name, &1.counts})

    Enum.map(rows, fn row -> Map.put(row, :counts, Map.fetch!(counted, row.name)) end)
  end
  |> List.flatten()

Supervisor.stop(supervisor)

measures = Runner.static_measures(Bench.BigServer)

Bench.Report.table(entries)
Bench.Report.print_load(entries)
Bench.Report.print_measures(measures)
Bench.Report.print_text_size(Bench.TextSize.count(Bench.TextSize.files()))

# The comparison runs before the write: the file of this git revision
# holds the result of the run before this one and the change against it
# is the change of this run.
#
if compare = opts[:compare], do: Bench.Report.compare(compare, entries)

path = Bench.Report.write(entries, measures)
IO.puts("\nresult written to #{path}")
