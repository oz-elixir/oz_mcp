#
# The `principal revoked` event: one event at the end of every session
# of a principal, with the count of the sessions that the revocation
# ended. The metadata holds no key beyond the ones that every event
# carries: the key of the principal never goes out.
#
defmodule OzMcp.PrincipalRevokedTelemetryTest do
  use ExUnit.Case, async: true

  alias OzMcp.Sessions
  alias Support.Helpers.TelemetryCapture
  alias Support.Helpers.Utils
  alias Support.Servers

  @server_module Servers.Default

  @alice {"https://issuer.test", "alice"}
  @bob {"https://issuer.test", "bob"}

  test "the revocation of a principal with two sessions gives the count of the ended sessions" do
    ref = TelemetryCapture.attach()
    instance = start_instance()

    {:ok, alice_a} = Sessions.start(instance, principal_key: @alice)
    {:ok, alice_b} = Sessions.start(instance, principal_key: @alice)
    {:ok, _bob} = Sessions.start(instance, principal_key: @bob)

    assert {:ok, ended} = Sessions.terminate_principal(instance, @alice)
    assert MapSet.new(ended) == MapSet.new([alice_a, alice_b])

    assert [event] = revoked_events(ref, instance)
    {_, measurements, meta} = event

    assert measurements == %{sessions: 2}
    assert meta.instance == instance
    assert meta.server == @server_module

    assert MapSet.new(Map.keys(meta)) == MapSet.new([:instance, :server])
  end

  test "the revocation of a principal with no session gives the count zero" do
    ref = TelemetryCapture.attach()
    instance = start_instance()

    assert {:ok, []} = Sessions.terminate_principal(instance, @alice)

    assert [event] = revoked_events(ref, instance)
    assert elem(event, 1) == %{sessions: 0}
  end

  test "an instance that does not run gives no event" do
    ref = TelemetryCapture.attach()
    instance = start_instance()
    Utils.stop_instance(instance)

    assert {:error, :unavailable} = Sessions.terminate_principal(instance, @alice)

    assert [] = TelemetryCapture.drain(ref, instance)
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp start_instance do
    name = Module.concat(@server_module, "P#{System.unique_integer([:positive])}")
    Utils.start_instance(@server_module, name: name)

    name
  end

  # The events of the revocation in the drained list. The drain consumes
  # the mailbox, so the test drains one time and picks the events here.
  #
  defp revoked_events(ref, instance) do
    events = TelemetryCapture.drain(ref, instance)

    Enum.filter(events, fn {name, _, _} -> name == [:oz_mcp, :principal, :revoked] end)
  end
end
