#
# The `request` span of the stdio transport: each decoded line gives a
# `:start` in the process of the transport and the `:stop` arrives from
# the same process (the cheap methods) or from the process of the
# request (the methods that run in a child). A line that the decode
# refuses has no span. Each span ends exactly one time: the refusals of
# the registration end the span before the error line goes out and a
# span that a `:stop` already ended gets no `:exception`.
#
defmodule OzMcp.Transport.StdioTelemetryTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias OzMcp.Transport.Stdio
  alias Support.Helpers.TelemetryCapture
  alias Support.Helpers.Utils
  alias Support.Servers

  # The runtime of `start/1` names the instance after the module
  # of the server.
  #
  @server Servers.Default

  # The server of the test of the refused duplicate id: it declares the
  # slow tool, whose callback blocks until the test tells it to finish.
  #
  @slow_server Servers.TasksTest

  @version "2025-11-25"
  @client_info %{"name" => "stdio-telemetry-test", "version" => "1.0.0"}

  setup do
    %{ref: TelemetryCapture.attach()}
  end

  test "a ping gives a start and a stop from the transport process", %{ref: ref} do
    %{pipe: pipe} = start()
    handshake(pipe)

    Support.Helpers.StdioPipe.send_line(pipe, %{"jsonrpc" => "2.0", "id" => 2, "method" => "ping"})

    assert %{"id" => 2, "result" => %{}} = Support.Helpers.StdioPipe.recv(pipe)

    assert [start] = wait_events(ref, @server, [:request, :start], "ping")
    assert [stop] = wait_events(ref, @server, [:request, :stop], "ping")

    assert start.measurements.system_time
    assert start.measurements.monotonic_time

    assert start.meta.instance == @server
    assert start.meta.server == @server
    assert start.meta.transport == :stdio
    assert start.meta.kind == :request
    assert start.meta.method == "ping"

    assert stop.meta.instance == @server
    assert stop.meta.transport == :stdio
    assert stop.meta.kind == :request
    assert stop.meta.method == "ping"
    assert stop.meta.status == nil
    assert stop.meta.result == :ok
    assert stop.meta.error_code == nil
    assert stop.measurements.duration >= 0

    assert stop.meta.telemetry_span_context == start.meta.telemetry_span_context
  end

  test "a tools/call carries the span into the process of the request", %{ref: ref} do
    %{pipe: pipe} = start()
    handshake(pipe)

    Support.Helpers.StdioPipe.send_line(pipe, %{
      "jsonrpc" => "2.0",
      "id" => 3,
      "method" => "tools/call",
      "params" => %{"name" => "get_date"}
    })

    assert %{"id" => 3, "result" => %{"content" => [_ | _]}} =
             Support.Helpers.StdioPipe.recv(pipe)

    assert [start] = wait_events(ref, @server, [:request, :start], "tools/call")
    assert [stop] = wait_events(ref, @server, [:request, :stop], "tools/call")

    assert start.meta.transport == :stdio
    assert start.meta.kind == :request

    assert stop.meta.status == nil
    assert stop.meta.result == :ok
    assert stop.measurements.duration >= 0
    assert stop.meta.telemetry_span_context == start.meta.telemetry_span_context
  end

  test "a refusal before the initialization ends the span with the code", %{ref: ref} do
    %{pipe: pipe} = start()

    Support.Helpers.StdioPipe.send_line(pipe, %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/list"
    })

    assert %{"id" => 1, "error" => %{"code" => -32600}} = Support.Helpers.StdioPipe.recv(pipe)

    assert [start] = wait_events(ref, @server, [:request, :start], "tools/list")
    assert [stop] = wait_events(ref, @server, [:request, :stop], "tools/list")

    assert start.meta.kind == :request
    assert stop.meta.status == nil
    assert stop.meta.result == :error
    assert stop.meta.error_code == :rpc_session_waiting_initialization
    assert stop.meta.telemetry_span_context == start.meta.telemetry_span_context
  end

  # The bind of a request runs in the process of the request, so a
  # refusal of the bind ends the span there, with the same metadata as a
  # refusal of the validation in the transport.
  #
  test "a refusal of the bind ends the span with the code of the bind", %{ref: ref} do
    %{pipe: pipe} = start()
    handshake(pipe)

    Support.Helpers.StdioPipe.send_line(pipe, %{
      "jsonrpc" => "2.0",
      "id" => 4,
      "method" => "tools/call",
      "params" => %{"name" => "no_such_tool", "arguments" => %{}}
    })

    assert %{"id" => 4, "error" => %{"code" => -32602}} = Support.Helpers.StdioPipe.recv(pipe)

    assert [start] = wait_events(ref, @server, [:request, :start], "tools/call")
    assert [stop] = wait_events(ref, @server, [:request, :stop], "tools/call")

    assert stop.meta.status == nil
    assert stop.meta.result == :error
    assert stop.meta.error_code == :rpc_tool_not_found
    assert stop.meta.telemetry_span_context == start.meta.telemetry_span_context
  end

  test "a notification gives the kind of a notification and the acceptance", %{ref: ref} do
    %{pipe: pipe} = start()
    handshake(pipe)

    Support.Helpers.StdioPipe.send_line(pipe, %{
      "jsonrpc" => "2.0",
      "method" => "notifications/roots/list_changed"
    })

    assert [start] =
             wait_events(ref, @server, [:request, :start], "notifications/roots/list_changed")

    assert [stop] =
             wait_events(ref, @server, [:request, :stop], "notifications/roots/list_changed")

    assert start.meta.kind == :notification
    assert stop.meta.kind == :notification
    assert stop.meta.status == nil
    assert stop.meta.result == :ok
    assert stop.meta.error_code == nil
  end

  test "a line that the decode refuses has no span", %{ref: ref} do
    %{pipe: pipe} = start()

    Support.Helpers.StdioPipe.send_line(pipe, "not json")
    assert %{"error" => %{"code" => -32700}} = Support.Helpers.StdioPipe.recv(pipe)

    # The traffic that follows proves that the transport works: the
    # events of these lines are the only ones of the instance, so an
    # event with the kind of an invalid body would show a span for the
    # parse error.
    #
    handshake(pipe)

    Support.Helpers.StdioPipe.send_line(pipe, %{"jsonrpc" => "2.0", "id" => 2, "method" => "ping"})

    assert %{"id" => 2, "result" => %{}} = Support.Helpers.StdioPipe.recv(pipe)

    events = TelemetryCapture.drain(ref, @server)

    refute Enum.any?(events, fn {_name, _measurements, meta} ->
             Map.get(meta, :kind) == :invalid
           end)

    # The events of the request spans name a method; the events of the
    # other spans (the session, for example) have no method.
    #
    for {name, _measurements, meta} <- events, Map.has_key?(meta, :method) do
      assert meta.method in ["initialize", "notifications/initialized", "ping"],
             "unexpected event #{inspect(name)} for #{inspect(meta.method)}"
    end
  end

  test "a request whose id is null has the kind invalid in the span", %{ref: ref} do
    %{pipe: pipe} = start()
    handshake(pipe)

    Support.Helpers.StdioPipe.send_line(pipe, %{
      "jsonrpc" => "2.0",
      "id" => nil,
      "method" => "ping"
    })

    assert %{"error" => %{"code" => -32600}} = Support.Helpers.StdioPipe.recv(pipe)

    assert [start | _] = wait_events(ref, @server, [:request, :start], "ping")
    assert start.meta.kind == :invalid
  end

  test "the metadata of the span holds no data of the caller", %{ref: ref} do
    %{pipe: pipe} = start()
    handshake(pipe)

    Support.Helpers.StdioPipe.send_line(pipe, %{"jsonrpc" => "2.0", "id" => 2, "method" => "ping"})

    assert %{"id" => 2, "result" => %{}} = Support.Helpers.StdioPipe.recv(pipe)

    wait_events(ref, @server, [:request, :stop], "ping")

    for {_name, _measurements, meta} <- TelemetryCapture.drain(ref, @server) do
      refute Map.has_key?(meta, :session_id)
      refute Map.has_key?(meta, :principal)
      refute Map.has_key?(meta, :params)
      refute Map.has_key?(meta, :token)
    end
  end

  test "the handshake gives the start of the session span", %{ref: ref} do
    %{pipe: pipe} = start()
    handshake(pipe)

    # The session starts while the transport answers `initialize`, so the
    # event is in the mailbox when the answer line arrived.
    #
    assert [start] = wait_session_events(ref, [:session, :start])

    assert start.meta.instance == @server
    assert start.meta.server == @server
    assert start.meta.transport == :stdio
    assert start.meta.restored? == false
    assert is_reference(start.meta.telemetry_span_context)
    assert start.measurements.system_time
    assert start.measurements.monotonic_time
  end

  test "each span of a mixed traffic ends exactly one time", %{ref: ref} do
    %{pipe: pipe} = start()
    handshake(pipe)

    Support.Helpers.StdioPipe.send_line(pipe, %{"jsonrpc" => "2.0", "id" => 2, "method" => "ping"})

    assert %{"id" => 2, "result" => %{}} = Support.Helpers.StdioPipe.recv(pipe)

    # A method that the server does not serve: the request runs in a
    # child and comes back as a JSON-RPC error.
    #
    Support.Helpers.StdioPipe.send_line(pipe, %{"jsonrpc" => "2.0", "id" => 3, "method" => "x/y"})
    assert %{"id" => 3, "error" => %{"code" => -32601}} = Support.Helpers.StdioPipe.recv(pipe)

    Support.Helpers.StdioPipe.send_line(pipe, %{
      "jsonrpc" => "2.0",
      "id" => 4,
      "method" => "tools/call",
      "params" => %{"name" => "get_date"}
    })

    assert %{"id" => 4, "result" => %{"content" => [_ | _]}} =
             Support.Helpers.StdioPipe.recv(pipe)

    Support.Helpers.StdioPipe.send_line(pipe, %{
      "jsonrpc" => "2.0",
      "method" => "notifications/roots/list_changed"
    })

    # The traffic gives six request spans: `initialize`, the
    # `notifications/initialized`, the `ping`, the unknown method, the
    # `tools/call` and the notification.
    #
    events = wait_request_spans(ref, @server, 6)

    assert length(request_events(events, :start)) == 6
    assert_one_end_per_span(events)
  end

  test "a ping that repeats the id of a request in flight ends its span one time", %{ref: ref} do
    %{pipe: pipe} = start(@slow_server)
    handshake(pipe)

    # The request of the slow tool runs in a child and the child
    # registers the id in the session before the callback runs. The wait
    # for the callback proves that the id is registered when the ping
    # arrives.
    #
    Support.Entities.Tools.TaskSlowTest.use_instance(@slow_server)

    Support.Helpers.StdioPipe.send_line(pipe, %{
      "jsonrpc" => "2.0",
      "id" => 7,
      "method" => "tools/call",
      "params" => %{"name" => "task_slow", "arguments" => %{}}
    })

    wait_runner()

    Support.Helpers.StdioPipe.send_line(pipe, %{"jsonrpc" => "2.0", "id" => 7, "method" => "ping"})

    assert %{"id" => 7, "error" => %{"code" => -32600}} = Support.Helpers.StdioPipe.recv(pipe)

    # The refusal did not disturb the request in flight: the tool goes
    # on and its answer line lets the span of the tool call end.
    #
    Support.Entities.Tools.TaskSlowTest.finish()

    assert %{"id" => 7, "result" => %{"content" => [_ | _]}} =
             Support.Helpers.StdioPipe.recv(pipe)

    events = wait_request_spans(ref, @slow_server, 4)

    assert [ping_start] = metas_of_method(request_events(events, :start), "ping")
    assert [ping_stop] = metas_of_method(request_events(events, :stop), "ping")

    assert ping_stop.result == :error
    assert ping_stop.error_code == :rpc_duplicate_request_id
    assert ping_stop.status == nil
    assert ping_stop.telemetry_span_context == ping_start.telemetry_span_context

    assert [tool_stop] = metas_of_method(request_events(events, :stop), "tools/call")
    assert tool_stop.result == :ok

    assert_one_end_per_span(events)
  end

  test "a tools/call that repeats the id of a request in flight ends its span one time", %{
    ref: ref
  } do
    %{pipe: pipe} = start(@slow_server)
    handshake(pipe)

    # The request of the slow tool runs in a child and the child
    # registers the id in the session before the callback runs. The wait
    # for the callback proves that the id is registered when the second
    # call arrives.
    #
    Support.Entities.Tools.TaskSlowTest.use_instance(@slow_server)

    Support.Helpers.StdioPipe.send_line(pipe, %{
      "jsonrpc" => "2.0",
      "id" => 7,
      "method" => "tools/call",
      "params" => %{"name" => "task_slow", "arguments" => %{}}
    })

    wait_runner()

    # The second call repeats the id: it is refused with no spawn, its
    # own span ends with the refusal and the first call is not
    # disturbed.
    #
    Support.Helpers.StdioPipe.send_line(pipe, %{
      "jsonrpc" => "2.0",
      "id" => 7,
      "method" => "tools/call",
      "params" => %{"name" => "task_slow", "arguments" => %{}}
    })

    assert %{"id" => 7, "error" => %{"code" => -32600}} = Support.Helpers.StdioPipe.recv(pipe)

    Support.Entities.Tools.TaskSlowTest.finish()

    assert %{"id" => 7, "result" => %{"content" => [_ | _]}} =
             Support.Helpers.StdioPipe.recv(pipe)

    events = wait_request_spans(ref, @slow_server, 4)

    stops = metas_of_method(request_events(events, :stop), "tools/call")

    assert Enum.any?(stops, fn meta ->
             meta.result == :error and meta.error_code == :rpc_duplicate_request_id and
               meta.status == nil
           end)

    assert Enum.any?(stops, &(&1.result == :ok))

    assert_one_end_per_span(events)
  end

  # A raise before the run of a request (here: the start of the process
  # of the request, because the supervisor is gone) ends the span one
  # time, with the exception event and the crash line keeps the id of
  # the raw message. The transport goes on with the next lines.
  #
  test "a raise before the run of a request ends its span one time", %{ref: ref} do
    %{pipe: pipe, transport: transport} = start()
    handshake(pipe)

    old_tasks = :sys.get_state(transport).tasks
    dead = spawn(fn -> :ok end)
    wait_until_dead(dead)
    :sys.replace_state(transport, &%{&1 | tasks: dead})

    log =
      capture_log(fn ->
        Support.Helpers.StdioPipe.send_line(pipe, %{
          "jsonrpc" => "2.0",
          "id" => 9,
          "method" => "tools/list"
        })

        assert %{"id" => 9, "error" => %{"code" => -32603, "message" => "internal error"}} =
                 Support.Helpers.StdioPipe.recv(pipe)
      end)

    assert log =~ "stdio message failed: "

    :sys.replace_state(transport, &%{&1 | tasks: old_tasks})

    Support.Helpers.StdioPipe.send_line(pipe, %{
      "jsonrpc" => "2.0",
      "id" => 10,
      "method" => "ping"
    })

    assert %{"id" => 10, "result" => %{}} = Support.Helpers.StdioPipe.recv(pipe)

    # The request spans of the handshake, of the failed start and of the
    # ping: the span of `tools/list` ends with the exception event, with
    # no stop event beside it.
    #
    events = wait_request_spans(ref, @server, 4)

    assert [start] = metas_of_method(request_events(events, :start), "tools/list")
    assert [] = metas_of_method(request_events(events, :stop), "tools/list")

    assert [exception] = metas_of_method(request_events(events, :exception), "tools/list")
    assert exception.telemetry_span_context == start.telemetry_span_context
    assert exception.exception_kind in [:error, :exit]

    assert_one_end_per_span(events)
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  # A pid that the transport cannot use: a call to it fails, like a call
  # to a process that stopped between two lines.
  #
  defp wait_until_dead(pid) do
    if Process.alive?(pid), do: wait_until_dead(pid)
  end

  defp start(server \\ @server) do
    start_supervised!(Utils.runtime_spec(%{transport: :stdio, servers: [server]}))

    pipe = start_supervised!({Support.Helpers.StdioPipe, nil})

    transport =
      start_supervised!(
        Supervisor.child_spec(
          {Stdio,
           [
             server: server,
             read: Support.Helpers.StdioPipe.reader(pipe),
             write: Support.Helpers.StdioPipe.writer(pipe)
           ]},
          restart: :temporary
        )
      )

    %{pipe: pipe, transport: transport}
  end

  defp initialize_request(id, capabilities) do
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
    assert %{"id" => 1, "result" => _} = Support.Helpers.StdioPipe.recv(pipe)

    Support.Helpers.StdioPipe.send_line(pipe, %{
      "jsonrpc" => "2.0",
      "method" => "notifications/initialized"
    })
  end

  # The events of one method of the instance, in the mailbox. The stop of
  # a request that runs in a child can arrive after the answer line, so
  # the test waits for the events with a deadline.
  #
  defp wait_events(ref, instance, tail, method, timeout \\ 5_000) do
    event = [:oz_mcp | tail]
    deadline = System.monotonic_time(:millisecond) + timeout

    do_wait(ref, instance, event, method, deadline, [])
    |> Enum.filter(fn e -> e.name == event and e.meta.method == method end)
  end

  defp do_wait(ref, instance, event, method, deadline, acc) do
    case Enum.find(acc, fn e -> e.name == event and e.meta.method == method end) do
      nil ->
        timeout = max(deadline - System.monotonic_time(:millisecond), 1)

        receive do
          {^event, ^ref, measurements, %{instance: ^instance} = meta} ->
            do_wait(ref, instance, event, method, deadline, [
              %{name: event, measurements: measurements, meta: meta} | acc
            ])

          {_event, ^ref, _measurements, _meta} ->
            do_wait(ref, instance, event, method, deadline, acc)
        after
          timeout ->
            flunk(
              "no #{inspect(event)} event for the method #{inspect(method)}, " <>
                "got: #{inspect(Enum.map(acc, fn e -> {e.name, e.meta.method} end))}"
            )
        end

      _found ->
        acc
        |> Enum.reverse()
    end
  end

  # The first event of one name with no `method` in the metadata (the
  # spans that do not name a method of a request, like the span of a
  # session). The messages of other events stay in the mailbox.
  #
  defp wait_session_events(ref, tail, timeout \\ 5_000) do
    event = [:oz_mcp | tail]

    receive do
      {^event, ^ref, measurements, %{instance: @server} = meta} ->
        [%{name: event, measurements: measurements, meta: meta}]

      {_event, ^ref, _measurements, _meta} ->
        wait_session_events(ref, tail, timeout)
    after
      timeout ->
        flunk("no #{inspect(event)} event for the instance #{inspect(@server)}")
    end
  end

  # The events of the instance, in the mailbox, until the spans of the
  # requests are settled: every `:start` has its end (a `:stop` or an
  # `:exception`) and the traffic reached `target` spans. The stop of a
  # request that runs in a child can arrive after the answer line, so
  # the helper waits with a deadline.
  #
  defp wait_request_spans(ref, instance, target, acc \\ [], tries \\ 300)

  defp wait_request_spans(_ref, _instance, _target, acc, 0), do: acc

  defp wait_request_spans(ref, instance, target, acc, tries) do
    acc = acc ++ TelemetryCapture.drain(ref, instance)
    starts = request_events(acc, :start)
    ends = request_events(acc, :stop) ++ request_events(acc, :exception)

    if length(starts) == length(ends) and length(ends) >= target do
      acc
    else
      case TelemetryCapture.drain_wait(ref, instance, 100) do
        [] -> wait_request_spans(ref, instance, target, acc, tries - 1)
        events -> wait_request_spans(ref, instance, target, acc ++ events, tries - 1)
      end
    end
  end

  defp request_events(events, tail) do
    Enum.filter(events, fn {name, _measurements, _meta} -> name == [:oz_mcp, :request, tail] end)
  end

  # The metadata of the events of one method, from a drained list.
  #
  defp metas_of_method(events, method) do
    events
    |> Enum.filter(fn {_name, _measurements, meta} -> meta.method == method end)
    |> Enum.map(fn {_name, _measurements, meta} -> meta end)
  end

  # One end for each span: a span context that two end events hold (a
  # `:stop` and an `:exception`, or two stops) makes a handler that
  # counts the open requests drift.
  #
  defp assert_one_end_per_span(events) do
    events
    |> Enum.filter(fn {name, _measurements, meta} ->
      name in [[:oz_mcp, :request, :stop], [:oz_mcp, :request, :exception]] and
        Map.has_key?(meta, :telemetry_span_context)
    end)
    |> Enum.group_by(fn {_name, _measurements, meta} -> meta.telemetry_span_context end)
    |> Enum.each(fn {context, ends} ->
      assert length(ends) == 1,
             "the span #{inspect(context)} got #{length(ends)} end events: " <>
               inspect(Enum.map(ends, fn {name, _measurements, _meta} -> name end))
    end)
  end

  # The callback of the slow tool stores the pid of its process when it
  # starts. The wait proves that the registration of the request in the
  # session happened (it happens before the callback runs). The pid must
  # belong to a process that is alive: a pid that another test left
  # behind belongs to a request that already ended.
  #
  defp wait_runner do
    assert Utils.eventually(fn ->
             pid = Support.Entities.Tools.TaskSlowTest.last_runner_pid()
             is_pid(pid) and Process.alive?(pid)
           end)

    Support.Entities.Tools.TaskSlowTest.last_runner_pid()
  end
end
