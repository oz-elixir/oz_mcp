#!/bin/sh
#
# Compares revisions of the benchmark in interleaved rounds.
#
#   bench/compare.sh [--rounds N] <revision> [<revision> ...]
#
# The script makes one worktree per revision under ./tmp/compare/, copies
# the bench files of the current tree over it, so every revision runs the
# bench code of today (the baseline of a gate can be an old revision),
# links the deps directory of the current tree into the worktree (the
# revisions must share the dep versions) and runs `mix bench` once per
# round. The rounds interleave the revisions, so the drift of the machine
# hits each revision the same way. At the end the script prints the
# median p50 and p95 of each scenario and the median of each static
# measure for each revision and removes the worktrees. The result files
# of the rounds stay in ./tmp/compare/results/ until the next run of the
# script.
#
# The script is not part of `mix bench` and not part of CI. Run it on a
# quiet machine. The first round pays the compile of each worktree; a run
# of two revisions with five rounds takes about fifteen minutes plus the
# compiles.
#
# A revision before `OzMcp.Handler.Result` existed times
# `OzMcp.Handler.Shape.check/2` for the check measures, so it gives a
# number too. A revision with neither module gives no value for the five
# check measures (the line prints n/a for them); the request scenarios
# and the other static measures stay comparable.

set -eu

if [ "${1-}" = "--rounds" ]; then
  rounds="$2"
  shift 2
else
  rounds=5
fi

if [ "$#" -lt 1 ]; then
  echo "usage: bench/compare.sh [--rounds N] <revision> [<revision> ...]" >&2
  exit 1
fi

root=$(git rev-parse --show-toplevel)
cd "$root"

if [ ! -d deps ]; then
  echo "no deps directory: run mix deps.get before the compare" >&2
  exit 1
fi

compare_dir=tmp/compare
results_dir=$compare_dir/results
rm -rf "$compare_dir"
mkdir -p "$results_dir"

labels=""

for revision in "$@"; do
  label=$(printf '%s' "$revision" | tr -c 'A-Za-z0-9._-' '_')
  worktree=$compare_dir/$label

  git worktree add --detach "$worktree" "$revision"

  rm -rf "$worktree/bench"
  mkdir "$worktree/bench"
  cp bench/run.exs bench/summarize.exs bench/README.md "$worktree/bench/"
  cp -R bench/support "$worktree/bench/support"

  rm -f "$worktree/deps"
  ln -s "$root/deps" "$worktree/deps"

  labels="$labels $label"
done

cleanup() {
  for label in $labels; do
    git worktree remove --force "$compare_dir/$label" >/dev/null 2>&1 || true
  done
}

trap cleanup EXIT

round=1
while [ "$round" -le "$rounds" ]; do
  for label in $labels; do
    worktree=$compare_dir/$label
    echo ""
    echo "=== round $round of $rounds: $label ==="
    (cd "$worktree" && mix bench)
    sha=$(git -C "$worktree" rev-parse HEAD)
    cp "$worktree/bench/results/$sha.json" "$results_dir/${label}_round${round}.json"
  done
  round=$((round + 1))
done

echo ""
echo "the median p50 and p95 of each scenario, the median of each static measure:"
elixir bench/summarize.exs "$results_dir"/*.json
