#
# The two paths of the stdio transport, driven directly: the test process
# plays the writer (it receives the lines as `{:write, data}` casts) and
# the context holds no session, so a message registers nothing. The
# mailbox of the test shows the order of the span end and of the line.
#
defmodule OzMcp.Transport.Stdio.RequestTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias OzMcp.{Context, Protocol, Telemetry, Validate}
  alias OzMcp.Transport.Stdio.Request
  alias OzMcp.Utils.JsonRpc
  alias Support.Helpers.TelemetryCapture
  alias Support.Helpers.Utils
  alias Support.Servers

  # The runtime of `start_runtime/0` names the instance after the module
  # of the server.
  #
  @server Servers.Default

  # An instance that does not run: the calls of the session fail with
  # `:unavailable`, which the handler turns into `:internal_error`.
  #
  @no_instance OzMcp.Transport.Stdio.RequestTest.NoRuntime

  @version "2025-11-25"

  setup do
    %{ref: TelemetryCapture.attach()}
  end

  describe "child/3" do
    test "a success ends the span before the response line goes out", %{ref: ref} do
      start_runtime()

      rpc = %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}
      context = validated(rpc)
      token = token(rpc)

      drain()
      Request.child(context, self(), token)

      assert %{result: :ok, error_code: nil, method: "ping"} = next_span_stop(ref)
      assert %{"id" => 1, "result" => %{}} = next_line()
    end

    test "a crash in the handler gives an error stop, the crash line and the log", %{ref: ref} do
      start_runtime()

      rpc = %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}

      # A context that the validation would refuse: the handler dispatches
      # on it and finds a server that cannot answer. A tool that raises
      # cannot test this: `OzMcp.Handler.Invoke` guards the callback.
      #
      context =
        validated(rpc)
        |> Map.put(:rpc_method, "resources/list")
        |> Map.put(:server, nil)

      crash_rpc = %{"jsonrpc" => "2.0", "id" => 1, "method" => "resources/list"}
      token = token(crash_rpc)

      drain()

      log =
        capture_log(fn ->
          Request.child(context, self(), token)
        end)

      assert log =~ "stdio request failed: "

      stop = next_span_stop(ref)
      assert stop.result == :error
      assert stop.error_code == nil
      assert stop.method == "resources/list"

      line = next_line()
      assert line["id"] == 1
      assert line["error"]["code"] == -32603
      assert line["error"]["message"] == "internal error"
    end
  end

  describe "inline/4" do
    test "a success ends the span before the response line goes out", %{ref: ref} do
      start_runtime()

      rpc = %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}
      context = validated(rpc)
      token = token(rpc)

      drain()
      outcome = Request.inline(context, self(), token, fn _session_id -> :no_adoption end)

      assert %{result: :ok, error_code: nil, method: "ping"} = next_span_stop(ref)
      assert %{"id" => 1, "result" => %{}} = next_line()
      assert outcome.next == nil
      assert outcome.line["id"] == 1
    end

    test "a crash in the handler gives an exception event, the crash line and the log", %{
      ref: ref
    } do
      start_runtime()

      rpc = %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}

      # The same trick as for the child path: the validation answered a
      # `ping` and the handler then finds a server that cannot answer.
      #
      context =
        validated(rpc)
        |> Map.put(:rpc_method, "resources/list")
        |> Map.put(:server, nil)

      crash_rpc = %{"jsonrpc" => "2.0", "id" => 1, "method" => "resources/list"}
      token = token(crash_rpc)

      drain()

      log =
        capture_log(fn ->
          Request.inline(context, self(), token, fn _session_id -> :no_adoption end)
        end)

      assert log =~ "stdio message failed: "

      exception = next_span_exception(ref)
      assert exception.method == "resources/list"
      assert exception.exception_kind == :error

      line = next_line()
      assert line["id"] == 1
      assert line["error"]["code"] == -32603
      assert line["error"]["message"] == "internal error"
    end

    # The answer of a client carries an id that the context does not hold
    # in `rpc_id`: the crash line must name the id of the raw message all
    # the same. The context pretends to carry a malformed answer, so the
    # handler raises on it.
    #
    test "the crash line of an answer of the client keeps the id of the message", %{ref: ref} do
      start_runtime()

      rpc = %{"jsonrpc" => "2.0", "id" => 7, "result" => %{}}

      context =
        %Context{instance: @server, server: @server}
        |> Context.put_rpc(rpc)
        |> Map.put(:rpc_response, :malformed)

      token = token(rpc)

      drain()

      log =
        capture_log(fn ->
          Request.inline(context, self(), token, fn _session_id -> :no_adoption end)
        end)

      assert log =~ "stdio message failed: "

      _exception = next_span_exception(ref)

      line = next_line()
      assert line["id"] == 7
      assert line["error"]["code"] == -32603
    end

    # The adoption of the session of an `initialize` can fail: the
    # response line does not go out and the span still ends with the
    # result of the handler.
    #
    test "an adoption that stops the transport writes no line and keeps the result", %{ref: ref} do
      start_runtime()

      context = validated(initialize_request())
      token = token(initialize_request())

      drain()

      outcome =
        Request.inline(context, self(), token, fn _session_id -> {:stop, :shutdown, :stopped} end)

      assert outcome.next == {:stop, :shutdown, :stopped}
      assert outcome.line == nil

      assert %{result: :ok, error_code: nil, method: "initialize"} = next_span_stop(ref)
      refute_line()
    end

    test "the adoption runs before the response line goes out", %{ref: ref} do
      start_runtime()

      context = validated(initialize_request())
      token = token(initialize_request())

      drain()

      outcome =
        Request.inline(context, self(), token, fn session_id ->
          send(self(), {:adopted, session_id})
          :new_state
        end)

      assert outcome.next == :new_state

      assert {:adopted, session_id} =
               next_of(fn
                 {:adopted, _session_id} -> true
                 _other -> false
               end)

      assert is_binary(session_id)

      assert %{result: :ok, method: "initialize"} = next_span_stop(ref)
      assert %{"id" => 1, "result" => _} = next_line()
    end

    test "a crash in the adoption gives an exception event, a line and no next", %{ref: ref} do
      start_runtime()

      context = validated(initialize_request())
      token = token(initialize_request())

      drain()

      log =
        capture_log(fn ->
          outcome =
            Request.inline(context, self(), token, fn _session_id -> raise "adoption boom" end)

          assert outcome.next == nil
        end)

      assert log =~ "stdio message failed: "

      exception = next_span_exception(ref)
      assert exception.method == "initialize"

      line = next_line()
      assert line["id"] == 1
      assert line["error"]["code"] == -32603
      assert line["error"]["message"] == "internal error"
    end

    # A store of the server failed for a message that gets no answer
    # (JSON-RPC 2.0): the failure is logged only and the span still ends
    # with the error of the store.
    #
    test "an internal error of a notification gets no line and one warning", %{ref: ref} do
      start_runtime()

      context = %Context{
        instance: @no_instance,
        server: @server,
        rpc_method: "notifications/initialized",
        session_id: "gone-session",
        session_initialized: false
      }

      token = token(%{"method" => "notifications/initialized"})

      drain()

      log =
        capture_log(fn ->
          outcome = Request.inline(context, self(), token, fn _session_id -> :no_adoption end)

          assert outcome.line == nil
          assert outcome.next == nil
        end)

      assert log =~ "stdio notification failed"

      stop = next_span_stop(ref)
      assert stop.result == :error
      assert stop.error_code == :http_internal_error

      refute_line()
    end
  end

  describe "refuse/3" do
    test "a refused request gets the error line after the span end", %{ref: ref} do
      start_runtime()

      rpc = %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"}
      context = refused(rpc, nil)
      token = token(rpc)

      drain()
      outcome = Request.refuse(context, self(), token)

      assert outcome.stop? == false

      stop = next_span_stop(ref)
      assert stop.result == :error
      assert stop.error_code == :rpc_session_waiting_initialization

      line = next_line()
      assert line["id"] == 2
      assert line["error"]["code"] == -32600
      assert line["error"]["message"] == "waiting session initialization"
    end

    test "a refused notification gets a warning, no line and the stop mark", %{ref: ref} do
      start_runtime()

      rpc = %{"jsonrpc" => "2.0", "method" => "notifications/roots/list_changed"}
      context = refused(rpc, "gone-session")
      token = token(rpc)

      drain()

      log =
        capture_log(fn ->
          outcome = Request.refuse(context, self(), token)

          assert outcome.stop? == true
          assert outcome.line == nil
        end)

      assert log =~ "stdio notification refused: :http_invalid_session"

      stop = next_span_stop(ref)
      assert stop.error_code == :http_invalid_session

      refute_line()
    end

    test "a malformed answer of the client gets a warning and no line", %{ref: ref} do
      start_runtime()

      rpc = %{"id" => "srv-1", "result" => 5}
      context = refused(rpc, nil)
      token = token(rpc)

      drain()

      log =
        capture_log(fn ->
          outcome = Request.refuse(context, self(), token)

          assert outcome.stop? == false
          assert outcome.line == nil
        end)

      assert log =~ "stdio response of the client refused: :rpc_invalid_request"

      stop = next_span_stop(ref)
      assert stop.error_code == :rpc_invalid_request

      refute_line()
    end
  end

  describe "crashed/4" do
    #
    # The place that answers a raise before the run of a message: the
    # span ends with the exception event, then the crash line goes out.
    # The id of the line is the one that the call gives, because the
    # caller takes it from the raw message.
    #
    test "the exception event comes before the line, which keeps the id of the call", %{ref: ref} do
      start_runtime()

      token = token(%{"jsonrpc" => "2.0", "id" => 9, "method" => "tools/list"})

      drain()

      log =
        capture_log(fn ->
          :ok =
            Request.crashed("req-9", self(), token, {:error, %RuntimeError{message: "boom"}, []})
        end)

      assert log =~ "stdio message failed: "

      exception = next_span_exception(ref)
      assert exception.exception_kind == :error

      line = next_line()
      assert line["id"] == "req-9"
      assert line["error"]["code"] == -32603
      assert line["error"]["message"] == "internal error"
    end
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp start_runtime do
    start_supervised!(Utils.runtime_spec(%{transport: :stdio, servers: [@server]}))
  end

  defp initialize_request do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @version,
        "clientInfo" => %{"name" => "request-test", "version" => "1.0.0"},
        "capabilities" => %{}
      }
    }
  end

  # The context of the transport: the same pipeline, with no session. The
  # validation answers a `ping` before `initialize`, so the context is
  # the one of the real traffic.
  #
  defp validated(rpc) do
    {:ok, config} = OzMcp.Instance.config(@server)

    result =
      Context.new(@server, :stdio, :rpc, config)
      |> Context.put_rpc(rpc)
      |> Map.put(:session_id, nil)
      |> Validate.stdio()

    case result do
      {:cont, context} -> context
      {:halt, _context} -> flunk("the validation refused the message")
    end
  end

  # The context of a message that the validation refused: the pipeline
  # halts with the error in the context.
  #
  defp refused(rpc, session_id) do
    {:ok, config} = OzMcp.Instance.config(@server)

    result =
      Context.new(@server, :stdio, :rpc, config)
      |> Context.put_rpc(rpc)
      |> Map.put(:session_id, session_id)
      |> Validate.stdio()

    case result do
      {:halt, context} -> context
      {:cont, _context} -> flunk("the validation accepted the message")
    end
  end

  defp token(rpc) do
    {:ok, config} = OzMcp.Instance.config(@server)

    Telemetry.start(
      config.telemetry,
      :request,
      %{method: Protocol.bound_method(rpc), kind: JsonRpc.kind(rpc)},
      :stdio
    )
  end

  # The messages of the runtime that wait already are not part of the
  # order that a test checks.
  #
  defp drain do
    receive do
      _message -> drain()
    after
      0 -> :ok
    end
  end

  # The next message that the `match` function accepts, in the order of
  # arrival: the test takes the messages in order, so the order of the
  # span end and of the line is the one of the code. The messages of the
  # runtime that the test does not check (the span of the session, for
  # example) are skipped.
  #
  defp next_of(match) do
    receive do
      message ->
        if match.(message) do
          message
        else
          next_of(match)
        end
    after
      1_000 -> flunk("no expected message arrived")
    end
  end

  defp next_span_stop(ref) do
    {[:oz_mcp, :request, :stop], ^ref, _measurements, meta} =
      next_of(fn
        {[:oz_mcp, :request, :stop], ^ref, _m, _meta} -> true
        _other -> false
      end)

    meta
  end

  defp next_span_exception(ref) do
    {[:oz_mcp, :request, :exception], ^ref, _measurements, meta} =
      next_of(fn
        {[:oz_mcp, :request, :exception], ^ref, _m, _meta} -> true
        _other -> false
      end)

    meta
  end

  defp next_line do
    {:"$gen_cast", {:write, data}} =
      next_of(fn
        {:"$gen_cast", {:write, _data}} -> true
        _other -> false
      end)

    :json.decode(IO.iodata_to_binary(data))
  end

  defp refute_line do
    receive do
      {:"$gen_cast", {:write, _data}} -> flunk("a line went out")
      _other -> refute_line()
    after
      200 -> :ok
    end
  end
end
