defmodule OzMcp.Session.LogRateTest do
  use ExUnit.Case, async: true

  alias OzMcp.Session.Core
  alias OzMcp.Session.LogRate
  alias Support.Helpers.{NoClock, StepClock}

  defp core(overrides) do
    opts = Keyword.merge([session_timeout_ms: 30_000, max_log_rate: 2], overrides)

    struct!(
      %Core{instance: __MODULE__, id: "session", opts: Map.new(opts)},
      clock: StepClock
    )
  end

  defp set_now(now), do: Process.put(:step_clock_now, now)

  test "a rate of nil passes, gives no effect and reads no clock" do
    core = %{core(max_log_rate: nil) | clock: NoClock}

    assert {:ok, ^core, []} = LogRate.admit(core)
  end

  test "the first message makes a full bucket, takes one token and gives no effect" do
    set_now(0)
    core = core(max_log_rate: 2)

    assert {:ok, %Core{log_bucket: bucket, log_dropped: 0}, []} = LogRate.admit(core)
    assert bucket == %OzMcp.Utils.TokenBucket{level: 1_000, at: 0}
  end

  test "the first drop starts the report timer, the next drop gives no effect" do
    set_now(0)
    core = core(max_log_rate: 1)

    assert {:ok, core, []} = LogRate.admit(core)

    assert {:drop, %Core{log_bucket: bucket, log_dropped: 1} = core,
            [{:timeout, {:timeout, :log_drops}, 1_000, :report}]} = LogRate.admit(core)

    assert bucket == %OzMcp.Utils.TokenBucket{level: 0, at: 0}

    assert {:drop, %Core{log_dropped: 2}, []} = LogRate.admit(core)
  end

  test "a pause between two messages refills the bucket" do
    set_now(0)
    core = core(max_log_rate: 1)

    assert {:ok, core, []} = LogRate.admit(core)
    assert {:drop, core, _timer} = LogRate.admit(core)

    set_now(1_000)

    assert {:ok, %Core{log_dropped: 1}, []} = LogRate.admit(core)
  end

  test "a report with no drop gives no effect" do
    assert {core, []} = LogRate.report(core(max_log_rate: 2))
    assert core.log_dropped == 0
  end

  test "a report gives one event and one line with the count and resets the count" do
    core = %{core(max_log_rate: 2) | log_dropped: 3}

    assert {%Core{log_dropped: 0}, effects} = LogRate.report(core)

    assert effects == [
             {:telemetry, :log_dropped, %{count: 3}, %{}},
             {:log, :warning, "3 log notifications were dropped by max_log_rate"}
           ]
  end
end
