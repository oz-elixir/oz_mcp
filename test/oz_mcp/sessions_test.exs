defmodule OzMcp.SessionsTest do
  use ExUnit.Case, async: true

  alias OzMcp.Context.Error
  alias OzMcp.Instance
  alias OzMcp.Session
  alias OzMcp.Sessions
  alias Support.Helpers.SessionProbe
  alias Support.Helpers.Utils
  alias Support.Servers

  @server Servers.Default
  @instance Module.concat(@server, __MODULE__)
  @stopped Module.concat(@server, SessionsStopped)

  setup do
    Utils.start_instance(@server, name: @instance)
    :ok
  end

  describe "with an instance that runs" do
    test "start/2 and lookup/2" do
      assert {:ok, id} =
               Sessions.start(@instance,
                 protocol_version: "2025-11-25",
                 client_capabilities: %{"roots" => %{}}
               )

      assert {:ok, session} = Sessions.lookup(@instance, id)
      assert session.initialized == false
      assert session.client_capabilities == %{"roots" => %{}}
    end

    test "lookup/2 of an unknown session" do
      assert {:error, :no_session} = Sessions.lookup(@instance, "unknown")
    end

    test "start/2 gives the limit error when no session is idle" do
      name = Module.concat(@server, SessionsLimit)
      Utils.start_instance(@server, name: name, max_sessions: 1)

      assert {:ok, id} = Sessions.start(name)
      assert {:ok, _} = Session.open_stream(name, id, :get, self(), nil)
      assert {:error, :too_many_sessions} = Sessions.start(name)
    end

    test "set_initialized/2, set_log_level/3 and touch/2" do
      {:ok, id} = Sessions.start(@instance)

      assert :ok = Sessions.set_initialized(@instance, id)
      assert :ok = Sessions.set_log_level(@instance, id, :info)
      assert :ok = Sessions.touch(@instance, id)

      assert {:ok, %{initialized: true, log_level: :info}} = Sessions.lookup(@instance, id)
    end

    test "the writes of an unknown session" do
      assert {:error, :no_session} = Sessions.set_initialized(@instance, "unknown")
      assert {:error, :no_session} = Sessions.touch(@instance, "unknown")
      assert {:error, :no_session} = Sessions.terminate(@instance, "unknown")
    end

    test "subscribe/3 and unsubscribe/3" do
      {:ok, id} = Sessions.start(@instance)

      assert :ok = Sessions.subscribe(@instance, id, "file:///a")
      assert Utils.subscriptions(@instance, id) == ["file:///a"]

      assert :ok = Sessions.unsubscribe(@instance, id, "file:///a")
      assert Utils.subscriptions(@instance, id) == []

      assert {:error, :no_session} = Sessions.subscribe(@instance, "unknown", "file:///a")
    end

    test "terminate/2" do
      {:ok, id} = Sessions.start(@instance)

      assert :ok = Sessions.terminate(@instance, id)
      assert {:error, :no_session} = Sessions.lookup(@instance, id)
    end

    test "list_principal/2 and terminate_principal/2" do
      key = {"issuer", "alice"}
      {:ok, a} = Sessions.start(@instance, principal_key: key)
      {:ok, b} = Sessions.start(@instance, principal_key: key)
      {:ok, other} = Sessions.start(@instance, principal_key: {"issuer", "bob"})

      assert {:ok, ids} = Sessions.list_principal(@instance, key)
      assert Enum.sort(ids) == Enum.sort([a, b])
      assert {:ok, []} = Sessions.list_principal(@instance, nil)

      assert {:ok, ended} = Sessions.terminate_principal(@instance, key)
      assert Enum.sort(ended) == Enum.sort([a, b])
      assert {:ok, _} = Sessions.lookup(@instance, other)
    end

    test "open_request/5, close_request/5, emit/4, events_after/3 and close_stream/3" do
      {:ok, id} = Sessions.start(@instance)
      :ok = Sessions.set_initialized(@instance, id)

      assert {:ok, _} = Session.open_stream(@instance, id, :get, self(), nil)
      assert :ok = Utils.open_request(@instance, id, 1, self(), {"stream-1", :sse})

      assert :ok =
               Sessions.emit(@instance, id, {:request, 1}, %{"jsonrpc" => "2.0", "method" => "x"})

      assert {:sse, "stream-1:2"} =
               Utils.close_request(
                 @instance,
                 id,
                 1,
                 "stream-1",
                 {:response, ~s({"id":1}), false}
               )

      # The call after the casts: the session handles the messages in order.
      #
      assert :ok = Session.close_stream(@instance, id, self())

      assert {:ok, [_ | _]} = SessionProbe.events_after(@instance, id, nil)
      assert {:error, :no_session} = SessionProbe.events_after(@instance, "unknown", nil)
    end

    test "state/2, delivery/2, client_capabilities/2 and is_initialized/2" do
      capabilities = %{"roots" => %{"listChanged" => true}}
      client_info = %{"name" => "test-client", "version" => "1.0.0"}

      {:ok, id} =
        Sessions.start(@instance,
          protocol_version: "2025-11-25",
          client_info: client_info,
          client_capabilities: capabilities
        )

      assert {:ok, %{initialized: false}} = Sessions.state(@instance, id)
      assert {:ok, %{stream?: false, log_level: nil}} = Sessions.delivery(@instance, id)
      assert {:ok, ^capabilities} = Sessions.client_capabilities(@instance, id)
      assert SessionProbe.initialized?(@instance, id) == false

      assert {:error, :no_session} = Sessions.state(@instance, "unknown")
      assert {:error, :no_session} = Sessions.delivery(@instance, "unknown")
      assert {:error, :no_session} = Sessions.client_capabilities(@instance, "unknown")
      assert {:error, :no_session} = SessionProbe.initialized?(@instance, "unknown")

      :ok = Sessions.set_initialized(@instance, id)
      :ok = Sessions.set_log_level(@instance, id, :warning)

      assert SessionProbe.initialized?(@instance, id) == true
      assert {:ok, %{log_level: :warning}} = Sessions.delivery(@instance, id)

      assert {:ok, %{initialized: true, protocol_version: "2025-11-25"}} =
               Sessions.state(@instance, id)

      assert {:error, :unavailable} = Sessions.state(@stopped, "unknown")
    end

    test "open_stream/5, close_stream/3 and detach_resume/4" do
      {:ok, id} = Sessions.start(@instance)
      :ok = Sessions.set_initialized(@instance, id)

      assert {:ok, _} = Session.open_stream(@instance, id, :get, self(), nil)
      assert {:ok, %{initialized: true, stream?: true}} = Sessions.delivery(@instance, id)

      assert :ok = Session.close_stream(@instance, id, self())
      assert {:ok, %{stream?: false}} = Sessions.delivery(@instance, id)

      assert {:ok, %{mode: :get, replay: [], priming_id: priming_id, session_pid: pid} = opened} =
               Session.open_stream(@instance, id, :get, self(), nil)

      assert is_binary(priming_id) and is_pid(pid) and is_binary(opened.stream_id)

      assert {:error, :no_session} = Session.open_stream(@instance, "unknown", :get, self(), nil)

      assert :ok = Session.detach_resume(@instance, id, "stream-9", self())
    end

    test "notify_all/2, notify_subscribers/3, notify_log_message/4 and log_event/4" do
      notification = %{"jsonrpc" => "2.0", "method" => "notifications/tools/list_changed"}
      {:ok, id} = Sessions.start(@instance)
      :ok = Sessions.set_initialized(@instance, id)
      {:ok, _} = Session.open_stream(@instance, id, :get, self(), nil)

      assert :ok = Sessions.notify_all(@instance, notification)
      {_, ^notification} = Utils.receive_event(5_000)

      # A session with no stream gets nothing: the same broadcast reaches
      # only the stream of the first session.
      #
      {:ok, quiet} = Sessions.start(@instance)
      :ok = Sessions.set_initialized(@instance, quiet)
      assert :ok = Sessions.notify_all(@instance, notification)
      {_, ^notification} = Utils.receive_event(5_000)
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100

      # Only the subscribed session gets the resource update.
      #
      :ok = Sessions.subscribe(@instance, id, "file:///a.md")
      update = %{"jsonrpc" => "2.0", "method" => "notifications/resources/updated"}
      assert :ok = Sessions.notify_subscribers(@instance, "file:///a.md", update)
      {_, ^update} = Utils.receive_event(5_000)

      # Only the session whose level accepts the message gets the log.
      #
      :ok = Sessions.set_log_level(@instance, id, :debug)
      log = %{"jsonrpc" => "2.0", "method" => "notifications/message"}
      assert :ok = Sessions.notify_log_message(@instance, :debug, log)
      {_, ^log} = Utils.receive_event(5_000)

      :ok = Sessions.set_log_level(@instance, id, :error)
      assert :ok = Sessions.notify_log_message(@instance, :notice, log)
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 100

      # The log of the event goes to the session record only.
      #
      assert :ok = SessionProbe.log_event(@instance, id, "g.teststrm01:1", ~s({"p":1}))
      assert {:ok, [_ | _]} = SessionProbe.events_after(@instance, id, nil)

      # The writes of an unknown session answer as a missing session.
      #
      assert {:error, :no_session} = Session.open_stream(@instance, "unknown", :get, self(), nil)
      assert {:error, :no_session} = Session.close_stream(@instance, "unknown", self())
    end
  end

  describe "the requests of a session" do
    defp request_data(instance, id) do
      case Utils.session_data(instance, id) do
        nil -> nil
        data -> data.requests
      end
    end

    defp cancel_owner(parent) do
      receive do
        {:oz_mcp_cancel, request_id, reason} ->
          send(parent, {:cancelled, request_id, reason})
          cancel_owner(parent)
      end
    end

    test "open_request/5 registers a request, a duplicate id is refused" do
      {:ok, id} = Sessions.start(@instance)

      assert :ok = Utils.open_request(@instance, id, 1, self())
      assert {:error, :duplicate} = Utils.open_request(@instance, id, 1, self())

      # The id is compared strictly: "1" and 1 are different requests.
      #
      assert :ok = Utils.open_request(@instance, id, "1", self())

      assert request_data(@instance, id) |> Map.keys() |> Enum.sort() == [1, "1"]

      assert {:error, :no_session} = Utils.open_request(@instance, "unknown", 1, self())
    end

    test "end_request/3 frees the id" do
      {:ok, id} = Sessions.start(@instance)
      :ok = Utils.open_request(@instance, id, 7, self())
      :ok = Session.end_request(@instance, id, 7)

      # The end is a cast: this call orders the read after it.
      #
      assert :ok = Sessions.touch(@instance, id)
      assert request_data(@instance, id) == %{}

      # The id is free again.
      #
      assert :ok = Utils.open_request(@instance, id, 7, self())
      assert Map.has_key?(request_data(@instance, id), 7)
    end

    test "the end of the owner frees the id" do
      {:ok, id} = Sessions.start(@instance)
      owner = spawn(fn -> Process.sleep(:infinity) end)
      :ok = Utils.open_request(@instance, id, 7, owner)

      ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^owner, :killed}

      wait_until(fn -> request_data(@instance, id) == %{} end)
    end

    test "attach_runner/4 names the callback process, an unknown request gives :no_request" do
      {:ok, id} = Sessions.start(@instance)
      runner = spawn(fn -> Process.sleep(:infinity) end)

      assert {:error, :no_session} = Session.attach_runner(@instance, "unknown", 1, runner)

      :ok = Utils.open_request(@instance, id, 7, self())
      assert :ok = Session.attach_runner(@instance, id, 7, runner)
      assert %{7 => %{runner: ^runner}} = request_data(@instance, id)

      # A second attach does not replace the first.
      #
      assert :ok = Session.attach_runner(@instance, id, 7, self())
      assert %{7 => %{runner: ^runner}} = request_data(@instance, id)

      # An unknown request: the callback process learns that nobody waits.
      #
      assert {:error, :no_request} = Session.attach_runner(@instance, id, 999, self())
    end

    test "cancel/4 sends the cancel message to the owner of the request" do
      {:ok, id} = Sessions.start(@instance)
      parent = self()
      owner = spawn(fn -> cancel_owner(parent) end)
      :ok = Utils.open_request(@instance, id, 7, owner)

      assert :ok = Sessions.cancel(@instance, id, 7, "user aborted")
      assert_receive {:cancelled, 7, "user aborted"}, 5_000

      # An unknown request and an unknown session are ignored: a cancel is
      # best effort.
      #
      assert :ok = Sessions.cancel(@instance, id, 999, nil)
      assert :ok = Sessions.cancel(@instance, "unknown", 7, nil)
      refute_receive {:cancelled, 999, _}, 100
    end

    test "cancel/4 bounds a long reason and drops a reason that is not text" do
      {:ok, id} = Sessions.start(@instance)
      parent = self()
      owner = spawn(fn -> cancel_owner(parent) end)
      :ok = Utils.open_request(@instance, id, 7, owner)

      reason = "ok " <> String.duplicate("é", 5_000)
      assert :ok = Sessions.cancel(@instance, id, 7, reason)

      assert_receive {:cancelled, 7, bounded}, 5_000
      assert byte_size(bounded) <= 200
      assert String.valid?(bounded)
      assert String.starts_with?(bounded, "ok ")

      assert :ok = Sessions.cancel(@instance, id, 7, %{"not" => "text"})
      assert_receive {:cancelled, 7, nil}, 5_000
    end
  end

  describe "the lifecycle of a session" do
    test "a session that is not initialized stops after session_init_timeout_ms" do
      name = Module.concat(@server, SessionsInit)
      Utils.start_instance(@server, name: name, session_init_timeout_ms: 50)

      {:ok, id} = Sessions.start(name)
      {:ok, initialized} = Sessions.start(name)
      :ok = Sessions.set_initialized(name, initialized)

      wait_until(fn -> Sessions.lookup(name, id) == {:error, :no_session} end)

      assert {:error, :no_session} = Sessions.set_initialized(name, id)
      assert {:ok, %{initialized: true}} = Sessions.lookup(name, initialized)
    end

    test "an idle session stops after session_timeout_ms, a touch starts the timer again" do
      name = Module.concat(@server, SessionsIdle)
      Utils.start_instance(@server, name: name, session_timeout_ms: 1_000)

      {:ok, idle} = Sessions.start(name)
      {:ok, busy} = Sessions.start(name)
      :ok = Sessions.set_initialized(name, idle)
      :ok = Sessions.set_initialized(name, busy)

      # The touch starts the idle timer of `busy` again. Each wait is the
      # check that the DOWN of `busy` did not arrive before the touch.
      #
      {:ok, busy_view} = Sessions.lookup(name, busy)
      busy_ref = Process.monitor(busy_view.pid)

      for _ <- 1..4 do
        refute_receive {:DOWN, ^busy_ref, :process, ^busy, _}, 400
        assert :ok = Sessions.touch(name, busy)
      end

      assert {:error, :no_session} = Sessions.lookup(name, idle)
      assert {:ok, _view} = Sessions.lookup(name, busy)
    end

    test "a session with an open stream does not stop and stops after the stream closes" do
      name = Module.concat(@server, SessionsStream)
      Utils.start_instance(@server, name: name, session_timeout_ms: 1_000)

      {:ok, id} = Sessions.start(name)
      :ok = Sessions.set_initialized(name, id)
      {:ok, _} = Session.open_stream(name, id, :get, self(), nil)

      # The open stream holds the idle timer: no DOWN within the span of
      # the timeout.
      #
      view = elem(Sessions.lookup(name, id), 1)
      session_ref = Process.monitor(view.pid)
      refute_receive {:DOWN, ^session_ref, :process, _, _}, 1_400

      :ok = Session.close_stream(name, id, self())
      wait_until(fn -> Sessions.lookup(name, id) == {:error, :no_session} end)
    end

    test "max_sessions: busy sessions are refused, the end of a session frees a slot" do
      name = Module.concat(@server, SessionsMax)
      Utils.start_instance(@server, name: name, max_sessions: 2)

      {:ok, first} = Sessions.start(name)
      {:ok, second} = Sessions.start(name)
      {:ok, _} = Session.open_stream(name, first, :get, self(), nil)
      {:ok, _} = Session.open_stream(name, second, :get, self(), nil)
      assert {:error, :too_many_sessions} = Sessions.start(name)

      assert :ok = Sessions.terminate(name, first)
      assert {:ok, _third} = Sessions.start(name)
    end

    test "max_sessions: the oldest idle session ends and the new session starts" do
      name = Module.concat(@server, SessionsReclaim)
      Utils.start_instance(@server, name: name, max_sessions: 2)

      {:ok, oldest} = Sessions.start(name)
      {:ok, newer} = Sessions.start(name)
      Utils.set_last_active(name, oldest, 100)
      Utils.set_last_active(name, newer, 200)

      assert {:ok, third} = Sessions.start(name)
      assert {:error, :no_session} = Sessions.lookup(name, oldest)
      assert {:ok, _} = Sessions.lookup(name, newer)
      assert {:ok, _} = Sessions.lookup(name, third)
    end

    test "max_sessions: a session that never initialized goes before an older one" do
      name = Module.concat(@server, SessionsReclaimFresh)
      Utils.start_instance(@server, name: name, max_sessions: 2)

      {:ok, initialized} = Sessions.start(name)
      :ok = Sessions.set_initialized(name, initialized)
      {:ok, fresh} = Sessions.start(name)
      Utils.set_last_active(name, initialized, 100)
      Utils.set_last_active(name, fresh, 500)

      assert {:ok, _third} = Sessions.start(name)
      assert {:ok, _} = Sessions.lookup(name, initialized)
      assert {:error, :no_session} = Sessions.lookup(name, fresh)
    end

    test "max_sessions_per_principal: busy sessions are refused" do
      name = Module.concat(@server, SessionsPrincipal)
      Utils.start_instance(@server, name: name, max_sessions_per_principal: 1)

      alice = {"issuer", "alice"}
      {:ok, id} = Sessions.start(name, principal_key: alice)
      {:ok, _} = Session.open_stream(name, id, :get, self(), nil)

      assert {:error, :too_many_sessions} = Sessions.start(name, principal_key: alice)
      assert {:ok, _other} = Sessions.start(name, principal_key: {"issuer", "bob"})

      assert :ok = Sessions.terminate(name, id)
      assert {:ok, _again} = Sessions.start(name, principal_key: alice)
    end

    test "max_sessions_per_principal: the oldest idle session of that principal ends" do
      name = Module.concat(@server, SessionsPrincipalReclaim)
      Utils.start_instance(@server, name: name, max_sessions_per_principal: 2)

      alice = {"issuer", "alice"}
      bob = {"issuer", "bob"}

      {:ok, oldest} = Sessions.start(name, principal_key: alice)
      {:ok, newer} = Sessions.start(name, principal_key: alice)
      {:ok, other} = Sessions.start(name, principal_key: bob)
      Utils.set_last_active(name, oldest, 100)
      Utils.set_last_active(name, newer, 200)
      Utils.set_last_active(name, other, 50)

      assert {:ok, third} = Sessions.start(name, principal_key: alice)
      assert {:error, :no_session} = Sessions.lookup(name, oldest)
      assert {:ok, _} = Sessions.lookup(name, newer)
      assert {:ok, _} = Sessions.lookup(name, third)
      assert {:ok, _} = Sessions.lookup(name, other)
    end

    test "a crash of one session does not change the other sessions" do
      {:ok, crashed} = Sessions.start(@instance)
      {:ok, other} = Sessions.start(@instance)
      :ok = Sessions.set_initialized(@instance, other)

      {:ok, pid} = Instance.whereis(@instance, {:session, crashed})
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      wait_until(fn -> Sessions.lookup(@instance, crashed) == {:error, :no_session} end)
      assert {:ok, %{initialized: true}} = Sessions.lookup(@instance, other)
    end

    test "the end of a session ends its streams and removes the session" do
      {:ok, id} = Sessions.start(@instance)
      :ok = Sessions.set_initialized(@instance, id)
      {:ok, _} = Session.open_stream(@instance, id, :get, self(), nil)

      assert :ok = Sessions.terminate(@instance, id)
      assert_receive {:oz_mcp_stream, _stream_id, :terminate}, 5_000
      assert {:error, :no_session} = Sessions.lookup(@instance, id)
    end

    test "terminate/2 returns when the session is down" do
      {:ok, id} = Sessions.start(@instance)
      {:ok, pid} = Instance.whereis(@instance, {:session, id})

      assert :ok = Sessions.terminate(@instance, id)
      refute Process.alive?(pid)
    end

    test "a refused start leaves no session" do
      name = Module.concat(@server, SessionsRefused)
      Utils.start_instance(@server, name: name, max_sessions: 1)

      {:ok, id} = Sessions.start(name)
      {:ok, _} = Session.open_stream(name, id, :get, self(), nil)
      assert {:error, :too_many_sessions} = Sessions.start(name)

      assert Utils.session_count(name) == 1
    end
  end

  describe "with an instance that does not run" do
    test "each function gives :unavailable" do
      id = "session"

      results = [
        Sessions.start(@stopped),
        Sessions.lookup(@stopped, id),
        Sessions.touch(@stopped, id),
        Sessions.terminate(@stopped, id),
        Sessions.terminate_principal(@stopped, {"i", "s"}),
        Sessions.list_principal(@stopped, {"i", "s"}),
        Sessions.set_initialized(@stopped, id),
        Sessions.set_log_level(@stopped, id, :info),
        Sessions.subscribe(@stopped, id, "file:///a"),
        Sessions.unsubscribe(@stopped, id, "file:///a"),
        Utils.close_request(@stopped, id, 1, "s", {:response, "d", false}),
        Session.close_stream(@stopped, id, self()),
        Sessions.emit(@stopped, id, :session, %{}),
        Sessions.state(@stopped, id),
        Sessions.delivery(@stopped, id),
        Sessions.client_capabilities(@stopped, id),
        Session.open_stream(@stopped, id, :get, self(), nil),
        Session.detach_resume(@stopped, id, "s", self()),
        Sessions.notify_all(@stopped, %{}),
        Sessions.notify_subscribers(@stopped, "file:///a", %{}),
        Sessions.notify_log_message(@stopped, :info, %{})
      ]

      assert Enum.all?(results, &(&1 == {:error, :unavailable}))

      # The probes of the test support read the Registry of the instance:
      # a Registry that does not run gives a missing session, no crash.
      #
      assert SessionProbe.events_after(@stopped, id, nil) == {:error, :no_session}
      assert SessionProbe.initialized?(@stopped, id) == {:error, :no_session}
      assert SessionProbe.log_event(@stopped, id, "e:1", "d") == {:error, :no_session}
    end
  end

  describe "Error" do
    test "http_unavailable is a 503" do
      assert {503, %{"error" => %{"code" => -32603, "message" => "server unavailable"}}} =
               Error.build(Error.new(:http_unavailable), 1)
    end
  end

  defp wait_until(fun, retries \\ 1_500) do
    if Utils.eventually(fun, retries * 10) do
      :ok
    else
      flunk("condition was not met in time")
    end
  end
end
