#
# A small module for the tests of the spec gap helper. It holds one
# function for each case: no spec, a spec, `@doc false`, `@impl` and a
# macro with no spec. It keeps the `@doc` of its functions, because the
# test of `SpecGaps` reads them.
#
defmodule Support.Helpers.SpecGaps.Fixture do
  @behaviour Support.Helpers.SpecGaps.Behaviour

  @doc "A public function with no spec."
  def no_spec(arg), do: arg

  @doc "A public function with a spec."
  @spec with_spec(integer()) :: integer()
  def with_spec(n), do: n

  @doc false
  def hidden(arg), do: arg

  @impl true
  def work(arg), do: arg

  @doc "A macro with no spec."
  defmacro twice(arg), do: quote(do: unquote(arg) * 2)
end
