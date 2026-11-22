defmodule OzMcp.SpecCoverageTest do
  use ExUnit.Case, async: true

  test "the helper finds only the public functions with no spec" do
    assert Support.Helpers.SpecGaps.gaps_of(Support.Helpers.SpecGaps.Fixture) == [
             "Support.Helpers.SpecGaps.Fixture.no_spec/1"
           ]
  end

  test "the helper finds nothing in a module with a hidden moduledoc" do
    assert Support.Helpers.SpecGaps.gaps_of(Support.Helpers.SpecGaps.HiddenModule) == []
  end

  test "every public function of a public module has a @spec" do
    gaps = Support.Helpers.SpecGaps.find(:oz_mcp)
    assert gaps == [], "Functions with no @spec:\n" <> Enum.join(gaps, "\n")
  end
end
