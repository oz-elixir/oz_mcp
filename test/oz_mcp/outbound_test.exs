defmodule OzMcp.OutboundTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Test

  alias OzMcp.{Instance, Outbound, PostStream, Session, Sessions}
  alias Support.Helpers.SessionProbe
  alias Support.Helpers.Utils
  alias Support.Servers

  @server_module Servers.Default

  @server Module.concat(@server_module, __MODULE__)
  setup do
    Utils.start_instance(@server_module, name: @server)
    :ok
  end

  # A session whose GET stream is the test process.
  #
  defp session(capabilities \\ %{}) do
    Utils.create_session(
      @server,
      initialized: true,
      streams: [self()],
      client_capabilities: capabilities
    )
  end

  defp ctx(session_id, request_id \\ nil),
    do: %{
      instance: @server,
      server: @server_module,
      session_id: session_id,
      request_id: request_id
    }

  defp elicit_params do
    %{
      "mode" => "form",
      "message" => "Who are you?",
      "requestedSchema" => %{"type" => "object", "properties" => %{"n" => %{"type" => "string"}}}
    }
  end

  defp request_async(ctx, method, params \\ nil, opts \\ []) do
    Task.async(fn -> Outbound.request(ctx, method, params, opts) end)
  end

  defp wait_pending(session_id, count \\ 1) do
    assert Utils.eventually(fn -> length(pending_ids(session_id)) == count end)
    pending_ids(session_id)
  end

  defp pending_ids(session_id) do
    case SessionProbe.pending_outbound_ids(@server, session_id) do
      ids when is_list(ids) -> ids
      _error -> []
    end
  end

  # The JSON messages carried by the events of an SSE body.
  #
  defp sse_messages(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn event ->
      #
      # The priming event has an id and no data: it carries no message.
      #
      case Regex.run(~r/^data: (.+)$/m, event, capture: :all_but_first) do
        [data] -> [:json.decode(data)]
        nil -> []
      end
    end)
  end

  # A process that sends a ping and waits for the answer.
  #
  defp spawn_waiting(ctx), do: spawn(fn -> Outbound.ping(ctx, timeout: 10_000) end)

  # The pid of the process of a session.
  #
  defp session_pid(session_id) do
    {:ok, pid} = Instance.whereis(@server, {:session, session_id})
    pid
  end

  # The monitor of a session pid in the list of the monitors of a process.
  #
  defp monitors_session?(monitors, session_pid),
    do: Enum.any?(monitors, &match?({:process, ^session_pid}, &1))

  describe "request/4 - validation (nothing is sent)" do
    test "refuses a method a server cannot send" do
      session_id = session()

      assert Outbound.request(ctx(session_id), "tools/call") == {:error, :unsupported_method}
      assert Outbound.request(ctx(session_id), "initialize") == {:error, :unsupported_method}
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 50
    end

    test "refuses params that JSON cannot encode" do
      session_id = session(%{"roots" => %{}})

      assert Outbound.request(ctx(session_id), "roots/list", %{"pid" => self()}) ==
               {:error, :not_encodable}

      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 50
      assert SessionProbe.pending_outbound_ids(@server, session_id) == []
    end

    test "refuses a method whose capability the client did not declare" do
      session_id = session(%{"roots" => %{}})

      for method <- ["sampling/createMessage", "elicitation/create"] do
        assert Outbound.request(ctx(session_id), method, %{}) ==
                 {:error, :capability_not_supported}
      end

      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 50
      assert SessionProbe.pending_outbound_ids(@server, session_id) == []
    end

    test "decides on the capabilities of the ctx, not of the session" do
      session_id = session(%{"roots" => %{}})

      declared = Map.put(ctx(session_id), :client_capabilities, %{})
      assert Outbound.request(declared, "roots/list") == {:error, :capability_not_supported}

      task =
        Task.async(fn ->
          Outbound.request(
            Map.put(ctx(session_id), :client_capabilities, %{"roots" => %{}}),
            "roots/list"
          )
        end)

      [id] = wait_pending(session_id)
      Outbound.deliver(@server, session_id, id, {:ok, %{"roots" => []}})
      assert Task.await(task, 30_000) == {:ok, %{"roots" => []}}
    end

    test "refuses a session that does not exist" do
      assert Outbound.ping(ctx("gone")) == {:error, :session_not_found}

      assert Outbound.ping(%{instance: @server, server: @server_module, session_id: nil}) ==
               {:error, :session_not_found}
    end

    test "refuses a server that is not running" do
      ctx = %{
        instance: Servers.ToolsOnly,
        server: Servers.ToolsOnly,
        session_id: "any"
      }

      assert Outbound.ping(ctx) == {:error, :session_not_found}
    end

    test "raises on an invalid timeout option" do
      session_id = session()

      for timeout <- [0, -1, "1", 1.5] do
        assert_raise ArgumentError, fn -> Outbound.ping(ctx(session_id), timeout: timeout) end
      end
    end
  end

  describe "request/4 - client task capabilities" do
    test "sends tasks/get and tasks/result to a client that declared tasks" do
      session_id = session(%{"tasks" => %{}})

      for method <- ["tasks/get", "tasks/result"] do
        task = request_async(ctx(session_id), method, %{"taskId" => "c1"})
        [id] = wait_pending(session_id)
        Outbound.deliver(@server, session_id, id, {:ok, %{"status" => "working"}})
        assert Task.await(task, 30_000) == {:ok, %{"status" => "working"}}
      end
    end

    test "refuses tasks/get when the client did not declare tasks" do
      session_id = session(%{"roots" => %{}})

      assert Outbound.request(ctx(session_id), "tasks/get", %{"taskId" => "c1"}) ==
               {:error, :capability_not_supported}

      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 50
      assert SessionProbe.pending_outbound_ids(@server, session_id) == []
    end

    test "sends tasks/cancel only to a client that declared tasks.cancel" do
      no_cancel = session(%{"tasks" => %{}})

      assert Outbound.request(ctx(no_cancel), "tasks/cancel", %{"taskId" => "c1"}) ==
               {:error, :capability_not_supported}

      session_id = session(%{"tasks" => %{"cancel" => %{}}})
      task = request_async(ctx(session_id), "tasks/cancel", %{"taskId" => "c1"})
      [id] = wait_pending(session_id)
      Outbound.deliver(@server, session_id, id, {:ok, %{}})
      assert Task.await(task, 30_000) == {:ok, %{}}
    end

    test "refuses a sampling with a task key and no task capability" do
      session_id = session(%{"sampling" => %{}})
      params = %{"messages" => [], "task" => %{"ttl" => 1_000}}

      assert Outbound.request(ctx(session_id), "sampling/createMessage", params) ==
               {:error, :capability_not_supported}

      assert SessionProbe.pending_outbound_ids(@server, session_id) == []
      refute Outbound.accepts?(%{"sampling" => %{}}, "sampling/createMessage", params)
    end

    test "sends a sampling with a task key when the client runs sampling as a task" do
      capabilities = %{
        "sampling" => %{},
        "tasks" => %{"requests" => %{"sampling" => %{"createMessage" => %{}}}}
      }

      session_id = session(capabilities)
      params = %{"messages" => [], "task" => %{"ttl" => 1_000}}

      assert Outbound.accepts?(capabilities, "sampling/createMessage", params)

      task = request_async(ctx(session_id), "sampling/createMessage", params)
      [id] = wait_pending(session_id)
      Outbound.deliver(@server, session_id, id, {:ok, %{"task" => %{"taskId" => "c1"}}})
      assert Task.await(task, 30_000) == {:ok, %{"task" => %{"taskId" => "c1"}}}
    end
  end

  describe "request/4 - a route that cannot carry the request" do
    test "fails with :no_stream when the session has no GET stream; nothing is sent" do
      session_id = Utils.create_session(@server, initialized: true)

      assert Outbound.ping(ctx(session_id)) == {:error, :no_stream}
      assert SessionProbe.pending_outbound_ids(@server, session_id) == []
      assert {:ok, []} = SessionProbe.events_after(@server, session_id, "none")
    end

    test "a stream process that is dead does not count" do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _}

      session_id = Utils.create_session(@server, initialized: true, streams: [dead])

      assert Outbound.ping(ctx(session_id)) == {:error, :no_stream}
    end

    test "fails with :session_not_initialized before notifications/initialized" do
      session_id = Utils.create_session(@server, streams: [self()])

      assert Outbound.ping(ctx(session_id)) == {:error, :session_not_initialized}
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 50
    end

    test "a GET resume counts the stream as live: the request goes out" do
      session_id = Utils.create_session(@server, initialized: true)

      assert {:ok, %{stream_id: _stream_id, priming_id: priming_id}} =
               Session.open_stream(@server, session_id, :get, self(), nil)

      assert :ok = Session.close_stream(@server, session_id, self())

      assert {:ok, %{mode: :get, stream_id: stream_id}} =
               Session.open_stream(@server, session_id, :get, self(), priming_id)

      task = request_async(ctx(session_id), "ping")

      {event_id, %{"method" => "ping", "id" => id}} = Utils.receive_event()
      assert String.starts_with?(event_id, stream_id <> ":")

      Outbound.deliver(@server, session_id, id, {:ok, %{}})

      assert Task.await(task, 30_000) == {:ok, %{}}
    end

    test "wait_for_stream: true sends the request to the event log of the session" do
      session_id = Utils.create_session(@server, initialized: true)

      # A GET stream opens and ends: the session keeps it for the resume
      # and the events of the gap go in its ring.
      #
      assert {:ok, _} = Session.open_stream(@server, session_id, :get, self(), nil)
      assert :ok = Session.close_stream(@server, session_id, self())

      assert Outbound.ping(ctx(session_id), timeout: 30, wait_for_stream: true) ==
               {:error, :timeout}

      # The cancellation is a cast of the Server: the barrier orders it
      # before the read of the log.
      #
      Utils.sync_server(@server, session_id)

      assert {:ok, events} = SessionProbe.events_after(@server, session_id, "none")

      assert [%{"method" => "ping"}, %{"method" => "notifications/cancelled"}] =
               Enum.map(events, fn {_id, encoded} -> :json.decode(encoded) end)
    end

    test "a request that has a POST stream needs no GET stream" do
      session_id = Utils.create_session(@server, initialized: true)
      {:ok, stream} = Utils.begin_stream(@server, session_id, 7, conn(:post, "/"), & &1)
      task = request_async(ctx(session_id, 7), "ping")

      assert {_, %{"method" => "ping", "id" => id}} = Utils.receive_event(5_000)
      Outbound.deliver(@server, session_id, id, {:ok, %{}})
      assert Task.await(task, 30_000) == {:ok, %{}}
      PostStream.close(stream)
    end

    test "a request of a closed POST stream falls under the GET rule" do
      session_id = Utils.create_session(@server, initialized: true)
      {:ok, stream} = Utils.begin_stream(@server, session_id, 7, conn(:post, "/"), & &1)
      PostStream.close(stream)

      assert Outbound.ping(ctx(session_id, 7)) == {:error, :no_stream}
    end
  end

  describe "request/4 - the GET stream" do
    test "sends the request to the stream and returns the result of the client" do
      session_id = session()
      task = request_async(ctx(session_id), "ping")

      {_, request} = Utils.receive_event(5_000)
      assert %{"jsonrpc" => "2.0", "method" => "ping", "id" => id} = request
      assert is_binary(id)
      refute Map.has_key?(request, "params")

      assert SessionProbe.pending_outbound_ids(@server, session_id) == [id]
      assert :ok = Outbound.deliver(@server, session_id, id, {:ok, %{}})

      assert Task.await(task, 30_000) == {:ok, %{}}
      assert SessionProbe.pending_outbound_ids(@server, session_id) == []
    end

    test "sends the params" do
      session_id = session(%{"roots" => %{}})
      task = request_async(ctx(session_id), "roots/list", %{"_meta" => %{"a" => 1}})

      assert {_, %{"method" => "roots/list", "params" => params, "id" => id}} =
               Utils.receive_event()

      assert params == %{"_meta" => %{"a" => 1}}

      Outbound.deliver(@server, session_id, id, {:ok, %{"roots" => []}})
      assert Task.await(task, 30_000) == {:ok, %{"roots" => []}}
    end

    test "sends a method that needs a capability the client declared" do
      session_id = session(%{"sampling" => %{}, "elicitation" => %{}})
      sampling = request_async(ctx(session_id), "sampling/createMessage", %{"x" => 1})

      assert {_, %{"method" => "sampling/createMessage", "id" => id}} = Utils.receive_event()

      Outbound.deliver(@server, session_id, id, {:ok, %{"role" => "assistant"}})
      assert Task.await(sampling, 30_000) == {:ok, %{"role" => "assistant"}}

      elicitation = request_async(ctx(session_id), "elicitation/create", %{"y" => 1})

      assert {_, %{"method" => "elicitation/create", "id" => id}} = Utils.receive_event()

      Outbound.deliver(@server, session_id, id, {:ok, %{"action" => "accept"}})
      assert Task.await(elicitation, 30_000) == {:ok, %{"action" => "accept"}}
    end

    test "returns the error object the client answered with" do
      session_id = session()
      task = request_async(ctx(session_id), "ping")
      {_, %{"id" => id}} = Utils.receive_event()

      error = %{"code" => -32601, "message" => "no ping", "data" => %{"a" => 1}}
      Outbound.deliver(@server, session_id, id, {:error, error})

      assert Task.await(task, 30_000) == {:error, {:rpc_error, error}}
    end

    test "ids are unique for concurrent requests of a session" do
      session_id = session()
      first = request_async(ctx(session_id), "ping")
      second = request_async(ctx(session_id), "ping")

      [id_one, id_two] = wait_pending(session_id, 2)
      refute id_one == id_two

      Outbound.deliver(@server, session_id, id_two, {:ok, %{"n" => 2}})
      Outbound.deliver(@server, session_id, id_one, {:ok, %{"n" => 1}})

      results = [Task.await(first, 30_000), Task.await(second, 30_000)]
      assert Enum.sort(results) == [{:ok, %{"n" => 1}}, {:ok, %{"n" => 2}}]
    end

    test "the request is kept in the event log of the session" do
      session_id = session()

      # A GET stream: the events of the session go in its log, so a client
      # can replay them.
      #
      assert {:ok, _} = Session.open_stream(@server, session_id, :get, self(), nil)

      task = request_async(ctx(session_id), "ping")
      {event_id, %{"id" => id}} = Utils.receive_event()

      assert {:ok, [_ | _] = events} = SessionProbe.events_after(@server, session_id, "none")
      assert Enum.any?(events, fn {logged_id, _} -> logged_id == event_id end)

      Outbound.deliver(@server, session_id, id, {:ok, %{}})
      Task.await(task, 30_000)
    end
  end

  describe "request/4 - timeout" do
    test "returns :timeout, frees the id and tells the client to cancel" do
      session_id = session()

      log =
        capture_log(fn ->
          task = request_async(ctx(session_id), "ping", nil, timeout: 50)

          {_, %{"id" => id}} = Utils.receive_event(5_000)
          assert Task.await(task, 30_000) == {:error, :timeout}

          assert {_,
                  %{
                    "method" => "notifications/cancelled",
                    "params" =>
                      %{"requestId" => ^id, "reason" => "request timed out"} =
                        params
                  }} = Utils.receive_event(5_000)

          # A request without a task gets no related-task meta.
          #
          refute Map.has_key?(params, "_meta")

          assert SessionProbe.pending_outbound_ids(@server, session_id) == []

          # The late answer is dropped.
          #
          assert :ok = Outbound.deliver(@server, session_id, id, {:ok, %{}})
        end)

      assert log =~ "did not answer"
    end

    test "uses the client_request_timeout_ms of the server" do
      Utils.stop_instance(@server)

      Utils.start_instance(
        @server_module,
        [name: @server] ++ Map.to_list(%{client_request_timeout_ms: 30})
      )

      session_id = session()

      capture_log(fn ->
        assert Outbound.ping(ctx(session_id)) == {:error, :timeout}
      end)
    end

    test "elicitation/create and sampling/createMessage use their own timeouts" do
      Utils.stop_instance(@server)

      Utils.start_instance(
        @server_module,
        [name: @server] ++
          Map.to_list(%{
            client_request_timeout_ms: 30,
            elicitation_timeout_ms: 60_000,
            sampling_timeout_ms: 40
          })
      )

      session_id = session(%{"elicitation" => %{}, "sampling" => %{}})

      # Not the 30 ms of client_request_timeout_ms: the request is still waiting.
      # A timeout of the request would end the task, so the wait is the check
      # that the DOWN of the task does not arrive.
      #
      task = request_async(ctx(session_id), "elicitation/create", elicit_params())
      [id] = wait_pending(session_id)
      task_ref = Process.monitor(task.pid)
      refute_receive {:DOWN, ^task_ref, :process, _, _}, 100
      assert SessionProbe.pending_outbound_ids(@server, session_id) == [id]
      assert :ok = Outbound.deliver(@server, session_id, id, {:ok, %{"action" => "decline"}})
      assert {:ok, %{"action" => "decline"}} = Task.await(task, 30_000)

      # sampling_timeout_ms (40 ms) applies to sampling.
      #
      capture_log(fn ->
        assert {:error, :timeout} =
                 Outbound.request(ctx(session_id), "sampling/createMessage", %{})
      end)
    end

    test "ping and roots/list use client_request_timeout_ms, not the human timeouts" do
      Utils.stop_instance(@server)

      Utils.start_instance(
        @server_module,
        [name: @server] ++
          Map.to_list(%{
            client_request_timeout_ms: 30,
            elicitation_timeout_ms: 60_000,
            sampling_timeout_ms: 60_000
          })
      )

      session_id = session(%{"roots" => %{}})

      capture_log(fn ->
        assert Outbound.ping(ctx(session_id)) == {:error, :timeout}
        assert Outbound.request(ctx(session_id), "roots/list") == {:error, :timeout}
      end)
    end

    test "the option of the call wins over the timeout of the method" do
      Utils.stop_instance(@server)

      Utils.start_instance(
        @server_module,
        [name: @server] ++ Map.to_list(%{elicitation_timeout_ms: 60_000})
      )

      session_id = session(%{"elicitation" => %{}})

      capture_log(fn ->
        assert {:error, :timeout} =
                 Outbound.request(ctx(session_id), "elicitation/create", elicit_params(),
                   timeout: 30
                 )
      end)
    end

    test "the option of the call wins over the runtime option" do
      Utils.stop_instance(@server)

      Utils.start_instance(
        @server_module,
        [name: @server] ++ Map.to_list(%{client_request_timeout_ms: 60_000})
      )

      session_id = session()

      capture_log(fn ->
        assert Outbound.ping(ctx(session_id), timeout: 30) == {:error, :timeout}
      end)
    end

    test "leaves nothing in the mailbox of the caller" do
      session_id = session()
      session_pid = session_pid(session_id)

      task =
        Task.async(fn ->
          result = Outbound.ping(ctx(session_id), timeout: 50)

          {result, Process.info(self(), :messages), Process.info(self(), :monitors)}
        end)

      {_, %{"id" => id}} = Utils.receive_event(5_000)
      Outbound.deliver(@server, session_id, id, {:ok, %{}})

      assert {{:ok, %{}}, {:messages, []}, {:monitors, monitors}} = Task.await(task, 30_000)
      refute monitors_session?(monitors, session_pid)
    end
  end

  describe "deliver/4" do
    test "ignores an answer for an id that is not pending" do
      session_id = session()

      assert Outbound.deliver(@server, session_id, "unknown", {:ok, %{}}) == :ok
    end

    test "ignores an answer of another session for a pending id" do
      session_id = session()
      other_session_id = session()
      task = request_async(ctx(session_id), "ping", nil, timeout: 300)
      {_, %{"id" => id}} = Utils.receive_event()

      capture_log(fn ->
        assert Outbound.deliver(@server, other_session_id, id, {:ok, %{}}) == :ok
        assert Task.await(task, 30_000) == {:error, :timeout}
      end)
    end

    test "delivers an answer only once" do
      session_id = session()
      task = request_async(ctx(session_id), "ping")
      {_, %{"id" => id}} = Utils.receive_event()

      Outbound.deliver(@server, session_id, id, {:ok, %{"n" => 1}})
      assert Task.await(task, 30_000) == {:ok, %{"n" => 1}}

      # The wait is over: a repeated answer finds nothing and is dropped.
      #
      assert Outbound.deliver(@server, session_id, id, {:ok, %{"n" => 2}}) == :ok
    end

    test "does not fail when the runtime is not running" do
      Utils.stop_instance(@server)

      assert Outbound.deliver(@server, "s", "id", {:ok, %{}}) == :ok
    end

    test "ignores an id of a request of a task: the answer goes to the task of its owner" do
      session_id = session()

      assert Outbound.deliver(@server, session_id, "t.some-task.1", {:ok, %{}}) == :ok
      assert SessionProbe.pending_outbound_ids(@server, session_id) == []
    end
  end

  describe "pending requests are tied to the waiting process" do
    test "a process that dies leaves no pending request" do
      session_id = session()

      {pid, ref} =
        spawn_monitor(fn -> Outbound.ping(ctx(session_id)) end)

      {_, %{"id" => id}} = Utils.receive_event()
      assert SessionProbe.pending_outbound_ids(@server, session_id) == [id]

      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      wait_pending(session_id, 0)

      # The late answer is dropped without a crash.
      #
      assert Outbound.deliver(@server, session_id, id, {:ok, %{}}) == :ok
    end

    test "the end of the session ends the waits of that session only" do
      session_id = session()
      other_session_id = session()

      first = request_async(ctx(session_id), "ping")
      second = request_async(ctx(session_id), "ping")
      other = request_async(ctx(other_session_id), "ping", nil, timeout: 5_000)

      wait_pending(session_id, 2)
      wait_pending(other_session_id, 1)

      assert :ok = Sessions.terminate(@server, session_id)

      assert Task.await(first, 30_000) == {:error, :session_terminated}
      assert Task.await(second, 30_000) == {:error, :session_terminated}

      # The other session is not touched.
      #
      assert [other_id] = SessionProbe.pending_outbound_ids(@server, other_session_id)
      Outbound.deliver(@server, other_session_id, other_id, {:ok, %{}})
      assert Task.await(other, 30_000) == {:ok, %{}}
    end

    test "terminating the session ends the wait" do
      session_id = session()
      task = request_async(ctx(session_id), "ping")
      wait_pending(session_id)

      assert :ok = Sessions.terminate(@server, session_id)
      assert Task.await(task, 30_000) == {:error, :session_terminated}
    end

    test "a kill of the session process ends the wait within 1 s" do
      session_id = session()
      session_pid = session_pid(session_id)
      task = request_async(ctx(session_id), "ping", nil, timeout: 60_000)
      wait_pending(session_id)

      Process.exit(session_pid, :kill)

      assert Task.await(task, 1_000) == {:error, :session_terminated}
    end

    test "the normal end of the session ends the wait once and leaves no message" do
      session_id = session()
      session_pid = session_pid(session_id)

      task =
        Task.async(fn ->
          result = Outbound.ping(ctx(session_id), timeout: 60_000)
          {result, Process.info(self(), :messages)}
        end)

      wait_pending(session_id)
      assert :ok = Sessions.terminate(@server, session_id)

      assert {{:error, :session_terminated}, {:messages, []}} = Task.await(task, 5_000)
      refute Process.alive?(session_pid)
    end

    test "an answer that came before the end of the session wins" do
      session_id = session()

      task =
        Task.async(fn ->
          result = Outbound.ping(ctx(session_id), timeout: 60_000)
          {result, Process.info(self(), :messages)}
        end)

      [id] = wait_pending(session_id)
      assert :ok = Outbound.deliver(@server, session_id, id, {:ok, %{"n" => 1}})
      Utils.sync_server(@server, session_id)
      assert :ok = Sessions.terminate(@server, session_id)

      assert {{:ok, %{"n" => 1}}, {:messages, []}} = Task.await(task, 5_000)
    end

    test "the call leaves no monitor of the session" do
      session_id = session()
      session_pid = session_pid(session_id)
      parent = self()

      spawn(fn ->
        [id] = wait_pending(session_id)
        Outbound.deliver(@server, session_id, id, {:ok, %{}})
        send(parent, :delivered)
      end)

      assert Outbound.ping(ctx(session_id), timeout: 10_000) == {:ok, %{}}
      assert_receive :delivered, 5_000

      {:monitors, monitors} = Process.info(self(), :monitors)
      refute monitors_session?(monitors, session_pid)
    end

    test "a waiter that crashes causes one notifications/cancelled" do
      session_id = session()
      pid = spawn_waiting(ctx(session_id))
      [id] = wait_pending(session_id)
      {_, %{"method" => "ping", "id" => ^id}} = Utils.receive_event(5_000)

      Process.exit(pid, :kill)
      wait_pending(session_id, 0)

      assert {_, %{"method" => "notifications/cancelled"} = cancelled} =
               Utils.receive_event(5_000)

      assert cancelled["params"] == %{"requestId" => id, "reason" => "the request ended"}

      # One notice only: the late answer of nobody is dropped.
      #
      refute_receive {:oz_mcp_stream, _, {:event, _, %{"method" => "notifications/cancelled"}}},
                     100

      assert Outbound.deliver(@server, session_id, id, {:ok, %{}}) == :ok
    end
  end

  describe "request/4 - the stream of a POST request" do
    setup do
      %{session_id: session()}
    end

    test "goes to the process that owns the stream of the request, not to the GET stream",
         %{session_id: session_id} do
      {:ok, stream} = Utils.begin_stream(@server, session_id, 7, conn(:post, "/"), & &1)
      task = request_async(ctx(session_id, 7), "ping")

      assert {_, %{"method" => "ping", "id" => id}} = Utils.receive_event(5_000)
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 50

      Outbound.deliver(@server, session_id, id, {:ok, %{}})
      assert Task.await(task, 30_000) == {:ok, %{}}
      PostStream.close(stream)
    end

    test "goes to the GET stream for a request that has no stream", %{session_id: session_id} do
      {:ok, stream} = Utils.begin_stream(@server, session_id, 7, conn(:post, "/"), & &1)
      task = request_async(ctx(session_id, 8), "ping")

      {_, %{"id" => id}} = Utils.receive_event(5_000)
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 50

      Outbound.deliver(@server, session_id, id, {:ok, %{}})
      assert Task.await(task, 30_000) == {:ok, %{}}
      PostStream.close(stream)
    end

    test "goes to the GET stream once the stream of the request is closed",
         %{session_id: session_id} do
      {:ok, stream} = Utils.begin_stream(@server, session_id, 7, conn(:post, "/"), & &1)
      PostStream.close(stream)
      task = request_async(ctx(session_id, 7), "ping")

      {_, %{"id" => id}} = Utils.receive_event(5_000)

      Outbound.deliver(@server, session_id, id, {:ok, %{}})
      assert Task.await(task, 30_000) == {:ok, %{}}
    end

    test "sends the cancel notification of a timeout on the same stream",
         %{session_id: session_id} do
      {:ok, stream} = Utils.begin_stream(@server, session_id, 7, conn(:post, "/"), & &1)
      task = request_async(ctx(session_id, 7), "ping", nil, timeout: 30)

      assert {_, %{"method" => "ping", "id" => id}} = Utils.receive_event()
      capture_log(fn -> assert Task.await(task, 30_000) == {:error, :timeout} end)

      assert {_, %{"method" => "notifications/cancelled"} = cancelled} = Utils.receive_event()

      assert cancelled["params"]["requestId"] == id
      PostStream.close(stream)
    end

    test "a caller that owns the stream writes the request before the response (inline callback)",
         %{session_id: session_id} do
      #
      # An inline callback runs in the process that owns the stream: its
      # message waits in the mailbox and the answer writes it, before the
      # response, in the order the messages arrived.
      #
      _answerer =
        spawn_link(fn ->
          [id] = wait_pending(session_id)
          Outbound.deliver(@server, session_id, id, {:ok, %{}})
        end)

      {:ok, stream} = Utils.begin_stream(@server, session_id, 7, conn(:post, "/"), & &1)

      assert Outbound.ping(ctx(session_id, 7), timeout: 2_000) == {:ok, %{}}

      assert {{:streamed, conn}, _stream} =
               PostStream.answer(%{"jsonrpc" => "2.0", "id" => 7}, stream)

      assert [%{"method" => "ping"}, %{"id" => 7}] = sse_messages(conn.resp_body)
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 50
    end

    test "a caller that owns the stream writes the cancel notification of a timeout, in order",
         %{session_id: session_id} do
      {:ok, stream} = Utils.begin_stream(@server, session_id, 7, conn(:post, "/"), & &1)

      capture_log(fn ->
        assert Outbound.ping(ctx(session_id, 7), timeout: 30) == {:error, :timeout}
      end)

      assert {{:streamed, conn}, _stream} =
               PostStream.answer(%{"jsonrpc" => "2.0", "id" => 7}, stream)

      assert [%{"method" => "ping", "id" => id}, cancelled, %{"id" => 7}] =
               sse_messages(conn.resp_body)

      assert cancelled["method"] == "notifications/cancelled"
      assert cancelled["params"]["requestId"] == id
    end

    test "the messages that wait in the mailbox of the owner are written in order",
         %{session_id: session_id} do
      {:ok, stream} = Utils.begin_stream(@server, session_id, 7, conn(:post, "/"), & &1)

      :ok = Sessions.emit(@server, session_id, {:request, 7}, %{"method" => "queued"})
      :ok = Sessions.emit(@server, session_id, {:request, 7}, %{"method" => "last"})

      assert {{:streamed, conn}, _stream} = PostStream.answer(%{"id" => 7}, stream)

      assert [%{"method" => "queued"}, %{"method" => "last"}, _] = sse_messages(conn.resp_body)
    end
  end

  describe "abandon_waiter/4" do
    setup do
      %{session_id: session()}
    end

    test "tells the client to cancel the request the process waits for (GET stream)",
         %{session_id: session_id} do
      pid = spawn_waiting(ctx(session_id))
      [id] = wait_pending(session_id)
      {_, %{"method" => "ping", "id" => ^id}} = Utils.receive_event(5_000)

      assert Session.abandon_waiter(@server, session_id, pid, "gone") == :ok

      assert {_, %{"method" => "notifications/cancelled"} = cancelled} =
               Utils.receive_event(5_000)

      assert cancelled["params"] == %{"requestId" => id, "reason" => "gone"}
      assert cancelled["jsonrpc"] == "2.0"
      refute Map.has_key?(cancelled, "id")
    end

    test "uses the stream of the POST request when it has one", %{session_id: session_id} do
      {:ok, stream} = Utils.begin_stream(@server, session_id, 7, conn(:post, "/"), & &1)
      pid = spawn_waiting(ctx(session_id, 7))
      [id] = wait_pending(session_id)
      assert {_, %{"method" => "ping", "id" => ^id}} = Utils.receive_event(5_000)

      # Another process: the framework that stops a callback of this one.
      #
      Task.await(
        Task.async(fn -> Session.abandon_waiter(@server, session_id, pid, "stop") end),
        30_000
      )

      assert {_, %{"method" => "notifications/cancelled"} = cancelled} =
               Utils.receive_event(5_000)

      assert cancelled["params"] == %{"requestId" => id, "reason" => "stop"}
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 50
      PostStream.close(stream)
    end

    test "does nothing for a process that waits for nothing", %{session_id: session_id} do
      pid = spawn(fn -> Process.sleep(:infinity) end)

      assert Session.abandon_waiter(@server, session_id, pid, "gone") == :ok
      refute_receive {:oz_mcp_stream, _, {:event, _, _}}, 50
      assert SessionProbe.pending_outbound_ids(@server, session_id) == []
    end

    test "does not touch the requests of other processes", %{session_id: session_id} do
      mine = spawn_waiting(ctx(session_id))
      _other = spawn_waiting(ctx(session_id))
      [_, _] = wait_pending(session_id, 2)
      {_, %{"id" => _}} = Utils.receive_event(5_000)
      {_, %{"id" => _}} = Utils.receive_event(5_000)

      Session.abandon_waiter(@server, session_id, mine, "gone")

      assert {_, %{"method" => "notifications/cancelled"}} = Utils.receive_event(5_000)

      refute_receive {:oz_mcp_stream, _, {:event, _, %{"method" => "notifications/cancelled"}}},
                     100
    end
  end

  describe "request/4 - a context struct" do
    test "is accepted and uses the request id of the context" do
      session_id = session()

      context = %OzMcp.Context{
        instance: @server,
        server: @server_module,
        session_id: session_id,
        rpc_id: 5
      }

      {:ok, stream} = Utils.begin_stream(@server, session_id, 5, conn(:post, "/"), & &1)

      task = Task.async(fn -> Outbound.ping(context) end)

      assert {_, %{"id" => id}} = Utils.receive_event(5_000)
      Outbound.deliver(@server, session_id, id, {:ok, %{}})
      assert Task.await(task, 30_000) == {:ok, %{}}
      PostStream.close(stream)
    end
  end

  describe "request/4 - parameters that need a nested capability" do
    defp refused?(capabilities, method, params) do
      session_id = session(capabilities)

      Outbound.request(ctx(session_id), method, params, timeout: 50) ==
        {:error, :capability_not_supported}
    end

    test "elicitation modes" do
      form = %{mode: "form", message: "m"}
      form_string_keys = %{"mode" => "form"}
      url = %{mode: "url", message: "m"}
      url_string_keys = %{"mode" => "url"}
      no_mode = %{message: "m"}

      assert refused?(%{"elicitation" => %{"url" => %{}}}, "elicitation/create", form)
      assert refused?(%{"elicitation" => %{"url" => %{}}}, "elicitation/create", form_string_keys)
      assert refused?(%{"elicitation" => %{"url" => %{}}}, "elicitation/create", no_mode)
      assert refused?(%{"elicitation" => %{}}, "elicitation/create", url)
      assert refused?(%{"elicitation" => %{"form" => %{}}}, "elicitation/create", url_string_keys)
      assert refused?(%{"elicitation" => %{"url" => nil}}, "elicitation/create", url)

      refute refused?(%{"elicitation" => %{}}, "elicitation/create", form)
      refute refused?(%{"elicitation" => %{"form" => %{}}}, "elicitation/create", no_mode)
      refute refused?(%{"elicitation" => %{"url" => %{}}}, "elicitation/create", url)
      refute refused?(%{"elicitation" => %{"form" => nil}}, "elicitation/create", form)

      refute refused?(
               %{"elicitation" => %{"form" => %{}, "url" => %{}}},
               "elicitation/create",
               url
             )
    end

    test "sampling with tools, tool choice or context" do
      with_tools = %{messages: [], tools: [%{name: "t"}]}
      with_choice = %{"toolChoice" => %{"mode" => "auto"}}
      with_context = %{includeContext: "thisServer"}

      assert refused?(%{"sampling" => %{}}, "sampling/createMessage", with_tools)
      assert refused?(%{"sampling" => %{}}, "sampling/createMessage", with_choice)
      assert refused?(%{"sampling" => %{"tools" => %{}}}, "sampling/createMessage", with_context)

      assert refused?(%{"sampling" => %{}}, "sampling/createMessage", %{
               "includeContext" => "allServers"
             })

      refute refused?(%{"sampling" => %{"tools" => %{}}}, "sampling/createMessage", with_tools)

      refute refused?(
               %{"sampling" => %{"context" => %{}}},
               "sampling/createMessage",
               with_context
             )

      refute refused?(%{"sampling" => %{}}, "sampling/createMessage", %{messages: [], tools: []})
      refute refused?(%{"sampling" => %{}}, "sampling/createMessage", %{includeContext: "none"})
      refute refused?(%{"sampling" => %{}}, "sampling/createMessage", nil)
    end
  end

  describe "accepts?/3" do
    #
    # {label, capabilities, method, params, accepted?}
    #
    @cases [
      {"ping", %{}, "ping", nil, true},
      {"a method a server cannot send", %{}, "tools/call", nil, false},
      {"roots/list with roots", %{"roots" => %{}}, "roots/list", nil, true},
      {"roots/list without roots", %{}, "roots/list", nil, false},
      {"elicitation in form mode with an empty elicitation", %{"elicitation" => %{}},
       "elicitation/create", %{mode: "form", message: "m"}, true},
      {"elicitation in form mode with the form mode", %{"elicitation" => %{"form" => %{}}},
       "elicitation/create", %{mode: "form", message: "m"}, true},
      {"elicitation in form mode with the url mode only", %{"elicitation" => %{"url" => %{}}},
       "elicitation/create", %{mode: "form", message: "m"}, false},
      {"elicitation in url mode with the form mode only", %{"elicitation" => %{"form" => %{}}},
       "elicitation/create", %{mode: "url", message: "m"}, false},
      {"elicitation in url mode with the url mode", %{"elicitation" => %{"url" => %{}}},
       "elicitation/create", %{mode: "url", message: "m"}, true},
      {"sampling with tools and no sampling.tools", %{"sampling" => %{}},
       "sampling/createMessage", %{messages: [], tools: [%{name: "t"}]}, false},
      {"sampling with tools and sampling.tools", %{"sampling" => %{"tools" => %{}}},
       "sampling/createMessage", %{messages: [], tools: [%{name: "t"}]}, true},
      {"sampling with toolChoice and no sampling.tools", %{"sampling" => %{}},
       "sampling/createMessage", %{"toolChoice" => %{"mode" => "auto"}}, false},
      {"sampling with toolChoice and sampling.tools", %{"sampling" => %{"tools" => %{}}},
       "sampling/createMessage", %{"toolChoice" => %{"mode" => "auto"}}, true},
      {"sampling with includeContext thisServer and no sampling.context", %{"sampling" => %{}},
       "sampling/createMessage", %{includeContext: "thisServer"}, false},
      {"sampling with includeContext thisServer and sampling.context",
       %{"sampling" => %{"context" => %{}}}, "sampling/createMessage",
       %{includeContext: "thisServer"}, true},
      {"sampling with includeContext allServers and no sampling.context", %{"sampling" => %{}},
       "sampling/createMessage", %{includeContext: "allServers"}, false},
      {"sampling with includeContext allServers and sampling.context",
       %{"sampling" => %{"context" => %{}}}, "sampling/createMessage",
       %{includeContext: "allServers"}, true},
      {"sampling with includeContext none and no sampling.context", %{"sampling" => %{}},
       "sampling/createMessage", %{includeContext: "none"}, true},
      {"sampling with a task and no task capability", %{"sampling" => %{}},
       "sampling/createMessage", %{messages: [], task: %{ttl: 1_000}}, false},
      {"sampling with a task and the task capability",
       %{
         "sampling" => %{},
         "tasks" => %{"requests" => %{"sampling" => %{"createMessage" => %{}}}}
       }, "sampling/createMessage", %{messages: [], task: %{ttl: 1_000}}, true},
      {"elicitation with a task and the task capability",
       %{
         "elicitation" => %{},
         "tasks" => %{"requests" => %{"elicitation" => %{"create" => %{}}}}
       }, "elicitation/create", %{mode: "form", message: "m", task: %{ttl: 1_000}}, true},
      {"tasks/get with tasks", %{"tasks" => %{}}, "tasks/get", %{taskId: "c1"}, true},
      {"tasks/get without tasks", %{}, "tasks/get", %{taskId: "c1"}, false},
      {"tasks/result without tasks", %{}, "tasks/result", %{taskId: "c1"}, false},
      {"tasks/cancel with tasks only", %{"tasks" => %{}}, "tasks/cancel", %{taskId: "c1"}, false},
      {"tasks/cancel with tasks.cancel", %{"tasks" => %{"cancel" => %{}}}, "tasks/cancel",
       %{taskId: "c1"}, true}
    ]

    # A session with no GET stream: a request that the capabilities accept
    # fails at the route (:no_stream), a request that they refuse fails at
    # the capability checks.
    #
    defp accepted_by_request?(capabilities, method, params) do
      session_id =
        Utils.create_session(@server, initialized: true, client_capabilities: capabilities)

      case Outbound.request(ctx(session_id), method, params) do
        {:error, :no_stream} -> true
        {:error, reason} when reason in [:capability_not_supported, :unsupported_method] -> false
        other -> flunk("unexpected result of request/4: #{inspect(other)}")
      end
    end

    test "gives the same answer as the checks of request/4" do
      for {label, capabilities, method, params, accepted?} <- @cases do
        assert Outbound.accepts?(capabilities, method, params) == accepted?,
               "accepts?/3 disagrees for: #{label}"

        assert accepted_by_request?(capabilities, method, params) == accepted?,
               "request/4 disagrees for: #{label}"
      end
    end
  end

  describe "request/4 - a task" do
    alias OzMcp.Tasks

    # The ids of the requests of a task that wait for an answer: a request
    # of a task waits in the process of the task, not in the session.
    #
    defp wait_task_pending(task_id, count \\ 1) do
      assert Utils.eventually(fn ->
               length(Tasks.pending_request_ids(@server, task_id)) == count
             end)

      Tasks.pending_request_ids(@server, task_id)
    end

    # A task whose runner blocks: the requests of the tests are sent with the
    # ctx of this task (the process of the task holds them).
    #
    defp start_task(session_id) do
      Support.Entities.Tools.TaskSlowTest.use_instance(@server)

      {:ok, task} =
        Tasks.create(@server, %{
          session_id: session_id,
          tool: {Support.Entities.Tools.TaskSlowTest, "task_slow"},
          request: %{"name" => "task_slow", "arguments" => %{}},
          ttl: nil,
          progress_token: nil
        })

      task.taskId
    end

    defp task_status(session_id, task_id) do
      {:ok, task} = Tasks.get(@server, Utils.owner(session_id), task_id)
      task.status
    end

    # The test process plays the `tasks/result` request of the task: it owns a
    # stream and attaches to the task. What the runner sends arrives as a
    # message of the stream.
    #
    defp attach_task_events(session_id, task_id) do
      {:ok, capabilities} = Sessions.client_capabilities(@server, session_id)

      {:ok, stream} = Utils.begin_stream(@server, session_id, 99, conn(:post, "/"), & &1)

      {:attached, _task} =
        Tasks.attach(@server, Utils.owner(session_id), task_id, stream.stream_id, %{
          session_id: session_id,
          client_capabilities: capabilities
        })

      stream
    end

    # A process that plays a `tasks/result` request and sends to the test
    # process what its stream receives. The stream is registered in the
    # session, so the session can send it the events of the task.
    #
    defp attach_in_process(session_id, task_id, label) do
      parent = self()
      {:ok, capabilities} = Sessions.client_capabilities(@server, session_id)

      spawn_link(fn ->
        {:ok, stream} = Utils.begin_stream(@server, session_id, label, conn(:post, "/"), & &1)
        stream_id = stream.stream_id

        {:attached, _task} =
          Tasks.attach(@server, Utils.owner(session_id), task_id, stream_id, %{
            session_id: session_id,
            client_capabilities: capabilities
          })

        send(parent, {:attached, label})
        relay(parent, label, stream_id)
      end)

      assert_receive {:attached, ^label}, 5_000
    end

    defp relay(parent, label, stream_id) do
      receive do
        {:oz_mcp_stream, ^stream_id, {:event, _event_id, data}} ->
          send(parent, {:stream, label, :json.decode(data)})
          relay(parent, label, stream_id)
      end
    end

    # The GET stream gets the status notifications of the task, but never a
    # request or a cancel notice of the task.
    #
    defp refute_task_message_on_get do
      receive do
        {:oz_mcp_stream, _, {:event, _, data}} ->
          refute data =~ "roots/list" and data =~ "related-task"
          refute data =~ "notifications/cancelled"
          refute_task_message_on_get()
      after
        50 -> :ok
      end
    end

    # The next event of the stream of the attached `tasks/result` request.
    # The test process can serve the GET stream of the session too, whose
    # events carry another stream id.
    #
    defp stream_event(stream, timeout \\ 5_000) do
      stream_id = stream.stream_id

      receive do
        {:oz_mcp_stream, ^stream_id, {:event, _event_id, data}} ->
          {:event, data |> IO.iodata_to_binary() |> :json.decode()}
      after
        timeout -> flunk("no event received within #{timeout} ms")
      end
    end

    defp task_ctx(session_id, task_id), do: Map.put(ctx(session_id), :task_id, task_id)

    defp wait_status(session_id, task_id, status) do
      assert Utils.eventually(fn -> task_status(session_id, task_id) == status end)
      :ok
    end

    test "needs no GET stream: the task waits in input_required until the answer" do
      session_id = session(%{"roots" => %{}})
      task_id = start_task(session_id)

      task =
        Task.async(fn -> Outbound.request(task_ctx(session_id, task_id), "roots/list", nil) end)

      [id] = wait_task_pending(task_id)
      wait_status(session_id, task_id, :input_required)

      Tasks.deliver(@server, Utils.owner(session_id), nil, id, {:ok, %{"roots" => []}})
      assert Task.await(task, 30_000) == {:ok, %{"roots" => []}}
      wait_status(session_id, task_id, :working)
    end

    test "the request goes to the attached stream and carries the related-task meta" do
      session_id = session(%{"roots" => %{}})
      task_id = start_task(session_id)
      stream = attach_task_events(session_id, task_id)

      task =
        Task.async(fn -> Outbound.request(task_ctx(session_id, task_id), "roots/list", nil) end)

      assert {:event, %{"id" => id, "method" => "roots/list"} = message} =
               stream_event(stream)

      assert message["params"] == %{
               "_meta" => %{"io.modelcontextprotocol/related-task" => %{"taskId" => task_id}}
             }

      # Nothing goes to the GET stream.
      #
      refute_task_message_on_get()

      Tasks.deliver(@server, Utils.owner(session_id), nil, id, {:ok, %{"roots" => []}})
      assert {:ok, _} = Task.await(task, 30_000)
      PostStream.close(stream)
    end

    test "the meta is merged into the _meta of the params" do
      session_id = session(%{"elicitation" => %{}})
      task_id = start_task(session_id)
      stream = attach_task_events(session_id, task_id)

      params = %{mode: "form", message: "m", requestedSchema: %{}, _meta: %{"k" => "v"}}

      task =
        Task.async(fn ->
          Outbound.request(task_ctx(session_id, task_id), "elicitation/create", params)
        end)

      assert {:event, %{"id" => id, "params" => sent}} = stream_event(stream)

      assert sent["_meta"] == %{
               "k" => "v",
               "io.modelcontextprotocol/related-task" => %{"taskId" => task_id}
             }

      assert sent["message"] == "m"

      Tasks.deliver(@server, Utils.owner(session_id), nil, id, {:ok, %{"action" => "cancel"}})
      assert {:ok, _} = Task.await(task, 30_000)
      PostStream.close(stream)
    end

    test "a request without a task does not get the meta" do
      session_id = session(%{"roots" => %{}})

      task = Task.async(fn -> Outbound.request(ctx(session_id), "roots/list", nil) end)
      {_, %{"id" => id} = message} = Utils.receive_event(5_000)
      refute Map.has_key?(message, "params")

      Outbound.deliver(@server, session_id, id, {:ok, %{"roots" => []}})
      assert {:ok, _} = Task.await(task, 30_000)
    end

    test "the timeout tells an attached stream, not the GET stream" do
      session_id = session(%{"roots" => %{}})
      task_id = start_task(session_id)
      stream = attach_task_events(session_id, task_id)

      task =
        Task.async(fn ->
          Outbound.request(task_ctx(session_id, task_id), "roots/list", nil, timeout: 50)
        end)

      assert Task.await(task, 30_000) == {:error, :timeout}

      assert {:event, %{"method" => "roots/list", "id" => id}} = stream_event(stream)

      # The status change to input_required also reaches the attached
      # stream.
      #
      assert {:event, %{"method" => "notifications/tasks/status"}} = stream_event(stream)

      assert {:event,
              %{
                "method" => "notifications/cancelled",
                "params" => %{"requestId" => ^id} = params
              }} = stream_event(stream)

      assert params == %{
               "requestId" => id,
               "reason" => "the request ended",
               "_meta" => %{"io.modelcontextprotocol/related-task" => %{"taskId" => task_id}}
             }

      refute_task_message_on_get()
      wait_status(session_id, task_id, :working)
      PostStream.close(stream)
    end

    test "the timeout without an attached stream sends nothing" do
      session_id = session(%{"roots" => %{}})
      task_id = start_task(session_id)

      assert Outbound.request(task_ctx(session_id, task_id), "roots/list", nil, timeout: 50) ==
               {:error, :timeout}

      refute_task_message_on_get()
    end

    test "a stream that attaches later receives the request that waits" do
      session_id = session(%{"roots" => %{}})
      task_id = start_task(session_id)

      task =
        Task.async(fn -> Outbound.request(task_ctx(session_id, task_id), "roots/list", nil) end)

      [id] = wait_task_pending(task_id)

      # The stream of this process writes the held request when it attaches.
      #
      stream = attach_task_events(session_id, task_id)

      Tasks.deliver(@server, Utils.owner(session_id), nil, id, {:ok, %{"roots" => []}})
      assert {:ok, _} = Task.await(task, 30_000)

      assert {{:streamed, conn}, _stream} =
               PostStream.answer(%{"jsonrpc" => "2.0", "id" => 99, "result" => %{}}, stream)

      assert conn.resp_body =~ ~s("method":"roots/list")
      assert conn.resp_body =~ id
    end

    test "each attached stream receives the request one time" do
      session_id = session(%{"roots" => %{}})
      task_id = start_task(session_id)
      attach_in_process(session_id, task_id, "one")

      task =
        Task.async(fn -> Outbound.request(task_ctx(session_id, task_id), "roots/list", nil) end)

      [id] = wait_task_pending(task_id)
      attach_in_process(session_id, task_id, "two")

      assert_receive {:stream, "one", %{"id" => ^id}}, 5_000
      assert_receive {:stream, "two", %{"id" => ^id}}, 5_000

      # The status change to input_required reaches the streams that were
      # attached when it happened.
      #
      assert_receive {:stream, "one", %{"method" => "notifications/tasks/status"}}, 5_000
      refute_receive {:stream, _, _}, 50

      Tasks.deliver(@server, Utils.owner(session_id), nil, id, {:ok, %{"roots" => []}})
      assert {:ok, _} = Task.await(task, 30_000)
    end

    test "the status stays input_required until each request has its answer" do
      session_id = session(%{"roots" => %{}})
      task_id = start_task(session_id)

      first =
        Task.async(fn -> Outbound.request(task_ctx(session_id, task_id), "roots/list", nil) end)

      [id1] = wait_task_pending(task_id)

      second =
        Task.async(fn -> Outbound.request(task_ctx(session_id, task_id), "roots/list", nil) end)

      [id2] = wait_task_pending(task_id, 2) -- [id1]
      wait_status(session_id, task_id, :input_required)

      Tasks.deliver(@server, Utils.owner(session_id), nil, id1, {:ok, %{"roots" => []}})
      assert {:ok, _} = Task.await(first, 30_000)
      wait_task_pending(task_id, 1)
      assert task_status(session_id, task_id) == :input_required

      Tasks.deliver(@server, Utils.owner(session_id), nil, id2, {:ok, %{"roots" => []}})
      assert {:ok, _} = Task.await(second, 30_000)
      wait_status(session_id, task_id, :working)
    end

    test "a ping of a task does not change the status" do
      session_id = session()
      task_id = start_task(session_id)
      attach_in_process(session_id, task_id, "one")

      task = Task.async(fn -> Outbound.ping(task_ctx(session_id, task_id)) end)

      [id] = wait_task_pending(task_id)
      assert_receive {:stream, "one", %{"id" => ^id, "method" => "ping"}}, 5_000
      assert task_status(session_id, task_id) == :working

      Tasks.deliver(@server, Utils.owner(session_id), nil, id, {:ok, %{}})
      assert Task.await(task, 30_000) == {:ok, %{}}
      assert task_status(session_id, task_id) == :working
    end

    test "a task that does not run gives :no_task" do
      session_id = session(%{"roots" => %{}})

      assert Outbound.request(task_ctx(session_id, "unknown"), "roots/list", nil) ==
               {:error, :no_task}

      assert pending_ids(session_id) == []
    end

    test "capabilities are still checked" do
      session_id = session(%{"sampling" => %{}})
      task_id = start_task(session_id)

      assert Outbound.request(task_ctx(session_id, task_id), "roots/list", nil) ==
               {:error, :capability_not_supported}

      assert task_status(session_id, task_id) == :working
    end

    test "the end of the session ends the wait" do
      session_id = session(%{"roots" => %{}})
      task_id = start_task(session_id)

      task =
        Task.async(fn -> Outbound.request(task_ctx(session_id, task_id), "roots/list", nil) end)

      wait_task_pending(task_id)

      assert :ok = Sessions.terminate(@server, session_id)

      assert Task.await(task, 30_000) == {:error, :session_terminated}
    end
  end
end
