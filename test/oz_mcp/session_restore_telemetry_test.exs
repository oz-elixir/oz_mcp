#
# The `session restore` event: one event for each attempt to read a
# session out of the snapshot store, with the outcome of the attempt.
# The metadata holds the outcome only, next to the keys that every
# event carries: the id of the session never goes out.
#
defmodule OzMcp.SessionRestoreTelemetryTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias OzMcp.Auth.Principal
  alias OzMcp.Context
  alias OzMcp.Sessions
  alias OzMcp.Validate.Http
  alias Support.Helpers.PersistentSnapshot
  alias Support.Helpers.TelemetryCapture
  alias Support.Helpers.Utils
  alias Support.Servers

  @server_module Servers.Default

  @alice Principal.new!(issuer: "https://issuer.test", subject: "alice")
  @bob Principal.new!(issuer: "https://issuer.test", subject: "bob")

  setup context do
    ref = TelemetryCapture.attach()
    opts = Map.get(context, :instance_opts) || %{}
    name = Module.concat(@server_module, "R#{System.unique_integer([:positive])}")

    Utils.start_instance(@server_module, [name: name] ++ Map.to_list(opts))

    {:ok, config} = OzMcp.Instance.config(name)

    %{ref: ref, instance: name, telemetry: config.telemetry}
  end

  describe "the outcomes of the read of the store" do
    @tag instance_opts: %{session_snapshot: PersistentSnapshot}
    test "an id that the store does not hold gives the outcome miss", %{
      ref: ref,
      instance: instance
    } do
      assert Sessions.fetch_snapshot(instance, "unknown-id") == :not_found

      assert [event] = restore_events(ref, instance)
      assert elem(event, 1) == %{count: 1}
      assert elem(event, 2).outcome == :miss
    end

    @tag instance_opts: %{session_snapshot: PersistentSnapshot}
    test "the second request for a missed id pays no call of the store and gives cached_miss", %{
      ref: ref,
      instance: instance
    } do
      assert Sessions.fetch_snapshot(instance, "unknown-id") == :not_found
      assert Sessions.fetch_snapshot(instance, "unknown-id") == :not_found

      assert [first, second] = restore_events(ref, instance)
      assert elem(first, 2).outcome == :miss
      assert elem(second, 2).outcome == :cached_miss
    end

    @tag instance_opts: %{session_snapshot: PersistentSnapshot}
    test "a store that fails gives the outcome failed", %{ref: ref, instance: instance} do
      PersistentSnapshot.fail(instance, :load, :raise)

      log =
        Utils.capture_log([level: :error], fn ->
          assert Sessions.fetch_snapshot(instance, "any-id") == {:error, :failed}
        end)

      assert log =~ "session snapshot load failed"

      assert [event] = restore_events(ref, instance)
      assert elem(event, 2).outcome == :failed
    end

    @tag instance_opts: %{session_snapshot: PersistentSnapshot}
    test "a value of a wrong shape gives the outcome invalid", %{ref: ref, instance: instance} do
      PersistentSnapshot.put(instance, "bad-id", "text-instead-of-a-snapshot")

      log =
        Utils.capture_log([level: :warning], fn ->
          assert Sessions.fetch_snapshot(instance, "bad-id") == {:error, :invalid}
        end)

      assert log =~ "session snapshot load: invalid answer"

      assert [event] = restore_events(ref, instance)
      assert elem(event, 2).outcome == :invalid
    end

    test "an instance with no snapshot module gives no event", %{ref: ref, instance: instance} do
      assert Sessions.fetch_snapshot(instance, "any-id") == :disabled

      assert [] = restore_events(ref, instance)
    end
  end

  describe "the outcomes of the restore stage" do
    @tag instance_opts: %{session_snapshot: PersistentSnapshot}
    test "a snapshot of the store that starts gives the outcome restored", %{
      ref: ref,
      instance: instance,
      telemetry: telemetry
    } do
      :ok = PersistentSnapshot.put(instance, "stored-id", snapshot())

      assert {:cont, _context} = Http.restore(restore_context(instance, telemetry, "stored-id"))

      assert [event] = restore_events(ref, instance)
      assert elem(event, 1) == %{count: 1}
      assert elem(event, 2).outcome == :restored

      # The session that the stage started is in the Registry.
      #
      assert {:ok, _view} = Sessions.lookup(instance, "stored-id")
    end

    @tag instance_opts: %{session_snapshot: PersistentSnapshot}
    test "a snapshot of another principal gives the outcome denied", %{
      ref: ref,
      instance: instance,
      telemetry: telemetry
    } do
      :ok =
        PersistentSnapshot.put(instance, "stored-id", %{snapshot() | principal_key: key(@alice)})

      log =
        Utils.capture_log([level: :warning], fn ->
          assert {:halt, %{error: %{code: :http_invalid_session}}} =
                   Http.restore(
                     restore_context(instance, telemetry, "stored-id", principal: @bob)
                   )
        end)

      assert log =~ "session owner mismatch"

      assert [event] = restore_events(ref, instance)
      assert elem(event, 2).outcome == :denied
      assert {:error, :no_session} = Sessions.lookup(instance, "stored-id")
    end

    @tag instance_opts: %{
           session_snapshot: PersistentSnapshot,
           max_sessions_per_principal: 1
         }
    test "a start over the limit of the principal gives the outcome limit", %{
      ref: ref,
      instance: instance,
      telemetry: telemetry
    } do
      _live_id =
        Utils.create_session(instance,
          initialized: true,
          principal_key: key(@alice),
          streams: [self()]
        )

      :ok =
        PersistentSnapshot.put(instance, "stored-id", %{snapshot() | principal_key: key(@alice)})

      assert {:halt, %{error: %{code: :http_too_many_sessions}}} =
               Http.restore(restore_context(instance, telemetry, "stored-id", principal: @alice))

      assert [event] = restore_events(ref, instance)
      assert elem(event, 2).outcome == :limit
    end

    @tag instance_opts: %{session_snapshot: PersistentSnapshot}
    test "a session that runs gives no event", %{ref: ref, instance: instance} do
      session_id = Utils.create_session(instance, initialized: true)
      {:ok, config} = OzMcp.Instance.config(instance)

      assert {:cont, _context} =
               Http.restore(restore_context(instance, config.telemetry, session_id))

      assert [] = restore_events(ref, instance)
    end
  end

  @tag instance_opts: %{session_snapshot: PersistentSnapshot}
  test "the metadata of each event holds the outcome only", %{
    ref: ref,
    instance: instance
  } do
    assert Sessions.fetch_snapshot(instance, "unknown-id") == :not_found
    assert [event] = restore_events(ref, instance)
    {_, measurements, meta} = event

    assert measurements == %{count: 1}
    assert MapSet.new(Map.keys(meta)) == MapSet.new([:instance, :server, :outcome])
    assert meta.instance == instance
    assert meta.server == @server_module
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp snapshot do
    %{
      principal_key: nil,
      protocol_version: nil,
      client_info: %{"name" => "restore-telemetry", "version" => "1"},
      client_capabilities: %{},
      log_level: :warning,
      subscriptions: []
    }
  end

  defp key(%Principal{} = principal), do: Principal.key(principal)

  # The conn and the context of the restore stage, with the handle of the
  # telemetry on the conn, as `OzMcp.Router` puts it there.
  #
  defp restore_context(instance, telemetry, session_id, overrides \\ []) do
    conn =
      conn(:post, "/", "{}")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-session-id", session_id)
      |> put_private(:server, instance)
      |> put_private(:oz_mcp_telemetry, telemetry)

    Context.new(instance, :http_streamable, :rpc)
    |> Context.put_http_conn(conn)
    |> Map.put(:session_id, session_id)
    |> Map.put(:rpc_method, "tools/call")
    |> Map.put(:principal, Keyword.get(overrides, :principal))
  end

  # The events of the restore in the drained list. The drain consumes the
  # mailbox, so the test drains one time and picks the events here.
  #
  defp restore_events(ref, instance) do
    events = TelemetryCapture.drain(ref, instance)

    Enum.filter(events, fn {name, _, _} -> name == [:oz_mcp, :session, :restore] end)
  end
end
