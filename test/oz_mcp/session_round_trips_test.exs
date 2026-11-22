#
# Counts the calls to the session process for one request of a scenario.
#
# `Bench.Runner.counts/3` arms a call-count trace on the private
# `OzMcp.Session.call/3`, so the counter sees the calls of the request
# process and of the callback process. The trace is global: the tests of
# this file do not run at the same time as each other or as another test.
#
defmodule OzMcp.SessionRoundTripsTest do
  use ExUnit.Case, async: false

  alias Bench.Runner

  @instance Bench.Server
  @count 10

  setup do
    start_supervised!({OzMcp, [server: @instance] ++ Runner.instance_opts()})
    :ok
  end

  test "a streamed tools/call makes 3 calls" do
    assert calls_per_request(:stream_1k) == 3.0
  end

  test "a ping makes 1 call" do
    assert calls_per_request(:ping_10k) == 1.0
  end

  defp calls_per_request(scenario) do
    [%{counts: counts}] = Runner.counts(@instance, scenario, @count)
    counts.session_calls / counts.ops
  end
end
