#
# The `auth` refusal event of the telemetry: each refusal of the
# authentication gives one event with the stage and the reason of the
# refusal, a request that passes gives none and the metadata holds no
# data of the token.
#
defmodule OzMcp.Auth.TelemetryTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias OzMcp.Auth.{Gate, Principal}
  alias Support.Helpers.TelemetryCapture
  alias Support.Helpers.Utils
  alias Support.Servers

  @resource_url "https://mcp.example.com/mcp"

  # The instances that serve the server modules of this file.
  #
  defp inst(module), do: Module.concat(module, __MODULE__)

  setup do
    ref = TelemetryCapture.attach()

    Utils.start_instances(
      [
        {Servers.Authorized, %{resource_url: @resource_url}},
        {Servers.AuthorizedBroken, %{resource_url: @resource_url}}
      ],
      __MODULE__,
      allowed_origins: []
    )

    {:ok, authorized} = OzMcp.Instance.config(inst(Servers.Authorized))
    {:ok, broken} = OzMcp.Instance.config(inst(Servers.AuthorizedBroken))

    %{ref: ref, authorized: authorized.telemetry, broken: broken.telemetry}
  end

  # The handle of the telemetry travels on the conn, as `OzMcp.Router`
  # puts it there before the gate runs.
  #
  defp request_conn(nil, telemetry),
    do: conn(:get, "/") |> put_private(:oz_mcp_telemetry, telemetry)

  defp request_conn(token, telemetry) do
    conn(:get, "/")
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_private(:oz_mcp_telemetry, telemetry)
  end

  defp two_headers_conn(telemetry) do
    conn(:get, "/")
    |> Map.replace!(:req_headers, [
      {"authorization", "Bearer alice-token"},
      {"authorization", "Bearer bob-token"}
    ])
    |> put_private(:oz_mcp_telemetry, telemetry)
  end

  # The drain consumes the mailbox, so each test drains one time and
  # picks the events of the refusal here.
  #
  defp refused_events(ref, instance) do
    Enum.filter(ref |> TelemetryCapture.drain(instance), fn {name, _, _} ->
      name == [:oz_mcp, :auth, :refused]
    end)
  end

  defp assert_one_event(events, instance, stage, reason) do
    assert [{_, %{count: 1}, meta}] = events
    assert meta.instance == instance
    assert meta.stage == stage
    assert meta.reason == reason
  end

  test "a request with no token gives one event for the missing credential", ctx do
    assert {:refuse, %OzMcp.Auth.Challenge{error: nil}, _} =
             Gate.run(
               request_conn(nil, ctx.authorized),
               inst(Servers.Authorized)
             )

    assert_one_event(
      refused_events(ctx.ref, inst(Servers.Authorized)),
      inst(Servers.Authorized),
      :authenticate,
      :missing_token
    )
  end

  test "a request with an unknown token gives one event for the refused token", ctx do
    assert {:refuse, %OzMcp.Auth.Challenge{}, _} =
             Gate.run(
               request_conn("no-such-token", ctx.authorized),
               inst(Servers.Authorized)
             )

    assert_one_event(
      refused_events(ctx.ref, inst(Servers.Authorized)),
      inst(Servers.Authorized),
      :authenticate,
      :invalid_token
    )
  end

  test "an expired principal gives one event with the reason of the expiry", ctx do
    #
    # The token of the test holds a number of its own: the verifier holds
    # the expiry time under the token, so no other test sees it.
    #
    token = Support.Auth.Default.register_token()
    Support.Auth.Default.expire_at(token, System.system_time(:second) - 10)

    assert {:refuse, %OzMcp.Auth.Challenge{}, _} =
             Gate.run(
               request_conn(token, ctx.authorized),
               inst(Servers.Authorized)
             )

    assert_one_event(
      refused_events(ctx.ref, inst(Servers.Authorized)),
      inst(Servers.Authorized),
      :authenticate,
      :token_expired
    )
  end

  test "a token for another audience gives one event for the mismatch", ctx do
    assert {:refuse, %OzMcp.Auth.Challenge{}, _} =
             Gate.run(
               request_conn("other-audience", ctx.authorized),
               inst(Servers.Authorized)
             )

    assert_one_event(
      refused_events(ctx.ref, inst(Servers.Authorized)),
      inst(Servers.Authorized),
      :authenticate,
      :audience_mismatch
    )
  end

  test "a malformed credential gives one event for the invalid request", ctx do
    assert {:refuse, %OzMcp.Auth.Challenge{error: :invalid_request}, _} =
             Gate.run(two_headers_conn(ctx.authorized), inst(Servers.Authorized))

    assert_one_event(
      refused_events(ctx.ref, inst(Servers.Authorized)),
      inst(Servers.Authorized),
      :authenticate,
      :invalid_request
    )
  end

  test "a verifier that raises gives one event for the defect of the verifier", ctx do
    log =
      Utils.capture_log([level: :error], fn ->
        assert Gate.run(
                 request_conn("raise-token", ctx.broken),
                 inst(Servers.AuthorizedBroken)
               ) ==
                 :error
      end)

    assert log =~ "authenticate/2 failed"

    assert_one_event(
      refused_events(ctx.ref, inst(Servers.AuthorizedBroken)),
      inst(Servers.AuthorizedBroken),
      :authenticate,
      :verifier_error
    )
  end

  test "a verifier that returns a value of a wrong shape gives one event", ctx do
    log =
      Utils.capture_log([level: :error], fn ->
        assert Gate.run(
                 request_conn("bad-value-token", ctx.broken),
                 inst(Servers.AuthorizedBroken)
               ) ==
                 :error
      end)

    assert log =~ "returned an invalid value"

    assert_one_event(
      refused_events(ctx.ref, inst(Servers.AuthorizedBroken)),
      inst(Servers.AuthorizedBroken),
      :authenticate,
      :verifier_error
    )
  end

  test "a shortcut atom the contract does not know gives one event", ctx do
    log =
      Utils.capture_log([level: :error], fn ->
        assert Gate.run(
                 request_conn("unknown-atom-token", ctx.broken),
                 inst(Servers.AuthorizedBroken)
               ) == :error
      end)

    assert log =~ "returned an invalid value"

    assert_one_event(
      refused_events(ctx.ref, inst(Servers.AuthorizedBroken)),
      inst(Servers.AuthorizedBroken),
      :authenticate,
      :verifier_error
    )
  end

  test "a challenge with an error the contract does not know gives one event", ctx do
    log =
      Utils.capture_log([level: :error], fn ->
        assert Gate.run(
                 request_conn("bogus-challenge-token", ctx.broken),
                 inst(Servers.AuthorizedBroken)
               ) == :error
      end)

    assert log =~ "returned an invalid value"

    assert_one_event(
      refused_events(ctx.ref, inst(Servers.AuthorizedBroken)),
      inst(Servers.AuthorizedBroken),
      :authenticate,
      :verifier_error
    )
  end

  test "a request that passes gives no event", ctx do
    assert {:ok, %Principal{}} =
             Gate.run(
               request_conn("alice-token", ctx.authorized),
               inst(Servers.Authorized)
             )

    assert refused_events(ctx.ref, inst(Servers.Authorized)) == []
  end

  test "an instance that does not run gives no event", ctx do
    assert Gate.run(
             request_conn("alice-token", ctx.authorized),
             Servers.AuthorizedLocalhost
           ) ==
             :not_running

    assert refused_events(ctx.ref, inst(Servers.Authorized)) == []
  end

  test "the metadata of each event holds the stage and the reason only", ctx do
    #
    # The token of the test holds a number of its own: the verifier holds
    # the expiry time under the token, so no other test sees it.
    #
    token = Support.Auth.Default.register_token()
    Support.Auth.Default.expire_at(token, System.system_time(:second) - 10)

    instance = inst(Servers.Authorized)

    assert {:refuse, _, _} = Gate.run(request_conn(nil, ctx.authorized), instance)
    assert {:refuse, _, _} = Gate.run(request_conn(token, ctx.authorized), instance)
    assert {:refuse, _, _} = Gate.run(request_conn("other-audience", ctx.authorized), instance)

    for {_, measurements, meta} <- refused_events(ctx.ref, instance) do
      assert measurements == %{count: 1}
      assert Map.keys(meta) |> Enum.sort() == [:instance, :reason, :server, :stage]
      assert meta.server == Servers.Authorized

      # The token text never goes out: no value of the metadata holds it.
      #
      refute Enum.any?(Map.values(meta), &(is_binary(&1) and String.contains?(&1, token)))
    end
  end
end
