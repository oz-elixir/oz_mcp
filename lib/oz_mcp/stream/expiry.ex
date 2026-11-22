#
# The timer of the expiry of a principal, for the waits of a stream.
# The delay is capped: the wait checks the principal when the message
# arrives and a new timer starts if the time is not reached. A stray
# message is dropped by its reference.
#
defmodule OzMcp.Stream.Expiry do
  @moduledoc false

  alias OzMcp.Auth.Principal
  alias OzMcp.Stream.Timers

  # The longest delay that every OTP release accepts for a timer (ms).
  #
  @max_timer_ms 4_294_967_295

  @type t :: Timers.handle()

  # Arms the timer of the expiry of the principal; a principal with no
  # expiry gets no timer (`nil`).
  #
  @spec arm(Principal.t() | nil) :: t()
  def arm(nil), do: nil

  def arm(%Principal{} = principal) do
    case Principal.expires_in(principal) do
      nil -> nil
      ms -> Timers.arm(:principal_expired, ms |> max(0) |> min(@max_timer_ms))
    end
  end

  # Reads the message of the timer: `:expired`, or `{:again, new_timer}`
  # when the principal is alive (a capped delay).
  #
  @spec check(Principal.t(), t()) :: :expired | {:again, t()}
  def check(principal, timer) do
    if Principal.expired?(principal) do
      :expired
    else
      cancel(timer)
      {:again, arm(principal)}
    end
  end

  # Cancels the timer and removes a fired message.
  #

  @spec cancel(t()) :: :ok
  def cancel(handle), do: Timers.cancel(handle, :principal_expired)
end
