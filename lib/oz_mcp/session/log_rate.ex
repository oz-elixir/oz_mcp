#
# The rate of the log notifications of a session. Owns the fields
# `log_bucket` and `log_dropped` of the core. At the first drop of a
# window it arms the report timer; when it fires, one telemetry event
# and one warning line cover all the drops, with the count only.
#
defmodule OzMcp.Session.LogRate do
  @moduledoc false

  alias OzMcp.Session.{Core, Effect}
  alias OzMcp.Utils.TokenBucket

  @report_ms 1_000

  # Checks the bucket for one log message that the level filter accepted.
  #
  @spec admit(Core.t()) :: {:ok | :drop, Core.t(), [Effect.t()]}
  def admit(%Core{opts: %{max_log_rate: nil}} = core), do: {:ok, core, []}

  def admit(%Core{opts: %{max_log_rate: rate}} = core) do
    now = core.clock.monotonic_time(:millisecond)
    bucket = core.log_bucket || TokenBucket.new(rate, now)

    case TokenBucket.take(bucket, rate, now) do
      {:ok, bucket} ->
        {:ok, %{core | log_bucket: bucket}, []}

      {:drop, bucket} ->
        effects =
          if core.log_dropped == 0,
            do: [{:timeout, {:timeout, :log_drops}, @report_ms, :report}],
            else: []

        {:drop, %{core | log_bucket: bucket, log_dropped: core.log_dropped + 1}, effects}
    end
  end

  # A count of 0 (a report that a second drop armed after the first
  # report of the same window) gives no effect.
  #
  @spec report(Core.t()) :: {Core.t(), [Effect.t()]}
  def report(%Core{log_dropped: 0} = core), do: {core, []}

  def report(%Core{log_dropped: count} = core) do
    {%{core | log_dropped: 0},
     [
       {:telemetry, :log_dropped, %{count: count}, %{}},
       {:log, :warning, "#{count} log notifications were dropped by max_log_rate"}
     ]}
  end
end
