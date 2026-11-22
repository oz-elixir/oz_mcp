defmodule OzMcp.Stream.TimersTest do
  use ExUnit.Case, async: true

  alias OzMcp.Stream.Timers

  describe "arm_poll/1" do
    test "gives no timer for nil" do
      assert Timers.arm_poll(nil) == nil
    end

    test "gives a timer that sends the poll close message" do
      handle = Timers.arm_poll(1)
      token = Timers.token(handle)
      assert is_reference(token)
      assert_receive {:sse_poll_close, ^token}
      assert Timers.cancel_poll(handle) == :ok
    end
  end

  describe "cancel/2" do
    test "gives :ok for nil" do
      assert Timers.cancel(nil, :sse_poll_close) == :ok
    end

    test "cancels a timer that did not fire: no message stays in the mailbox" do
      handle = Timers.arm(:sse_poll_close, 20)
      assert Timers.cancel(handle, :sse_poll_close) == :ok
      refute_receive {:sse_poll_close, _}, 25
    end

    test "removes the message of a timer that fired already" do
      #
      # A reference that matches no active timer makes the cancel report
      # that the timer fired already: the message waits in the mailbox and
      # the cancel removes it with a receive with a zero timeout.
      #
      token = make_ref()
      send(self(), {:sse_poll_close, token})
      assert Timers.cancel({token, make_ref()}, :sse_poll_close) == :ok
      refute_receive {:sse_poll_close, _}
    end

    test "the flush removes the message of its own token and keeps another" do
      token = make_ref()
      other = make_ref()
      send(self(), {:sse_poll_close, token})
      send(self(), {:sse_poll_close, other})

      assert Timers.cancel({token, make_ref()}, :sse_poll_close) == :ok

      refute_received {:sse_poll_close, ^token}
      assert_received {:sse_poll_close, ^other}
    end

    test "gives :ok twice for the same timer" do
      handle = Timers.arm(:sse_poll_close, 20)
      assert Timers.cancel(handle, :sse_poll_close) == :ok
      assert Timers.cancel(handle, :sse_poll_close) == :ok
      refute_receive {:sse_poll_close, _}, 25
    end
  end

  describe "cancel_poll/1" do
    test "cancels a poll timer: the message never arrives" do
      handle = Timers.arm_poll(20)
      assert Timers.cancel_poll(handle) == :ok
      refute_receive {:sse_poll_close, _}, 25
    end

    test "gives :ok for nil" do
      assert Timers.cancel_poll(nil) == :ok
    end
  end
end
