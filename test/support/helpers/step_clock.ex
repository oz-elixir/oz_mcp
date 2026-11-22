#
# A clock for the tests of a pure module: the time is the value of the
# process dictionary under the key `:step_clock_now` and the test moves
# it forward with `Process.put/2`. The default is 0.
#
defmodule Support.Helpers.StepClock do
  def monotonic_time(:millisecond), do: Process.get(:step_clock_now) || 0
end
