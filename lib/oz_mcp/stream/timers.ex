#
# The poll timer of a stream and the cancel of a timer. The reference
# of the message ties it to its timer: the loop drops a message with
# another reference.
#
defmodule OzMcp.Stream.Timers do
  @moduledoc false

  @typedoc "A timer of a stream: the token of its message and the timer reference."
  @type handle :: {reference(), reference()} | nil

  # Arms a timer. The message is `{name, token}`, with a fresh token.
  #
  @spec arm(atom(), non_neg_integer()) :: handle()
  def arm(name, ms) when is_atom(name) and is_integer(ms) do
    token = make_ref()
    {token, Process.send_after(self(), {name, token}, ms)}
  end

  @spec arm_poll(pos_integer() | nil) :: handle()
  def arm_poll(nil), do: nil
  def arm_poll(ms) when is_integer(ms), do: arm(:sse_poll_close, ms)

  # The token that the messages of the timer carry. `nil` when there is no timer.
  #
  @spec token(handle()) :: reference() | nil
  def token(nil), do: nil
  def token({token, _timer}), do: token

  # Cancels a timer; a fired message is removed with a zero timeout
  # receive, as a cleanup.
  #
  @spec cancel(handle(), atom()) :: :ok
  def cancel(nil, _name), do: :ok

  def cancel({token, timer}, name) do
    if Process.cancel_timer(timer) == false do
      receive do
        {^name, ^token} -> :ok
      after
        0 -> :ok
      end
    end

    :ok
  end

  @spec cancel_poll(handle()) :: :ok
  def cancel_poll(handle), do: cancel(handle, :sse_poll_close)
end
