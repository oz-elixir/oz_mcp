#
# The `callback` span of `Invoke.run/3`: one `:start` before the callback
# and one `:stop` after the outcome, for each way a callback can end.
# A callback that the HTTP route runs names the entity and the
# callbacks that run outside `run/3` (a task, a roots change) give no
# span.
#
defmodule OzMcp.Handler.InvokeTelemetryTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias OzMcp.Handler.Invoke
  alias OzMcp.Sessions
  alias OzMcp.Transport.Http.Post
  alias OzMcp.Utils.Error
  alias Support.Helpers.TelemetryCapture
  alias Support.Helpers.Utils
  alias Support.Servers

  @server Servers.TasksTest
  @http_server Servers.Default

  @accept "application/json, text/event-stream"
  @parsers Plug.Parsers.init(parsers: [:json], json_decoder: {OzMcp.Wire, :decode!, []})

  # The instance of the calls of `Invoke.run/3` in this file.
  #
  defp inst, do: Module.concat(@server, __MODULE__)

  # The instance of the HTTP route in this file.
  #
  defp http_inst, do: Module.concat(@http_server, __MODULE__)

  describe "the outcome of the callback" do
    setup do
      ref = TelemetryCapture.attach()
      Utils.start_instance(@server, name: inst())
      {:ok, config} = OzMcp.Instance.config(inst())

      # The session of the requests that a cancel or the end of the
      # session stops and a session of the HTTP route.
      #
      {:ok, _} = OzMcp.Session.start(inst(), %{session_id: "s1"})
      session_id = Utils.create_session(inst(), initialized: true)

      %{ref: ref, telemetry: config.telemetry, session_id: session_id}
    end

    test "a callback that answers {:ok, value} gives result ok", %{ref: ref} do
      assert {:ok, :done} =
               Invoke.run(ctx(), fn -> {:ok, :done} end, telemetry_name: "the_tool")

      events = drain(ref, inst())
      assert [start] = named(events, :start)
      assert [stop] = named(events, :stop)

      {_, %{system_time: system_time, monotonic_time: monotonic_time}, start_meta} = start
      assert is_integer(system_time)
      assert is_integer(monotonic_time)

      assert start_meta.instance == inst()
      assert start_meta.server == @server
      assert start_meta.method == nil
      assert start_meta.name == "the_tool"
      assert is_reference(start_meta.telemetry_span_context)

      {_, %{duration: duration}, stop_meta} = stop

      assert stop_meta.result == :ok
      assert stop_meta.error_code == nil
      assert stop_meta.method == nil
      assert stop_meta.name == "the_tool"
      assert duration >= 0

      assert stop_meta.telemetry_span_context == start_meta.telemetry_span_context
    end

    test "a callback that answers an error of its own gives result error", %{ref: ref} do
      assert {:error, %Error{code: -32000}} =
               Invoke.run(ctx(), fn -> {:error, Error.new(-32000, "boom")} end)

      assert [stop] = named(drain(ref, inst()), :stop)
      meta = elem(stop, 2)

      assert meta.result == :error
      assert meta.error_code == -32000
    end

    @tag :capture_log
    test "a callback that raises gives result crashed", %{ref: ref} do
      assert {:error, %Error{code: -32603, data: nil}} =
               Invoke.run(ctx(), fn -> raise "secret details" end)

      assert [stop] = named(drain(ref, inst()), :stop)
      meta = elem(stop, 2)

      assert meta.result == :crashed
      assert meta.error_code == -32603
    end

    @tag :capture_log
    test "a slow callback that overruns the deadline gives result timeout", %{ref: ref} do
      deadline_inst = Module.concat(@server, Timeout)
      Utils.start_instance(@server, name: deadline_inst, request_timeout_ms: 50)

      assert {:error, %Error{code: -32603, data: %{"reason" => "timeout"}}} =
               Invoke.run(%{instance: deadline_inst, server: @server}, fn ->
                 Process.sleep(30_000)
               end)

      events = drain(ref, deadline_inst)
      assert [start] = named(events, :start)
      assert [stop] = named(events, :stop)
      stop_meta = elem(stop, 2)

      assert stop_meta.result == :timeout
      assert stop_meta.error_code == -32603
      assert stop_meta.telemetry_span_context == elem(start, 2).telemetry_span_context
      assert elem(stop, 1).duration >= 0
    end

    test "a callback that a cancel stops gives result cancelled", %{ref: ref} do
      parent = self()

      task =
        Task.async(fn ->
          assert :ok = Utils.open_request(inst(), "s1", 1, self())

          Invoke.run(ctx("s1", 1), fn ->
            send(parent, {:started, self()})

            receive do
              :never -> {:ok, :never}
            end
          end)
        end)

      assert_receive {:started, _runner}, 5_000
      assert Sessions.cancel(inst(), "s1", 1, "user aborted") == :ok

      assert {:error, %Error{code: -32800}} = Task.await(task, 30_000)

      events = drain(ref, inst())
      assert [start] = named(events, :start)
      assert [stop] = named(events, :stop)
      stop_meta = elem(stop, 2)

      assert stop_meta.result == :cancelled
      assert stop_meta.error_code == -32800
      assert stop_meta.telemetry_span_context == elem(start, 2).telemetry_span_context
    end

    test "the end of the session gives result session_terminated", %{ref: ref} do
      task =
        Task.async(fn ->
          assert :ok = Utils.open_request(inst(), "s1", 2, self())

          Invoke.run(ctx("s1", 2), fn -> Process.sleep(:infinity) end, session_end_error: true)
        end)

      wait_until(fn -> requests("s1") == [2] end)
      assert :ok = Sessions.terminate(inst(), "s1")

      assert {:error, %Error{code: -32000, message: "session terminated"}} =
               Task.await(task, 30_000)

      assert [stop] = named(drain(ref, inst()), :stop)
      meta = elem(stop, 2)

      assert meta.result == :session_terminated
      assert meta.error_code == -32000
    end

    @tag :capture_log
    test "each started span stops", %{ref: ref} do
      Invoke.run(ctx(), fn -> {:ok, :done} end)
      Invoke.run(ctx(), fn -> {:error, Error.new(-32000, "boom")} end)
      assert {:error, %Error{}} = Invoke.run(ctx(), fn -> raise "boom" end)

      events = drain(ref, inst())
      starts = named(events, :start)
      stops = named(events, :stop)

      assert length(starts) == length(stops)
      assert length(stops) == 3
    end

    @tag :capture_log
    test "a task augmented call runs no callback span", %{
      ref: ref,
      telemetry: telemetry,
      session_id: session_id
    } do
      conn =
        rpc_request(inst(), session_id, 3, "tools/call", telemetry, %{
          "name" => "task_immediate",
          "task" => %{}
        })

      assert conn.status == 200

      events = drain(ref, inst())

      # The route took the request and no span of a callback exists: the
      # callback of a task runs detached.
      #
      assert [%{method: "tools/call", kind: :request}] =
               Enum.map(request_stops(events), &elem(&1, 2))

      assert named(events, :start) == []
      assert named(events, :stop) == []
    end
  end

  describe "the span of a callback of the HTTP route" do
    setup do
      ref = TelemetryCapture.attach()
      Utils.start_instance(@http_server, name: http_inst())
      {:ok, config} = OzMcp.Instance.config(http_inst())
      session_id = Utils.create_session(http_inst(), initialized: true)

      %{ref: ref, telemetry: config.telemetry, session_id: session_id}
    end

    test "a tool call names the tool", %{
      ref: ref,
      telemetry: telemetry,
      session_id: session_id
    } do
      conn =
        rpc_request(http_inst(), session_id, 1, "tools/call", telemetry, %{"name" => "get_date"})

      assert conn.status == 200

      events = drain(ref, http_inst())
      assert [start] = named(events, :start)
      assert [stop] = named(events, :stop)

      {_, _, start_meta} = start
      {_, %{duration: duration}, stop_meta} = stop

      assert start_meta.instance == http_inst()
      assert start_meta.server == @http_server
      assert start_meta.method == "tools/call"
      assert start_meta.name == "get_date"

      assert stop_meta.method == "tools/call"
      assert stop_meta.name == "get_date"
      assert stop_meta.result == :ok
      assert stop_meta.error_code == nil
      assert duration >= 0

      assert stop_meta.telemetry_span_context == start_meta.telemetry_span_context
    end

    test "a read names the declared resource and no uri goes out", %{
      ref: ref,
      telemetry: telemetry,
      session_id: session_id
    } do
      conn =
        rpc_request(http_inst(), session_id, 2, "resources/read", telemetry, %{
          "uri" => "file:///marketing.md"
        })

      assert conn.status == 200

      events = drain(ref, http_inst())

      callback_events =
        Enum.filter(events, fn {name, _, _} ->
          name in [[:oz_mcp, :callback, :start], [:oz_mcp, :callback, :stop]]
        end)

      assert [start, stop] = callback_events

      assert elem(start, 2).method == "resources/read"
      assert elem(stop, 2).method == "resources/read"
      assert elem(stop, 2).result == :ok
      assert elem(stop, 2).error_code == nil

      for {_, _, meta} <- callback_events do
        assert meta.name == "marketing.md"

        for value <- Map.values(meta) do
          refute is_binary(value) and value =~ "file://"
        end
      end
    end

    @tag :capture_log
    test "a roots change notification runs no callback span", %{
      ref: ref,
      telemetry: telemetry,
      session_id: session_id
    } do
      conn =
        rpc_request(http_inst(), session_id, nil, "notifications/roots/list_changed", telemetry)

      assert conn.status == 202

      events = drain(ref, http_inst())
      assert named(events, :start) == []
      assert named(events, :stop) == []
    end
  end

  defp ctx, do: %{instance: inst(), server: @server}

  defp ctx(session_id, request_id),
    do: %{instance: inst(), server: @server, session_id: session_id, request_id: request_id}

  # The events of one instance that are in the mailbox of the test.
  #
  defp drain(ref, instance), do: TelemetryCapture.drain(ref, instance)

  # The events of one name of the callback span.
  #
  defp named(events, tail) do
    Enum.filter(events, fn {name, _, _} -> name == [:oz_mcp, :callback, tail] end)
  end

  # The `:stop` events of the request span.
  #
  defp request_stops(events) do
    Enum.filter(events, fn {name, _, _} -> name == [:oz_mcp, :request, :stop] end)
  end

  # The ids of the registered requests of a session.
  #
  defp requests(session_id) do
    case Utils.session_data(inst(), session_id) do
      nil -> []
      data -> Map.keys(data.requests)
    end
  end

  defp wait_until(fun, retries \\ 1_500) do
    if Utils.eventually(fun, retries * 10) do
      :ok
    else
      flunk("condition was not met in time")
    end
  end

  # The route runs without the plugs of the router: the instance and the
  # handle of the telemetry come from the private of the conn and the
  # parser runs as the router runs it.
  #
  defp rpc_request(instance, session_id, id, method, telemetry, params \\ %{}) do
    message =
      %{"jsonrpc" => "2.0", "params" => params}
      |> maybe_put("id", id)
      |> maybe_put("method", method)

    conn(:post, "/", :json.encode(message) |> IO.iodata_to_binary())
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", @accept)
    |> put_req_header("mcp-session-id", session_id)
    |> put_private(:instance, instance)
    |> put_private(:oz_mcp_telemetry, telemetry)
    |> parse()
    |> Post.call()
  end

  defp parse(conn), do: Plug.Parsers.call(conn, @parsers)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
