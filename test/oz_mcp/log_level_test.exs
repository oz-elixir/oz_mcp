defmodule OzMcp.LogLevelTest do
  use ExUnit.Case, async: true

  alias OzMcp.LogLevel

  require LogLevel

  # A defguard runs at compile time: exercise it through a guard.
  #
  defp level?(level) when LogLevel.is_level(level), do: true
  defp level?(_level), do: false

  test "levels/0 lists the RFC 5424 severities, lowest first" do
    assert LogLevel.levels() == [
             :debug,
             :info,
             :notice,
             :warning,
             :error,
             :critical,
             :alert,
             :emergency
           ]
  end

  test "is_level/1 accepts only the known levels" do
    for level <- LogLevel.levels() do
      assert level?(level)
    end

    refute level?(:verbose)
    refute level?("info")
    refute level?(nil)
  end

  test "a session gets the messages at its level and above" do
    assert LogLevel.wanted?(:info, :info)
    assert LogLevel.wanted?(:info, :emergency)
    refute LogLevel.wanted?(:info, :debug)
  end

  test "a session with no level gets nothing" do
    refute LogLevel.wanted?(nil, :emergency)
  end

  test "an unknown value gives false, not a raise" do
    refute LogLevel.wanted?(:verbose, :info)
    refute LogLevel.wanted?("info", :info)
    refute LogLevel.wanted?(:info, :verbose)
    refute LogLevel.wanted?(:verbose, :verbose)
  end
end
