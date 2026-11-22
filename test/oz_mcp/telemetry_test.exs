defmodule OzMcp.TelemetryTest do
  use ExUnit.Case, async: true

  alias OzMcp.Telemetry

  @server SomeServer

  test "new/3 builds the full names once" do
    t = Telemetry.new(:a, @server, [:oz_mcp, :engineering])

    assert t.spans.request.stop == [:oz_mcp, :engineering, :request, :stop]
    assert t.spans.task.exception == [:oz_mcp, :engineering, :task, :exception]
    assert t.spans.client_task.stop == [:oz_mcp, :engineering, :client_task, :stop]
    assert t.points.limit_reached == [:oz_mcp, :engineering, :limit, :reached]
    assert t.points.auth_refused == [:oz_mcp, :engineering, :auth, :refused]
  end

  test "a nil handle makes each function a no-op" do
    assert Telemetry.start(nil, :request) == nil
    assert Telemetry.stop(nil, %{}) == :ok
    assert Telemetry.exception(nil, :error, :reason, []) == :ok
    assert Telemetry.event(nil, :limit_reached, %{}, %{}) == :ok
    assert Telemetry.stop_untracked(nil, :task, 0, %{}) == :ok
  end

  test "handle/1 gives nil when the instance does not run" do
    assert Telemetry.handle(:no_such_telemetry_instance) == nil
  end

  test "span/5 emits start and stop with the same span context" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:oz_mcp, :t1, :request, :start],
        [:oz_mcp, :t1, :request, :stop]
      ])

    on_exit(fn -> :telemetry.detach(ref) end)

    t = Telemetry.new(:t1_instance, @server, [:oz_mcp, :t1])

    assert :done ==
             Telemetry.span(t, :request, %{method: "ping"}, :stdio, fn ->
               {:done, %{result: :ok}}
             end)

    assert_receive {[:oz_mcp, :t1, :request, :start], ^ref, %{system_time: _, monotonic_time: _},
                    %{
                      telemetry_span_context: span,
                      instance: :t1_instance,
                      server: @server,
                      transport: :stdio,
                      method: "ping"
                    }}

    assert_receive {[:oz_mcp, :t1, :request, :stop], ^ref, %{duration: d},
                    %{
                      telemetry_span_context: ^span,
                      instance: :t1_instance,
                      server: @server,
                      transport: :stdio,
                      method: "ping",
                      result: :ok
                    }}

    assert d >= 0
  end

  test "an exception ends the span and is raised again" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:oz_mcp, :t2, :request, :start],
        [:oz_mcp, :t2, :request, :exception]
      ])

    on_exit(fn -> :telemetry.detach(ref) end)

    t = Telemetry.new(:t2_instance, @server, [:oz_mcp, :t2])

    assert_raise RuntimeError, "boom", fn ->
      Telemetry.span(t, :request, %{method: "ping"}, nil, fn -> raise "boom" end)
    end

    assert_receive {[:oz_mcp, :t2, :request, :start], ^ref, _,
                    %{telemetry_span_context: span, method: "ping"}}

    assert_receive {[:oz_mcp, :t2, :request, :exception], ^ref, %{duration: d},
                    %{
                      telemetry_span_context: ^span,
                      exception_kind: :error,
                      method: "ping",
                      reason: %RuntimeError{message: "boom"},
                      stacktrace: stacktrace
                    }}

    assert d >= 0
    assert is_list(stacktrace)
  end

  test "a nil transport adds no :transport key" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:oz_mcp, :t3, :callback, :start],
        [:oz_mcp, :t3, :callback, :stop],
        [:oz_mcp, :t3, :limit, :reached]
      ])

    on_exit(fn -> :telemetry.detach(ref) end)

    t = Telemetry.new(:t3_instance, @server, [:oz_mcp, :t3])

    Telemetry.event(t, :limit_reached, %{count: 1}, %{limit: :max_sessions})

    assert_receive {[:oz_mcp, :t3, :limit, :reached], ^ref, %{count: 1}, meta}
    refute Map.has_key?(meta, :transport)
    assert meta.instance == :t3_instance
    assert meta.server == @server
    assert meta.limit == :max_sessions

    token = Telemetry.start(t, :callback, %{method: "tools/call"})
    Telemetry.stop(token, %{result: :ok})

    assert_receive {[:oz_mcp, :t3, :callback, :start], ^ref, _, start_meta}
    assert_receive {[:oz_mcp, :t3, :callback, :stop], ^ref, _, stop_meta}
    refute Map.has_key?(start_meta, :transport)
    refute Map.has_key?(stop_meta, :transport)
  end

  test "stop_untracked/4 emits the stop event with no span context" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:oz_mcp, :t4, :task, :stop]])
    on_exit(fn -> :telemetry.detach(ref) end)

    t = Telemetry.new(:t4_instance, @server, [:oz_mcp, :t4])
    Telemetry.stop_untracked(t, :task, 123, %{status: :failed})

    assert_receive {[:oz_mcp, :t4, :task, :stop], ^ref, %{duration: 123}, meta}
    assert meta.status == :failed
    assert meta.instance == :t4_instance
    assert meta.server == @server
    refute Map.has_key?(meta, :telemetry_span_context)
    refute Map.has_key?(meta, :transport)
  end

  test "limit/5 defaults the outcome to :refused and passes :replaced through" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:oz_mcp, :t5, :limit, :reached]])
    on_exit(fn -> :telemetry.detach(ref) end)

    t = Telemetry.new(:t5_instance, @server, [:oz_mcp, :t5])

    Telemetry.limit(t, :max_sessions, 1, :instance)

    assert_receive {[:oz_mcp, :t5, :limit, :reached], ^ref, %{count: 1}, meta}
    assert meta.limit == :max_sessions
    assert meta.limit_value == 1
    assert meta.scope == :instance
    assert meta.outcome == :refused

    Telemetry.limit(t, :max_streams_per_session, 2, :session, :replaced)

    assert_receive {[:oz_mcp, :t5, :limit, :reached], ^ref, %{count: 1}, meta}
    assert meta.limit == :max_streams_per_session
    assert meta.limit_value == 2
    assert meta.scope == :session
    assert meta.outcome == :replaced
  end

  # The table has no `exception` row for `session` and `task`, so the test
  # checks the `start`, the `stop` and the points only.
  #
  test "each event name is in the telemetry guide" do
    guide = File.read!(Path.join(File.cwd!(), "guides/runtime/telemetry.md"))
    t = Telemetry.new(:guide_check, @server, [:oz_mcp])

    names = Enum.flat_map(Map.values(t.spans), &[&1.start, &1.stop]) ++ Map.values(t.points)

    for name <- names do
      assert guide =~ inspect(name), "the guide has no row for #{inspect(name)}"
    end
  end
end
