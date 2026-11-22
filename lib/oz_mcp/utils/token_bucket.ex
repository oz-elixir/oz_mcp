#
# A token bucket in thousandths of a token. `rate` is the number of
# tokens for each second. The bucket holds one second of tokens (the
# burst). One take costs one token. `OzMcp.Session.LogRate` uses it for
# the log notifications of a session.
#
# `now` is a monotonic time in milliseconds. The caller gives it: this
# module reads no clock.
#
defmodule OzMcp.Utils.TokenBucket do
  @moduledoc false

  @cost 1000

  @enforce_keys [:level, :at]
  defstruct [:level, :at]

  @type t :: %__MODULE__{level: non_neg_integer(), at: integer()}

  # A new bucket is full.
  #
  @spec new(pos_integer(), integer()) :: t()
  def new(rate, now), do: %__MODULE__{level: rate * @cost, at: now}

  # Takes one token. A clock that goes back (it must not) adds no token.
  #
  @spec take(t(), pos_integer(), integer()) :: {:ok | :drop, t()}
  def take(%__MODULE__{} = bucket, rate, now) do
    elapsed = max(now - bucket.at, 0)
    level = min(bucket.level + elapsed * rate, rate * @cost)

    if level >= @cost do
      {:ok, %__MODULE__{level: level - @cost, at: now}}
    else
      {:drop, %__MODULE__{level: level, at: now}}
    end
  end
end
