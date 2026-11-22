defmodule OzMcp.Transport.StdioTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias OzMcp.{Notify, PostStream, Sessions}
  alias OzMcp.Transport.Stdio
  alias OzMcp.Transport.Stdio.{Outcome, Request}
  alias Support.Helpers.{SessionLeak, SessionProbe}
  alias Support.Helpers.Utils
  alias Support.Servers

  @version "2025-11-25"
  @client_info %{"name" => "stdio-test", "version" => "1.0.0"}

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp start_runtime(servers) do
    start_supervised!(Utils.runtime_spec(%{transport: :stdio, servers: servers}))
  end

  defp start_transport(server, extra \\ []) do
    pipe = start_supervised!({Support.Helpers.StdioPipe, nil})

    # `restart: :temporary`: a test that ends the transport on purpose must
    # not get a new one. The test supervisor would restart it and the new
    # reader would read the pipe that still holds the pending read of the
    # old reader: the pipe crashes and the new transport logs "the stdin
    # reader failed".
    #
    transport =
      start_supervised!(
        Supervisor.child_spec(
          {Stdio,
           [
             server: server,
             read: Support.Helpers.StdioPipe.reader(pipe),
             write: Support.Helpers.StdioPipe.writer(pipe)
           ] ++
             extra},
          restart: :temporary
        )
      )

    %{pipe: pipe, transport: transport}
  end

  defp start_session(server, capabilities \\ %{}) do
    start_runtime([server])
    %{pipe: pipe} = start_transport(server)
    handshake(pipe, capabilities)
    %{pipe: pipe}
  end

  defp initialize_request(id, capabilities \\ %{}) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @version,
        "clientInfo" => @client_info,
        "capabilities" => capabilities
      }
    }
  end

  defp handshake(pipe, capabilities \\ %{}) do
    Support.Helpers.StdioPipe.send_line(pipe, initialize_request(1, capabilities))
    init = Support.Helpers.StdioPipe.recv(pipe)

    Support.Helpers.StdioPipe.send_line(pipe, %{
      "jsonrpc" => "2.0",
      "method" => "notifications/initialized"
    })

    init
  end

  defp send_request(pipe, id, method, params \\ %{}) do
    Support.Helpers.StdioPipe.send_line(pipe, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    })
  end

  defp assert_result(pipe, id) do
    assert %{"id" => ^id, "result" => result} = Support.Helpers.StdioPipe.recv(pipe)
    result
  end

  defp assert_error(pipe, id, code) do
    assert %{"id" => ^id, "error" => %{"code" => ^code}} = Support.Helpers.StdioPipe.recv(pipe)
  end

  # Reads lines until one matches, drops the ones before it. For a message
  # the transport writes while other messages flow.
  #
  defp recv_matching(pipe, fun, timeout \\ 10_000) do
    deadline = deadline(timeout)

    case next_line(pipe, deadline) do
      {:ok, message} ->
        if fun.(message), do: message, else: recv_matching(pipe, fun, remaining(deadline))

      :timeout ->
        flunk(
          "no matching line before the deadline, got: #{inspect(Support.Helpers.StdioPipe.lines(pipe))}"
        )
    end
  end

  # Reads lines until one matches and returns the ones read before it, in
  # order. For the tests that pin what came before a response.
  #
  defp collect_until(pipe, fun, timeout \\ 10_000) do
    deadline = deadline(timeout)
    do_collect(pipe, fun, deadline, [])
  end

  defp do_collect(pipe, fun, deadline, acc) do
    case next_line(pipe, deadline) do
      {:ok, message} ->
        if fun.(message) do
          {Enum.reverse(acc), message}
        else
          do_collect(pipe, fun, deadline, [message | acc])
        end

      :timeout ->
        flunk("no matching line before the deadline")
    end
  end

  defp next_line(pipe, deadline) do
    case Support.Helpers.StdioPipe.recv(pipe, 50) do
      :timeout ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: :timeout,
          else: next_line(pipe, deadline)

      message ->
        {:ok, message}
    end
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 1)

  defp wait_until(fun, timeout \\ 15_000) do
    if Utils.eventually(fn -> fun.() != nil end, timeout) do
      fun.()
    else
      flunk("condition was not met in time")
    end
  end

  defp session_id(server) do
    case Utils.sessions(server) do
      [{session_id, _session}] -> session_id
      _ -> nil
    end
  end

  # The runtime that `run/2` starts itself is not a child of the test
  # supervisor: it ends with the task that called run/2. This helper is
  # the safety net of a test that failed before that end.
  #
  defp stop_runtime do
    case Process.whereis(Utils.Runtime) do
      nil -> :ok
      pid -> Supervisor.stop(pid)
    end
  catch
    :exit, _reason -> :ok
  end

  # The children that the request runner of the transport runs now. The
  # read must happen before the transport stops: the stop kills that
  # supervisor, so a read after the stop raises.
  #
  defp running_children(transport) do
    case :sys.get_state(transport) do
      %{tasks: tasks} when is_pid(tasks) -> Task.Supervisor.children(tasks)
      _ -> []
    end
  end

  # -------------------------------------------------------------------
  # Lifecycle
  # -------------------------------------------------------------------

  describe "lifecycle" do
    test "initialize creates one session whose stream is the writer" do
      start_runtime([Servers.Default])
      %{pipe: pipe} = start_transport(Servers.Default)

      # The first state is read before `notifications/initialized` is sent:
      # after it the session can be initialized already.
      #
      Support.Helpers.StdioPipe.send_line(pipe, initialize_request(1))
      assert %{"id" => 1, "result" => result} = Support.Helpers.StdioPipe.recv(pipe)
      assert result["protocolVersion"] == @version
      assert is_map(result["capabilities"])
      assert result["serverInfo"]["name"] == "ts-default-test"

      sessions = Utils.sessions(Servers.Default)
      assert length(sessions) == 1
      [{session_id, _session}] = sessions

      assert {:ok, %{initialized: false, stream?: true}} =
               Sessions.delivery(Servers.Default, session_id)

      assert {:ok, %{protocol_version: @version, client_capabilities: %{}}} =
               Sessions.state(Servers.Default, session_id)

      Support.Helpers.StdioPipe.send_line(pipe, %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized"
      })

      wait_until(fn ->
        if SessionProbe.initialized?(Servers.Default, session_id), do: :ok
      end)
    end

    @tag :capture_log
    test "a session that gets no notifications/initialized stops after session_init_timeout_ms" do
      start_runtime([{Servers.Default, %{session_init_timeout_ms: 300}}])
      %{pipe: pipe, transport: transport} = start_transport(Servers.Default)

      Support.Helpers.StdioPipe.send_line(pipe, initialize_request(1))
      assert %{"id" => 1, "result" => _} = Support.Helpers.StdioPipe.recv(pipe)

      session_id = session_id(Servers.Default)

      ref = Process.monitor(transport)

      log =
        capture_log(fn ->
          assert_receive {:DOWN, ^ref, :process, ^transport, {:shutdown, :init_timeout}}, 10_000
        end)

      assert log =~ "notifications/initialized"
      assert log =~ "session_init_timeout_ms"

      wait_until(fn ->
        Sessions.lookup(Servers.Default, session_id) == {:error, :no_session}
      end)
    end

    test "the session keeps the protocol version, the client info and the capabilities of initialize" do
      start_runtime([Servers.Default])
      %{pipe: pipe} = start_transport(Servers.Default)

      Support.Helpers.StdioPipe.send_line(
        pipe,
        initialize_request(1, %{"roots" => %{"listChanged" => true}})
      )

      assert %{"id" => 1, "result" => %{"protocolVersion" => @version}} =
               Support.Helpers.StdioPipe.recv(pipe)

      [{session_id, _session}] = Utils.sessions(Servers.Default)

      assert {:ok, %{protocol_version: @version}} =
               Sessions.state(Servers.Default, session_id)

      assert {:ok, view} = Sessions.lookup(Servers.Default, session_id)
      assert view.client_info == @client_info
      assert view.client_capabilities == %{"roots" => %{"listChanged" => true}}
    end

    test "ping is answered with an empty result before initialize, any other request waits for it" do
      start_runtime([Servers.Default])
      %{pipe: pipe} = start_transport(Servers.Default)

      send_request(pipe, 1, "ping")
      assert assert_result(pipe, 1) == %{}

      send_request(pipe, 2, "tools/list")

      assert %{
               "id" => 2,
               "error" => %{"code" => -32600, "message" => "waiting session initialization"}
             } =
               Support.Helpers.StdioPipe.recv(pipe)
    end

    test "requests wait for notifications/initialized" do
      start_runtime([Servers.Default])
      %{pipe: pipe} = start_transport(Servers.Default)

      Support.Helpers.StdioPipe.send_line(pipe, initialize_request(1))
      assert %{"result" => _} = Support.Helpers.StdioPipe.recv(pipe)

      send_request(pipe, 2, "tools/list")
      assert_error(pipe, 2, -32600)

      Support.Helpers.StdioPipe.send_line(pipe, %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized"
      })

      send_request(pipe, 3, "tools/list")

      assert %{"tools" => tools} = assert_result(pipe, 3)
      assert length(tools) == 2
    end

    test "a duplicate notifications/initialized writes no line and no warning" do
      start_runtime([Servers.Default])
      %{pipe: pipe} = start_transport(Servers.Default)
      handshake(pipe)

      log =
        capture_log(fn ->
          Support.Helpers.StdioPipe.send_line(pipe, %{
            "jsonrpc" => "2.0",
            "method" => "notifications/initialized"
          })

          assert :timeout = Support.Helpers.StdioPipe.recv(pipe, 200)
        end)

      refute log =~ "stdio notification refused"
      assert [] = Support.Helpers.StdioPipe.lines(pipe)

      # The session stays alive and initialized.
      #
      send_request(pipe, 2, "tools/list")
      assert %{"tools" => _} = assert_result(pipe, 2)
    end

    test "a second initialize is refused and the first session stays" do
      start_runtime([Servers.Default])
      %{pipe: pipe} = start_transport(Servers.Default)

      handshake(pipe)
      assert length(Utils.sessions(Servers.Default)) == 1

      Support.Helpers.StdioPipe.send_line(pipe, initialize_request(2))

      assert %{
               "id" => 2,
               "error" => %{"code" => -32600, "message" => "session already initialized"}
             } =
               Support.Helpers.StdioPipe.recv(pipe)

      assert length(Utils.sessions(Servers.Default)) == 1
    end

    test "initialize with a bad protocol version or client info creates no session" do
      start_runtime([Servers.Default])
      %{pipe: pipe} = start_transport(Servers.Default)

      Support.Helpers.StdioPipe.send_line(pipe, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{"protocolVersion" => "", "clientInfo" => @client_info}
      })

      assert_error(pipe, 1, -32602)

      Support.Helpers.StdioPipe.send_line(pipe, %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "initialize",
        "params" => %{"protocolVersion" => @version, "clientInfo" => %{"name" => "x"}}
      })

      assert_error(pipe, 2, -32602)
      assert Utils.sessions(Servers.Default) == []
    end

    test "an initialize of a full runtime gets a too many sessions line" do
      start_runtime([{Servers.Default, %{max_sessions: 1}}])

      # The first transport takes the only slot.
      #
      %{pipe: pipe1} = start_transport(Servers.Default)
      assert %{"id" => 1, "result" => _} = handshake(pipe1)

      # The second transport gets the refusal of the limit.
      #
      pipe2 =
        start_supervised!(
          Supervisor.child_spec({Support.Helpers.StdioPipe, nil}, id: :pipe_full_runtime)
        )

      _transport2 =
        start_supervised!(
          Supervisor.child_spec(
            {Stdio,
             [
               server: Servers.Default,
               read: Support.Helpers.StdioPipe.reader(pipe2),
               write: Support.Helpers.StdioPipe.writer(pipe2)
             ]},
            id: :transport_full_runtime
          )
        )

      Support.Helpers.StdioPipe.send_line(pipe2, initialize_request(1))

      assert %{"id" => 1, "error" => %{"code" => -32000, "message" => "too many sessions"}} =
               Support.Helpers.StdioPipe.recv(pipe2)

      assert length(Utils.sessions(Servers.Default)) == 1
    end
  end

  # -------------------------------------------------------------------
  # Framing
  # -------------------------------------------------------------------

  describe "framing" do
    test "a line that is not JSON, an array, a number, an empty line" do
      start_runtime([Servers.Default])
      %{pipe: pipe} = start_transport(Servers.Default)

      Support.Helpers.StdioPipe.send_line(pipe, "not json")
      assert %{"error" => %{"code" => -32700}} = message = Support.Helpers.StdioPipe.recv(pipe)
      refute Map.has_key?(message, "id")

      Support.Helpers.StdioPipe.send_line(pipe, "[1, 2]")

      assert %{"error" => %{"code" => -32600, "message" => "batching is not supported"}} =
               Support.Helpers.StdioPipe.recv(pipe)

      Support.Helpers.StdioPipe.send_line(pipe, "42")

      assert %{"error" => %{"code" => -32600, "message" => "invalid request"}} =
               Support.Helpers.StdioPipe.recv(pipe)

      send_request(pipe, 1, "ping")
      assert_result(pipe, 1)
    end

    test "a line with a number of more than 100 characters gets -32700 and the next line runs" do
      start_runtime([Servers.Default])
      %{pipe: pipe} = start_transport(Servers.Default)

      long = String.duplicate("7", 1_000)

      bad =
        ~s({"jsonrpc":"2.0","id":1,"method":"ping","params":{"_meta":{"n":#{long}}}})

      log =
        capture_log(fn ->
          Support.Helpers.StdioPipe.send_line(pipe, bad)

          assert %{"error" => %{"code" => -32700, "message" => "parse error"}} =
                   message = Support.Helpers.StdioPipe.recv(pipe)

          refute Map.has_key?(message, "id")
        end)

      refute log =~ long

      send_request(pipe, 2, "ping")
      assert_result(pipe, 2)
    end

    test "a line that is the JSON value null is a scalar, answered with one error line" do
      start_runtime([Servers.Default])
      %{pipe: pipe} = start_transport(Servers.Default)

      Support.Helpers.StdioPipe.send_line(pipe, "null")

      assert %{"error" => %{"code" => -32600, "message" => "invalid request"}} =
               message = Support.Helpers.StdioPipe.recv(pipe)

      refute Map.has_key?(message, "id")

      send_request(pipe, 1, "ping")
      assert_result(pipe, 1)
    end

    test "an id of null on a notification method gets one -32600 line, with no id" do
      start_runtime([Servers.Default])
      %{pipe: pipe} = start_transport(Servers.Default)

      Support.Helpers.StdioPipe.send_line(
        pipe,
        ~s({"jsonrpc":"2.0","id":null,"method":"notifications/initialized"})
      )

      assert %{"error" => %{"code" => -32600, "message" => "invalid request"}} =
               message = Support.Helpers.StdioPipe.recv(pipe)

      refute Map.has_key?(message, "id")
      assert Support.Helpers.StdioPipe.recv(pipe, 100) == :timeout

      send_request(pipe, 1, "ping")
      assert_result(pipe, 1)
    end

    test "a line that ends with a carriage return and a newline works" do
      start_runtime([Servers.Default])
      %{pipe: pipe} = start_transport(Servers.Default)

      Support.Helpers.StdioPipe.send_line(
        pipe,
        ~s({"jsonrpc":"2.0","id":1,"method":"ping"}) <> "\r"
      )

      assert_result(pipe, 1)
    end

    test "a request with no id is refused without an id, an unknown notification is silent" do
      start_runtime([Servers.Default])
      %{pipe: pipe} = start_transport(Servers.Default)

      Support.Helpers.StdioPipe.send_line(pipe, %{"jsonrpc" => "2.0", "method" => "tools/list"})
      assert %{"error" => %{"code" => -32600}} = message = Support.Helpers.StdioPipe.recv(pipe)
      refute Map.has_key?(message, "id")

      Support.Helpers.StdioPipe.send_line(pipe, %{
        "jsonrpc" => "2.0",
        "method" => "notifications/no_such"
      })

      assert Support.Helpers.StdioPipe.recv(pipe, 100) == :timeout

      send_request(pipe, 1, "ping")
      assert_result(pipe, 1)
    end

    test "an error response of the client with no id is silent" do
      start_runtime([Servers.Default])
      %{pipe: pipe} = start_transport(Servers.Default)

      error = %{"code" => -32601, "message" => "nope"}

      # No id member at all.
      #
      Support.Helpers.StdioPipe.send_line(pipe, %{"jsonrpc" => "2.0", "error" => error})
      assert Support.Helpers.StdioPipe.recv(pipe, 100) == :timeout

      # An id of null: the decoder gives nil for a JSON null.
      #
      Support.Helpers.StdioPipe.send_line(pipe, %{
        "jsonrpc" => "2.0",
        "id" => nil,
        "error" => error
      })

      assert Support.Helpers.StdioPipe.recv(pipe, 100) == :timeout

      send_request(pipe, 1, "ping")
      assert_result(pipe, 1)
    end

    test "a response of the client that is not valid gets no line" do
      start_runtime([Servers.Default])
      %{pipe: pipe} = start_transport(Servers.Default)

      lines = [
        %{"jsonrpc" => "2.0", "result" => %{}},
        %{"jsonrpc" => "2.0", "error" => %{"code" => "x", "message" => "m"}},
        %{"jsonrpc" => "2.0", "id" => "srv-1", "result" => 5},
        %{
          "jsonrpc" => "2.0",
          "id" => "srv-1",
          "result" => %{},
          "error" => %{"code" => 1, "message" => "x"}
        }
      ]

      log =
        capture_log(fn ->
          for line <- lines do
            Support.Helpers.StdioPipe.send_line(pipe, line)
            assert Support.Helpers.StdioPipe.recv(pipe, 100) == :timeout
          end
        end)

      assert log =~ "stdio response of the client refused: :rpc_invalid_request"

      send_request(pipe, 1, "ping")
      assert_result(pipe, 1)
    end

    test "a notification method with an id gets one line with -32601 and the id" do
      start_runtime([Servers.Default])
      %{pipe: pipe} = start_transport(Servers.Default)

      Support.Helpers.StdioPipe.send_line(pipe, %{
        "jsonrpc" => "2.0",
        "id" => 7,
        "method" => "notifications/no_such"
      })

      assert %{"id" => 7, "error" => %{"code" => -32601, "message" => "method not found"}} =
               Support.Helpers.StdioPipe.recv(pipe)

      assert Support.Helpers.StdioPipe.recv(pipe, 100) == :timeout

      send_request(pipe, 1, "ping")
      assert_result(pipe, 1)
    end

    test "every line of stdout is one valid UTF-8 JSON line" do
      start_runtime([Servers.Outbound])
      %{pipe: pipe} = start_transport(Servers.Outbound)
      handshake(pipe, %{"sampling" => %{}})

      send_request(pipe, 2, "tools/call", %{
        "name" => "outbound",
        "arguments" => %{"feature" => "sample"}
      })

      sampling = recv_matching(pipe, &match?(%{"method" => "sampling/createMessage"}, &1))

      Support.Helpers.StdioPipe.send_line(pipe, %{
        "jsonrpc" => "2.0",
        "id" => sampling["id"],
        "result" => %{
          "role" => "assistant",
          "content" => %{"type" => "text", "text" => "première\nligne"},
          "model" => "model-1",
          "stopReason" => "endTurn"
        }
      })

      lines =
        wait_until(fn ->
          lines = Support.Helpers.StdioPipe.lines(pipe)
          if Enum.any?(lines, &String.contains?(&1, "è")), do: lines
        end)

      assert length(lines) == 1
      [line] = lines
      assert String.valid?(line)
      trimmed = String.trim_trailing(line, "\n")
      refute String.contains?(trimmed, "\n")

      response = :json.decode(trimmed)
      assert response["jsonrpc"] == "2.0"
      assert [%{"text" => text}] = response["result"]["content"]
      #
      # The text of the tool went through inspect: the newline is escaped.
      #
      assert text =~ "première"
      assert text =~ "\\nligne"

      assert_result(pipe, 2)
    end
  end

  # -------------------------------------------------------------------
  # Requests
  # -------------------------------------------------------------------

  describe "requests" do
    test "tools/list, tools/call and resources/read answer like the HTTP router" do
      start_runtime([Servers.Default])
      %{pipe: pipe} = start_transport(Servers.Default)
      handshake(pipe)

      send_request(pipe, "a", "tools/list")
      assert %{"tools" => tools} = assert_result(pipe, "a")
      assert Enum.map(tools, & &1["name"]) == ["get_date", "get_time"]

      send_request(pipe, 7, "tools/call", %{"name" => "get_date"})
      assert %{"content" => [%{"text" => "22/11/2025"}]} = assert_result(pipe, 7)

      send_request(pipe, 8, "resources/read", %{"uri" => "file:///marketing.md"})

      assert %{"contents" => [%{"text" => "# Marketing rules"}]} =
               assert_result(pipe, 8)
    end

    test "a request in its own process leaves no request or stream entry" do
      start_runtime([Servers.Default])
      %{pipe: pipe} = start_transport(Servers.Default)
      handshake(pipe)

      send_request(pipe, 7, "tools/call", %{"name" => "get_date"})
      assert %{"content" => [_ | _]} = assert_result(pipe, 7)

      session_id = session_id(Servers.Default)
      assert {:ok, view} = Sessions.lookup(Servers.Default, session_id)

      snap = SessionLeak.snapshot(view.pid)
      assert snap.requests == 0
      assert snap.streams == 0
    end

    test "prompts/get answers like the HTTP router" do
      %{pipe: pipe} = start_session(Servers.WithPrompts)

      send_request(pipe, 1, "prompts/get", %{
        "name" => "code_review",
        "arguments" => %{"language" => "elixir"}
      })

      assert %{"messages" => [%{"content" => %{"text" => "Review this code."}}]} =
               assert_result(pipe, 1)
    end

    test "completion/complete answers like the HTTP router" do
      %{pipe: pipe} = start_session(Servers.Completions)

      send_request(pipe, 1, "completion/complete", %{
        "ref" => %{"type" => "ref/prompt", "name" => "code_review"},
        "argument" => %{"name" => "language", "value" => "e"}
      })

      assert %{"completion" => %{"values" => ["elixir", "python"]}} =
               assert_result(pipe, 1)
    end

    test "an unknown tool gives -32602, bad arguments give the isError result" do
      %{pipe: pipe} = start_session(Servers.Scoped)

      send_request(pipe, 1, "tools/call", %{"name" => "no_such_tool", "arguments" => %{}})
      assert_error(pipe, 1, -32602)

      send_request(pipe, 2, "tools/call", %{"name" => "read_file", "arguments" => %{}})
      assert %{"isError" => true} = assert_result(pipe, 2)
    end
  end

  # -------------------------------------------------------------------
  # Concurrency and ordering
  # -------------------------------------------------------------------

  describe "concurrency and ordering" do
    test "a sampling round trip does not block the transport" do
      start_runtime([Servers.Outbound])
      %{pipe: pipe} = start_transport(Servers.Outbound)
      handshake(pipe, %{"sampling" => %{}})

      send_request(pipe, 2, "tools/call", %{
        "name" => "outbound",
        "arguments" => %{"feature" => "sample"}
      })

      sampling = recv_matching(pipe, &match?(%{"method" => "sampling/createMessage"}, &1))
      assert sampling["params"]["maxTokens"] == 50

      # The reader is free while the callback waits for the client.
      #
      send_request(pipe, 3, "ping")
      assert_result(pipe, 3)

      Support.Helpers.StdioPipe.send_line(pipe, %{
        "jsonrpc" => "2.0",
        "id" => sampling["id"],
        "result" => %{
          "role" => "assistant",
          "content" => %{"type" => "text", "text" => "Hello!"},
          "model" => "model-1",
          "stopReason" => "endTurn"
        }
      })

      assert %{"content" => [%{"text" => text}]} = assert_result(pipe, 2)
      assert text =~ "model-1"
      assert text =~ "endTurn"
    end

    test "a form elicitation round trip" do
      start_runtime([Servers.Outbound])
      %{pipe: pipe} = start_transport(Servers.Outbound)
      handshake(pipe, %{"elicitation" => %{}})

      send_request(pipe, 2, "tools/call", %{
        "name" => "outbound",
        "arguments" => %{"feature" => "elicit_form"}
      })

      elicit = recv_matching(pipe, &match?(%{"method" => "elicitation/create"}, &1))
      assert elicit["params"]["message"] == "Who are you?"
      assert elicit["params"]["requestedSchema"]["required"] == ["name"]

      Support.Helpers.StdioPipe.send_line(pipe, %{
        "jsonrpc" => "2.0",
        "id" => elicit["id"],
        "result" => %{"action" => "accept", "content" => %{"name" => "Ana", "age" => 30}}
      })

      assert %{"content" => [%{"text" => text}]} = assert_result(pipe, 2)
      assert text =~ "action: :accept"
      assert text =~ "Ana"
    end

    test "a roots round trip" do
      start_runtime([Servers.Outbound])
      %{pipe: pipe} = start_transport(Servers.Outbound)
      handshake(pipe, %{"roots" => %{}})

      send_request(pipe, 2, "tools/call", %{
        "name" => "outbound",
        "arguments" => %{"feature" => "roots"}
      })

      roots = recv_matching(pipe, &match?(%{"method" => "roots/list"}, &1))

      Support.Helpers.StdioPipe.send_line(pipe, %{
        "jsonrpc" => "2.0",
        "id" => roots["id"],
        "result" => %{"roots" => [%{"uri" => "file:///work", "name" => "work"}]}
      })

      assert %{"content" => [%{"text" => text}]} = assert_result(pipe, 2)
      assert text =~ "file:///work"
    end

    test "the progress notifications of a request come before its response" do
      start_runtime([Servers.Outbound])
      %{pipe: pipe} = start_transport(Servers.Outbound)
      handshake(pipe)

      send_request(pipe, 2, "tools/call", %{
        "name" => "progress",
        "arguments" => %{},
        "_meta" => %{"progressToken" => "tok-1"}
      })

      {before, response} = collect_until(pipe, &match?(%{"id" => 2}, &1))

      assert response["result"]["content"] == [%{"type" => "text", "text" => "progress done"}]
      assert length(before) == 2
      assert Enum.all?(before, &(&1["method"] == "notifications/progress"))
      assert Enum.all?(before, &(&1["params"]["progressToken"] == "tok-1"))
    end

    test "a cancelled call gets the notification of the server request and -32800" do
      start_runtime([Servers.Outbound])
      %{pipe: pipe} = start_transport(Servers.Outbound)
      handshake(pipe)

      send_request(pipe, 2, "tools/call", %{
        "name" => "outbound",
        "arguments" => %{"method" => "ping", "timeout" => 30_000}
      })

      ping = recv_matching(pipe, &match?(%{"method" => "ping"}, &1))

      Support.Helpers.StdioPipe.send_line(pipe, %{
        "jsonrpc" => "2.0",
        "method" => "notifications/cancelled",
        "params" => %{"requestId" => 2, "reason" => "not needed"}
      })

      cancelled = recv_matching(pipe, &match?(%{"method" => "notifications/cancelled"}, &1))
      assert cancelled["params"]["requestId"] == ping["id"]

      assert %{"id" => 2, "error" => %{"code" => -32800}} = Support.Helpers.StdioPipe.recv(pipe)
    end

    test "a task asks the client through the stream of the tasks/result request" do
      start_runtime([Servers.Outbound])
      %{pipe: pipe} = start_transport(Servers.Outbound)
      handshake(pipe, %{"elicitation" => %{}})

      send_request(pipe, 2, "tools/call", %{
        "name" => "outbound",
        "arguments" => %{"feature" => "elicit_form"},
        "task" => %{}
      })

      created =
        recv_matching(pipe, fn
          %{"id" => 2, "result" => %{"task" => %{"taskId" => _}}} -> true
          _ -> false
        end)

      %{"task" => %{"taskId" => task_id}} = created["result"]

      send_request(pipe, 3, "tasks/result", %{"taskId" => task_id})

      elicit = recv_matching(pipe, &match?(%{"method" => "elicitation/create"}, &1))

      assert elicit["params"]["_meta"]["io.modelcontextprotocol/related-task"]["taskId"] ==
               task_id

      Support.Helpers.StdioPipe.send_line(pipe, %{
        "jsonrpc" => "2.0",
        "id" => elicit["id"],
        "result" => %{"action" => "accept", "content" => %{"name" => "Ana"}}
      })

      {before, result_response} =
        collect_until(pipe, fn
          %{"id" => 3, "result" => _} -> true
          _ -> false
        end)

      assert [%{"text" => text}] = result_response["result"]["content"]
      assert text =~ "action: :accept"

      assert result_response["result"]["_meta"]["io.modelcontextprotocol/related-task"]["taskId"] ==
               task_id

      # The statuses of the task travel on the session stream: the order
      # between the two writers is not defined, so the status waits either
      # before the response or after it.
      #
      status =
        Enum.find(before, &match?(%{"method" => "notifications/tasks/status"}, &1)) ||
          recv_matching(pipe, &match?(%{"method" => "notifications/tasks/status"}, &1))

      assert is_map(status["params"])
    end

    test "a slow task returns the result on tasks/result without heartbeat lines" do
      start_runtime([{Servers.Outbound, %{sse_heartbeat_ms: 100}}])
      %{pipe: pipe} = start_transport(Servers.Outbound)
      handshake(pipe, %{"elicitation" => %{}})

      send_request(pipe, 2, "tools/call", %{
        "name" => "outbound",
        "arguments" => %{"method" => "ping", "delay" => 250},
        "task" => %{}
      })

      created =
        recv_matching(pipe, fn
          %{"id" => 2, "result" => %{"task" => %{"taskId" => _}}} -> true
          _ -> false
        end)

      %{"task" => %{"taskId" => task_id}} = created["result"]

      # The tasks/result request waits for the task to end.
      #
      send_request(pipe, 3, "tasks/result", %{"taskId" => task_id})

      # The task sends its ping after the delay.
      #
      ping = recv_matching(pipe, &match?(%{"method" => "ping"}, &1))

      Support.Helpers.StdioPipe.send_line(pipe, %{
        "jsonrpc" => "2.0",
        "id" => ping["id"],
        "result" => %{}
      })

      result_response =
        recv_matching(pipe, fn
          %{"id" => 3, "result" => _} -> true
          _ -> false
        end)

      assert result_response["result"]["_meta"]["io.modelcontextprotocol/related-task"]["taskId"] ==
               task_id

      # No SSE heartbeat comment leaks on stdout.
      #
      refute Enum.any?(Support.Helpers.StdioPipe.lines(pipe), fn line ->
               is_binary(line) and line =~ "heartbeat"
             end)
    end

    test "two requests in flight: the one that waits does not block the other" do
      start_runtime([Servers.Outbound])
      %{pipe: pipe} = start_transport(Servers.Outbound)
      handshake(pipe)

      send_request(pipe, 2, "tools/call", %{
        "name" => "outbound",
        "arguments" => %{"method" => "ping", "timeout" => 30_000}
      })

      send_request(pipe, 3, "tools/list")

      {before, _} = collect_both(pipe)

      # The order of the two writers is not defined, but both lines are
      # there and the call that waits for the client has no answer yet.
      #
      assert Enum.any?(before, &match?(%{"method" => "ping"}, &1))
      assert Enum.any?(before, &match?(%{"id" => 3, "result" => _}, &1))
      refute Enum.any?(before, &match?(%{"id" => 2}, &1))

      ping = Enum.find(before, &match?(%{"method" => "ping"}, &1))

      Support.Helpers.StdioPipe.send_line(pipe, %{
        "jsonrpc" => "2.0",
        "id" => ping["id"],
        "result" => %{}
      })

      assert_result(pipe, 2)
    end

    test "the session state of the next request follows notifications/initialized" do
      start_runtime([Servers.Default])
      %{pipe: pipe} = start_transport(Servers.Default)

      Support.Helpers.StdioPipe.send_line(pipe, initialize_request(1))
      assert %{"result" => _} = Support.Helpers.StdioPipe.recv(pipe)

      Support.Helpers.StdioPipe.send_line(pipe, %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized"
      })

      send_request(pipe, 2, "tools/list")

      assert %{"tools" => _} = assert_result(pipe, 2)
    end
  end

  # -------------------------------------------------------------------
  # The id of a refused request
  # -------------------------------------------------------------------

  test "an unknown tool is refused once with -32602 and the id is free again" do
    %{pipe: pipe} = start_session(Servers.ToolsOnly)

    send_request(pipe, 1, "tools/call", %{"name" => "no_such_tool", "arguments" => %{}})
    assert_error(pipe, 1, -32602)

    # The refusal closed the request in the session: the id is free.
    #
    send_request(pipe, 1, "tools/call", %{"name" => "get_date", "arguments" => %{}})
    assert_result(pipe, 1)
  end

  # Collects lines until both the request of the server and the answer of
  # tools/list have been seen: the order of the two writers is not defined.
  #
  defp collect_both(pipe, timeout \\ 10_000) do
    do_collect_both(pipe, deadline(timeout), [], false, false)
  end

  defp do_collect_both(pipe, deadline, acc, ping?, list?) do
    case next_line(pipe, deadline) do
      {:ok, message} ->
        acc = [message | acc]
        ping? = ping? or match?(%{"method" => "ping", "id" => _}, message)
        list? = list? or match?(%{"id" => 3, "result" => _}, message)

        if ping? and list? do
          {Enum.reverse(acc), message}
        else
          do_collect_both(pipe, deadline, acc, ping?, list?)
        end

      :timeout ->
        flunk("did not see the request of the server and the answer of tools/list")
    end
  end

  # -------------------------------------------------------------------
  # Session-wide messages
  # -------------------------------------------------------------------

  describe "session-wide messages" do
    test "list_changed flows only after notifications/initialized" do
      start_runtime([Servers.Default])
      %{pipe: pipe} = start_transport(Servers.Default)

      Support.Helpers.StdioPipe.send_line(pipe, initialize_request(1))
      assert %{"result" => _} = Support.Helpers.StdioPipe.recv(pipe)

      assert :ok = Support.Helpers.Broadcast.notify_all(Servers.Default)
      assert Support.Helpers.StdioPipe.recv(pipe, 100) == :timeout

      Support.Helpers.StdioPipe.send_line(pipe, %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized"
      })

      session_id = session_id(Servers.Default)

      wait_until(fn ->
        if SessionProbe.initialized?(Servers.Default, session_id), do: :ok
      end)

      assert :ok = Support.Helpers.Broadcast.notify_all(Servers.Default)

      assert %{"method" => "notifications/tools/list_changed"} =
               Support.Helpers.StdioPipe.recv(pipe)
    end

    test "resources/updated flows to a subscribed session" do
      start_runtime([Servers.ToolsAndResources])
      %{pipe: pipe} = start_transport(Servers.ToolsAndResources)
      handshake(pipe)

      send_request(pipe, 2, "resources/subscribe", %{"uri" => "file:///marketing.md"})
      assert_result(pipe, 2)

      assert :ok =
               Notify.resource_updated(Servers.ToolsAndResources, "file:///marketing.md")

      assert %{
               "method" => "notifications/resources/updated",
               "params" => %{"uri" => "file:///marketing.md"}
             } = Support.Helpers.StdioPipe.recv(pipe)
    end

    test "resources/subscribe over the subscription limit gives the rpc error" do
      start_runtime([{Servers.WithTemplates, %{max_subscriptions_per_session: 1}}])
      %{pipe: pipe} = start_transport(Servers.WithTemplates)
      handshake(pipe)

      send_request(pipe, 2, "resources/subscribe", %{"uri" => "file:///definitions.md"})
      assert_result(pipe, 2)

      send_request(pipe, 3, "resources/subscribe", %{"uri" => "file://docs/other.md"})
      assert_error(pipe, 3, -32000)

      # A repeat subscribe of a held uri is not a new subscription.
      #
      send_request(pipe, 4, "resources/subscribe", %{"uri" => "file:///definitions.md"})
      assert_result(pipe, 4)

      # The unsubscribe makes room again.
      #
      send_request(pipe, 5, "resources/unsubscribe", %{"uri" => "file:///definitions.md"})
      assert_result(pipe, 5)

      send_request(pipe, 6, "resources/subscribe", %{"uri" => "file://docs/other.md"})
      assert_result(pipe, 6)
    end

    test "log messages flow to a session that set a level" do
      start_runtime([Servers.WithLogging])
      %{pipe: pipe} = start_transport(Servers.WithLogging)
      handshake(pipe)

      send_request(pipe, 2, "logging/setLevel", %{"level" => "debug"})
      assert_result(pipe, 2)

      assert :ok = Notify.broadcast_log(Servers.WithLogging, :debug, "cache miss")

      assert %{
               "method" => "notifications/message",
               "params" => %{"level" => "debug", "data" => "cache miss"}
             } = Support.Helpers.StdioPipe.recv(pipe)
    end
  end

  # -------------------------------------------------------------------
  # End of the connection
  # -------------------------------------------------------------------

  describe "end of the connection" do
    test "the end of stdin stops the transport with :normal and ends the session" do
      start_runtime([Servers.Default])
      %{pipe: pipe, transport: transport} = start_transport(Servers.Default)
      handshake(pipe)
      session_id = session_id(Servers.Default)
      refute is_nil(session_id)

      ref = Process.monitor(transport)
      Support.Helpers.StdioPipe.close_input(pipe)

      assert_receive {:DOWN, ^ref, :process, ^transport, :normal}, 5_000

      wait_until(fn ->
        if Utils.sessions(Servers.Default) == [], do: :gone
      end)
    end

    test "the end of stdin waits for a request in flight and its answer is written" do
      start_runtime([Servers.Outbound])

      %{pipe: pipe, transport: transport} =
        start_transport(Servers.Outbound, drain_timeout_ms: 5_000)

      handshake(pipe)

      send_request(pipe, 2, "tools/call", %{
        "name" => "outbound",
        "arguments" => %{"feature" => "text", "delay" => 300}
      })

      ref = Process.monitor(transport)
      Support.Helpers.StdioPipe.close_input(pipe)

      assert %{"id" => 2, "result" => _} = Support.Helpers.StdioPipe.recv(pipe, 2_000)

      # The stop follows the end of the request, not the 5 s timer.
      #
      assert_receive {:DOWN, ^ref, :process, ^transport, :normal}, 5_000
    end

    test "a piped script gets every answer" do
      start_runtime([Servers.Default])
      %{pipe: pipe, transport: transport} = start_transport(Servers.Default)
      ref = Process.monitor(transport)

      Support.Helpers.StdioPipe.send_line(pipe, initialize_request(1))

      Support.Helpers.StdioPipe.send_line(pipe, %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized"
      })

      send_request(pipe, 2, "tools/list")
      Support.Helpers.StdioPipe.close_input(pipe)

      assert %{"id" => 1, "result" => _} = Support.Helpers.StdioPipe.recv(pipe)
      assert %{"id" => 2, "result" => %{"tools" => _}} = Support.Helpers.StdioPipe.recv(pipe)
      assert_receive {:DOWN, ^ref, :process, ^transport, :normal}, 5_000
    end

    test "the drain ends at the drain time and cancels the request that still runs" do
      start_runtime([Servers.Outbound])

      %{pipe: pipe, transport: transport} =
        start_transport(Servers.Outbound, drain_timeout_ms: 150)

      handshake(pipe)

      send_request(pipe, 2, "tools/call", %{
        "name" => "outbound",
        "arguments" => %{"method" => "ping", "timeout" => 30_000}
      })

      recv_matching(pipe, &match?(%{"method" => "ping"}, &1))

      ref = Process.monitor(transport)
      started = System.monotonic_time(:millisecond)
      Support.Helpers.StdioPipe.close_input(pipe)

      assert_receive {:DOWN, ^ref, :process, ^transport, :normal}, 5_000
      assert System.monotonic_time(:millisecond) - started >= 150

      wait_until(fn -> if Utils.sessions(Servers.Outbound) == [], do: :gone end)
    end

    test "drain_timeout_ms 0 ends at once and the slow answer is not written" do
      start_runtime([Servers.Outbound])

      %{pipe: pipe, transport: transport} =
        start_transport(Servers.Outbound, drain_timeout_ms: 0)

      handshake(pipe)

      send_request(pipe, 2, "tools/call", %{
        "name" => "outbound",
        "arguments" => %{"feature" => "text", "delay" => 300}
      })

      ref = Process.monitor(transport)
      Support.Helpers.StdioPipe.close_input(pipe)

      assert_receive {:DOWN, ^ref, :process, ^transport, :normal}, 5_000

      refute Enum.any?(
               Support.Helpers.StdioPipe.lines(pipe),
               &(&1 =~ ~s("result") and &1 =~ ~s("id":2))
             )
    end

    test "a write failure stops the transport with an error" do
      start_runtime([Servers.Default])

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      read = fn ->
        case Agent.get_and_update(counter, fn n -> {n, n + 1} end) do
          0 -> {:ok, :json.encode(initialize_request(1))}
          #
          # No end of stdin: it would race with the failed write.
          #
          _ -> Process.sleep(:infinity)
        end
      end

      spec =
        Supervisor.child_spec(
          {Stdio, server: Servers.Default, read: read, write: fn _iodata -> {:error, :epipe} end},
          restart: :temporary
        )

      transport = start_supervised!(spec)

      ref = Process.monitor(transport)

      assert_receive {:DOWN, ^ref, :process, ^transport, {:shutdown, {:write_failed, :epipe}}},
                     5_000
    end

    test "a slow reader of stdout stops the transport with an error log" do
      start_runtime([Servers.Default])

      {:ok, reads} = Agent.start_link(fn -> 0 end)
      {:ok, writes} = Agent.start_link(fn -> 0 end)

      read = fn ->
        case Agent.get_and_update(reads, fn n -> {n, n + 1} end) do
          0 ->
            {:ok, Utils.encode_json(initialize_request(1))}

          1 ->
            {:ok,
             Utils.encode_json(%{
               "jsonrpc" => "2.0",
               "method" => "notifications/initialized"
             })}

          # No end of stdin: it would race with the overflow.
          #
          _ ->
            Process.sleep(:infinity)
        end
      end

      test_pid = self()

      # The first write (the initialize response) goes out; the next one
      # blocks, as a full pipe of stdout blocks the real writer.
      #
      write = fn _iodata ->
        case Agent.get_and_update(writes, fn n -> {n, n + 1} end) do
          0 ->
            :ok

          _ ->
            send(test_pid, {:blocked, self()})

            receive do
              :release -> :ok
            end
        end
      end

      spec =
        Supervisor.child_spec(
          {Stdio,
           [
             server: Servers.Default,
             read: read,
             write: write,
             max_queue: 2
           ]},
          restart: :temporary
        )

      log =
        capture_log(fn ->
          transport = start_supervised!(spec)
          ref = Process.monitor(transport)

          wait_until(fn ->
            case Utils.sessions(Servers.Default) do
              [{id, _}] ->
                if SessionProbe.initialized?(Servers.Default, id), do: :ok

              _ ->
                nil
            end
          end)

          # The first notification blocks in the sink; two fill the queue;
          # the one over the bound of 2 stops the writer.
          #
          Support.Helpers.Broadcast.notify_all(Servers.Default)
          assert_receive {:blocked, sink}, 5_000
          sink_ref = Process.monitor(sink)

          for _ <- 1..3, do: Support.Helpers.Broadcast.notify_all(Servers.Default)

          assert_receive {:DOWN, ^ref, :process, ^transport, {:shutdown, {:output_overflow, 2}}},
                         5_000

          # The blocked sink died with the writer: no process leaks.
          #
          assert_receive {:DOWN, ^sink_ref, :process, ^sink, {:shutdown, {:output_overflow, 2}}},
                         5_000
        end)

      assert [line] =
               log
               |> String.split("\n")
               |> Enum.filter(&String.contains?(&1, "the stdout reader is too slow"))

      assert line =~ ":max_queue"
    end

    @tag :capture_log
    test "a session that the runtime ends stops the transport with :normal" do
      start_runtime([Servers.Default])
      %{pipe: pipe, transport: transport} = start_transport(Servers.Default)
      handshake(pipe)
      session_id = session_id(Servers.Default)

      # The handshake is over only when notifications/initialized was
      # processed: the line waits in the pipe until the reader takes it
      # and a refusal after the end of the session would stop the
      # transport for a lost session instead of :normal.
      #
      wait_until(fn ->
        if SessionProbe.initialized?(Servers.Default, session_id), do: :ok
      end)

      ref = Process.monitor(transport)
      :ok = Sessions.terminate(Servers.Default, session_id)

      assert_receive {:DOWN, ^ref, :process, ^transport, :normal}, 5_000
    end

    test "a callback that raises gives -32603 and the transport stays up" do
      start_runtime([Servers.TasksTest])
      %{pipe: pipe, transport: transport} = start_transport(Servers.TasksTest)
      handshake(pipe)

      send_request(pipe, 2, "tools/call", %{"name" => "task_crash", "arguments" => %{}})
      assert_error(pipe, 2, -32603)

      send_request(pipe, 3, "ping")
      assert_result(pipe, 3)
      assert Process.alive?(transport)
    end
  end

  # -------------------------------------------------------------------
  # The end of the session process
  # -------------------------------------------------------------------

  describe "the end of the session process" do
    @tag :capture_log
    test "a kill of the session process stops the transport with :session_lost" do
      start_runtime([Servers.Default])
      %{pipe: pipe, transport: transport} = start_transport(Servers.Default)
      handshake(pipe)
      session_id = session_id(Servers.Default)

      {:ok, session_pid} =
        OzMcp.Instance.whereis(Servers.Default, {:session, session_id})

      ref = Process.monitor(transport)

      log =
        capture_log(fn ->
          Process.exit(session_pid, :kill)
          assert_receive {:DOWN, ^ref, :process, ^transport, {:shutdown, :session_lost}}, 5_000
        end)

      assert log =~ "the MCP session stopped"
      #
      # The logs never name the session id.
      #
      refute log =~ session_id

      # The runtime is alive again: the transport is the only casualty.
      #
      assert OzMcp.Instance.config(Servers.Default) != :not_running
    end

    test "the reader is not blocked: the lines that arrive during the stop do not hang" do
      start_runtime([Servers.Default])
      %{pipe: pipe, transport: transport} = start_transport(Servers.Default)
      handshake(pipe)
      session_id = session_id(Servers.Default)

      {:ok, session_pid} =
        OzMcp.Instance.whereis(Servers.Default, {:session, session_id})

      ref = Process.monitor(transport)

      capture_log(fn ->
        Process.exit(session_pid, :kill)
        send_request(pipe, 2, "ping")
        send_request(pipe, 3, "ping")

        assert_receive {:DOWN, ^ref, :process, ^transport, _reason}, 5_000
      end)

      refute Process.alive?(transport)
    end
  end

  # -------------------------------------------------------------------
  # A lost session
  # -------------------------------------------------------------------

  describe "a lost session" do
    test "a request for a lost session gets -32001 and the transport stops" do
      start_runtime([Servers.Default])
      %{pipe: pipe, transport: transport} = start_transport(Servers.Default)
      handshake(pipe)
      session_id = session_id(Servers.Default)

      wait_until(fn ->
        if SessionProbe.initialized?(Servers.Default, session_id), do: :ok
      end)

      # The store loses the session, with no restart of the Server.
      #
      Utils.session_delete(Servers.Default, session_id)
      ref = Process.monitor(transport)

      log =
        capture_log(fn ->
          send_request(pipe, 2, "tools/list")
          assert_error(pipe, 2, -32001)
          assert_receive {:DOWN, ^ref, :process, ^transport, {:shutdown, :session_lost}}, 5_000
        end)

      # The capture reads the log of every process: the check is on the
      # lines of the transport about the lost session.
      #
      lines = log |> String.split("\n") |> Enum.filter(&(&1 =~ "the stdio session of"))

      assert Enum.any?(lines, &(&1 =~ "the stdio session of Support.Servers.Default is lost"))
      #
      # The logs name the server module, never the session id.
      #
      refute Enum.any?(lines, &(&1 =~ session_id))
    end

    test "a notification for a lost session writes no line and the transport stops" do
      start_runtime([Servers.Default])
      %{pipe: pipe, transport: transport} = start_transport(Servers.Default)
      handshake(pipe)
      session_id = session_id(Servers.Default)

      wait_until(fn ->
        if SessionProbe.initialized?(Servers.Default, session_id), do: :ok
      end)

      Utils.session_delete(Servers.Default, session_id)
      ref = Process.monitor(transport)

      log =
        capture_log(fn ->
          Support.Helpers.StdioPipe.send_line(pipe, %{
            "jsonrpc" => "2.0",
            "method" => "notifications/roots/list_changed"
          })

          assert_receive {:DOWN, ^ref, :process, ^transport, {:shutdown, :session_lost}}, 5_000
        end)

      assert log =~ "stdio notification refused"
      assert log =~ "the stdio session of Support.Servers.Default is lost"
      #
      # A notification gets no answer line (JSON-RPC 2.0).
      #
      assert [] = Support.Helpers.StdioPipe.lines(pipe)
    end
  end

  # -------------------------------------------------------------------
  # A failed reader
  # -------------------------------------------------------------------

  describe "a failed reader" do
    test "a read function that raises stops the transport with an error" do
      start_runtime([Servers.Default])
      pipe = start_supervised!({Support.Helpers.StdioPipe, nil})
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      read = fn ->
        case Agent.get_and_update(counter, fn n -> {n, n + 1} end) do
          0 -> {:ok, Utils.encode_json(initialize_request(1))}
          _ -> raise "boom"
        end
      end

      spec =
        Supervisor.child_spec(
          {Stdio,
           server: Servers.Default, read: read, write: Support.Helpers.StdioPipe.writer(pipe)},
          restart: :temporary
        )

      log =
        capture_log(fn ->
          transport = start_supervised!(spec)
          ref = Process.monitor(transport)

          assert_receive {:DOWN, ^ref, :process, ^transport,
                          {:shutdown, {:reader_failed, "raised RuntimeError"}}},
                         2_000
        end)

      # The crash report of the reader process can hold the text of the
      # exception: the line of the transport is checked only.
      #
      assert log =~ "the stdin reader failed: raised RuntimeError"

      # The first line was answered before the failure.
      #
      assert %{"id" => 1, "result" => _} = Support.Helpers.StdioPipe.recv(pipe)

      # The session of the connection ended.
      #
      wait_until(fn ->
        if Utils.sessions(Servers.Default) == [], do: :gone
      end)
    end

    test "a read function that returns an error stops the transport with an error" do
      start_runtime([Servers.Default])
      pipe = start_supervised!({Support.Helpers.StdioPipe, nil})
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      read = fn ->
        case Agent.get_and_update(counter, fn n -> {n, n + 1} end) do
          0 -> {:ok, Utils.encode_json(initialize_request(1))}
          _ -> {:error, :terminated}
        end
      end

      spec =
        Supervisor.child_spec(
          {Stdio,
           server: Servers.Default, read: read, write: Support.Helpers.StdioPipe.writer(pipe)},
          restart: :temporary
        )

      log =
        capture_log(fn ->
          transport = start_supervised!(spec)
          ref = Process.monitor(transport)

          assert_receive {:DOWN, ^ref, :process, ^transport,
                          {:shutdown, {:reader_failed, "cannot read stdin: :terminated"}}},
                         2_000
        end)

      # The transport logs the failure one time; the reader does not.
      #
      assert [line] =
               log
               |> String.split("\n")
               |> Enum.filter(&String.contains?(&1, "the stdin reader failed"))

      assert line =~ "cannot read stdin: :terminated"

      # The first line was answered before the failure.
      #
      assert %{"id" => 1, "result" => _} = Support.Helpers.StdioPipe.recv(pipe)

      # The session of the connection ended.
      #
      wait_until(fn ->
        if Utils.sessions(Servers.Default) == [], do: :gone
      end)
    end

    test "the transport works on the instance it is given" do
      start_supervised!({OzMcp, server: Servers.Default, name: :stdio_named, transport: :stdio})

      pipe = start_supervised!({Support.Helpers.StdioPipe, nil})

      start_supervised!(
        {Stdio,
         [
           instance: :stdio_named,
           read: Support.Helpers.StdioPipe.reader(pipe),
           write: Support.Helpers.StdioPipe.writer(pipe)
         ]}
      )

      assert %{"result" => %{"protocolVersion" => @version}} = handshake(pipe)
      assert [{_id, _session}] = Utils.sessions(:stdio_named)
    end

    test "run/2 joins an instance that already runs under another name" do
      start_supervised!({OzMcp, server: Servers.Default, name: :stdio_joined, transport: :stdio})

      assert {:error, {:shutdown, {:reader_failed, _}}} =
               Stdio.run(Servers.Default,
                 instance: :stdio_joined,
                 read: fn -> nil end,
                 write: fn _iodata -> :ok end
               )
    end

    test "a read function that returns a bad value stops the transport" do
      start_supervised!(Utils.runtime_spec(%{transport: :stdio, servers: [Servers.Default]}))

      assert {:error, {:shutdown, {:reader_failed, "read returned an unexpected value"}}} =
               Stdio.run(Servers.Default,
                 read: fn -> nil end,
                 write: fn _iodata -> :ok end
               )
    end

    test "a failed reader makes run/2 return the reason of the transport" do
      start_supervised!(Utils.runtime_spec(%{transport: :stdio, servers: [Servers.Default]}))

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      read = fn ->
        case Agent.get_and_update(counter, fn n -> {n, n + 1} end) do
          0 -> {:ok, Utils.encode_json(initialize_request(1))}
          _ -> raise "boom"
        end
      end

      assert {:error, {:shutdown, {:reader_failed, "raised RuntimeError"}}} =
               Stdio.run(Servers.Default, read: read, write: fn _iodata -> :ok end)
    end
  end

  # -------------------------------------------------------------------
  # The lifecycle of the session
  # -------------------------------------------------------------------

  describe "the lifecycle of the session" do
    test "logging/setLevel is kept in the session and the log reaches the writer" do
      start_runtime([Servers.WithLogging])
      %{pipe: pipe} = start_transport(Servers.WithLogging)
      handshake(pipe)

      send_request(pipe, 5, "logging/setLevel", %{"level" => "warning"})
      assert_result(pipe, 5)

      session_id = session_id(Servers.WithLogging)

      assert {:ok, %{log_level: :warning}} =
               Sessions.lookup(Servers.WithLogging, session_id)
    end
  end

  # -------------------------------------------------------------------
  # run/2
  # -------------------------------------------------------------------

  describe "run/2" do
    test "starts the runtime when it is not running and returns :ok at the end of stdin" do
      on_exit(fn -> stop_runtime() end)
      refute Utils.runtime_running?()

      pipe = start_supervised!({Support.Helpers.StdioPipe, nil})

      task =
        Task.async(fn ->
          Stdio.run(Servers.Default,
            read: Support.Helpers.StdioPipe.reader(pipe),
            write: Support.Helpers.StdioPipe.writer(pipe)
          )
        end)

      init = handshake(pipe)
      assert init["result"]["serverInfo"]["name"] == "ts-default-test"

      send_request(pipe, 2, "ping")
      assert_result(pipe, 2)

      Support.Helpers.StdioPipe.close_input(pipe)
      assert :ok = Task.await(task, 30_000)

      # The runtime was started by the task that called run/2, so it ends
      # with that task. Wait for its shutdown, so the next test never sees
      # a registry that is going away.
      #
      wait_until(fn ->
        if Utils.runtime_running?(), do: nil, else: :gone
      end)
    end

    test "joins the runtime that already runs the server" do
      start_supervised!(Utils.runtime_spec(%{transport: :stdio, servers: [Servers.Default]}))

      runtime = Process.whereis(Utils.Runtime)

      pipe = start_supervised!({Support.Helpers.StdioPipe, nil})

      task =
        Task.async(fn ->
          Stdio.run(Servers.Default,
            read: Support.Helpers.StdioPipe.reader(pipe),
            write: Support.Helpers.StdioPipe.writer(pipe)
          )
        end)

      handshake(pipe)

      send_request(pipe, 2, "ping")
      assert_result(pipe, 2)

      Support.Helpers.StdioPipe.close_input(pipe)
      assert :ok = Task.await(task, 30_000)

      # The runtime that was already running is the one that served.
      #
      assert Process.whereis(Utils.Runtime) == runtime
    end

    test "a write failure makes run/2 return the reason of the transport" do
      start_supervised!(Utils.runtime_spec(%{transport: :stdio, servers: [Servers.Default]}))

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      # The first line is the initialize request; then the reader waits
      # forever, so the stop of the transport can only come from the
      # failed write (no race with the end of stdin).
      #
      read = fn ->
        case Agent.get_and_update(counter, fn n -> {n, n + 1} end) do
          0 -> {:ok, :json.encode(initialize_request(1))}
          _ -> Process.sleep(:infinity)
        end
      end

      assert {:error, {:shutdown, {:write_failed, :epipe}}} =
               Stdio.run(Servers.Default,
                 read: read,
                 write: fn _iodata -> {:error, :epipe} end
               )
    end

    test "a bad :drain_timeout_ms raises and starts nothing" do
      for bad <- [-1, "1000", :infinity, 1.5] do
        assert_raise ArgumentError, ~r/drain_timeout_ms/, fn ->
          Stdio.run(Servers.Outbound,
            read: fn -> :eof end,
            write: fn _iodata -> :ok end,
            drain_timeout_ms: bad
          )
        end

        refute Utils.runtime_running?()
      end
    end

    test "a bad :max_queue raises in run/2 and in start_link and starts nothing" do
      for bad <- [0, -1, "x"] do
        assert_raise ArgumentError, ~r/max_queue/, fn ->
          Stdio.run(Servers.Outbound,
            read: fn -> :eof end,
            write: fn _iodata -> :ok end,
            max_queue: bad
          )
        end

        refute Utils.runtime_running?()

        assert_raise ArgumentError, ~r/max_queue/, fn ->
          Stdio.start_link(
            server: Servers.Default,
            read: fn -> :eof end,
            write: fn _iodata -> :ok end,
            max_queue: bad
          )
        end
      end
    end

    @tag :capture_log
    test "the bound of stdout holds when both paths write together" do
      start_runtime([Servers.TasksTest])

      {:ok, reads} = Agent.start_link(fn -> 0 end)
      {:ok, writes} = Agent.start_link(fn -> 0 end)

      test_pid = self()

      # The scripted read gives one message of each path before the
      # flood: the inline path (initialize, the notification), the child
      # path (a tools/call of a tool that blocks, then a method the
      # server does not know). The read of the first ping sends a
      # message to the test and waits for an answer, so the children run
      # before the overflow. No end of stdin: it would race with the
      # overflow.
      #
      read = fn ->
        case Agent.get_and_update(reads, fn n -> {n, n + 1} end) do
          0 ->
            {:ok, Utils.encode_json(initialize_request(1))}

          1 ->
            {:ok,
             Utils.encode_json(%{
               "jsonrpc" => "2.0",
               "method" => "notifications/initialized"
             })}

          2 ->
            {:ok,
             Utils.encode_json(%{
               "jsonrpc" => "2.0",
               "id" => 2,
               "method" => "tools/call",
               "params" => %{"name" => "task_slow", "arguments" => %{}}
             })}

          3 ->
            {:ok,
             Utils.encode_json(%{
               "jsonrpc" => "2.0",
               "id" => 3,
               "method" => "no_such/method"
             })}

          4 ->
            send(test_pid, {:at_gate, self()})

            receive do
              :go -> :ok
            end

            {:ok,
             Utils.encode_json(%{
               "jsonrpc" => "2.0",
               "id" => 4,
               "method" => "ping"
             })}

          n ->
            {:ok,
             Utils.encode_json(%{
               "jsonrpc" => "2.0",
               "id" => n,
               "method" => "ping"
             })}
        end
      end

      # The first write (the initialize response) goes out; the next one
      # blocks, as a full pipe of stdout blocks the real writer.
      #
      write = fn _iodata ->
        case Agent.get_and_update(writes, fn n -> {n, n + 1} end) do
          0 ->
            :ok

          _ ->
            send(test_pid, {:blocked, self()})

            receive do
              :release -> :ok
            end
        end
      end

      spec =
        Supervisor.child_spec(
          {Stdio,
           [
             server: Servers.TasksTest,
             read: read,
             write: write,
             max_queue: 2
           ]},
          restart: :temporary
        )

      log =
        capture_log(fn ->
          transport = start_supervised!(spec)
          ref = Process.monitor(transport)

          wait_until(fn ->
            case Utils.sessions(Servers.TasksTest) do
              [{id, _}] ->
                if SessionProbe.initialized?(Servers.TasksTest, id), do: :ok

              _ ->
                nil
            end
          end)

          # The child of the tools/call runs now. The monitors must be in
          # place before the flood: the stop of the transport kills the
          # children and a monitor that comes after the stop never gets
          # its {:DOWN, ...} message.
          #
          children =
            wait_until(fn ->
              case running_children(transport) do
                [] -> nil
                children -> children
              end
            end)

          refs = Enum.map(children, &Process.monitor/1)

          # The error line of the unknown method is the second write: the
          # sink blocks on it, so every ping queues behind it.
          #
          assert_receive {:blocked, _sink}, 5_000

          assert_receive {:at_gate, reader}, 5_000
          send(reader, :go)

          assert_receive {:DOWN, ^ref, :process, ^transport, {:shutdown, {:output_overflow, 2}}},
                         5_000

          for child_ref <- refs,
              do: assert_receive({:DOWN, ^child_ref, :process, _pid, _reason}, 5_000)
        end)

      # The stop happens one time: one log line names the bound.
      #
      assert [line] =
               log
               |> String.split("\n")
               |> Enum.filter(&String.contains?(&1, "the stdout reader is too slow"))

      assert line =~ ":max_queue"
    end

    @tag :capture_log
    test "run/2 returns the overflow error when both paths write together" do
      start_supervised!(Utils.runtime_spec(%{transport: :stdio, servers: [Servers.TasksTest]}))

      {:ok, reads} = Agent.start_link(fn -> 0 end)
      {:ok, writes} = Agent.start_link(fn -> 0 end)

      # The same script as the test above, without the gate: the pings
      # flood at once. No end of stdin: it would race with the overflow.
      #
      read = fn ->
        case Agent.get_and_update(reads, fn n -> {n, n + 1} end) do
          0 ->
            {:ok, Utils.encode_json(initialize_request(1))}

          1 ->
            {:ok,
             Utils.encode_json(%{
               "jsonrpc" => "2.0",
               "method" => "notifications/initialized"
             })}

          2 ->
            {:ok,
             Utils.encode_json(%{
               "jsonrpc" => "2.0",
               "id" => 2,
               "method" => "tools/call",
               "params" => %{"name" => "task_slow", "arguments" => %{}}
             })}

          3 ->
            {:ok,
             Utils.encode_json(%{
               "jsonrpc" => "2.0",
               "id" => 3,
               "method" => "no_such/method"
             })}

          n ->
            {:ok,
             Utils.encode_json(%{
               "jsonrpc" => "2.0",
               "id" => n,
               "method" => "ping"
             })}
        end
      end

      write = fn _iodata ->
        case Agent.get_and_update(writes, fn n -> {n, n + 1} end) do
          0 ->
            :ok

          # The sink never comes back: the pings queue behind the blocked
          # write until the bound of the queue stops the writer.
          #
          _ ->
            Process.sleep(:infinity)
        end
      end

      assert {:error, {:shutdown, {:output_overflow, 2}}} =
               Stdio.run(Servers.TasksTest,
                 read: read,
                 write: write,
                 max_queue: 2
               )
    end
  end

  # -------------------------------------------------------------------
  # A protected server
  # -------------------------------------------------------------------

  describe "a protected server" do
    test "runs open on stdio: the lists are complete and a scoped tool runs" do
      start_runtime([Servers.Scoped])
      %{pipe: pipe} = start_transport(Servers.Scoped)
      handshake(pipe)

      send_request(pipe, 2, "tools/list")
      assert %{"tools" => tools} = assert_result(pipe, 2)
      names = Enum.map(tools, & &1["name"])
      assert "read_file" in names
      assert "write_file" in names
      assert "admin_tool" in names

      Support.Entities.Tools.ScopedTest.reset()

      send_request(pipe, 3, "tools/call", %{
        "name" => "write_file",
        "arguments" => %{"path" => "a"}
      })

      assert %{"content" => [%{"text" => "write_file ran"}]} =
               assert_result(pipe, 3)
    end
  end

  # -------------------------------------------------------------------
  # The last line of a request
  # -------------------------------------------------------------------

  # The test process plays the writer: it receives the lines as
  # `{:write, data}` casts.
  #
  describe "the last line of a request" do
    #
    # A line that cannot be encoded is not dropped: it becomes the -32603
    # error with the id of the message, so the client gets an answer.
    #
    test "write_line/2 writes one -32603 line for a line that cannot be encoded" do
      log =
        capture_log(fn ->
          :ok =
            Request.write_line(self(), %{
              "jsonrpc" => "2.0",
              "id" => 7,
              "result" => %{"text" => <<0xFF>>}
            })
        end)

      assert log =~ "not JSON-encodable"

      line = next_written()
      assert line["id"] == 7
      assert line["error"]["code"] == -32603
      assert line["error"]["message"] == "internal server error"
    end

    # The release of a request runs after the span end. A raise in the
    # stream (the sink here) must not take the answer away: the catch
    # writes the crash line with the id of the request.
    #
    test "safe_release/5 writes one -32603 line when the stream of a request fails" do
      stream = %PostStream{
        instance: Servers.Default,
        stream_id: "stream-1",
        registration: nil,
        sink: fn _encoded -> raise "sink boom" end
      }

      outcome = %Outcome{line: %{"jsonrpc" => "2.0", "id" => 5, "result" => %{}}}
      context = %{rpc: %{"jsonrpc" => "2.0", "id" => 5, "method" => "tools/call"}}

      log =
        capture_log(fn ->
          assert :ok = Request.safe_release(:child, stream, context, outcome, self())
        end)

      assert log =~ "stdio release failed: "

      line = next_written()
      assert line["id"] == 5
      assert line["error"]["code"] == -32603
    end

    # A message with no line (a notification) gets no crash line: JSON-RPC
    # does not answer a notification. The failure is a log only.
    #
    test "safe_release/5 writes no line for a message with no line" do
      stream = %PostStream{
        instance: Servers.Default,
        stream_id: "stream-2",
        registration: :bad
      }

      outcome = %Outcome{line: nil}
      context = %{rpc: %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}}

      log =
        capture_log(fn ->
          assert :ok = Request.safe_release(:inline, stream, context, outcome, self())
        end)

      assert log =~ "stdio release failed: "
      refute_written()
    end
  end

  defp next_written do
    {:"$gen_cast", {:write, data}} =
      receive do
        {:"$gen_cast", {:write, _data}} = message -> message
        _other -> next_written()
      after
        1_000 -> flunk("no line was written")
      end

    :json.decode(IO.iodata_to_binary(data))
  end

  defp refute_written do
    receive do
      {:"$gen_cast", {:write, _data}} -> flunk("a line was written")
      _other -> refute_written()
    after
      200 -> :ok
    end
  end
end
