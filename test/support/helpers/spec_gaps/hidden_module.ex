#
# The fixture of a hidden module: it keeps its `@moduledoc false` and
# the `@doc` of its function, because the test of `SpecGaps` reads them.
#
defmodule Support.Helpers.SpecGaps.HiddenModule do
  @moduledoc false

  @doc "A public function of an internal module."
  def no_spec(arg), do: arg
end
