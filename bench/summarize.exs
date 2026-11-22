# The summary of the result files of `bench/compare.sh`:
#
#   elixir bench/summarize.exs tmp/compare/results/*.json
#
# The script groups the files by their git sha and prints the median p50
# and p95 of each scenario and the median of each static measure, one
# block per revision. A measure that a revision cannot give (an old tree
# without the check modules) stays out of its block. The script runs with
# `elixir` alone, with no mix and no compiled project.
#

#
# Groups the result files by revision and prints the medians of each
# revision.
#
defmodule Bench.Summarize do
  #
  # One block per revision, in the order of the first file that carries
  # the revision.
  #
  def run(files) do
    docs = Enum.map(files, fn path -> {path, path |> File.read!() |> JSON.decode!()} end)
    shas = docs |> Enum.map(fn {_path, doc} -> doc["git_sha"] end) |> Enum.uniq()

    Enum.each(shas, fn sha ->
      runs = Enum.filter(docs, fn {_path, doc} -> doc["git_sha"] == sha end)
      revision(sha, runs)
    end)
  end

  defp revision(sha, runs) do
    first = elem(hd(runs), 1)

    IO.puts("")
    IO.puts("#{sha}  #{length(runs)} runs  machine #{first["machine"]}")

    print_scenarios(runs, first["results"])
    print_measures(runs)
  end

  defp print_scenarios(runs, results) do
    names = Enum.map(results, & &1["name"]) |> Enum.uniq()
    width = names |> Enum.map(&String.length/1) |> Enum.max()

    Enum.each(names, fn name ->
      entries =
        for {_path, doc} <- runs, entry <- doc["results"], entry["name"] == name, do: entry

      p50 = median(Enum.map(entries, & &1["p50"]))
      p95 = median(Enum.map(entries, & &1["p95"]))

      IO.puts(
        "  #{String.pad_trailing(name, width)}  " <>
          "p50 #{String.pad_leading(to_string(p50), 8)}  p95 #{String.pad_leading(to_string(p95), 8)}"
      )
    end)
  end

  defp print_measures(runs) do
    keys =
      runs
      |> Enum.flat_map(fn {_path, doc} -> Map.keys(doc["measures"]) end)
      |> Enum.uniq()
      |> Enum.sort()

    cells =
      for key <- keys do
        values =
          for {_path, doc} <- runs, value = doc["measures"][key], is_number(value), do: value

        "#{key} #{median(values)}"
      end

    IO.puts("  measures: " <> Enum.join(cells, "  "))
  end

  defp median([]), do: "n/a"

  defp median(values) do
    sorted = Enum.sort(values)
    count = length(sorted)
    middle = div(count, 2)

    value =
      if rem(count, 2) == 0 do
        (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2
      else
        Enum.at(sorted, middle)
      end

    if is_float(value), do: Float.round(value, 1), else: value
  end
end

case System.argv() do
  [] ->
    IO.puts(:stderr, "usage: elixir bench/summarize.exs <result.json> [<result.json> ...]")
    System.halt(1)

  files ->
    Bench.Summarize.run(files)
end
