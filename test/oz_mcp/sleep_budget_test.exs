defmodule OzMcp.SleepBudgetTest do
  use ExUnit.Case, async: true

  @budget 30

  # `Process.sleep(:infinity)` keeps a process alive. It is not a wait for
  # an event, so it does not count.
  #
  test "the tests keep the number of timed Process.sleep calls under the budget" do
    count =
      "test/**/*.{ex,exs}"
      |> Path.wildcard()
      |> Enum.reject(&String.ends_with?(&1, "sleep_budget_test.exs"))
      |> Enum.map(fn path ->
        source = File.read!(path)
        all = length(String.split(source, "Process.sleep(")) - 1
        all - (length(String.split(source, "Process.sleep(:infinity)")) - 1)
      end)
      |> Enum.sum()

    assert count < @budget,
           "#{count} timed Process.sleep calls in test/ (budget: #{@budget})"
  end
end
