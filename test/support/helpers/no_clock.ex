#
# A clock for the tests of a pure module that must not read the time:
# each read is a failure.
#
defmodule Support.Helpers.NoClock do
  def monotonic_time(_unit), do: raise("the clock of the test was read")
end
