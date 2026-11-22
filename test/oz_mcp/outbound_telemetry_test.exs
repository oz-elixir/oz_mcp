#
# The `client_request` span: one `:start` event before the checks of a
# request to the client and one `:stop` event when the call gives its
# outcome, with the method and the atom of the result. A `:exception`
# event comes only from a defect of the framework itself.
#
defmodule OzMcp.OutboundTelemetryTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias OzMcp.{Outbound, PostStream, Sessions, Tasks}
  alias Support.Helpers.SessionProbe
  alias Support.Helpers.TelemetryCapture
  alias Support.Helpers.Utils
  alias Support.Servers

  @server_module Servers.Default
  @server Module.concat(@server_module, __MODULE__)

  setup do
    ref = TelemetryCapture.attach()
    Utils.start_instance(@server_module, name: @server, client_tasks: true)
    %{ref: ref}
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

  defp ctx(session_id),
    do: %{
      instance: @server,
      server: @server_module,
      session_id: session_id,
      request_id: nil,
      principal: nil
    }

  defp request_async(ctx, method, params \\ nil, opts \\ []) do
    Task.async(fn -> Outbound.request(ctx, method, params, opts) end)
  end

  # The events of the mailbox for one instance, until the condition holds
  # on the events of the `client_request` span. Each drain consumes the
  # mailbox, so the helper accumulates the events it took.
  #
  defp collect_until(ref, instance, fun, acc \\ [], tries \\ 300)

  defp collect_until(_ref, _instance, _fun, acc, 0), do: acc

  defp collect_until(ref, instance, fun, acc, tries) do
    if fun.(acc) do
      acc
    else
      case TelemetryCapture.drain_wait(ref, instance, 100) do
        [] -> collect_until(ref, instance, fun, acc, tries - 1)
        events -> collect_until(ref, instance, fun, acc ++ events, tries - 1)
      end
    end
  end

  defp named(events, tail) do
    event = [:oz_mcp | tail]
    Enum.filter(events, fn {name, _, _} -> name == event end)
  end

  test "an answer gives one start and one stop with result ok", %{ref: ref} do
    session_id = session()
    task = request_async(ctx(session_id), "ping")

    {_, %{"id" => id}} = Utils.receive_event(5_000)
    assert :ok = Outbound.deliver(@server, session_id, id, {:ok, %{}})
    assert Task.await(task, 30_000) == {:ok, %{}}

    events = collect_until(ref, @server, &(named(&1, [:client_request, :stop]) != []))
    assert [start] = named(events, [:client_request, :start])
    assert [stop] = named(events, [:client_request, :stop])

    {_, measurements, start_meta} = start
    assert is_integer(measurements.system_time)
    assert is_integer(measurements.monotonic_time)
    assert start_meta.method == "ping"
    assert start_meta.instance == @server
    assert start_meta.server == @server_module
    assert is_reference(start_meta.telemetry_span_context)

    assert MapSet.new(Map.keys(start_meta)) ==
             MapSet.new([:instance, :server, :method, :telemetry_span_context])

    {_, %{duration: duration}, stop_meta} = stop
    assert stop_meta.method == "ping"
    assert stop_meta.result == :ok
    assert stop_meta.instance == @server
    assert stop_meta.server == @server_module
    assert stop_meta.telemetry_span_context == start_meta.telemetry_span_context
    assert duration >= 0

    assert MapSet.new(Map.keys(stop_meta)) ==
             MapSet.new([:instance, :server, :method, :result, :telemetry_span_context])
  end

  @tag :capture_log
  test "a timeout of the wait gives result timeout", %{ref: ref} do
    session_id = session()
    task = request_async(ctx(session_id), "ping", nil, timeout: 50)

    {_, _request} = Utils.receive_event(5_000)
    assert Task.await(task, 30_000) == {:error, :timeout}

    events = collect_until(ref, @server, &(named(&1, [:client_request, :stop]) != []))
    assert [stop] = named(events, [:client_request, :stop])
    assert elem(stop, 2).method == "ping"
    assert elem(stop, 2).result == :timeout
  end

  test "the end of the session during the wait gives result session_terminated", %{ref: ref} do
    session_id = session()
    task = request_async(ctx(session_id), "ping")
    wait_pending(session_id)

    assert :ok = Sessions.terminate(@server, session_id)
    assert Task.await(task, 30_000) == {:error, :session_terminated}

    events = collect_until(ref, @server, &(named(&1, [:client_request, :stop]) != []))
    assert [stop] = named(events, [:client_request, :stop])
    assert elem(stop, 2).result == :session_terminated
  end

  test "an answer of the client with a JSON-RPC error gives result rpc_error", %{ref: ref} do
    session_id = session()
    task = request_async(ctx(session_id), "ping")

    {_, %{"id" => id}} = Utils.receive_event(5_000)
    error = %{"code" => -32601, "message" => "no ping"}
    assert :ok = Outbound.deliver(@server, session_id, id, {:error, error})

    assert Task.await(task, 30_000) == {:error, {:rpc_error, error}}

    events = collect_until(ref, @server, &(named(&1, [:client_request, :stop]) != []))
    assert [stop] = named(events, [:client_request, :stop])
    assert elem(stop, 2).result == :rpc_error
  end

  test "a method whose capability the client did not declare gives result capability_not_supported",
       %{ref: ref} do
    session_id = session()

    assert Outbound.request(ctx(session_id), "elicitation/create", %{}) ==
             {:error, :capability_not_supported}

    events = collect_until(ref, @server, &(named(&1, [:client_request, :stop]) != []))
    assert [stop] = named(events, [:client_request, :stop])
    assert elem(stop, 2).method == "elicitation/create"
    assert elem(stop, 2).result == :capability_not_supported
  end

  test "a request of a task gives one span with result ok and no id in the metadata", %{ref: ref} do
    session_id = session(%{"roots" => %{}})
    task_id = start_task(session_id)
    stream = attach_task_events(session_id, task_id)

    waiter =
      Task.async(fn ->
        Outbound.request(Map.put(ctx(session_id), :task_id, task_id), "roots/list", nil)
      end)

    assert {:event, %{"id" => id, "method" => "roots/list"}} = stream_event(stream)

    assert :ok =
             Tasks.deliver(@server, Utils.owner(session_id), nil, id, {:ok, %{"roots" => []}})

    assert Task.await(waiter, 30_000) == {:ok, %{"roots" => []}}
    PostStream.close(stream)

    events = collect_until(ref, @server, &(named(&1, [:client_request, :stop]) != []))
    assert [start] = named(events, [:client_request, :start])
    assert [stop] = named(events, [:client_request, :stop])

    assert elem(start, 2).method == "roots/list"
    assert elem(stop, 2).method == "roots/list"
    assert elem(stop, 2).result == :ok
    assert elem(stop, 2).telemetry_span_context == elem(start, 2).telemetry_span_context

    for {_, _, meta} <- [start, stop] do
      refute Map.has_key?(meta, :session_id)
      refute Map.has_key?(meta, :task_id)
    end
  end

  test "a method that the framework does not send gives method unknown", %{ref: ref} do
    session_id = session()

    assert Outbound.request(ctx(session_id), "x/y") == {:error, :unsupported_method}

    events = collect_until(ref, @server, &(named(&1, [:client_request, :stop]) != []))
    assert [stop] = named(events, [:client_request, :stop])
    assert elem(stop, 2).method == :unknown
    assert elem(stop, 2).result == :unsupported_method
  end

  test "a task that does not run gives result no_task", %{ref: ref} do
    session_id = session(%{"roots" => %{}})

    assert Outbound.request(Map.put(ctx(session_id), :task_id, "unknown"), "roots/list") ==
             {:error, :no_task}

    events = collect_until(ref, @server, &(named(&1, [:client_request, :stop]) != []))
    assert [stop] = named(events, [:client_request, :stop])
    assert elem(stop, 2).result == :no_task
  end

  test "a defect of the framework gives an exception event and no stop", %{ref: ref} do
    session_id = session(%{"roots" => %{}})

    assert_raise ArgumentError, fn -> Outbound.ping(ctx(session_id), timeout: 0) end

    events = collect_until(ref, @server, &(named(&1, [:client_request, :exception]) != []))
    assert [start] = named(events, [:client_request, :start])
    assert [exception] = named(events, [:client_request, :exception])
    assert [] = named(events, [:client_request, :stop])

    {_, %{duration: duration}, meta} = exception
    assert meta.method == "ping"
    assert match?(%ArgumentError{}, meta.reason)
    assert meta.stacktrace != []
    assert meta.telemetry_span_context == elem(start, 2).telemetry_span_context
    assert duration >= 0
  end

  test "a completed client task gives one client_task span and one span of each request",
       %{ref: ref} do
    session_id = session(task_capabilities())
    task = task_request_async(ctx(session_id), poll_interval: 100)

    created(session_id, "working")
    polled(session_id, "completed")
    answered(session_id, {:ok, sample_result()})

    assert Task.await(task, 30_000) == {:ok, sample_result()}

    events = collect_until(ref, @server, &(named(&1, [:client_task, :stop]) != []))
    assert [start] = named(events, [:client_task, :start])
    assert [stop] = named(events, [:client_task, :stop])

    assert elem(start, 2).method == "sampling/createMessage"
    assert elem(stop, 2).method == "sampling/createMessage"
    assert elem(stop, 2).result == :ok
    assert elem(stop, 2).telemetry_span_context == elem(start, 2).telemetry_span_context

    assert MapSet.new(Map.keys(elem(start, 2))) ==
             MapSet.new([:instance, :server, :method, :telemetry_span_context])

    assert MapSet.new(Map.keys(elem(stop, 2))) ==
             MapSet.new([:instance, :server, :method, :result, :telemetry_span_context])

    methods = events |> named([:client_request, :stop]) |> Enum.map(&elem(&1, 2).method)

    assert "sampling/createMessage" in methods
    assert "tasks/get" in methods
    assert "tasks/result" in methods
  end

  test "a cancelled client task gives result client_task_cancelled", %{ref: ref} do
    session_id = session(task_capabilities())
    task = task_request_async(ctx(session_id), poll_interval: 100)

    created(session_id, "working")
    polled(session_id, "cancelled")

    assert Task.await(task, 30_000) == {:error, {:client_task_cancelled, "c1"}}

    events = collect_until(ref, @server, &(named(&1, [:client_task, :stop]) != []))
    assert [stop] = named(events, [:client_task, :stop])
    assert elem(stop, 2).result == :client_task_cancelled

    result_calls =
      events
      |> named([:client_request, :stop])
      |> Enum.filter(&(elem(&1, 2).method == "tasks/result"))

    assert result_calls == []
  end

  test "a bad CreateTaskResult gives result invalid_response", %{ref: ref} do
    session_id = session(task_capabilities())
    task = task_request_async(ctx(session_id))

    {_, create} = Utils.receive_event(5_000)
    assert :ok = Outbound.deliver(@server, session_id, create["id"], {:ok, %{}})

    assert Task.await(task, 30_000) == {:error, {:invalid_response, %{}}}

    events = collect_until(ref, @server, &(named(&1, [:client_task, :stop]) != []))
    assert [stop] = named(events, [:client_task, :stop])
    assert elem(stop, 2).result == :invalid_response
  end

  test "a refused client task gives a client_task span with result :client_tasks_disabled",
       %{ref: ref} do
    off = Module.concat(@server, "Off")
    Utils.start_instance(@server_module, name: off)

    session_id =
      Utils.create_session(off,
        initialized: true,
        streams: [self()],
        client_capabilities: task_capabilities()
      )

    ctx = %{
      instance: off,
      server: @server_module,
      session_id: session_id,
      request_id: nil,
      principal: nil
    }

    assert {:error, :client_tasks_disabled} =
             Outbound.request_task(ctx, "sampling/createMessage", sample_params())

    events = collect_until(ref, off, &(named(&1, [:client_task, :stop]) != []))
    assert [stop] = named(events, [:client_task, :stop])
    assert elem(stop, 2).result == :client_tasks_disabled
    assert named(events, [:client_request, :start]) == []
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp task_capabilities do
    %{
      "sampling" => %{},
      "tasks" => %{"requests" => %{"sampling" => %{"createMessage" => %{}}}}
    }
  end

  defp sample_params, do: %{"messages" => [], "maxTokens" => 16}

  defp sample_result, do: %{"role" => "assistant", "content" => [], "model" => "m"}

  defp task_request_async(ctx, opts \\ []) do
    Task.async(fn ->
      Outbound.request_task(ctx, "sampling/createMessage", sample_params(), opts)
    end)
  end

  defp created(session_id, status) do
    {_, create} = Utils.receive_event(5_000)
    assert create["method"] == "sampling/createMessage"
    task = %{"taskId" => "c1", "status" => status}
    assert :ok = Outbound.deliver(@server, session_id, create["id"], {:ok, %{"task" => task}})
    create
  end

  defp polled(session_id, status) do
    {_, get} = Utils.receive_event(5_000)
    assert get["method"] == "tasks/get"
    task = %{"taskId" => "c1", "status" => status}
    assert :ok = Outbound.deliver(@server, session_id, get["id"], {:ok, task})
    get
  end

  defp answered(session_id, result) do
    {_, request} = Utils.receive_event(5_000)
    assert request["method"] == "tasks/result"
    assert :ok = Outbound.deliver(@server, session_id, request["id"], result)
    request
  end

  defp wait_pending(session_id, count \\ 1) do
    assert Utils.eventually(fn ->
             length(SessionProbe.pending_outbound_ids(@server, session_id)) == count
           end)

    SessionProbe.pending_outbound_ids(@server, session_id)
  end

  # A task whose runner blocks: the requests of the test are sent with the
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

  # The test process plays the `tasks/result` request of the task: it owns
  # a stream and attaches to the task. What the runner sends arrives as a
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

  defp stream_event(stream, timeout \\ 5_000) do
    stream_id = stream.stream_id

    receive do
      {:oz_mcp_stream, ^stream_id, {:event, _event_id, data}} ->
        {:event, data |> IO.iodata_to_binary() |> :json.decode()}
    after
      timeout -> flunk("no event received within #{timeout} ms")
    end
  end
end
