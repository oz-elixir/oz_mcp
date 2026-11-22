defmodule OzMcp.Stream.ExpiryTest do
  use ExUnit.Case, async: true

  alias OzMcp.Auth.Principal
  alias OzMcp.Stream.Expiry
  alias OzMcp.Stream.Timers

  describe "arm/1" do
    test "gives no timer for nil" do
      assert Expiry.arm(nil) == nil
    end

    test "gives no timer for a principal with no expires_at" do
      principal = Principal.new!(subject: "alice")
      assert Expiry.arm(principal) == nil
    end

    test "gives a timer that sends the expiry message for an expired principal" do
      principal = Principal.new!(subject: "alice", expires_at: 0)
      handle = Expiry.arm(principal)
      token = Timers.token(handle)
      assert is_reference(token)
      assert_receive {:principal_expired, ^token}
      assert Expiry.cancel(handle) == :ok
    end

    test "gives a timer for a principal with a future expiry" do
      principal = Principal.new!(subject: "alice", expires_at: System.system_time(:second) + 60)
      handle = Expiry.arm(principal)
      assert is_reference(Timers.token(handle))
      refute_receive {:principal_expired, _}, 1
      assert Expiry.cancel(handle) == :ok
    end
  end

  describe "check/2" do
    test "gives :expired for an expired principal" do
      principal = Principal.new!(subject: "alice", expires_at: 0)
      assert Expiry.check(principal, nil) == :expired
    end

    test "gives {:again, new_timer} for a live principal and cancels the old timer" do
      principal = Principal.new!(subject: "alice", expires_at: System.system_time(:second) + 60)
      old_handle = Expiry.arm(principal)

      assert {:again, new_handle} = Expiry.check(principal, old_handle)
      assert is_reference(Timers.token(new_handle))
      refute Timers.token(new_handle) == Timers.token(old_handle)
      #
      # The old timer is cancelled: its message never arrives.
      #
      refute_receive {:principal_expired, _}, 1
      assert Expiry.cancel(new_handle) == :ok
    end

    test "a message of the old timer does not match the timer armed by check/2" do
      principal =
        Principal.new!(subject: "alice", expires_at: System.system_time(:second) + 3_600)

      old = Expiry.arm(principal)
      assert {:again, new} = Expiry.check(principal, old)

      refute Timers.token(old) == Timers.token(new)
      assert Expiry.cancel(new) == :ok
    end

    test "removes the message of an old timer that fired already" do
      principal = Principal.new!(subject: "alice", expires_at: 0)
      live = Principal.new!(subject: "alice", expires_at: System.system_time(:second) + 60)
      old_handle = Expiry.arm(principal)
      token = Timers.token(old_handle)
      assert_receive {:principal_expired, ^token}
      _ = Process.cancel_timer(elem(old_handle, 1))

      assert {:again, new_handle} = Expiry.check(live, old_handle)
      #
      # The message of the old timer was consumed: only the new timer runs.
      #
      refute_receive {:principal_expired, _}, 1
      assert Expiry.cancel(new_handle) == :ok
    end
  end

  describe "cancel/1" do
    test "gives :ok for nil" do
      assert Expiry.cancel(nil) == :ok
    end

    test "cancels a timer that did not fire: no message stays in the mailbox" do
      principal = Principal.new!(subject: "alice", expires_at: System.system_time(:second) + 60)
      handle = Expiry.arm(principal)
      assert Expiry.cancel(handle) == :ok
      refute_receive {:principal_expired, _}, 1
    end

    test "removes the message of a timer that fired already" do
      principal = Principal.new!(subject: "alice", expires_at: 0)
      handle = Expiry.arm(principal)
      token = Timers.token(handle)
      assert_receive {:principal_expired, ^token}
      assert Expiry.cancel(handle) == :ok
      refute_receive {:principal_expired, _}, 1
    end
  end
end
